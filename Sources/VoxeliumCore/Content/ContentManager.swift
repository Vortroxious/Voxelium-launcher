import Foundation

/// Things a player adds to a game folder (as ZalithLauncher2's mod and resource
/// managers): mods, resource packs and shader packs.
public enum ContentKind: String, CaseIterable, Sendable, Identifiable {
    case mods
    case resourcePacks = "resourcepacks"
    case shaderPacks = "shaderpacks"

    public var id: String { rawValue }
    /// The folder inside the game directory.
    public var folderName: String { rawValue }

    public var title: String {
        switch self {
        case .mods: "Mods"
        case .resourcePacks: "Resource packs"
        case .shaderPacks: "Shader packs"
        }
    }

    /// File extension of the packaged form (folders are also accepted for packs).
    public var fileExtension: String { self == .mods ? "jar" : "zip" }
}

/// Mod metadata read from inside the jar.
public struct ModMetadata: Sendable, Equatable {
    public let id: String
    public let name: String
    public let version: String?
    public let description: String?
    public let authors: [String]
    /// "fabric", "quilt", "forge", "neoforge".
    public let loaders: [String]
}

/// One mod, resource pack or shader pack in a game folder.
public struct ContentItem: Sendable, Equatable, Identifiable {
    public let kind: ContentKind
    /// The name on disk (with ".disabled" when switched off).
    public let fileName: String
    public let url: URL
    public let isEnabled: Bool
    public let isFolder: Bool
    public let size: Int64
    /// Display name: the mod's or pack's own name, else the file name.
    public let name: String
    public let version: String?
    public let description: String?
    public let mod: ModMetadata?
    /// Set when the file could not be read as this kind of content.
    public let problem: String?

    /// Stable across enabling/disabling: the file name without ".disabled".
    public var id: String { ContentManager.baseName(fileName) }
}

public enum ContentError: Error, Equatable, CustomStringConvertible {
    case wrongType(String)
    case notReadable(String)
    case wrongLoader(String)

    public var description: String {
        switch self {
        case .wrongType(let m), .notReadable(let m), .wrongLoader(let m): m
        }
    }
}

/// Lists and changes the mods, resource packs and shader packs of one game folder.
/// Disabling renames `x.jar` to `x.jar.disabled` (the convention ZalithLauncher2 and
/// other launchers use), which Minecraft and the mod loaders skip.
public struct ContentManager: Sendable {
    public let gameDirectory: URL
    static let disabledSuffix = ".disabled"

    public init(gameDirectory: URL) { self.gameDirectory = gameDirectory }

    public func folder(_ kind: ContentKind) -> URL {
        gameDirectory.appendingPathComponent(kind.folderName, isDirectory: true)
    }

    static func baseName(_ fileName: String) -> String {
        fileName.hasSuffix(disabledSuffix) ? String(fileName.dropLast(disabledSuffix.count)) : fileName
    }

    /// Everything in the kind's folder, sorted by name.
    public func list(_ kind: ContentKind) -> [ContentItem] {
        let dir = folder(kind)
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names.compactMap { name -> ContentItem? in
            if name.hasPrefix(".") { return nil }
            let url = dir.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }
            let base = Self.baseName(name)
            if !isDir.boolValue && !base.lowercased().hasSuffix(".\(kind.fileExtension)") { return nil }
            if isDir.boolValue && kind == .mods { return nil }
            return Self.inspect(url, kind: kind, isFolder: isDir.boolValue)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Switches an item on or off by renaming it.
    @discardableResult
    public func setEnabled(_ item: ContentItem, _ enabled: Bool) throws -> ContentItem {
        guard item.isEnabled != enabled else { return item }
        let base = Self.baseName(item.fileName)
        let target = folder(item.kind).appendingPathComponent(enabled ? base : base + Self.disabledSuffix)
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        try FileManager.default.moveItem(at: item.url, to: target)
        return Self.inspect(target, kind: item.kind, isFolder: item.isFolder)
    }

    /// Deletes the item from the game folder.
    public func remove(_ item: ContentItem) throws {
        try FileManager.default.removeItem(at: item.url)
    }

    /// Copies a file into the kind's folder (replacing one with the same name,
    /// enabled or disabled). Mods must be jars; packs must be zips, and a shader
    /// pack must contain a `shaders/` folder.
    @discardableResult
    /// Copies `source` in as `kind`. With `loader` (the version's mod loader id), a mod
    /// whose metadata says it is only for other loaders (a Fabric mod on NeoForge, a
    /// Forge mod on Fabric) is refused; mods without loader metadata are let through.
    public func add(_ source: URL, as kind: ContentKind, loader: String? = nil) throws -> ContentItem {
        let name = source.lastPathComponent
        guard name.lowercased().hasSuffix(".\(kind.fileExtension)") else {
            throw ContentError.wrongType("\(name) is not a .\(kind.fileExtension) file, so it can't be added to \(kind.title.lowercased()).")
        }
        let zip: ZipReader
        do { zip = try ZipReader(url: source) } catch {
            throw ContentError.notReadable("\(name) is not a valid \(kind == .mods ? "jar" : "zip") file.")
        }
        switch kind {
        case .shaderPacks where !zip.entries.contains { $0.name.hasPrefix("shaders/") }:
            throw ContentError.wrongType("\(name) has no shaders/ folder, so it is not a shader pack\(zip.entry(named: "pack.mcmeta") != nil ? " (it looks like a resource pack)" : "").")
        case .resourcePacks where zip.entry(named: "pack.mcmeta") == nil:
            throw ContentError.wrongType("\(name) has no pack.mcmeta, so it is not a resource pack\(zip.entries.contains { $0.name.hasPrefix("shaders/") } ? " (it looks like a shader pack)" : "").")
        default:
            break
        }
        if kind == .mods, let loader, let warning = Self.compatibilityWarning(Self.inspect(source, kind: .mods, isFolder: false), loader: loader) {
            throw ContentError.wrongLoader("\(name): \(warning) Look for its \(Self.loaderDisplayName(loader)) version under Browse.")
        }
        let dir = folder(kind)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(name)
        for existing in [dest, dir.appendingPathComponent(name + Self.disabledSuffix)]
        where FileManager.default.fileExists(atPath: existing.path) {
            try FileManager.default.removeItem(at: existing)
        }
        try FileManager.default.copyItem(at: source, to: dest)
        return Self.inspect(dest, kind: kind, isFolder: false)
    }

    /// Whether a mod can load on a version's loader; nil when it can (or is unknown).
    public static func compatibilityWarning(_ item: ContentItem, loader: String?) -> String? {
        guard item.kind == .mods, let loader, let mod = item.mod, !mod.loaders.isEmpty else { return nil }
        let accepted: Set<String> = loader == "quilt" ? ["quilt", "fabric"] : [loader]
        if !accepted.isDisjoint(with: mod.loaders) { return nil }
        let names = mod.loaders.map(loaderDisplayName).joined(separator: "/")
        return "Made for \(names), so \(loaderDisplayName(loader)) won't load it."
    }

    static func loaderDisplayName(_ id: String) -> String {
        ModLoader(rawValue: id)?.displayName ?? id.capitalized
    }

    // MARK: Reading metadata

    /// Reads one file or folder as content of `kind`.
    public static func inspect(_ url: URL, kind: ContentKind, isFolder: Bool) -> ContentItem {
        let fileName = url.lastPathComponent
        let enabled = !fileName.hasSuffix(disabledSuffix)
        let fallbackName = (baseName(fileName) as NSString).deletingPathExtension
        let size = isFolder ? folderSize(url) : ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0)
        func item(name: String? = nil, version: String? = nil, description: String? = nil, mod: ModMetadata? = nil, problem: String? = nil) -> ContentItem {
            ContentItem(kind: kind, fileName: fileName, url: url, isEnabled: enabled, isFolder: isFolder, size: size,
                        name: name ?? fallbackName, version: version, description: description, mod: mod, problem: problem)
        }
        if isFolder {
            let meta = try? Data(contentsOf: url.appendingPathComponent("pack.mcmeta"))
            return item(description: meta.flatMap(packDescription))
        }
        guard let zip = try? ZipReader(url: url) else { return item(problem: "Not a readable \(kind == .mods ? "jar" : "zip") file") }
        switch kind {
        case .mods:
            guard let mod = modMetadata(zip) else { return item(problem: "No mod metadata found (not a Fabric, Quilt or Forge mod?)") }
            return item(name: mod.name, version: mod.version, description: mod.description, mod: mod)
        case .resourcePacks:
            let meta = try? zip.read("pack.mcmeta")
            return item(description: meta.flatMap(packDescription), problem: meta == nil ? "No pack.mcmeta" : nil)
        case .shaderPacks:
            return item(problem: zip.entries.contains { $0.name.hasPrefix("shaders/") } ? nil : "No shaders/ folder")
        }
    }

    static func modMetadata(_ zip: ZipReader) -> ModMetadata? {
        if let data = try? zip.read("fabric.mod.json"), let j = jsonObject(data) {
            return ModMetadata(id: j["id"] as? String ?? "?", name: j["name"] as? String ?? (j["id"] as? String ?? "?"),
                               version: j["version"] as? String, description: j["description"] as? String,
                               authors: people(j["authors"]), loaders: ["fabric"])
        }
        if let data = try? zip.read("quilt.mod.json"), let j = jsonObject(data), let q = j["quilt_loader"] as? [String: Any] {
            let meta = q["metadata"] as? [String: Any] ?? [:]
            let contributors = (meta["contributors"] as? [String: Any]).map { Array($0.keys).sorted() } ?? []
            return ModMetadata(id: q["id"] as? String ?? "?", name: meta["name"] as? String ?? (q["id"] as? String ?? "?"),
                               version: q["version"] as? String, description: meta["description"] as? String,
                               authors: contributors, loaders: ["quilt"])
        }
        for (file, loader) in [("META-INF/neoforge.mods.toml", "neoforge"), ("META-INF/mods.toml", "forge")] {
            guard let data = try? zip.read(file), let toml = String(data: data, encoding: .utf8) else { continue }
            let mod = tomlFirstMod(toml)
            var version = mod["version"]
            if version?.contains("${") ?? true, let mf = try? zip.read("META-INF/MANIFEST.MF"), let text = String(data: mf, encoding: .utf8) {
                version = manifestValue(text, "Implementation-Version") ?? version
            }
            let id = mod["modId"] ?? "?"
            return ModMetadata(id: id, name: mod["displayName"] ?? id, version: version, description: mod["description"],
                               authors: mod["authors"].map { [$0] } ?? [], loaders: [loader])
        }
        if let data = try? zip.read("mcmod.info"), let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]], let j = list.first {
            return ModMetadata(id: j["modid"] as? String ?? "?", name: j["name"] as? String ?? "?", version: j["version"] as? String,
                               description: j["description"] as? String, authors: people(j["authorList"]), loaders: ["forge"])
        }
        return nil
    }

    static func jsonObject(_ data: Data) -> [String: Any]? {
        if let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { return j }
        // Some fabric.mod.json files contain raw control characters in strings.
        let cleaned = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\t", with: " ")
            .components(separatedBy: .newlines).joined(separator: " ")
        return (try? JSONSerialization.jsonObject(with: Data(cleaned.utf8))) as? [String: Any]
    }

    /// Author lists: strings or `{ "name": … }` objects.
    static func people(_ any: Any?) -> [String] {
        (any as? [Any] ?? []).compactMap { ($0 as? String) ?? (($0 as? [String: Any])?["name"] as? String) }
    }

    /// The first `[[mods]]` table's `key = value` strings (enough for display),
    /// including multi-line `\'\'\'…\'\'\'` / `"""…"""` strings.
    static func tomlFirstMod(_ toml: String) -> [String: String] {
        var inMods = false, seenMods = false
        var out: [String: String] = [:]
        var topLevel: [String: String] = [:]
        var pending: (key: String, delimiter: String, text: String)?
        func store(_ key: String, _ value: String) {
            if inMods { out[key] = value } else if !seenMods { topLevel[key] = value }
        }
        for raw in toml.components(separatedBy: .newlines) {
            if let p = pending {
                if let end = raw.range(of: p.delimiter) {
                    store(p.key, (p.text + raw[..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines))
                    pending = nil
                } else {
                    pending = (p.key, p.delimiter, p.text + raw + "\n")
                }
                continue
            }
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                if inMods { break }
                // Table headers may carry a comment: `[[mods]] #mandatory` (JEI).
                let header = line.split(separator: "#", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? line
                inMods = header == "[[mods]]"
                seenMods = seenMods || inMods
                continue
            }
            guard let eq = line.firstIndex(of: "="), !line.hasPrefix("#") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if let q = ["\'\'\'", "\"\"\""].first(where: value.hasPrefix) {
                let rest = String(value.dropFirst(q.count))
                if let end = rest.range(of: q) { store(key, String(rest[..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)) }
                else { pending = (key, q, rest.isEmpty ? "" : rest + "\n") }
                continue
            }
            for q in ["\"", "'"] where value.hasPrefix(q) {
                value = String(value.dropFirst())
                if let end = value.range(of: q) { value = String(value[..<end.lowerBound]) }
                break
            }
            if !value.isEmpty, let hash = value.range(of: " #") { value = String(value[..<hash.lowerBound]) }
            store(key, value)
        }
        if out["authors"] == nil { out["authors"] = topLevel["authors"] }
        return out
    }

    static func manifestValue(_ manifest: String, _ key: String) -> String? {
        for line in manifest.components(separatedBy: .newlines) where line.hasPrefix(key + ":") {
            return line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// A pack's description as plain text: a string, a text component, or a list of them.
    static func packDescription(_ data: Data) -> String? {
        guard let j = jsonObject(data), let pack = j["pack"] as? [String: Any], let d = pack["description"] else { return nil }
        let text = componentText(d).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : stripFormatting(text)
    }

    static func componentText(_ any: Any) -> String {
        if let s = any as? String { return s }
        if let list = any as? [Any] { return list.map(componentText).joined() }
        if let c = any as? [String: Any] {
            return (c["text"] as? String ?? (c["translate"] as? String ?? "")) + ((c["extra"] as? [Any]).map { $0.map(componentText).joined() } ?? "")
        }
        return ""
    }

    /// Removes Minecraft's `§x` colour/format codes.
    static func stripFormatting(_ s: String) -> String {
        var out = ""
        var skip = false
        for ch in s {
            if skip { skip = false; continue }
            if ch == "§" { skip = true; continue }
            out.append(ch)
        }
        return out
    }

    static func folderSize(_ url: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e { total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return total
    }
}
