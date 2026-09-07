import Foundation
import Testing

@testable import Piko

private final class FolderFixture {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "folder-upload-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }
    func directory(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func file(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture: \(path)".utf8).write(to: url)
        return url
    }
    deinit { try? FileManager.default.removeItem(at: root) }
}

@Test func duplicateUploadRootsArePlannedOnce() throws {
    let local = try FolderFixture()
    let folder = try local.directory("Album")
    let child = try local.file("Album/photo.txt")
    let plan = try UploadPlan.build(sources: [child, folder, folder, child])
    #expect(
        plan.map { $0.source.resolvingSymlinksInPath() }
            == [folder, child].map { $0.resolvingSymlinksInPath() })
}

@Test func folderPlanPreservesHierarchyAndAvoidsOverlappingSelections() throws {
    let local = try FolderFixture()
    let folder = try local.directory("Album")
    let child = try local.file("Album/Sub/photo.txt")
    _ = try local.directory("Album/Empty")
    _ = try local.file("Album/.DS_Store")
    _ = try local.file("Album/.hidden.txt")
    let plan = try UploadPlan.build(sources: [child, folder])
    #expect(plan.count == 6)
    #expect(plan.first?.components == ["Album"])
    #expect(plan.first?.remoteParent(in: "/") == "/")
    #expect(plan.last?.components == ["Album", "Sub", "photo.txt"])
    #expect(plan.last?.remoteParent(in: "/Demo Files") == "/Demo Files/Album/Sub")
    #expect(plan.filter { if case .excluded = $0.kind { true } else { false } }.count == 1)
    #expect(plan.contains { $0.source.lastPathComponent == ".hidden.txt" })
}

@MainActor @Test func folderUploadsAndDownloadsRoundTripIncludingEmptyDirectories() async throws {
    let local = try FolderFixture()
    let output = try FolderFixture()
    let folder = try local.directory("旅行 Album")
    let a = try local.file("旅行 Album/a.txt")
    let b = try local.file("旅行 Album/Sub/写真.txt")
    _ = try local.directory("旅行 Album/Empty")
    _ = try local.file("旅行 Album/.DS_Store")
    let backend = DemoBackend(delay: .zero)
    let model = DeviceBrowserModel(client: backend)
    await model.connectAndLoad()
    await model.load(path: "/Demo Files")
    await model.upload(sources: [folder])
    #expect(model.transferConfirmation == nil)
    #expect(model.transfers.summary.uploaded == 2)
    #expect(model.transfers.summary.folders == 3)
    #expect(model.transfers.summary.excluded == 1)
    let remote = try #require(model.files.first { $0.name == "旅行 Album" })
    await model.download(files: [remote], to: output.root)
    #expect(model.transferConfirmation == nil)
    for source in [a, b] {
        let relative = String(source.path.dropFirst(local.root.path.count + 1))
        #expect(
            try Data(contentsOf: source) == Data(contentsOf: output.root.appendingPathComponent(relative)))
    }
    var isDirectory: ObjCBool = false
    #expect(
        FileManager.default.fileExists(
            atPath: output.root.appendingPathComponent("旅行 Album/Empty").path, isDirectory: &isDirectory))
    #expect(isDirectory.boolValue)
    #expect(
        !FileManager.default.fileExists(atPath: output.root.appendingPathComponent("旅行 Album/.DS_Store").path)
    )
}

@MainActor @Test func existingRemoteFolderSkipsEntireSubtreeWithoutMerging() async throws {
    let local = try FolderFixture()
    let folder = try local.directory("demo files")  // case-insensitive conflict
    _ = try local.file("demo files/Sub/new.txt")
    let backend = DemoBackend(delay: .zero)
    _ = try await backend.connect()
    let before = try await backend.contents(storageID: 1, path: "/Demo Files")
    let coordinator = TransferCoordinator()
    try await coordinator.upload(backend: backend, storageID: 1, sources: [folder], directory: "/")
    #expect(coordinator.results.count == 3)
    #expect(coordinator.results.allSatisfy {
        if case .uploadConflict = $0.outcome { true } else { false }
    })
    #expect(try await backend.contents(storageID: 1, path: "/Demo Files") == before)
}

@MainActor @Test func remoteFileCollisionBlocksFolderAndChildren() async throws {
    let local = try FolderFixture()
    let other = try FolderFixture()
    let file = try local.file("Collision")
    let folder = try other.directory("Collision")
    _ = try other.file("Collision/child.txt")
    let backend = DemoBackend(delay: .zero)
    _ = try await backend.connect()
    let coordinator = TransferCoordinator()
    try await coordinator.upload(backend: backend, storageID: 1, sources: [file], directory: "/")
    try await coordinator.upload(backend: backend, storageID: 1, sources: [folder], directory: "/")
    #expect(coordinator.results.count == 2)
    #expect(coordinator.results.allSatisfy {
        if case .uploadConflict = $0.outcome { true } else { false }
    })
    let remote = try #require(
        try await backend.contents(storageID: 1, path: "/").first { $0.name == "Collision" })
    #expect(!remote.isFolder)
    let originalSize = Int64(try Data(contentsOf: file).count)
    #expect(remote.size == originalSize)
}

@MainActor @Test func rejectedFolderBlocksChildrenButAllowsIndependentFile() async throws {
    let local = try FolderFixture()
    let folder = try local.directory("Denied")
    _ = try local.file("Denied/Sub/child.txt")
    let good = try local.file("good.txt")
    let backend = DemoBackend(delay: .zero, uploadFailures: ["Denied": .permissionDenied])
    _ = try await backend.connect()
    let coordinator = TransferCoordinator()
    try await coordinator.upload(backend: backend, storageID: 1, sources: [folder, good], directory: "/")
    #expect(coordinator.results.filter { if case .failed = $0.outcome { true } else { false } }.count == 1)
    #expect(coordinator.results.filter { $0.outcome == .notAttempted }.count == 2)
    #expect(coordinator.results.last?.outcome == .uploaded("/good.txt"))
    #expect(try await backend.contents(storageID: 1, path: "/").allSatisfy { $0.name != "Denied" })
}

@MainActor @Test func ambiguousFolderCreationStopsBatchWithoutCleanup() async throws {
    let local = try FolderFixture()
    let folder = try local.directory("Broken")
    _ = try local.file("Broken/child.txt")
    let later = try local.file("later.txt")
    let backend = DemoBackend(delay: .zero, uploadFailures: ["Broken": .partialDisconnect])
    let model = DeviceBrowserModel(client: backend)
    await model.connectAndLoad()
    await model.upload(sources: [folder, later])
    #expect(model.uploadNeedsReconnect)
    #expect(
        model.transfers.results.filter { if case .uploadUncertain = $0.outcome { true } else { false } }.count
            == 1)
    #expect(model.transfers.results.filter { $0.outcome == .notAttempted }.count == 2)
    await model.disconnectAndReset()
    await model.connectAndLoad()
    #expect(model.files.contains { $0.name == "Broken" && $0.isFolder })
    #expect(try await backend.contents(storageID: 1, path: "/Broken").isEmpty)
}

@MainActor @Test func invalidTreeIsRejectedBeforeCreatingAnyRemoteObjects() async throws {
    let local = try FolderFixture()
    let folder = try local.directory("Unsafe")
    _ = try local.file("Unsafe/good.txt")
    let link = folder.appendingPathComponent("loop")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
    let backend = DemoBackend(delay: .zero)
    _ = try await backend.connect()
    let coordinator = TransferCoordinator()
    await #expect(throws: UploadError.unsupportedSource) {
        try await coordinator.upload(backend: backend, storageID: 1, sources: [folder], directory: "/")
    }
    #expect(coordinator.results.isEmpty)
    #expect(!coordinator.isRunning)
    #expect(try await backend.contents(storageID: 1, path: "/").map(\.name) == ["Demo Files"])
    let package = try local.directory("Example.app")
    #expect(throws: UploadError.unsupportedSource) { try UploadPlan.build(sources: [package]) }
}

@Test func folderPlanLimitsCancellationAndAncestorChanges() throws {
    let local = try FolderFixture()
    let folder = try local.directory("Root")
    let child = try local.file("Root/Sub/child.txt")
    #expect(throws: TransferError.treeLimit) { try UploadPlan.build(sources: [folder], maximumItems: 2) }
    #expect(throws: TransferError.treeLimit) { try UploadPlan.build(sources: [folder], maximumDepth: 2) }
    #expect(throws: CancellationError.self) { try UploadPlan.build(sources: [folder], cancelled: { true }) }
    let item = try #require(UploadPlan.build(sources: [folder]).last)
    try item.validateAncestors()
    let sub = child.deletingLastPathComponent()
    let moved = folder.appendingPathComponent("Moved")
    try FileManager.default.moveItem(at: sub, to: moved)
    try FileManager.default.createSymbolicLink(at: sub, withDestinationURL: moved)
    #expect(throws: UploadError.sourceChanged) { try item.validateAncestors() }
}

private actor PausedDirectoryBackend: MTPFolderUploadBackend {
    nonisolated let capabilities = BackendCapabilities(reportsProgress: true, canCancelActiveTransfer: false)
    private let demo = DemoBackend(delay: .zero)
    private var waiter: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    func connect() async throws -> [MTPStorage] { try await demo.connect() }
    func disconnect() async throws -> Bool { try await demo.disconnect() }
    func contents(storageID: UInt32, path: String, showHiddenFiles: Bool) async throws -> [MTPFile] {
        try await demo.contents(storageID: storageID, path: path, showHiddenFiles: showHiddenFiles)
    }
    func download(
        storageID: UInt32, files: [MTPFile], to destination: URL, progress: @escaping ProgressHandler
    ) async throws {
        try await demo.download(storageID: storageID, files: files, to: destination, progress: progress)
    }
    func upload(storageID: UInt32, source: URL, to directory: String, progress: @escaping ProgressHandler)
        async throws -> UploadDisposition
    {
        try await demo.upload(storageID: storageID, source: source, to: directory, progress: progress)
    }
    func createUploadDirectory(storageID: UInt32, parent: String, name: String) async throws
        -> UploadDirectoryDisposition
    {
        let result = try await demo.createUploadDirectory(storageID: storageID, parent: parent, name: name)
        await withCheckedContinuation {
            waiter = $0
            observer?.resume()
            observer = nil
        }
        return result
    }
    func waitUntilCreated() async {
        if waiter != nil { return }
        await withCheckedContinuation { observer = $0 }
    }
    func release() {
        waiter?.resume()
        waiter = nil
    }
}

@MainActor @Test func stopDuringFolderCreationDoesNotSendChildren() async throws {
    let local = try FolderFixture()
    let folder = try local.directory("Stopped")
    _ = try local.file("Stopped/child.txt")
    let backend = PausedDirectoryBackend()
    _ = try await backend.connect()
    let coordinator = TransferCoordinator()
    let operation = Task {
        try await coordinator.upload(backend: backend, storageID: 1, sources: [folder], directory: "/")
    }
    await backend.waitUntilCreated()
    coordinator.stopAfterCurrentFile()
    await backend.release()
    try await operation.value
    #expect(coordinator.results.first?.outcome == .uploadedDirectory("/Stopped"))
    #expect(coordinator.results.last?.outcome == .notAttempted)
    #expect(try await backend.contents(storageID: 1, path: "/Stopped", showHiddenFiles: true).isEmpty)
}
