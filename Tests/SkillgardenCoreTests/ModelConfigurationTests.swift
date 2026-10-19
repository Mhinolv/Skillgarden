import Foundation
import Testing
@testable import SkillgardenCore

private func modelFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(path: "ModelConfigurationTests-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

private func littleEndian<T: FixedWidthInteger>(_ value: T) -> Data {
    withUnsafeBytes(of: value.littleEndian) { Data($0) }
}

private func ggufString(_ text: String) -> Data {
    littleEndian(UInt64(text.utf8.count)) + Data(text.utf8)
}

/// A GGUF v3 header with `keys`: each key holds a string value or a uint16 value.
private func gguf(_ keys: [(String, Any)] = [("general.architecture", "llama")], padding: Int = 256) -> Data {
    var data = Data("GGUF".utf8) + littleEndian(UInt32(3))
    data += littleEndian(UInt64(0)) + littleEndian(UInt64(keys.count))
    for (key, value) in keys {
        data += ggufString(key)
        if let text = value as? String {
            data += littleEndian(UInt32(8)) + ggufString(text)
        } else if let number = value as? UInt16 {
            data += littleEndian(UInt32(2)) + littleEndian(number)
        }
    }
    return data + Data(repeating: 0, count: padding)
}

private func write(_ data: Data, _ name: String, in folder: URL) throws -> URL {
    let url = folder.appending(path: name)
    try data.write(to: url)
    return url
}

/// #122: a readable single-file GGUF is valid. The model shows its name, `ByteCountFormatter` size and `~` path.
@Test func modelValidatorAcceptsAGGUFFileAndShowsItsIdentity() throws {
    let folder = try modelFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let data = gguf(padding: 2_000_000)
    let url = try write(data, "tiny-q4_k_m.gguf", in: folder)
    let model = try ModelValidator.validate(url).get()
    #expect(model.name == "tiny-q4_k_m.gguf")
    #expect(model.sizeBytes == Int64(data.count))
    #expect(model.sizeText == ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))
    #expect(model.sizeText == "2 MB")
    let home = URL(fileURLWithPath: "/Users/learner")
    #expect(LocalModel(url: URL(fileURLWithPath: "/Users/learner/Models/a.gguf"), sizeBytes: 0).displayPath(home: home) == "~/Models/a.gguf")
    #expect(LocalModel(url: URL(fileURLWithPath: "/Users/learner2/a.gguf"), sizeBytes: 0).displayPath(home: home) == "/Users/learner2/a.gguf")
    #expect(LocalModel(url: URL(fileURLWithPath: "/Volumes/AI/a.gguf"), sizeBytes: 1_000).detailText(home: home) == "1 KB · /Volumes/AI/a.gguf")
    #expect(LocalModel.displayPath("/Users/learner", home: URL(fileURLWithPath: "/Users/learner/")) == "~")
}

/// #122: missing, unreadable, non-GGUF and split files each give their design-note message.
@Test func modelValidatorRejectsEachUnsupportedFile() throws {
    let folder = try modelFolder()
    defer { try? FileManager.default.removeItem(at: folder) }

    let missing = folder.appending(path: "gone.gguf")
    #expect(ModelValidator.validate(missing) == .failure(.missing("gone.gguf")))
    #expect(ModelProblem.missing("gone.gguf").message == "The model file is missing. It was moved or deleted. Choose it again.")

    let text = try write(Data("not a model".utf8), "notes.gguf", in: folder)
    #expect(ModelValidator.validate(text) == .failure(.notGGUF("notes.gguf")))
    #expect(ModelProblem.notGGUF("notes.gguf").message == "\"notes.gguf\" is not a GGUF model file.")
    // Smallest input: an empty file and a file shorter than the magic.
    #expect(ModelValidator.validate(try write(Data(), "empty.gguf", in: folder)) == .failure(.notGGUF("empty.gguf")))
    #expect(ModelValidator.validate(try write(Data("GG".utf8), "short.gguf", in: folder)) == .failure(.notGGUF("short.gguf")))
    // A folder is not a model file.
    let directory = folder.appending(path: "folder.gguf")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    #expect(ModelValidator.validate(directory) == .failure(.notGGUF("folder.gguf")))

    let split = try write(gguf(), "model-00001-of-00003.gguf", in: folder)
    #expect(ModelValidator.validate(split) == .failure(.splitPart("model-00001-of-00003.gguf")))
    #expect(ModelProblem.splitPart("m.gguf").message == "\"m.gguf\" is one part of a split model. Choose a single-file GGUF model.")
    // A renamed split part still has `split.count` in its metadata.
    let renamed = try write(gguf([("split.no", UInt16(0)), ("split.count", UInt16(2)), ("general.name", "x")]), "renamed.gguf", in: folder)
    #expect(ModelValidator.validate(renamed) == .failure(.splitPart("renamed.gguf")))
    // `split.count` 1 is one whole file.
    let whole = try write(gguf([("general.name", "x"), ("split.count", UInt16(1))]), "whole.gguf", in: folder)
    #expect((try? ModelValidator.validate(whole).get())?.name == "whole.gguf")

    let locked = try write(gguf(), "locked.gguf", in: folder)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }
    #expect(ModelValidator.validate(locked) == .failure(.unreadable("locked.gguf")))
    #expect(ModelProblem.unreadable("locked.gguf").message
        == "Skillgarden can't read \"locked.gguf\". Check its permissions, then choose it again.")
}

/// The metadata scan stops at an array or at a cut header and does not crash.
@Test func ggufSplitCountScanStopsAtTheEndOfTheHeader() {
    #expect(ModelValidator.splitCount(gguf([("split.count", UInt16(3))])) == 3)
    #expect(ModelValidator.splitCount(gguf([])) == nil)
    #expect(ModelValidator.splitCount(gguf([("split.count", UInt16(3))], padding: 0).prefix(30)) == nil)
    // A key length that is larger than the header.
    var bad = Data("GGUF".utf8) + littleEndian(UInt32(3))
    bad += littleEndian(UInt64(0)) + littleEndian(UInt64(1)) + littleEndian(UInt64.max)
    #expect(ModelValidator.splitCount(bad) == nil)
    // An array value ends the scan.
    var array = Data("GGUF".utf8) + littleEndian(UInt32(3)) + littleEndian(UInt64(0)) + littleEndian(UInt64(2))
    array += ggufString("tokens") + littleEndian(UInt32(9))
    array += ggufString("split.count") + littleEndian(UInt32(2)) + littleEndian(UInt16(2))
    #expect(ModelValidator.splitCount(array) == nil)
    // GGUF v1 has 32-bit counts, so the scan skips it.
    #expect(ModelValidator.splitCount(Data("GGUF".utf8) + littleEndian(UInt32(1)) + Data(count: 64)) == nil)
}

/// #122: the bookmark is saved in the data folder and resolves to the file in place, also after a move.
@Test func modelBookmarkStoreReadsTheModelInPlace() throws {
    let folder = try modelFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = ModelBookmarkStore(directory: folder.appending(path: "Support"), securityScoped: false)
    #expect(store.load() == nil)

    let url = try write(gguf(), "a.gguf", in: folder)
    try store.save(url)
    #expect(store.fileURL.lastPathComponent == "LocalModel.json")
    let model = try #require(try store.load()?.get())
    #expect(model.url.resolvingSymlinksInPath() == url.resolvingSymlinksInPath())
    // The app reads the file where it is. Nothing is copied next to the bookmark.
    #expect(try FileManager.default.contentsOfDirectory(atPath: store.fileURL.deletingLastPathComponent().path) == ["LocalModel.json"])
    #expect(try store.withAccess(to: model.url) { try Data(contentsOf: model.url).prefix(4) } == Data("GGUF".utf8))

    // A moved file resolves, and the store saves the new path.
    let moved = folder.appending(path: "moved.gguf")
    try FileManager.default.moveItem(at: url, to: moved)
    #expect(try store.load()?.get().name == "moved.gguf")
    let saved = try JSONDecoder().decode(SavedModel.self, from: Data(contentsOf: store.fileURL))
    #expect(URL(fileURLWithPath: saved.path).lastPathComponent == "moved.gguf")
    #expect(saved.version == 1)

    // A deleted file is missing. The message uses the last known name.
    try FileManager.default.removeItem(at: moved)
    #expect(store.load() == .failure(.missing("moved.gguf")))
}

/// The app store uses a read-only security-scoped bookmark. It also resolves in a process with no App Sandbox.
@Test func securityScopedModelBookmarkResolves() throws {
    let folder = try modelFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = ModelBookmarkStore(directory: folder.appending(path: "Support"))
    let url = try write(gguf(), "scoped.gguf", in: folder)
    try store.save(url)
    #expect(try store.load()?.get().name == "scoped.gguf")
}

/// #122 snapshots: `settings` shows a valid model in the suggested folder, `settings-model-missing` the missing message.
@Test func settingsSnapshotsInjectTheModelState() throws {
    let home = URL(fileURLWithPath: "/Users/agent")
    let model = try #require(SnapshotScreen.settings.modelState(home: home).flatMap { state -> LocalModel? in
        if case .ready(let model) = state { model } else { nil }
    })
    #expect(model.detailText(home: home) == "2.1 GB · ~/Library/Application Support/Skillgarden/Models/qwen2.5-3b-instruct-q4_k_m.gguf")
    #expect(SnapshotScreen.settingsModelMissing.modelState(home: home) == .problem(.missing("qwen2.5-3b-instruct-q4_k_m.gguf")))
    #expect(SnapshotScreen.allCases.filter { $0.modelState(home: home) != nil } == [.settings, .settingsModelMissing, .settingsAIOff,
                                                                                    .settingsAIError])
    // #123: the AI screens show the same valid model.
    #expect(SnapshotScreen.settingsAIOff.modelState(home: home) == SnapshotScreen.settings.modelState(home: home))
    #expect(SnapshotScreen.settingsAIError.modelState(home: home) == SnapshotScreen.settings.modelState(home: home))
}

/// Saved data stays readable: a file with no version or path decodes. A damaged file is no model.
@Test func savedModelDecodesTolerantly() throws {
    let saved = try JSONDecoder().decode(SavedModel.self, from: Data(#"{"bookmark":"AAEC"}"#.utf8))
    #expect(saved.version == 1 && saved.path == "" && saved.bookmark == Data([0, 1, 2]))
    let folder = try modelFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = ModelBookmarkStore(directory: folder, securityScoped: false)
    try Data("{".utf8).write(to: store.fileURL)
    #expect(store.load() == nil)
    // A bookmark that does not resolve is a missing model.
    try JSONEncoder().encode(SavedModel(bookmark: Data([1, 2, 3]), path: "/Models/old.gguf")).write(to: store.fileURL)
    #expect(store.load() == .failure(.missing("old.gguf")))
}

/// #122: an invalid new choice keeps the earlier model. A valid choice replaces it and is saved.
@MainActor @Test func modelSettingsKeepsTheEarlierModelWhenAChoiceIsInvalid() async throws {
    let folder = try modelFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = ModelBookmarkStore(directory: folder.appending(path: "Support"), securityScoped: false)
    let settings = ModelSettings(store: store)
    await settings.load()
    #expect(settings.state == .none)

    let first = try write(gguf(), "first.gguf", in: folder)
    #expect(await settings.choose(first) == nil)
    #expect(settings.model?.name == "first.gguf")
    #expect(!settings.isChecking)

    let bad = try write(Data("text".utf8), "bad.gguf", in: folder)
    #expect(await settings.choose(bad) == .notGGUF("bad.gguf"))
    #expect(settings.model?.name == "first.gguf")
    let split = try write(gguf(), "m-00002-of-00002.gguf", in: folder)
    #expect(await settings.choose(split) == .splitPart("m-00002-of-00002.gguf"))
    #expect(settings.model?.name == "first.gguf")

    // The app starts again: the saved choice loads.
    let again = ModelSettings(store: store)
    await again.load()
    #expect(again.model?.name == "first.gguf")

    // The saved model is deleted: the row shows the missing message.
    try FileManager.default.removeItem(at: first)
    await again.load()
    #expect(again.state == .problem(.missing("first.gguf")))

    // The snapshot harness injects a state and saves nothing.
    let injected = ModelSettings(store: nil, state: .problem(.missing("x.gguf")))
    await injected.load()
    #expect(injected.state == .problem(.missing("x.gguf")))
}
