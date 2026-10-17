import CryptoKit
import Foundation

/// Offline identity, as offered by ZalithLauncher2 ("offline" account type).
/// Offline play does not authenticate with Microsoft and cannot join
/// online-mode servers. Microsoft accounts: see MicrosoftAuth.
public enum OfflineIdentity {
    /// Player names Minecraft accepts: 3–16 chars of [A-Za-z0-9_].
    public static func isValidName(_ name: String) -> Bool {
        (3...16).contains(name.count) && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }

    /// Same UUID as vanilla's offline mode: UUIDv3(MD5("OfflinePlayer:<name>")).
    public static func uuid(for name: String) -> UUID {
        var b = Array(Insecure.MD5.hash(data: Data("OfflinePlayer:\(name)".utf8)))
        b[6] = (b[6] & 0x0f) | 0x30
        b[8] = (b[8] & 0x3f) | 0x80
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    public static func identity(for name: String) -> LaunchIdentity {
        let id = uuid(for: name).uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        return LaunchIdentity(playerName: name, uuid: id, accessToken: "0", userType: "legacy")
    }
}
