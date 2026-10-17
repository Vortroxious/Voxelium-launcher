import Foundation
import VoxeliumCore

// Developer tool for exercising VoxeliumCore against the real Mojang servers on
// macOS. It does not launch the game.

let usage = """
usage: voxelium-cli <command> [args]
  list-versions [--snapshots]        list versions from Mojang's manifest
  plan <id> [--root DIR]             fetch the version JSON and print the download + launch plan
  install <id> [--root DIR]          download client, libraries and assets (verified)
  check-macho <file>...              report Mach-O slices and iOS-device loadability
"""

func arg(_ name: String) -> String? {
    guard let i = CommandLine.arguments.firstIndex(of: name), i + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[i + 1]
}

func paths() -> AppPaths {
    let root = arg("--root").map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.temporaryDirectory.appendingPathComponent("voxelium-cli")
    return AppPaths(root: root)
}

func formatBytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

let args = CommandLine.arguments.dropFirst()
guard let command = args.first else {
    print(usage)
    exit(2)
}
Logger.shared.minimumLevel = .warning

do {
    switch command {
    case "list-versions":
        let p = paths()
        try p.createLayout()
        let manifest = try await GameInstaller(paths: p).fetchManifest()
        let types: Set<VersionType> = args.contains("--snapshots") ? [.release, .snapshot] : [.release]
        print("latest release: \(manifest.latest.release), snapshot: \(manifest.latest.snapshot)")
        for v in manifest.versions(of: types).prefix(40) { print("\(v.id)\t\(v.type.rawValue)\t\(v.releaseTime)") }

    case "plan", "install":
        guard let id = args.dropFirst().first else { print(usage); exit(2) }
        let p = paths()
        try p.createLayout()
        let installer = GameInstaller(paths: p)
        let manifest = try await installer.fetchManifest()
        guard let entry = manifest.entry(id: id) else { print("unknown version \(id)"); exit(1) }
        let version = try await installer.fetchVersion(entry)
        let items = try installer.planner.installItems(for: version)
        print("version \(version.id): java \(version.javaVersion?.majorVersion ?? 8), main \(version.mainClass)")
        print("game files: \(items.count) (\(formatBytes(items.compactMap(\.size).reduce(0, +))))")
        print("assets: index \(version.assetIndex?.id ?? "-"), total \(formatBytes(version.assetIndex?.totalSize ?? 0))")
        let skipped = version.libraries.filter(GameFilePlanner.isReplacedByLauncher).count
        print("libraries replaced by launcher-bundled builds (LWJGL etc.): \(skipped)")

        if command == "install" {
            let report = try await installer.install(version) { stage, prog in
                if prog.completed % 200 == 0 || prog.completed == prog.total {
                    print("  [\(stage)] \(prog.completed)/\(prog.total) failed=\(prog.failed)")
                }
            }
            let fresh = report.outcomes.values.filter { if case .downloaded = $0 { true } else { false } }.count
            print("done: \(report.outcomes.count) ok (\(fresh) downloaded), \(report.failures.count) failed")
            for (item, err) in report.failures.prefix(10) { print("  FAIL \(item.destination.lastPathComponent): \(err)") }
            if !report.succeeded { exit(1) }
        }

        let plan = try LaunchPlanner(paths: p).plan(version: version, identity: OfflineIdentity.identity(for: "Player"))
        print("launch plan: \(plan.classpath.count) classpath entries, \(plan.missingFiles.count) missing")
        print("jvm args: \(plan.jvmArguments.filter { !$0.contains(":") || $0.count < 120 }.joined(separator: " "))")
        print("game args: \(plan.gameArguments.joined(separator: " "))")

    case "check-macho":
        for path in args.dropFirst() {
            let slices = try MachO.slices(of: URL(fileURLWithPath: path))
            let desc = slices.map { "\($0.cpu)/\($0.platform.map { "\($0)" } ?? "unknown")" }.joined(separator: ", ")
            print("\(path): \(desc) → iOS device loadable: \(MachO.isLoadableOnIOSDevice(slices))")
        }

    default:
        print(usage)
        exit(2)
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
