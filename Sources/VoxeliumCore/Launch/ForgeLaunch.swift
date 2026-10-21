import Foundation

/// What a Forge or NeoForge version needs at launch on iOS, on top of the plan
/// `LaunchPlanner` makes. Verified on macOS with NeoForge 21.11.48 and 21.1.264,
/// Forge 47.4.10 (1.20.1, Java 17) and 61.2.0 (1.21.11), each to the title screen
/// (2026-10-21, docs/ENGINEERING_LOG.md).
public enum ForgeLaunch {
    /// JavaRuntime/voxelium-boot: runs the installer processors once, then the real main class.
    public static let bootMainClass = "io.github.voxelium.boot.Boot"
    public static let bootJarName = "voxelium-boot.jar"

    /// The processor plan of the first version in the chain that has one (a modpack
    /// builds on the Forge/NeoForge version that owns it).
    public static func processorPlan(for resolved: ResolvedVersion, paths: AppPaths) -> URL? {
        resolved.chain.lazy.compactMap { ForgeInstaller.processorPlan($0, paths: paths) }.first
    }

    /// The java launcher accepts `--add-opens X`, `-p X` etc., but JNI_CreateJavaVM only
    /// takes HotSpot's own `--add-opens=X` / `--module-path=X` forms, so convert them.
    /// Everything else passes through unchanged.
    public static func jniOptions(_ args: [String]) -> [String] {
        let joined: [String: String] = [
            "--add-opens": "--add-opens=", "--add-exports": "--add-exports=", "--add-reads": "--add-reads=",
            "--add-modules": "--add-modules=", "--patch-module": "--patch-module=", "--limit-modules": "--limit-modules=",
            "--enable-native-access": "--enable-native-access=",
            "-p": "--module-path=", "--module-path": "--module-path=",
        ]
        var out: [String] = []
        var i = 0
        while i < args.count {
            if let prefix = joined[args[i]], i + 1 < args.count {
                out.append(prefix + args[i + 1])
                i += 2
            } else {
                out.append(args[i])
                i += 1
            }
        }
        return out
    }

    /// BootstrapLauncher (Forge 1.17 – 1.20.x, NeoForge before 21.9) turns every
    /// classpath jar not named in `-DignoreList` into a module; the boot jar is only
    /// the entry point, so keep it out.
    public static func extendIgnoreList(_ args: [String], with names: [String]) -> [String] {
        args.map { a in
            guard a.hasPrefix("-DignoreList=") else { return a }
            return ([a] + names).joined(separator: ",")
        }
    }

    /// FML's early loading screen opens its own GLFW window and GL context on another
    /// thread, which the app's single iOS window cannot provide. Turn it off in
    /// `config/fml.toml` (Forge 1.17+ and NeoForge read the same key); other settings
    /// in the file are kept, and FML fills in the rest when the file is new.
    public static func disableEarlyWindow(gameDirectory: URL, fileManager: FileManager = .default) throws {
        let url = gameDirectory.appendingPathComponent("config", isDirectory: true).appendingPathComponent("fml.toml")
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        var lines = text.isEmpty ? [] : text.components(separatedBy: "\n")
        let isKey: (String) -> Bool = {
            let t = $0.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("earlyWindowControl") && t.dropFirst("earlyWindowControl".count).trimmingCharacters(in: .whitespaces).hasPrefix("=")
        }
        if let i = lines.firstIndex(where: isKey) {
            if lines[i].replacingOccurrences(of: " ", with: "") == "earlyWindowControl=false" { return }
            lines[i] = "earlyWindowControl = false"
        } else {
            if lines.last == "" { lines.removeLast() }
            lines.append("earlyWindowControl = false")
            lines.append("")
        }
        text = lines.joined(separator: "\n")
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
    }
}
