import Foundation
import Testing

@testable import Piko

private final class UploadFixture {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "upload-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }
    func file(_ name: String, bytes: Data = Data("upload fixture".utf8)) throws -> URL {
        let url = root.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }
    deinit { try? FileManager.default.removeItem(at: root) }
}

private actor FileOnlyDropBackend: MTPUploadBackend {
    nonisolated let capabilities = BackendCapabilities(
        reportsProgress: false, canCancelActiveTransfer: false)
    private(set) var uploadCount = 0
    private var uploadObserver: CheckedContinuation<Void, Never>?

    func connect() async throws -> [MTPStorage] { [DemoBackend.storage] }
    func disconnect() async throws -> Bool { true }
    func contents(storageID: UInt32, path: String, showHiddenFiles: Bool) async throws -> [MTPFile] {
        []
    }
    func download(
        storageID: UInt32, files: [MTPFile], to destination: URL,
        progress: @escaping ProgressHandler
    ) async throws {}
    func upload(
        storageID: UInt32, source: URL, to directory: String,
        progress: @escaping ProgressHandler
    ) async throws -> UploadDisposition {
        uploadCount += 1
        uploadObserver?.resume()
        uploadObserver = nil
        return .skippedExisting
    }

    func waitForUpload() async {
        if uploadCount > 0 { return }
        await withCheckedContinuation { uploadObserver = $0 }
    }
}

private actor RuntimeReadOnlyUploadBackend: MTPUploadBackend {
    nonisolated let capabilities = BackendCapabilities(
        reportsProgress: false, canCancelActiveTransfer: false)

    func supportsUpload(to storageID: UInt32) async -> Bool { false }
    func connect() async throws -> [MTPStorage] { [DemoBackend.storage] }
    func disconnect() async throws -> Bool { true }
    func contents(storageID: UInt32, path: String, showHiddenFiles: Bool) async throws -> [MTPFile] {
        []
    }
    func download(
        storageID: UInt32, files: [MTPFile], to destination: URL,
        progress: @escaping ProgressHandler
    ) async throws {}
    func upload(
        storageID: UInt32, source: URL, to directory: String,
        progress: @escaping ProgressHandler
    ) async throws -> UploadDisposition {
        Issue.record("An unavailable upload backend must not be invoked")
        return .uploaded
    }
}

@MainActor @Test func demoUploadsRoundTripAndRefreshBrowser() async throws {
    let local = try UploadFixture()
    let output = try UploadFixture()
    let a = try local.file("a.txt")
    let b = try local.file("empty.txt", bytes: Data())
    let unicode = try local.file("写真.txt", bytes: Data([0, 1, 2, 255]))
    let backend = DemoBackend(delay: .zero)
    let model = DeviceBrowserModel(client: backend)
    await model.connectAndLoad()
    await model.load(path: "/Demo Files")
    #expect(model.canUpload)
    await model.upload(sources: [a, b, unicode])
    #expect(model.transferConfirmation == nil)
    #expect(model.files.contains { $0.name == "写真.txt" })
    #expect(!model.isTransferring)
    let files = model.files.filter { ["a.txt", "empty.txt", "写真.txt"].contains($0.name) }
    await model.download(files: files, to: output.root)
    for source in [a, b, unicode] {
        #expect(
            try Data(contentsOf: source)
                == Data(contentsOf: output.root.appendingPathComponent(source.lastPathComponent)))
    }
}

@MainActor @Test func finderDropAcceptsLocalFilesAndQueuesUpload() async throws {
    let local = try UploadFixture()
    let source = try local.file("dropped.txt")
    let backend = FileOnlyDropBackend()
    let model = DeviceBrowserModel(client: PreparedBinFixture(backend))
    await model.connectAndLoad()

    #expect(model.acceptUploadDrop([source]))
    await backend.waitForUpload()
    #expect(await backend.uploadCount == 1)
}

@MainActor @Test func runtimeDeviceCapabilityKeepsUploadAndDropDisabled() async throws {
    let local = try UploadFixture()
    let model = DeviceBrowserModel(client: RuntimeReadOnlyUploadBackend())
    await model.connectAndLoad()

    #expect(model.isConnected)
    #expect(!model.uploadCapabilityAvailable)
    #expect(!model.canUpload)
    #expect(!model.acceptUploadDrop([try local.file("not-sent.txt")]))
}

@MainActor @Test func fileOnlyBackendWithoutRecognisedBinRejectsAllUploadDrops() async throws {
    let local = try UploadFixture()
    let backend = FileOnlyDropBackend()
    let model = DeviceBrowserModel(client: backend)
    await model.connectAndLoad()

    #expect(!model.acceptUploadDrop([]))
    #expect(!model.acceptUploadDrop([try #require(URL(string: "https://example.com/file.txt"))]))
    #expect(!model.acceptUploadDrop([local.root]))
    #expect(!model.canUpload && model.writeRestriction != nil)
    for _ in 0..<10 { await Task.yield() }
    #expect(await backend.uploadCount == 0)
}

@MainActor @Test func finderDropDoesNotStartAfterStorageContextChanges() async throws {
    let local = try UploadFixture()
    let source = try local.file("stale.txt")
    let backend = FileOnlyDropBackend()
    let model = DeviceBrowserModel(client: PreparedBinFixture(backend))
    await model.connectAndLoad()

    #expect(model.acceptUploadDrop([source]))
    model.selectStorage(nil)
    try await Task.sleep(for: .milliseconds(20))
    #expect(await backend.uploadCount == 0)
}

@MainActor @Test func uploadConflictsSkipCaseHiddenFolderAndBatchDuplicates() async throws {
    let local = try UploadFixture()
    let backend = DemoBackend(delay: .zero)
    _ = try await backend.connect()
    let coordinator = TransferCoordinator()
    let hidden = try local.file(".hidden.txt")
    try await coordinator.upload(backend: backend, storageID: 1, sources: [hidden], directory: "/Demo Files")
    let a = try local.file("sample-0002.TXT")
    let folderConflict = try local.file("Nested")
    let fresh = try local.file("fresh.txt")
    try await coordinator.upload(
        backend: backend, storageID: 1,
        sources: [a, folderConflict, hidden, fresh, fresh], directory: "/Demo Files")
    // Exact duplicate sources are planned once; only real remote conflicts are reported.
    #expect(coordinator.plannedCount == 4)
    #expect(coordinator.results.filter {
        if case .uploadConflict = $0.outcome { true } else { false }
    }.count == 3)
    #expect(coordinator.results.filter { if case .uploaded = $0.outcome { true } else { false } }.count == 1)
    let contents = try await backend.contents(storageID: 1, path: "/Demo Files", showHiddenFiles: true)
    #expect(contents.first { $0.name == "Sample-0002.txt" }?.size == 8192)
    #expect(contents.first { $0.name == "Nested" }?.isFolder == true)
    #expect(contents.filter { $0.name == "fresh.txt" }.count == 1)
}

@MainActor @Test func uploadKnownRejectionsReportFailureAndContinue() async throws {
    let local = try UploadFixture()
    let sources = try ["denied.txt", "full.txt", "good.txt"].map { try local.file($0) }
    let backend = DemoBackend(
        delay: .zero, uploadFailures: ["denied.txt": .permissionDenied, "full.txt": .storageFull])
    _ = try await backend.connect()
    let coordinator = TransferCoordinator()
    try await coordinator.upload(backend: backend, storageID: 1, sources: sources, directory: "/")
    #expect(coordinator.results.filter { if case .failed = $0.outcome { true } else { false } }.count == 2)
    #expect(coordinator.results.filter { if case .uploaded = $0.outcome { true } else { false } }.count == 1)
    #expect(coordinator.results.allSatisfy { if case .uploadUncertain = $0.outcome { false } else { true } })
}

@MainActor @Test func uploadPartialDisconnectStopsBatchAndRequiresReconnect() async throws {
    let local = try UploadFixture()
    let sources = try ["good.txt", "broken.txt", "later.txt"].map { try local.file($0) }
    let backend = DemoBackend(delay: .zero, uploadFailures: ["broken.txt": .partialDisconnect])
    let model = DeviceBrowserModel(client: backend)
    await model.connectAndLoad()
    await model.upload(sources: sources)
    #expect(model.uploadNeedsReconnect)
    #expect(!model.canUpload)
    #expect(model.transfers.results.count == 3)
    #expect(model.transfers.results.last?.outcome == .notAttempted)
    #expect(model.transferConfirmation?.contains("1 uncertain") == true)
    // A terminal loss exposes Connect directly; a successful fresh connection
    // clears the prior upload uncertainty without requiring a redundant dispose.
    await model.connectAndLoad()
    #expect(model.isConnected)
    #expect(model.canUpload)
    #expect(model.files.contains { $0.name == "broken.txt" && $0.size < 13 })
    #expect(!model.files.contains { $0.name == "later.txt" })
    // Explicit retry reports the partial object as a conflict. No automatic deletion/replacement.
    await model.upload(sources: [sources[1]])
    let retryWasConflict: Bool
    if case .uploadConflict = model.transfers.results.first?.outcome {
        retryWasConflict = true
    } else {
        retryWasConflict = false
    }
    #expect(retryWasConflict)
}

@Test func uploadSnapshotRejectsNonregularSourcesAndIsIndependent() throws {
    let local = try UploadFixture()
    let source = try local.file("original.txt")
    let snapshot = try UploadSnapshot(source: source)
    defer { snapshot.remove() }
    try Data("changed".utf8).write(to: source)
    #expect(try Data(contentsOf: snapshot.file) == Data("upload fixture".utf8))
    let link = local.root.appendingPathComponent("link.txt")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
    #expect(throws: UploadError.unsupportedSource) { try UploadSnapshot(source: link) }
    #expect(throws: UploadError.unsupportedSource) { try UploadSnapshot(source: local.root) }
    #expect(throws: (any Error).self) {
        try UploadSnapshot(source: local.root.appendingPathComponent("missing.txt"))
    }
    for path in ["relative", "/../escape", "/bad//path", "/bad/", "/bad\0path"] {
        #expect(throws: (any Error).self) { try RemotePath.validate(path) }
    }
    try RemotePath.validate("/")
    try RemotePath.validate("/DCIM/Camera")
}

private actor ControlledUploadBackend: MTPUploadBackend {
    nonisolated let capabilities = BackendCapabilities(reportsProgress: true, canCancelActiveTransfer: false)
    var files: [MTPFile] = []
    var observedSources: [URL] = []
    private var waiting: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    let verify: Bool
    let readOnly: Bool
    let terminalError: BackendSessionError?
    init(
        verify: Bool = true, readOnly: Bool = false,
        terminalError: BackendSessionError? = nil
    ) {
        self.verify = verify
        self.readOnly = readOnly
        self.terminalError = terminalError
    }
    func connect() async throws -> [MTPStorage] {
        if !readOnly { return [DemoBackend.storage] }
        let info = DemoBackend.storage.info
        return [
            MTPStorage(
                id: 1,
                info: MTPStorageInfo(
                    storageType: info.storageType,
                    filesystemType: info.filesystemType, accessCapability: 1, maxCapacity: info.maxCapacity,
                    freeSpaceInBytes: info.freeSpaceInBytes, freeSpaceInImages: 0,
                    storageDescription: "Read only", volumeLabel: ""))
        ]
    }
    func disconnect() async throws -> Bool { true }
    func contents(storageID: UInt32, path: String, showHiddenFiles: Bool) async throws -> [MTPFile] { files }
    func download(
        storageID: UInt32, files: [MTPFile], to destination: URL, progress: @escaping ProgressHandler
    ) async throws {}
    func upload(storageID: UInt32, source: URL, to directory: String, progress: @escaping ProgressHandler)
        async throws -> UploadDisposition
    {
        observedSources.append(source)
        if let terminalError {
            progress(
                TransferProgress(
                    fileName: source.lastPathComponent, bytesTransferred: 500,
                    totalBytes: try LocalFileIO.sourceSize(source)))
            throw terminalError
        }
        if verify {
            await withCheckedContinuation { continuation in
                waiting = continuation
                started?.resume()
                started = nil
            }
            try Task.checkCancellation()
            let size = try LocalFileIO.sourceSize(source)
            files.append(
                MTPFile(
                    size: size, isFolder: false, dateAdded: "", name: source.lastPathComponent,
                    path: "/\(source.lastPathComponent)", parentPath: "/", fileExtension: "txt", parentID: 0,
                    id: 1))
            progress(
                TransferProgress(fileName: source.lastPathComponent, bytesTransferred: size, totalBytes: size)
            )
        }
        return .uploaded
    }
    func waitUntilStarted() async {
        if waiting != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func release() {
        waiting?.resume()
        waiting = nil
    }
}

@MainActor @Test func uploadSessionFailureClearsSessionAndExplainsUncertainOutcome() async throws {
    let timeout = BackendSessionError.usbTransportFailure(
        "USB transfer timed out")
    let backend = ControlledUploadBackend(terminalError: timeout)
    let model = DeviceBrowserModel(client: PreparedBinFixture(backend))
    await model.connectAndLoad()
    let local = try UploadFixture()
    await model.upload(sources: [try local.file("timeout.png")])

    #expect(model.state == .reconnectRequired(timeout.localizedDescription))
    #expect(model.uploadNeedsReconnect)
    #expect(model.operationError == nil)
    #expect(model.transferConfirmation?.contains("1 uncertain") == true)
    #expect(model.transferConfirmation?.contains("reconnect before retrying") == true)
}

@MainActor @Test func uploadStopFinishesCurrentRejectsOverlapAndCleansSnapshot() async throws {
    let local = try UploadFixture()
    let sources = try ["first.txt", "second.txt"].map { try local.file($0) }
    let backend = ControlledUploadBackend()
    let coordinator = TransferCoordinator()
    let task = Task {
        try await coordinator.upload(backend: backend, storageID: 1, sources: sources, directory: "/")
    }
    await backend.waitUntilStarted()
    #expect(coordinator.isRunning)
    await #expect(throws: BackendError.busy) {
        try await coordinator.run(backend: backend, storageID: 1, files: [], destination: local.root)
    }
    coordinator.cancelTransfer()
    await backend.release()
    try await task.value
    #expect(coordinator.results.first?.outcome == .uploaded("/first.txt"))
    #expect(coordinator.results.last?.outcome == .notAttempted)
    let staged = await backend.observedSources
    #expect(staged.count == 1)
    for path in staged {
        #expect(!FileManager.default.fileExists(atPath: path.deletingLastPathComponent().path))
    }
    #expect(try Data(contentsOf: sources[0]) == Data("upload fixture".utf8))
}

@MainActor @Test func unverifiedUploadIsUncertainAndNeverRetried() async throws {
    let local = try UploadFixture()
    let sources = try ["first.txt", "second.txt"].map { try local.file($0) }
    let backend = ControlledUploadBackend(verify: false)
    let coordinator = TransferCoordinator()
    try await coordinator.upload(backend: backend, storageID: 1, sources: sources, directory: "/")
    #expect(
        coordinator.results.filter { if case .uploadUncertain = $0.outcome { true } else { false } }.count
            == 1)
    #expect(coordinator.results.last?.outcome == .notAttempted)
    let staged = await backend.observedSources
    #expect(staged.count == 1)
    for path in staged { #expect(!FileManager.default.fileExists(atPath: path.path)) }
}

@MainActor @Test func readOnlyStorageDisablesUploads() async throws {
    let backend = ControlledUploadBackend(readOnly: true)
    let model = DeviceBrowserModel(client: backend)
    await model.connectAndLoad()
    #expect(model.isConnected)
    #expect(!model.canUpload)
    let local = try UploadFixture()
    await model.upload(sources: [try local.file("not-sent.txt")])
    #expect(await backend.observedSources.isEmpty)
}
