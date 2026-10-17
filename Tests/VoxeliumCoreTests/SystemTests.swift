import Foundation
import Testing
@testable import VoxeliumCore

@Suite struct PathTests {
    @Test func layoutIsUnderRoot() throws {
        let tmp = try TempDir()
        let p = tmp.paths
        try p.createLayout()
        #expect(FileManager.default.fileExists(atPath: p.assetObjectsDir.path))
        #expect(try p.library("com/mojang/x/1/x-1.jar").path.hasPrefix(p.librariesDir.path + "/"))
        #expect(try p.assetObject(hash: "abcdef").path.hasSuffix("objects/ab/abcdef"))
        #expect(try p.clientJar("1.20.1").path.hasSuffix("versions/1.20.1/1.20.1.jar"))
    }

    @Test(arguments: ["../etc/passwd", "/etc/passwd", "a/../../b", "~/x", "a\\b", "", "./a", "a/\0b"])
    func rejectsTraversal(_ bad: String) throws {
        let tmp = try TempDir()
        #expect(throws: PathError.self) { try tmp.paths.library(bad) }
    }

    @Test func versionIDCannotEscape() throws {
        let tmp = try TempDir()
        #expect(throws: PathError.self) { try tmp.paths.versionJSON("../../x") }
    }
}

@Suite struct SettingsTests {
    @Test func roundTrip() throws {
        let tmp = try TempDir()
        let store = SettingsStore(paths: tmp.paths)
        #expect(store.load(log: Logger()) == LauncherSettings())
        var s = LauncherSettings()
        s.selectedVersion = "1.20.1"
        s.playerName = "Alex"
        s.maxMemoryMB = 3072
        try store.save(s)
        #expect(store.load(log: Logger()) == s)
    }

    @Test func missingKeysUseDefaults() throws {
        let tmp = try TempDir()
        let store = SettingsStore(paths: tmp.paths)
        try FileManager.default.createDirectory(at: tmp.paths.configDir, withIntermediateDirectories: true)
        try Data(#"{"playerName":"Old"}"#.utf8).write(to: store.url)
        let s = store.load(log: Logger())
        #expect(s.playerName == "Old")
        #expect(s.maxMemoryMB == LauncherSettings().maxMemoryMB)
    }

    @Test func corruptFileIsMovedAside() throws {
        let tmp = try TempDir()
        let store = SettingsStore(paths: tmp.paths)
        try FileManager.default.createDirectory(at: tmp.paths.configDir, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: store.url)
        let log = Logger()
        #expect(store.load(log: log) == LauncherSettings())
        #expect(FileManager.default.fileExists(atPath: store.url.path + ".corrupt"))
        #expect(log.snapshot.contains { $0.level == .error && $0.category == "settings" })
    }
}

@Suite struct RuntimeTests {
    func makeRuntime(_ root: URL, _ name: String, release: String, libjvm: Bool = false) throws {
        let home = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("lib/server"), withIntermediateDirectories: true)
        try Data(release.utf8).write(to: home.appendingPathComponent("release"))
        if libjvm { try Data().write(to: home.appendingPathComponent("lib/server/libjvm.dylib")) }
    }

    @Test func discoversRuntimes() throws {
        let tmp = try TempDir()
        let dir = tmp.paths.runtimesDir
        try makeRuntime(dir, "jre-17", release: "JAVA_VERSION=\"17.0.10\"\nOS_NAME=\"Darwin\"\nOS_ARCH=\"aarch64\"\n", libjvm: true)
        try makeRuntime(dir, "jre-8", release: "JAVA_VERSION=\"1.8.0_402\"\n")
        try makeRuntime(dir, "jre-21", release: "JAVA_VERSION=\"21\"\n")
        try makeRuntime(dir, "broken", release: "NOTHING=1\n")
        let cat = RuntimeCatalog(directory: dir)
        let found = cat.discover()
        #expect(found.map(\.majorVersion).sorted() == [8, 17, 21])
        let j17 = try #require(found.first { $0.majorVersion == 17 })
        #expect(j17.osArch == "aarch64")
        #expect(j17.libjvm != nil)
        #expect(cat.best(forMajor: 17, in: found)?.name == "jre-17")
        #expect(cat.best(forMajor: 16, in: found)?.name == "jre-17")
        #expect(cat.best(forMajor: 25, in: found) == nil)
    }

    @Test func discoverOnMissingDirectoryIsEmpty() throws {
        let tmp = try TempDir()
        #expect(RuntimeCatalog(directory: tmp.url.appendingPathComponent("nope")).discover().isEmpty)
    }

    @Test func majorVersionParsing() {
        #expect(RuntimeCatalog.majorVersion("1.8.0_402") == 8)
        #expect(RuntimeCatalog.majorVersion("17.0.10") == 17)
        #expect(RuntimeCatalog.majorVersion("25") == 25)
        #expect(RuntimeCatalog.majorVersion("abc") == nil)
    }
}

@Suite struct MachOTests {
    /// Builds a minimal thin 64-bit Mach-O header with one LC_BUILD_VERSION.
    func header(cpu: UInt32, sub: UInt32 = 0, platform: UInt32) -> Data {
        var d = Data()
        func le(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        le(0xfeedfacf); le(cpu); le(sub); le(6 /* MH_DYLIB */); le(1); le(24); le(0); le(0)
        le(0x32); le(24); le(platform); le(0); le(0); le(0)
        return d
    }

    @Test func detectsIOSArm64() throws {
        let s = try MachO.slices(of: header(cpu: 0x0100000c, platform: 2))
        #expect(s == [MachO.Slice(cpu: .arm64, platform: .iOS, fileType: 6)])
        #expect(MachO.isLoadableOnIOSDevice(s))
    }

    @Test func rejectsMacAndSimulator() throws {
        #expect(!MachO.isLoadableOnIOSDevice(try MachO.slices(of: header(cpu: 0x0100000c, platform: 1))))
        #expect(!MachO.isLoadableOnIOSDevice(try MachO.slices(of: header(cpu: 0x0100000c, platform: 7))))
        #expect(!MachO.isLoadableOnIOSDevice(try MachO.slices(of: header(cpu: 0x01000007, platform: 2))))
    }

    @Test func parsesFatBinary() throws {
        let a = header(cpu: 0x01000007, platform: 1), b = header(cpu: 0x0100000c, platform: 2)
        var d = Data()
        func be(_ v: UInt32) { withUnsafeBytes(of: v.bigEndian) { d.append(contentsOf: $0) } }
        be(0xcafebabe); be(2)
        let off1: UInt32 = 64, off2 = off1 + UInt32(a.count)
        be(0x01000007); be(3); be(off1); be(UInt32(a.count)); be(0)
        be(0x0100000c); be(0); be(off2); be(UInt32(b.count)); be(0)
        d.append(Data(count: Int(off1) - d.count))
        d.append(a); d.append(b)
        let s = try MachO.slices(of: d)
        #expect(s.map(\.cpu) == [.x86_64, .arm64])
        #expect(MachO.isLoadableOnIOSDevice(s))
    }

    @Test func realBinaryOnThisMac() throws {
        // The running test binary is a real arm64 macOS Mach-O.
        let exe = try #require(Bundle.main.executableURL)
        let s = try MachO.slices(of: exe)
        #expect(s.contains { $0.platform == .macOS })
        #expect(!MachO.isLoadableOnIOSDevice(s))
    }

    @Test func rejectsNonMachO() {
        #expect(throws: MachO.ParseError.notMachO) { try MachO.slices(of: Data(repeating: 0x41, count: 64)) }
        #expect(throws: MachO.ParseError.truncated) { try MachO.slices(of: Data([1, 2])) }
    }
}

@Suite struct LoggerTests {
    @Test func writesToFileAndRespectsLevel() throws {
        let tmp = try TempDir()
        let log = Logger(maxEntries: 2)
        let file = tmp.url.appendingPathComponent("logs/launcher.log")
        try log.attachFile(file)
        log.minimumLevel = .info
        log.debug("t", "hidden")
        log.info("t", "one")
        log.warning("t", "two")
        log.error("t", "three")
        #expect(log.snapshot.map(\.message) == ["two", "three"])
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains("[INFO] t: one"))
        #expect(!text.contains("hidden"))
    }
}
