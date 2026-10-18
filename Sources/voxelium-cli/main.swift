import Foundation
import VoxeliumCore

// Developer tool for exercising VoxeliumCore against the real Mojang servers on
// macOS. It does not launch the game.

let usage = """
usage: voxelium-cli <command> [args]
  list-versions [--snapshots]        list versions from Mojang's manifest
  plan <id> [--root DIR]             fetch the version JSON and print the download + launch plan
  install <id> [--root DIR]          download client, libraries and assets (verified)
  loaders <fabric|quilt> <mc>        list loader builds for a Minecraft version
  install-loader <fabric|quilt> <mc> [build] [--root DIR]
                                     install a Fabric/Quilt build (and its base version)
  check-macho <file>...              report Mach-O slices and iOS-device loadability
  inspect <mods|resourcepacks|shaderpacks> <file>...
                                     show what the mod manager reads from a jar/zip
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

    case "loaders":
        let rest = Array(args.dropFirst())
        guard rest.count >= 2, let loader = ModLoader(rawValue: rest[0]) else { print(usage); exit(2) }
        let builds = try await ModLoaderMeta().versions(for: loader, minecraft: rest[1])
        let rec = ModLoaderMeta.recommended(builds)?.version
        for b in builds.prefix(15) { print("\(b.version)\t\(b.stable ? "stable" : "unstable")\(b.version == rec ? "\t(recommended)" : "")") }

    case "install-loader":
        let rest = Array(args.dropFirst()).filter { !$0.hasPrefix("--") && $0 != arg("--root") }
        guard rest.count >= 2, let loader = ModLoader(rawValue: rest[0]) else { print(usage); exit(2) }
        let mc = rest[1]
        let build: String
        if rest.count >= 3 { build = rest[2] } else {
            guard let rec = ModLoaderMeta.recommended(try await ModLoaderMeta().versions(for: loader, minecraft: mc)) else { exit(1) }
            build = rec.version
        }
        let p = paths()
        try p.createLayout()
        let installer = GameInstaller(paths: p)
        let (id, report) = try await installer.installLoader(loader, minecraft: mc, version: build) { stage, prog in
            if prog.completed % 500 == 0 || prog.completed == prog.total { print("  [\(stage)] \(prog.completed)/\(prog.total) failed=\(prog.failed)") }
        }
        let fresh = report.outcomes.values.filter { if case .downloaded = $0 { true } else { false } }.count
        print("\(id): \(report.outcomes.count) ok (\(fresh) downloaded), \(report.failures.count) failed")
        for (item, err) in report.failures.prefix(10) { print("  FAIL \(item.destination.lastPathComponent): \(err)") }
        if !report.succeeded { exit(1) }
        let resolved = try VersionResolver(paths: p).resolve(id)
        let plan = try LaunchPlanner(paths: p).plan(version: resolved.info, identity: OfflineIdentity.identity(for: "Player"),
                                                    gameDirectory: try p.instanceDir(id))
        print("chain: \(resolved.chain.joined(separator: " -> ")), main \(plan.mainClass), \(plan.classpath.count) classpath entries, \(plan.missingFiles.count) missing")

    case "inspect":
        let rest = Array(args.dropFirst())
        guard rest.count >= 2, let kind = ContentKind(rawValue: rest[0]) else { print(usage); exit(2) }
        for path in rest.dropFirst() {
            let item = ContentManager.inspect(URL(fileURLWithPath: path), kind: kind, isFolder: false)
            print("\(item.fileName): name=\(item.name) version=\(item.version ?? "-") loaders=\(item.mod?.loaders.joined(separator: ",") ?? "-") id=\(item.mod?.id ?? "-") authors=\(item.mod?.authors.prefix(3).joined(separator: ",") ?? "-")")
            if let d = item.description { print("  description: \(d.prefix(100))") }
            if let p = item.problem { print("  problem: \(p)") }
            for loader in ["fabric", "quilt", "neoforge"] {
                if let w = ContentManager.compatibilityWarning(item, loader: loader) { print("  on \(loader): \(w)") }
            }
        }

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
