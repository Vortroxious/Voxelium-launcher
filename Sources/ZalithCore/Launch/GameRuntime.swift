import Foundation

/// Which bundled Java and LWJGL a version needs, as ZalithLauncher2 decides it
/// (`detectLwjglVersion`, `lwjglVersionDir`, its jre-8/17/21/25 runtimes).
public enum GameRuntime {
    /// Java versions the app bundles (scripts/fetch-runtime.sh).
    public static let bundledJava = [8, 17, 21, 25]

    /// The Java major a version asks for; versions older than 1.6's
    /// `javaVersion` field (pre-1.17 JSONs without it) run on Java 8.
    public static func javaMajor(for version: VersionInfo) -> Int {
        version.javaVersion?.majorVersion ?? 8
    }

    /// The smallest bundled Java that is at least `major` (16 → 17), or nil when
    /// the version needs a newer Java than any bundled one.
    public static func java(for major: Int, available: [Int] = bundledJava) -> Int? {
        available.sorted().first { $0 >= major }
    }

    public struct LWJGLVersion: Sendable, Equatable, Comparable, CustomStringConvertible {
        public let major: Int, minor: Int, patch: Int
        public init(_ major: Int, _ minor: Int, _ patch: Int) {
            self.major = major; self.minor = minor; self.patch = patch
        }
        public var description: String { "\(major).\(minor).\(patch)" }
        public static func < (a: Self, b: Self) -> Bool { (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch) }

        /// "3.3.3", "3.2.2", "2.9.4-nightly-20150209" (suffix ignored).
        init?(_ s: Substring) {
            let parts = s.split(separator: "-").first?.split(separator: ".").compactMap { Int($0) } ?? []
            guard parts.count >= 2 else { return nil }
            self.init(parts[0], parts[1], parts.count > 2 ? parts[2] : 0)
        }
    }

    /// The highest `org.lwjgl:lwjgl` / `org.lwjgl.lwjgl:lwjgl` version in the libraries.
    public static func lwjgl(for version: VersionInfo) -> LWJGLVersion? {
        version.libraries.compactMap { lib -> LWJGLVersion? in
            let c = lib.name.split(separator: ":")
            guard c.count >= 3, c[1] == "lwjgl", c[0] == "org.lwjgl" || c[0] == "org.lwjgl.lwjgl" else { return nil }
            return LWJGLVersion(c[2])
        }.max()
    }

    /// Which of the app's LWJGL builds a version uses: like upstream, 3.4.1 for
    /// LWJGL ≥ 3.4.1, otherwise 3.3.3 (LWJGL 2 versions additionally need the
    /// lwjglx bridge on top of 3.3.3).
    public enum LWJGLBuild: String, Sendable, Equatable {
        case v333 = "3.3.3", v341 = "3.4.1"
    }

    public static func lwjglBuild(for v: LWJGLVersion?) -> LWJGLBuild {
        guard let v else { return .v333 }
        return v >= LWJGLVersion(3, 4, 1) ? .v341 : .v333
    }

    public static func needsLWJGL2Bridge(_ v: LWJGLVersion?) -> Bool { (v?.major ?? 3) < 3 }
}
