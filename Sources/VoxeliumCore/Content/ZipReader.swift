import Compression
import Foundation

/// A minimal read-only ZIP reader (enough for mod jars and resource/shader packs):
/// the central directory, plus entries that are stored (method 0) or deflated
/// (method 8, through Apple's Compression framework). No ZIP64, no encryption.
public struct ZipReader: Sendable {
    public struct Entry: Sendable, Equatable {
        public let name: String
        let method: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    public enum ZipError: Error, Equatable {
        case notAZip
        case unsupported(String)
        case corrupt(String)
    }

    let data: Data
    public let entries: [Entry]

    public init(url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .mappedIfSafe))
    }

    public init(data: Data) throws {
        self.data = data
        self.entries = try Self.readCentralDirectory(data)
    }

    public func entry(named name: String) -> Entry? { entries.first { $0.name == name } }

    /// The uncompressed bytes of `name`, or nil if there is no such entry.
    /// Entries larger than `limit` are refused (metadata files are small).
    public func read(_ name: String, limit: Int = 4 << 20) throws -> Data? {
        guard let e = entry(named: name) else { return nil }
        guard e.uncompressedSize <= limit else { throw ZipError.unsupported("\(name) is too large") }
        let lh = e.localHeaderOffset
        guard lh + 30 <= data.count, data.u32(lh) == 0x04034b50 else { throw ZipError.corrupt("local header of \(name)") }
        let start = lh + 30 + Int(data.u16(lh + 26)) + Int(data.u16(lh + 28))
        guard start + e.compressedSize <= data.count else { throw ZipError.corrupt("data of \(name)") }
        let raw = data.subdata(in: start ..< start + e.compressedSize)
        switch e.method {
        case 0: return raw
        case 8: return try Self.inflate(raw, size: e.uncompressedSize)
        default: throw ZipError.unsupported("compression method \(e.method)")
        }
    }

    static func readCentralDirectory(_ d: Data) throws -> [Entry] {
        // End of central directory: last 22 bytes plus up to 64 KiB of comment.
        guard d.count >= 22 else { throw ZipError.notAZip }
        var eocd = -1
        var i = d.count - 22
        let floor = max(0, d.count - 22 - 0xFFFF)
        while i >= floor {
            if d.u32(i) == 0x06054b50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipError.notAZip }
        let count = Int(d.u16(eocd + 10))
        let cdOffset = Int(d.u32(eocd + 16))
        if count == 0xFFFF || cdOffset == 0xFFFF_FFFF { throw ZipError.unsupported("ZIP64") }
        var entries: [Entry] = []
        entries.reserveCapacity(count)
        var p = cdOffset
        for _ in 0 ..< count {
            guard p + 46 <= d.count, d.u32(p) == 0x02014b50 else { throw ZipError.corrupt("central directory") }
            let method = d.u16(p + 10)
            let csize = Int(d.u32(p + 20)), usize = Int(d.u32(p + 24))
            let nameLen = Int(d.u16(p + 28)), extraLen = Int(d.u16(p + 30)), commentLen = Int(d.u16(p + 32))
            let offset = Int(d.u32(p + 42))
            guard p + 46 + nameLen <= d.count else { throw ZipError.corrupt("entry name") }
            let name = String(decoding: d.subdata(in: p + 46 ..< p + 46 + nameLen), as: UTF8.self)
            entries.append(Entry(name: name, method: method, compressedSize: csize, uncompressedSize: usize, localHeaderOffset: offset))
            p += 46 + nameLen + extraLen + commentLen
        }
        return entries
    }

    static func inflate(_ input: Data, size: Int) throws -> Data {
        if size == 0 { return Data() }
        var out = Data(count: size)
        let written = out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
            input.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                // COMPRESSION_ZLIB is raw DEFLATE (RFC 1951), which is what ZIP stores.
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, size,
                                          src.bindMemory(to: UInt8.self).baseAddress!, input.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        guard written == size else { throw ZipError.corrupt("deflate stream (\(written) of \(size) bytes)") }
        return out
    }
}

private extension Data {
    func u16(_ o: Int) -> UInt16 {
        guard o + 2 <= count else { return 0 }
        return UInt16(self[startIndex + o]) | UInt16(self[startIndex + o + 1]) << 8
    }
    func u32(_ o: Int) -> UInt32 {
        guard o + 4 <= count else { return 0 }
        return UInt32(u16(o)) | UInt32(u16(o + 2)) << 16
    }
}
