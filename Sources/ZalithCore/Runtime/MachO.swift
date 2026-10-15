import Foundation

/// Minimal Mach-O header reader used to check that bundled native libraries
/// (JRE dylibs, LWJGL natives, GL layers) are built for iOS arm64 before we
/// try to load them. Reads only the headers; does not validate signatures.
public enum MachO {
    public enum CPU: Equatable, Sendable {
        case arm64, arm64e, x86_64, other(Int32)
    }

    /// LC_BUILD_VERSION platform values (mach-o/loader.h).
    public enum Platform: UInt32, Sendable {
        case macOS = 1, iOS = 2, tvOS = 3, watchOS = 4, bridgeOS = 5, macCatalyst = 6
        case iOSSimulator = 7, tvOSSimulator = 8, watchOSSimulator = 9, driverKit = 10, visionOS = 11, visionOSSimulator = 12
    }

    public struct Slice: Equatable, Sendable {
        public let cpu: CPU
        /// nil when there is no LC_BUILD_VERSION (older LC_VERSION_MIN_* binaries)
        /// or the value is unknown.
        public let platform: Platform?
        public let fileType: UInt32
    }

    public enum ParseError: Error, Equatable { case notMachO, truncated }

    static let MH_MAGIC_64: UInt32 = 0xfeedfacf
    static let FAT_MAGIC: UInt32 = 0xcafebabe
    static let FAT_MAGIC_64: UInt32 = 0xcafebabf
    static let LC_BUILD_VERSION: UInt32 = 0x32
    static let LC_VERSION_MIN_IPHONEOS: UInt32 = 0x25
    static let LC_VERSION_MIN_MACOSX: UInt32 = 0x24

    public static func slices(of url: URL) throws -> [Slice] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        // Headers + load commands fit well within this for real binaries.
        let data = try handle.read(upToCount: 1 << 20) ?? Data()
        return try slices(of: data)
    }

    public static func slices(of data: Data) throws -> [Slice] {
        guard data.count >= 8 else { throw ParseError.truncated }
        let magicBE = data.u32(0, bigEndian: true)
        if magicBE == FAT_MAGIC || magicBE == FAT_MAGIC_64 {
            let is64 = magicBE == FAT_MAGIC_64
            let count = Int(data.u32(4, bigEndian: true))
            let archSize = is64 ? 32 : 20
            var result: [Slice] = []
            for i in 0..<count {
                let base = 8 + i * archSize
                guard base + archSize <= data.count else { throw ParseError.truncated }
                let offset = is64 ? Int(data.u64(base + 8, bigEndian: true)) : Int(data.u32(base + 8, bigEndian: true))
                guard offset < data.count else {
                    // Slice body beyond the read window: report CPU only.
                    result.append(Slice(cpu: cpu(Int32(bitPattern: data.u32(base, bigEndian: true)), sub: data.u32(base + 4, bigEndian: true)), platform: nil, fileType: 0))
                    continue
                }
                result.append(try thin(data.subdata(in: offset..<data.count)))
            }
            return result
        }
        return [try thin(data)]
    }

    static func thin(_ d: Data) throws -> Slice {
        guard d.count >= 32 else { throw ParseError.truncated }
        guard d.u32(0, bigEndian: false) == MH_MAGIC_64 else { throw ParseError.notMachO }
        let cpuType = Int32(bitPattern: d.u32(4, bigEndian: false))
        let sub = d.u32(8, bigEndian: false)
        let fileType = d.u32(12, bigEndian: false)
        let ncmds = Int(d.u32(16, bigEndian: false))
        var offset = 32
        var platform: Platform?
        for _ in 0..<ncmds {
            guard offset + 8 <= d.count else { break }
            let cmd = d.u32(offset, bigEndian: false)
            let size = Int(d.u32(offset + 4, bigEndian: false))
            if cmd == LC_BUILD_VERSION, offset + 12 <= d.count {
                platform = Platform(rawValue: d.u32(offset + 8, bigEndian: false))
                break
            } else if cmd == LC_VERSION_MIN_IPHONEOS {
                platform = .iOS
            } else if cmd == LC_VERSION_MIN_MACOSX {
                platform = .macOS
            }
            guard size > 0 else { break }
            offset += size
        }
        return Slice(cpu: cpu(cpuType, sub: sub), platform: platform, fileType: fileType)
    }

    static func cpu(_ type: Int32, sub: UInt32) -> CPU {
        switch type {
        case 0x0100000c: (sub & 0x00ffffff) == 2 ? .arm64e : .arm64
        case 0x01000007: .x86_64
        default: .other(type)
        }
    }

    /// True if some slice can load on an iOS arm64 device.
    public static func isLoadableOnIOSDevice(_ slices: [Slice]) -> Bool {
        slices.contains { ($0.cpu == .arm64 || $0.cpu == .arm64e) && $0.platform == .iOS }
    }
}

extension Data {
    func u32(_ at: Int, bigEndian: Bool) -> UInt32 {
        var v: UInt32 = 0
        for i in 0..<4 { v |= UInt32(self[startIndex + at + i]) << (bigEndian ? (24 - 8 * i) : (8 * i)) }
        return v
    }

    func u64(_ at: Int, bigEndian: Bool) -> UInt64 {
        let hi = UInt64(u32(at, bigEndian: bigEndian)), lo = UInt64(u32(at + 4, bigEndian: bigEndian))
        return bigEndian ? (hi << 32 | lo) : (lo << 32 | hi)
    }
}
