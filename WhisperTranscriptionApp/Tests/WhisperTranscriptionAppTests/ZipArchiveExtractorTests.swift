import Foundation
import XCTest
@testable import WhisperTranscriptionApp

final class ZipArchiveExtractorTests: XCTestCase {
    func testExtractDeflatedArchiveStripsMLModelCRootDirectory() throws {
        let directory = try makeTemporaryDirectory()
        let archiveURL = directory.appendingPathComponent("encoder.zip")
        let destinationURL = directory.appendingPathComponent("ggml-tiny-encoder.mlmodelc", isDirectory: true)
        let expectedData = Data("compiled model data".utf8)
        let compressedData = Data([
            0x4b, 0xce, 0xcf, 0x2d, 0xc8, 0xcc, 0x49, 0x4d,
            0x51, 0xc8, 0xcd, 0x4f, 0x49, 0xcd, 0x51, 0x48,
            0x49, 0x2c, 0x49, 0x04, 0x00
        ])
        let archive = makeZipData(entries: [
            ZipEntry(
                path: "ggml-tiny-encoder.mlmodelc/coremldata.bin",
                compressionMethod: 8,
                compressedData: compressedData,
                uncompressedSize: expectedData.count
            )
        ])
        try archive.write(to: archiveURL)

        try ZipArchiveExtractor.extractMLModelCArchive(at: archiveURL, to: destinationURL)

        let extractedURL = destinationURL.appendingPathComponent("coremldata.bin")
        XCTAssertEqual(try Data(contentsOf: extractedURL), expectedData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationURL.appendingPathComponent("ggml-tiny-encoder.mlmodelc").path))
    }

    func testExtractStoredArchiveCreatesNestedFiles() throws {
        let directory = try makeTemporaryDirectory()
        let archiveURL = directory.appendingPathComponent("encoder.zip")
        let destinationURL = directory.appendingPathComponent("Encoder.mlmodelc", isDirectory: true)
        let expectedData = Data("metadata".utf8)
        let archive = makeZipData(entries: [
            .stored(path: "metadata/Info.plist", data: expectedData)
        ])
        try archive.write(to: archiveURL)

        try ZipArchiveExtractor.extractMLModelCArchive(at: archiveURL, to: destinationURL)

        XCTAssertEqual(
            try Data(contentsOf: destinationURL.appendingPathComponent("metadata/Info.plist")),
            expectedData
        )
    }

    func testUnsafeRelativePathThrowsAndRemovesTemporaryDestination() throws {
        let directory = try makeTemporaryDirectory()
        let archiveURL = directory.appendingPathComponent("unsafe.zip")
        let destinationURL = directory.appendingPathComponent("Unsafe.mlmodelc", isDirectory: true)
        let archive = makeZipData(entries: [
            .stored(path: "../escape.txt", data: Data("owned".utf8))
        ])
        try archive.write(to: archiveURL)

        XCTAssertThrowsError(try ZipArchiveExtractor.extractMLModelCArchive(at: archiveURL, to: destinationURL)) { error in
            guard case ZipArchiveExtractor.ZipArchiveError.unsafePath(let path) = error else {
                XCTFail("Expected unsafePath, got \(error)")
                return
            }
            XCTAssertEqual(path, "../escape.txt")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("escape.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationURL.path))
    }

    func testUnsupportedCompressionMethodThrowsBeforeWritingDestination() throws {
        let directory = try makeTemporaryDirectory()
        let archiveURL = directory.appendingPathComponent("unsupported.zip")
        let destinationURL = directory.appendingPathComponent("Unsupported.mlmodelc", isDirectory: true)
        let archive = makeZipData(entries: [
            ZipEntry(
                path: "weights.bin",
                compressionMethod: 99,
                compressedData: Data([0x01, 0x02, 0x03]),
                uncompressedSize: 3
            )
        ])
        try archive.write(to: archiveURL)

        XCTAssertThrowsError(try ZipArchiveExtractor.extractMLModelCArchive(at: archiveURL, to: destinationURL)) { error in
            guard case ZipArchiveExtractor.ZipArchiveError.unsupportedCompressionMethod(let method) = error else {
                XCTFail("Expected unsupportedCompressionMethod, got \(error)")
                return
            }
            XCTAssertEqual(method, 99)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationURL.path))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperZipTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private struct ZipEntry {
        let path: String
        let compressionMethod: UInt16
        let compressedData: Data
        let uncompressedSize: Int

        static func stored(path: String, data: Data) -> ZipEntry {
            ZipEntry(path: path, compressionMethod: 0, compressedData: data, uncompressedSize: data.count)
        }
    }

    private func makeZipData(entries: [ZipEntry]) -> Data {
        var localData = Data()
        var centralDirectory = Data()

        for entry in entries {
            let localHeaderOffset = UInt32(localData.count)
            let fileNameData = Data(entry.path.utf8)

            localData.appendUInt32LE(0x0403_4b50)
            localData.appendUInt16LE(20)
            localData.appendUInt16LE(0)
            localData.appendUInt16LE(entry.compressionMethod)
            localData.appendUInt16LE(0)
            localData.appendUInt16LE(0)
            localData.appendUInt32LE(0)
            localData.appendUInt32LE(UInt32(entry.compressedData.count))
            localData.appendUInt32LE(UInt32(entry.uncompressedSize))
            localData.appendUInt16LE(UInt16(fileNameData.count))
            localData.appendUInt16LE(0)
            localData.append(fileNameData)
            localData.append(entry.compressedData)

            centralDirectory.appendUInt32LE(0x0201_4b50)
            centralDirectory.appendUInt16LE(20)
            centralDirectory.appendUInt16LE(20)
            centralDirectory.appendUInt16LE(0)
            centralDirectory.appendUInt16LE(entry.compressionMethod)
            centralDirectory.appendUInt16LE(0)
            centralDirectory.appendUInt16LE(0)
            centralDirectory.appendUInt32LE(0)
            centralDirectory.appendUInt32LE(UInt32(entry.compressedData.count))
            centralDirectory.appendUInt32LE(UInt32(entry.uncompressedSize))
            centralDirectory.appendUInt16LE(UInt16(fileNameData.count))
            centralDirectory.appendUInt16LE(0)
            centralDirectory.appendUInt16LE(0)
            centralDirectory.appendUInt16LE(0)
            centralDirectory.appendUInt16LE(0)
            centralDirectory.appendUInt32LE(0)
            centralDirectory.appendUInt32LE(localHeaderOffset)
            centralDirectory.append(fileNameData)
        }

        var archive = localData
        let centralDirectoryOffset = UInt32(archive.count)
        archive.append(centralDirectory)
        archive.appendUInt32LE(0x0605_4b50)
        archive.appendUInt16LE(0)
        archive.appendUInt16LE(0)
        archive.appendUInt16LE(UInt16(entries.count))
        archive.appendUInt16LE(UInt16(entries.count))
        archive.appendUInt32LE(UInt32(centralDirectory.count))
        archive.appendUInt32LE(centralDirectoryOffset)
        archive.appendUInt16LE(0)
        return archive
    }
}

private extension Data {
    mutating func appendUInt16LE(_ value: UInt16) {
        append(contentsOf: [
            UInt8(value & 0x00ff),
            UInt8((value >> 8) & 0x00ff)
        ])
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        append(contentsOf: [
            UInt8(value & 0x0000_00ff),
            UInt8((value >> 8) & 0x0000_00ff),
            UInt8((value >> 16) & 0x0000_00ff),
            UInt8((value >> 24) & 0x0000_00ff)
        ])
    }
}
