import Foundation
import Testing
@testable import VoxeliumCore

@Suite struct ContentManagerTests {
    func fixture(_ file: String) throws -> URL {
        let name = (file as NSString).deletingPathExtension, ext = (file as NSString).pathExtension
        return try #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures/content"))
    }

    @Test func zipReaderHandlesDeflatedAndStoredEntries() throws {
        let deflated = try ZipReader(url: fixture("fabric-example-1.2.3.jar"))
        let json = try #require(try deflated.read("fabric.mod.json"))
        #expect(String(decoding: json, as: UTF8.self).contains("\"examplemod\""))
        let stored = try ZipReader(url: fixture("test-shaders.zip"))
        #expect(String(decoding: try #require(try stored.read("shaders/composite.fsh")), as: UTF8.self) == "void main(){}\n")
        #expect(try stored.read("missing") == nil)
        #expect(throws: ZipReader.ZipError.notAZip) { try ZipReader(url: try fixture("broken.jar")) }
    }

    @Test func readsModMetadataForEveryLoader() throws {
        let fabric = ContentManager.inspect(try fixture("fabric-example-1.2.3.jar"), kind: .mods, isFolder: false)
        #expect(fabric.name == "Example Mod" && fabric.version == "1.2.3" && fabric.problem == nil)
        #expect(fabric.mod?.loaders == ["fabric"] && fabric.mod?.authors == ["Alice", "Bob"] && fabric.mod?.id == "examplemod")

        let quilt = ContentManager.inspect(try fixture("quilt-example-0.4.0.jar"), kind: .mods, isFolder: false)
        #expect(quilt.name == "Quilt Example" && quilt.version == "0.4.0" && quilt.mod?.loaders == ["quilt"] && quilt.mod?.authors == ["Carol"])

        // [[mods]] with a trailing comment, ${file.jarVersion} from the manifest, a
        // multi-line description and the top-level authors key.
        let forge = ContentManager.inspect(try fixture("forge-example-2.0.1.jar"), kind: .mods, isFolder: false)
        #expect(forge.name == "Forge Example" && forge.version == "2.0.1" && forge.mod?.id == "forgeexample")
        #expect(forge.description == "A Forge mod\non two lines." && forge.mod?.authors == ["Dave"] && forge.mod?.loaders == ["forge"])

        let broken = ContentManager.inspect(try fixture("broken.jar"), kind: .mods, isFolder: false)
        #expect(broken.problem != nil && broken.name == "broken")
    }

    @Test func readsPacks() throws {
        let rp = ContentManager.inspect(try fixture("gold-pack.zip"), kind: .resourcePacks, isFolder: false)
        #expect(rp.description == "Gold Pack v1" && rp.problem == nil)   // components joined, § codes stripped
        let sp = ContentManager.inspect(try fixture("test-shaders.zip"), kind: .shaderPacks, isFolder: false)
        #expect(sp.name == "test-shaders" && sp.problem == nil)
    }

    @Test func addEnableDisableRemove() throws {
        let tmp = try TempDir()
        let game = tmp.paths.root.appendingPathComponent("instance")
        let cm = ContentManager(gameDirectory: game)
        #expect(cm.list(.mods).isEmpty)

        let added = try cm.add(try fixture("fabric-example-1.2.3.jar"), as: .mods)
        try cm.add(try fixture("quilt-example-0.4.0.jar"), as: .mods)
        #expect(FileManager.default.fileExists(atPath: game.appendingPathComponent("mods/fabric-example-1.2.3.jar").path))
        #expect(cm.list(.mods).map(\.name) == ["Example Mod", "Quilt Example"])

        // Disabling renames to .disabled; the id stays the same.
        let off = try cm.setEnabled(added, false)
        #expect(!off.isEnabled && off.fileName == "fabric-example-1.2.3.jar.disabled" && off.id == added.id)
        #expect(cm.list(.mods).first { $0.id == added.id }?.isEnabled == false)
        let on = try cm.setEnabled(off, true)
        #expect(on.isEnabled && on.fileName == "fabric-example-1.2.3.jar")

        // Re-adding replaces the file, enabled or disabled.
        try cm.setEnabled(on, false)
        try cm.add(try fixture("fabric-example-1.2.3.jar"), as: .mods)
        #expect(cm.list(.mods).filter { $0.id == added.id }.map(\.isEnabled) == [true])

        try cm.remove(try #require(cm.list(.mods).first { $0.id == added.id }))
        #expect(cm.list(.mods).map(\.name) == ["Quilt Example"])

        try cm.add(try fixture("gold-pack.zip"), as: .resourcePacks)
        try cm.add(try fixture("test-shaders.zip"), as: .shaderPacks)
        #expect(cm.list(.resourcePacks).count == 1 && cm.list(.shaderPacks).count == 1)
    }

    @Test func refusesTheWrongKind() throws {
        let tmp = try TempDir()
        let cm = ContentManager(gameDirectory: tmp.paths.root)
        #expect(throws: ContentError.self) { try cm.add(try fixture("gold-pack.zip"), as: .mods) }        // not a jar
        #expect(throws: ContentError.self) { try cm.add(try fixture("broken.jar"), as: .mods) }           // not a zip
        do {
            try cm.add(try fixture("gold-pack.zip"), as: .shaderPacks)
            Issue.record("a resource pack was accepted as a shader pack")
        } catch let e as ContentError {
            #expect(e.description.contains("looks like a resource pack"))
        }
        do {
            try cm.add(try fixture("test-shaders.zip"), as: .resourcePacks)
            Issue.record("a shader pack was accepted as a resource pack")
        } catch let e as ContentError {
            #expect(e.description.contains("looks like a shader pack"))
        }
        #expect(cm.list(.mods).isEmpty && cm.list(.shaderPacks).isEmpty)
    }

    @Test func compatibilityWarnings() throws {
        let fabric = ContentManager.inspect(try fixture("fabric-example-1.2.3.jar"), kind: .mods, isFolder: false)
        let quilt = ContentManager.inspect(try fixture("quilt-example-0.4.0.jar"), kind: .mods, isFolder: false)
        let forge = ContentManager.inspect(try fixture("forge-example-2.0.1.jar"), kind: .mods, isFolder: false)
        #expect(ContentManager.compatibilityWarning(fabric, loader: "fabric") == nil)
        #expect(ContentManager.compatibilityWarning(fabric, loader: "quilt") == nil)   // Quilt loads Fabric mods
        #expect(ContentManager.compatibilityWarning(quilt, loader: "fabric") == "Made for Quilt, so Fabric won't load it.")
        #expect(ContentManager.compatibilityWarning(forge, loader: "fabric") == "Made for Forge, so Fabric won't load it.")
        #expect(ContentManager.compatibilityWarning(forge, loader: nil) == nil)
    }
}

@Suite struct IrisSettingsTests {
    @Test func readsAndSwitchesShadersOff() throws {
        let tmp = try TempDir()
        let game = tmp.paths.root.appendingPathComponent("instance")
        var none = IrisSettings(gameDirectory: game)
        #expect(!none.exists && none.shadersEnabled && none.shaderPack == nil)

        // As Iris 1.10.8 wrote it on the iPhone (2026-10-18), with an escaped name.
        try FileManager.default.createDirectory(at: game.appendingPathComponent("config"), withIntermediateDirectories: true)
        let original = """
            #This file stores configuration options for Iris, such as the currently active shaderpack
            #Sun Oct 18 02:07:36 GMT 2026
            allowUnknownShaders=false
            enableShaders=true
            maxShadowRenderDistance=32
            shaderPack=My\\: Pack.zip

            """
        try original.write(to: game.appendingPathComponent("config/iris.properties"), atomically: true, encoding: .utf8)
        var iris = IrisSettings(gameDirectory: game)
        #expect(iris.exists && iris.shadersEnabled && iris.shaderPack == "My: Pack.zip")

        try iris.setShadersEnabled(false)
        let written = try String(contentsOf: iris.file, encoding: .utf8)
        #expect(written == original.replacingOccurrences(of: "enableShaders=true", with: "enableShaders=false"))
        #expect(IrisSettings(gameDirectory: game).shadersEnabled == false)

        // No file yet: the key is added.
        try none.setShadersEnabled(false)
        #expect(IrisSettings(gameDirectory: game).shadersEnabled == false)
    }
}
