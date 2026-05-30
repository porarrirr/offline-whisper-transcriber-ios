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

    private static let endOfCentralDirectorySearchLength = 65_557
    private static let ioChunkSize = 1_024 * 1_024
    private static let inflateOutputChunkSize = 256 * 1_024

    static func extractMLModelCArchive(at archiveURL: URL, to destinationURL: URL) throws {
        let archiveHandle = try FileHandle(forReadingFrom: archiveURL)
        defer { try? archiveHandle.close() }

        let archiveSize = try archiveHandle.seekToEnd()
        let entries = try centralDirectoryEntries(in: archiveHandle, archiveSize: archiveSize)
        let fileManager = FileManager.default
        let temporaryDestination = destinationURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(destinationURL.lastPathComponent).installing-\(UUID().uuidString)")

        try? fileManager.removeItem(at: temporaryDestination)
        try fileManager.createDirectory(at: temporaryDestination, withIntermediateDirectories: true)

        do {
            for entry in entries {
                try Task.checkCancellation()
                try extract(
                    entry: entry,
                    from: archiveHandle,
                    archiveSize: archiveSize,
                    rootName: destinationURL.lastPathComponent,
                    to: temporaryDestination
                )
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
        let compressedSize: UInt64
        let uncompressedSize: UInt64
        let localHeaderOffset: UInt64
    }

    private static func centralDirectoryEntries(
        in fileHandle: FileHandle,
        archiveSize: UInt64
    ) throws -> [CentralDirectoryEntry] {
        guard archiveSize >= 22 else {
            throw ZipArchiveError.invalidArchive
        }

        let searchLength = Int(min(UInt64(endOfCentralDirectorySearchLength), archiveSize))
        try fileHandle.seek(toOffset: archiveSize - UInt64(searchLength))
        let tailData = try readData(from: fileHandle, length: searchLength)
        guard let eocdOffsetInTail = try findEndOfCentralDirectory(in: tailData) else {
            throw ZipArchiveError.invalidArchive
        }

        let entryCount = Int(try tailData.uint16(at: eocdOffsetInTail + 10))
        let centralDirectorySize = Int(try tailData.uint32(at: eocdOffsetInTail + 12))
        let centralDirectoryOffset = UInt64(try tailData.uint32(at: eocdOffsetInTail + 16))
        guard centralDirectoryOffset + UInt64(centralDirectorySize) <= archiveSize else {
            throw ZipArchiveError.invalidArchive
        }

        try fileHandle.seek(toOffset: centralDirectoryOffset)
        let centralDirectoryData = try readData(from: fileHandle, length: centralDirectorySize)
        var offset = 0
        var entries: [CentralDirectoryEntry] = []
        entries.reserveCapacity(entryCount)

        for _ in 0..<entryCount {
            guard try centralDirectoryData.uint32(at: offset) == 0x0201_4b50 else {
                throw ZipArchiveError.invalidArchive
            }

            let compressionMethod = try centralDirectoryData.uint16(at: offset + 10)
            let compressedSize = UInt64(try centralDirectoryData.uint32(at: offset + 20))
            let uncompressedSize = UInt64(try centralDirectoryData.uint32(at: offset + 24))
            let fileNameLength = Int(try centralDirectoryData.uint16(at: offset + 28))
            let extraFieldLength = Int(try centralDirectoryData.uint16(at: offset + 30))
            let commentLength = Int(try centralDirectoryData.uint16(at: offset + 32))
            let localHeaderOffset = UInt64(try centralDirectoryData.uint32(at: offset + 42))
            let fileNameStart = offset + 46
            let fileNameEnd = fileNameStart + fileNameLength

            guard centralDirectoryData.rangeIsAvailable(fileNameStart..<fileNameEnd),
                  let fileName = String(data: centralDirectoryData[fileNameStart..<fileNameEnd], encoding: .utf8) else {
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
            guard offset <= centralDirectoryData.count else {
                throw ZipArchiveError.invalidArchive
            }
        }

        return entries
    }

    private static func findEndOfCentralDirectory(in data: Data) throws -> Int? {
        guard data.count >= 22 else { return nil }
        let minimumOffset = max(0, data.count - endOfCentralDirectorySearchLength)
        for offset in stride(from: data.count - 22, through: minimumOffset, by: -1) {
            if try data.uint32(at: offset) == 0x0605_4b50 {
                return offset
            }
        }
        return nil
    }

    private static func extract(
        entry: CentralDirectoryEntry,
        from archiveHandle: FileHandle,
        archiveSize: UInt64,
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

        try archiveHandle.seek(toOffset: entry.localHeaderOffset)
        let localHeader = try readData(from: archiveHandle, length: 30)
        guard try localHeader.uint32(at: 0) == 0x0403_4b50 else {
            throw ZipArchiveError.invalidArchive
        }

        let localFileNameLength = UInt64(try localHeader.uint16(at: 26))
        let localExtraFieldLength = UInt64(try localHeader.uint16(at: 28))
        let compressedDataOffset = entry.localHeaderOffset + 30 + localFileNameLength + localExtraFieldLength
        guard compressedDataOffset + entry.compressedSize <= archiveSize else {
            throw ZipArchiveError.invalidArchive
        }

        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let writtenBytes: UInt64
        switch entry.compressionMethod {
        case 0:
            writtenBytes = try copyStoredEntry(
                from: archiveHandle,
                compressedDataOffset: compressedDataOffset,
                compressedSize: entry.compressedSize,
                to: destinationURL
            )
        case 8:
            writtenBytes = try inflateDeflatedEntry(
                from: archiveHandle,
                compressedDataOffset: compressedDataOffset,
                compressedSize: entry.compressedSize,
                to: destinationURL
            )
        default:
            throw ZipArchiveError.unsupportedCompressionMethod(entry.compressionMethod)
        }

        guard writtenBytes == entry.uncompressedSize else {
            throw ZipArchiveError.decompressionFailed
        }
    }

    private static func copyStoredEntry(
        from archiveHandle: FileHandle,
        compressedDataOffset: UInt64,
        compressedSize: UInt64,
        to destinationURL: URL
    ) throws -> UInt64 {
        try archiveHandle.seek(toOffset: compressedDataOffset)
        return try writeOutputFile(at: destinationURL) { outputHandle in
            var remainingBytes = compressedSize
            var writtenBytes: UInt64 = 0
            while remainingBytes > 0 {
                try Task.checkCancellation()
                let readLength = Int(min(UInt64(ioChunkSize), remainingBytes))
                let chunk = try readData(from: archiveHandle, length: readLength)
                try outputHandle.write(contentsOf: chunk)
                remainingBytes -= UInt64(chunk.count)
                writtenBytes += UInt64(chunk.count)
            }
            return writtenBytes
        }
    }

    private static func inflateDeflatedEntry(
        from archiveHandle: FileHandle,
        compressedDataOffset: UInt64,
        compressedSize: UInt64,
        to destinationURL: URL
    ) throws -> UInt64 {
        try archiveHandle.seek(toOffset: compressedDataOffset)
        var stream = z_stream()
        let initStatus = inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initStatus == Z_OK else {
            throw ZipArchiveError.decompressionFailed
        }
        defer { inflateEnd(&stream) }

        return try writeOutputFile(at: destinationURL) { outputHandle in
            var remainingBytes = compressedSize
            var writtenBytes: UInt64 = 0
            var reachedEndOfStream = false

            while remainingBytes > 0 && !reachedEndOfStream {
                try Task.checkCancellation()
                let readLength = Int(min(UInt64(ioChunkSize), remainingBytes))
                let inputData = try readData(from: archiveHandle, length: readLength)
                remainingBytes -= UInt64(inputData.count)

                try inputData.withUnsafeBytes { inputBuffer in
                    guard let inputBaseAddress = inputBuffer.bindMemory(to: Bytef.self).baseAddress else {
                        throw ZipArchiveError.invalidArchive
                    }
                    stream.next_in = UnsafeMutablePointer<Bytef>(mutating: inputBaseAddress)
                    stream.avail_in = uInt(inputData.count)

                    while stream.avail_in > 0 && !reachedEndOfStream {
                        var outputData = Data(count: inflateOutputChunkSize)
                        let status = outputData.withUnsafeMutableBytes { outputBuffer -> Int32 in
                            stream.next_out = outputBuffer.bindMemory(to: Bytef.self).baseAddress
                            stream.avail_out = uInt(outputBuffer.count)
                            return inflate(&stream, Z_NO_FLUSH)
                        }

                        let producedBytes = outputData.count - Int(stream.avail_out)
                        if producedBytes > 0 {
                            outputData.removeSubrange(producedBytes..<outputData.count)
                            try outputHandle.write(contentsOf: outputData)
                            writtenBytes += UInt64(producedBytes)
                        }

                        if status == Z_STREAM_END {
                            reachedEndOfStream = true
                        } else if status != Z_OK {
                            throw ZipArchiveError.decompressionFailed
                        }
                    }
                }
            }

            guard reachedEndOfStream else {
                throw ZipArchiveError.decompressionFailed
            }
            return writtenBytes
        }
    }

    private static func writeOutputFile(
        at url: URL,
        _ body: (FileHandle) throws -> UInt64
    ) throws -> UInt64 {
        _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: url)
        do {
            let writtenBytes = try body(outputHandle)
            try outputHandle.close()
            return writtenBytes
        } catch {
            try? outputHandle.close()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    private static func readData(from fileHandle: FileHandle, length: Int) throws -> Data {
        guard length >= 0,
              let data = try fileHandle.read(upToCount: length),
              data.count == length else {
            throw ZipArchiveError.invalidArchive
        }
        return data
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
}

private extension Data {
    func uint16(at offset: Int) throws -> UInt16 {
        guard rangeIsAvailable(offset..<(offset + 2)) else {
            throw ZipArchiveExtractor.ZipArchiveError.invalidArchive
        }
        return UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func uint32(at offset: Int) throws -> UInt32 {
        guard rangeIsAvailable(offset..<(offset + 4)) else {
            throw ZipArchiveExtractor.ZipArchiveError.invalidArchive
        }
        return UInt32(self[offset]) |
        (UInt32(self[offset + 1]) << 8) |
        (UInt32(self[offset + 2]) << 16) |
        (UInt32(self[offset + 3]) << 24)
    }

    func rangeIsAvailable(_ range: Range<Int>) -> Bool {
        range.lowerBound >= 0 && range.upperBound <= count
    }
}
