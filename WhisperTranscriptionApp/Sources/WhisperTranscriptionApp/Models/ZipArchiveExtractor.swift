import Foundation
import zlib

enum ZipArchiveExtractor {
    enum ZipArchiveError: LocalizedError {
        case invalidArchive
        case unsupportedCompressionMethod(UInt16)
        case unsafePath(String)
        case decompressionFailed

        var errorDescription: String? {
            switch self {
            case .invalidArchive:
                return String(localized: "Core ML encoder archive is invalid.")
            case .unsupportedCompressionMethod(let method):
                return String(localized: "Core ML encoder archive uses unsupported compression method \(method).")
            case .unsafePath(let path):
                return String(localized: "Core ML encoder archive contains an unsafe path: \(path)")
            case .decompressionFailed:
                return String(localized: "Failed to decompress Core ML encoder archive.")
            }
        }
    }

    static func extractMLModelCArchive(at archiveURL: URL, to destinationURL: URL) throws {
        let archiveData = try Data(contentsOf: archiveURL)
        let entries = try centralDirectoryEntries(in: archiveData)
        let fileManager = FileManager.default
        let temporaryDestination = destinationURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(destinationURL.lastPathComponent).installing-\(UUID().uuidString)")

        try? fileManager.removeItem(at: temporaryDestination)
        try fileManager.createDirectory(at: temporaryDestination, withIntermediateDirectories: true)

        do {
            for entry in entries {
                try extract(entry: entry, from: archiveData, rootName: destinationURL.lastPathComponent, to: temporaryDestination)
            }

            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.moveItem(at: temporaryDestination, to: destinationURL)
        } catch {
            try? fileManager.removeItem(at: temporaryDestination)
            throw error
        }
    }

    private struct CentralDirectoryEntry {
        let fileName: String
        let compressionMethod: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    private static func centralDirectoryEntries(in data: Data) throws -> [CentralDirectoryEntry] {
        guard let endOfCentralDirectoryOffset = findEndOfCentralDirectory(in: data) else {
            throw ZipArchiveError.invalidArchive
        }

        let entryCount = Int(data.uint16(at: endOfCentralDirectoryOffset + 10))
        let centralDirectoryOffset = Int(data.uint32(at: endOfCentralDirectoryOffset + 16))
        var offset = centralDirectoryOffset
        var entries: [CentralDirectoryEntry] = []
        entries.reserveCapacity(entryCount)

        for _ in 0..<entryCount {
            guard data.uint32(at: offset) == 0x0201_4b50 else {
                throw ZipArchiveError.invalidArchive
            }

            let compressionMethod = data.uint16(at: offset + 10)
            let compressedSize = Int(data.uint32(at: offset + 20))
            let uncompressedSize = Int(data.uint32(at: offset + 24))
            let fileNameLength = Int(data.uint16(at: offset + 28))
            let extraFieldLength = Int(data.uint16(at: offset + 30))
            let commentLength = Int(data.uint16(at: offset + 32))
            let localHeaderOffset = Int(data.uint32(at: offset + 42))
            let fileNameStart = offset + 46
            let fileNameEnd = fileNameStart + fileNameLength

            guard fileNameEnd <= data.count,
                  let fileName = String(data: data[fileNameStart..<fileNameEnd], encoding: .utf8) else {
                throw ZipArchiveError.invalidArchive
            }

            entries.append(CentralDirectoryEntry(
                fileName: fileName,
                compressionMethod: compressionMethod,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                localHeaderOffset: localHeaderOffset
            ))

            offset = fileNameEnd + extraFieldLength + commentLength
        }

        return entries
    }

    private static func findEndOfCentralDirectory(in data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        let minimumOffset = max(0, data.count - 65_557)
        var offset = data.count - 22

        while offset >= minimumOffset {
            if data.uint32(at: offset) == 0x0605_4b50 {
                return offset
            }
            offset -= 1
        }

        return nil
    }

    private static func extract(
        entry: CentralDirectoryEntry,
        from archiveData: Data,
        rootName: String,
        to destinationRoot: URL
    ) throws {
        guard let relativePath = try normalizedRelativePath(entry.fileName, rootName: rootName) else {
            return
        }

        let destinationURL = destinationRoot.appendingPathComponent(relativePath)
        if entry.fileName.hasSuffix("/") {
            try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
            return
        }

        let localHeaderOffset = entry.localHeaderOffset
        guard archiveData.uint32(at: localHeaderOffset) == 0x0403_4b50 else {
            throw ZipArchiveError.invalidArchive
        }

        let localFileNameLength = Int(archiveData.uint16(at: localHeaderOffset + 26))
        let localExtraFieldLength = Int(archiveData.uint16(at: localHeaderOffset + 28))
        let compressedDataStart = localHeaderOffset + 30 + localFileNameLength + localExtraFieldLength
        let compressedDataEnd = compressedDataStart + entry.compressedSize
        guard compressedDataEnd <= archiveData.count else {
            throw ZipArchiveError.invalidArchive
        }

        let outputData: Data
        let compressedData = archiveData[compressedDataStart..<compressedDataEnd]
        switch entry.compressionMethod {
        case 0:
            outputData = Data(compressedData)
        case 8:
            outputData = try inflateRawDeflate(compressedData, uncompressedSize: entry.uncompressedSize)
        default:
            throw ZipArchiveError.unsupportedCompressionMethod(entry.compressionMethod)
        }

        try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try outputData.write(to: destinationURL, options: .atomic)
    }

    private static func normalizedRelativePath(_ path: String, rootName: String) throws -> String? {
        let components = path.split(separator: "/").map(String.init)
        let shouldStripArchiveRoot = components.first == rootName || components.first?.hasSuffix(".mlmodelc") == true
        let strippedComponents = shouldStripArchiveRoot ? Array(components.dropFirst()) : components

        guard !strippedComponents.isEmpty else { return nil }
        guard strippedComponents.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !path.hasPrefix("/") else {
            throw ZipArchiveError.unsafePath(path)
        }
        return strippedComponents.joined(separator: "/")
    }

    private static func inflateRawDeflate(_ compressedData: Data.SubSequence, uncompressedSize: Int) throws -> Data {
        guard uncompressedSize >= 0 else {
            throw ZipArchiveError.invalidArchive
        }
        guard uncompressedSize > 0 else {
            return Data()
        }

        var output = Data(count: uncompressedSize)
        let result = compressedData.withUnsafeBytes { compressedBuffer in
            output.withUnsafeMutableBytes { outputBuffer in
                var stream = z_stream()
                stream.next_in = UnsafeMutablePointer<Bytef>(mutating: compressedBuffer.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(compressedBuffer.count)
                stream.next_out = outputBuffer.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(outputBuffer.count)

                let initStatus = inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
                guard initStatus == Z_OK else {
                    return initStatus
                }
                defer { inflateEnd(&stream) }

                return inflate(&stream, Z_FINISH)
            }
        }

        guard result == Z_STREAM_END else {
            throw ZipArchiveError.decompressionFailed
        }

        return output
    }
}

private extension Data {
    func uint16(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func uint32(at offset: Int) -> UInt32 {
        UInt32(self[offset]) |
        (UInt32(self[offset + 1]) << 8) |
        (UInt32(self[offset + 2]) << 16) |
        (UInt32(self[offset + 3]) << 24)
    }
}
