import Compression
import Foundation

enum ZipMemoryError: Error {
    case malformed
    case tooLarge
    case unsupported
}

/// Reads ZIP entries into memory. Does not write archive contents onto user paths.
enum ZipMemory {
    static func entryNames(in data: Data) throws -> [String] {
        try centralDirectory(in: data).map(\.name)
    }

    static func data(named name: String, in archive: Data) throws -> Data {
        guard let header = try centralDirectory(in: archive).first(where: { $0.name == name }) else {
            throw ZipMemoryError.malformed
        }
        return try inflate(header, archive: archive)
    }

    static func entries(in archive: Data, matching predicate: (String) -> Bool) throws -> [(name: String, data: Data)] {
        let headers = try centralDirectory(in: archive)
        if headers.count > AttachmentLimits.maxZipEntries { throw ZipMemoryError.tooLarge }
        return try headers.filter { predicate($0.name) }.map { header in
            (header.name, try inflate(header, archive: archive))
        }
    }

    private struct Header {
        var name: String
        var compression: UInt16
        var compressedSize: Int
        var uncompressedSize: Int
        var localOffset: Int
    }

    private static func centralDirectory(in data: Data) throws -> [Header] {
        guard let eocd = eocdOffset(in: data) else { throw ZipMemoryError.malformed }
        let count = int(data, eocd + 10, 2)
        let size = int(data, eocd + 12, 4)
        let start = int(data, eocd + 16, 4)
        if count > AttachmentLimits.maxZipEntries || size > AttachmentLimits.maxZipEntryBytes {
            throw ZipMemoryError.tooLarge
        }
        var offset = start
        var headers: [Header] = []
        for _ in 0..<count {
            guard offset + 46 <= data.count, int(data, offset, 4) == 0x02014b50 else {
                throw ZipMemoryError.malformed
            }
            let compression = UInt16(int(data, offset + 10, 2))
            let compressed = int(data, offset + 20, 4)
            let uncompressed = int(data, offset + 24, 4)
            let nameLength = int(data, offset + 28, 2)
            let extra = int(data, offset + 30, 2)
            let comment = int(data, offset + 32, 2)
            let local = int(data, offset + 42, 4)
            let nameStart = offset + 46
            let nameEnd = nameStart + nameLength
            guard nameEnd <= data.count else { throw ZipMemoryError.malformed }
            let name = String(data: data[nameStart..<nameEnd], encoding: .utf8) ?? ""
            headers.append(
                Header(
                    name: name,
                    compression: compression,
                    compressedSize: compressed,
                    uncompressedSize: uncompressed,
                    localOffset: local
                )
            )
            offset = nameEnd + extra + comment
        }
        return headers
    }

    private static func inflate(_ header: Header, archive: Data) throws -> Data {
        if header.uncompressedSize > AttachmentLimits.maxZipEntryBytes {
            throw ZipMemoryError.tooLarge
        }
        guard header.localOffset + 30 <= archive.count, int(archive, header.localOffset, 4) == 0x04034b50 else {
            throw ZipMemoryError.malformed
        }
        let nameLength = int(archive, header.localOffset + 26, 2)
        let extra = int(archive, header.localOffset + 28, 2)
        let dataStart = header.localOffset + 30 + nameLength + extra
        let dataEnd = dataStart + header.compressedSize
        guard dataEnd <= archive.count else { throw ZipMemoryError.malformed }
        let payload = archive[dataStart..<dataEnd]
        switch header.compression {
        case 0:
            return Data(payload)
        case 8:
            return try inflateRaw(Data(payload), uncompressedSize: header.uncompressedSize)
        default:
            throw ZipMemoryError.unsupported
        }
    }

    private static func inflateRaw(_ data: Data, uncompressedSize: Int) throws -> Data {
        guard uncompressedSize > 0 else { return Data() }
        var destination = Data(count: uncompressedSize)
        let written = destination.withUnsafeMutableBytes { dest in
            data.withUnsafeBytes { source in
                compression_decode_buffer(
                    dest.bindMemory(to: UInt8.self).baseAddress!,
                    uncompressedSize,
                    source.bindMemory(to: UInt8.self).baseAddress!,
                    data.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard written == uncompressedSize else { throw ZipMemoryError.malformed }
        return destination
    }

    private static func eocdOffset(in data: Data) -> Int? {
        let maxComment = min(data.count, 22 + 0xFFFF)
        guard data.count >= 22 else { return nil }
        let start = data.count - 22
        let end = data.count - maxComment
        var offset = start
        while offset >= end {
            if int(data, offset, 4) == 0x06054b50 { return offset }
            offset -= 1
        }
        return nil
    }

    private static func int(_ data: Data, _ offset: Int, _ count: Int) -> Int {
        guard offset >= 0, offset + count <= data.count else { return 0 }
        var value = 0
        for index in 0..<count {
            value |= Int(data[offset + index]) << (8 * index)
        }
        return value
    }
}
