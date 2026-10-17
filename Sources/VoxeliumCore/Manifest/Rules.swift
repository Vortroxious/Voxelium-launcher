import Foundation

/// A Mojang `rules` entry, used on libraries and on conditional arguments.
public struct Rule: Codable, Sendable, Equatable {
    public enum Action: String, Codable, Sendable { case allow, disallow }

    public struct OS: Codable, Sendable, Equatable {
        public let name: String?
        public let arch: String?
        /// A regular expression matched against the OS version.
        public let version: String?
    }

    public let action: Action
    public let os: OS?
    public let features: [String: Bool]?
}

/// The platform that rules are evaluated against.
///
/// iOS has no Mojang OS key. ZalithLauncher2 2.6.1 (Android) effectively
/// evaluates rules as a non-osx platform (`GameManifest.Rule.checkRules`
/// rejects osx-only allow rules), and replaces every `org.lwjgl` library with
/// its own bundled LWJGL. We mirror that by evaluating as `linux` by default.
/// ASSUMPTION (unverified on device): Linux-flavoured Java libraries are
/// correct for the iOS JRE; natives are never taken from Mojang anyway.
public struct RulePlatform: Sendable, Equatable {
    public var osName: String
    public var osArch: String
    public var osVersion: String
    public var features: [String: Bool]

    public init(osName: String, osArch: String, osVersion: String = "", features: [String: Bool] = [:]) {
        self.osName = osName
        self.osArch = osArch
        self.osVersion = osVersion
        self.features = features
    }

    public static let iOSDefault = RulePlatform(osName: "linux", osArch: "aarch64")
}

public enum RuleEvaluator {
    /// Standard launcher semantics: no rules means allowed; otherwise start
    /// disallowed and let each matching rule set the outcome (last match wins).
    public static func allows(_ rules: [Rule]?, on platform: RulePlatform) -> Bool {
        guard let rules, !rules.isEmpty else { return true }
        var allowed = false
        for rule in rules where matches(rule, platform) {
            allowed = rule.action == .allow
        }
        return allowed
    }

    static func matches(_ rule: Rule, _ p: RulePlatform) -> Bool {
        if let os = rule.os {
            if let name = os.name, name != p.osName { return false }
            if let arch = os.arch, !archMatches(arch, p.osArch) { return false }
            if let version = os.version {
                guard let re = try? NSRegularExpression(pattern: version),
                      re.firstMatch(in: p.osVersion, range: NSRange(p.osVersion.startIndex..., in: p.osVersion)) != nil
                else { return false }
            }
        }
        if let features = rule.features {
            for (key, value) in features where (p.features[key] ?? false) != value { return false }
        }
        return true
    }

    /// Mojang uses `x86` for 32-bit Intel; treat x86/x64 aliases loosely.
    static func archMatches(_ ruleArch: String, _ arch: String) -> Bool {
        if ruleArch == arch { return true }
        let aliases: [String: Set<String>] = ["x86": ["x86", "i386", "i686"], "arm64": ["arm64", "aarch64"], "aarch64": ["arm64", "aarch64"]]
        return aliases[ruleArch]?.contains(arch) ?? false
    }
}
