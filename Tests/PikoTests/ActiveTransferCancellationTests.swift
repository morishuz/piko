import Darwin
import Foundation
import MTPWire
import Testing

@testable import Piko

private final class CancellationPreparationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var startedValue = false
    private var snapshotAttemptsValue = 0

    var started: Bool {
        lock.lock()
        defer { lock.unlock() }
        return startedValue
    }

    var snapshotAttempts: Int {
        lock.lock()
        defer { lock.unlock() }
        return snapshotAttemptsValue
    }

    func markStarted() {
        lock.lock()
        startedValue = true
        lock.unlock()
    }

    func markSnapshotAttempt() {
        lock.lock()
        snapshotAttemptsValue += 1
        lock.unlock()
    }
}

private enum CancellationFixtureError: Error { case timedOut }

private func waitForStart(_ probe: CancellationPreparationProbe) async throws {
    for _ in 0..<1_000 {
        if probe.started { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    throw CancellationFixtureError.timedOut
}

private final class CancellationTestDirectory {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "active-transfer-cancellation-\(UUID().uuidString)", isDirectory: true)

    init() throws {
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
    }

    func file(_ name: String, bytes: Data = Data("fixture".utf8)) throws -> URL {
        let result = url.appendingPathComponent(name)
        try bytes.write(to: result)
        return result
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}

private actor CancellableUploadBackend: MTPUploadBackend {
    enum CancellationOutcome: Sendable {
        case preflight
        case remoteWrite
        case recoveredRemoteWrite
        case unexpectedInvocation
    }

    nonisolated let capabilities: BackendCapabilities
    nonisolated let maximumUploadFileSize: Int64?
    private let cancellationOutcome: CancellationOutcome
    private var uploadCallsValue = 0
    private var listingCallsValue = 0
    private var uploadStartedObserver: CheckedContinuation<Void, Never>?

    init(cancellationOutcome: CancellationOutcome, maximumUploadFileSize: Int64? = nil,
         canCancelActiveTransfer: Bool = true) {
        self.capabilities = BackendCapabilities(
            reportsProgress: true, canCancelActiveTransfer: canCancelActiveTransfer)
        self.cancellationOutcome = cancellationOutcome
        self.maximumUploadFileSize = maximumUploadFileSize
    }

    var uploadCalls: Int { uploadCallsValue }
    var listingCalls: Int { listingCallsValue }

    func connect() async throws -> [MTPStorage] { [DemoBackend.storage] }
    func disconnect() async throws -> Bool { true }
    func contents(storageID: UInt32, path: String, showHiddenFiles: Bool) async throws -> [MTPFile] {
        listingCallsValue += 1
        return []
    }
    func download(
        storageID: UInt32, files: [MTPFile], to destination: URL,
        progress: @escaping ProgressHandler
    ) async throws {}

    func upload(
        storageID: UInt32, source: URL, to directory: String,
        progress: @escaping ProgressHandler
    ) async throws -> UploadDisposition {
        uploadCallsValue += 1
        uploadStartedObserver?.resume()
        uploadStartedObserver = nil
        if cancellationOutcome == .unexpectedInvocation {
            return .uploaded
        }
        do {
            try await Task.sleep(for: .seconds(30))
            return .uploaded
        } catch is CancellationError {
            switch cancellationOutcome {
            case .preflight:
                throw UploadPreflightFailure(CancellationError())
            case .remoteWrite:
                throw BackendSessionError.reconnectRequired
            case .recoveredRemoteWrite:
                throw UploadError.cancelledSessionRecovered
            case .unexpectedInvocation:
                return .uploaded
            }
        }
    }

    func waitUntilUploadStarted() async {
        if uploadCallsValue > 0 { return }
        await withCheckedContinuation { uploadStartedObserver = $0 }
    }
}

private actor CancellableDownloadBackend: MTPBackend {
    nonisolated let capabilities = BackendCapabilities(
        reportsProgress: true, canCancelActiveTransfer: true)
    private var started = false
    private var listingCallsValue = 0
    private var startObserver: CheckedContinuation<Void, Never>?

    var listingCalls: Int { listingCallsValue }

    func connect() async throws -> [MTPStorage] { [DemoBackend.storage] }
    func disconnect() async throws -> Bool { true }
    func contents(storageID: UInt32, path: String, showHiddenFiles: Bool) async throws -> [MTPFile] {
        listingCallsValue += 1
        return [DemoBackend.entry(id: 91, name: "cancelled.bin", parent: "/", folder: false)]
    }
    func download(
        storageID: UInt32, files: [MTPFile], to destination: URL,
        progress: @escaping ProgressHandler
    ) async throws {
        started = true
        startObserver?.resume()
        startObserver = nil
        try await Task.sleep(for: .seconds(30))
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startObserver = $0 }
    }
}

private actor BlockingDownloadPlanningBackend: MTPBackend {
    nonisolated let capabilities = BackendCapabilities(
        reportsProgress: true, canCancelActiveTransfer: true)
    private var listingStarted = false
    private var startObserver: CheckedContinuation<Void, Never>?
    private(set) var observedCancellation = false

    func connect() async throws -> [MTPStorage] { [DemoBackend.storage] }
    func disconnect() async throws -> Bool { true }
    func contents(storageID: UInt32, path: String, showHiddenFiles: Bool) async throws -> [MTPFile] {
        listingStarted = true
        startObserver?.resume()
        startObserver = nil
        do {
            try await Task.sleep(for: .seconds(30))
            return []
        } catch is CancellationError {
            observedCancellation = true
            throw CancellationError()
        }
    }
    func download(
        storageID: UInt32, files: [MTPFile], to destination: URL,
        progress: @escaping ProgressHandler
    ) async throws {
        Issue.record("Download must not begin while folder planning is blocked")
    }

    func waitUntilListingStarts() async {
        if listingStarted { return }
        await withCheckedContinuation { startObserver = $0 }
    }
}

private actor ImmediatePreflightFailureBackend: MTPUploadBackend {
    enum Failure: Sendable { case reconnect, rejected }

    nonisolated let capabilities = BackendCapabilities(
        reportsProgress: false, canCancelActiveTransfer: true)
    private let failure: Failure
    private var uploadCallsValue = 0

    init(_ failure: Failure) { self.failure = failure }
    var uploadCalls: Int { uploadCallsValue }

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
        uploadCallsValue += 1
        switch failure {
        case .reconnect:
            throw UploadPreflightFailure(BackendSessionError.reconnectRequired)
        case .rejected:
            throw UploadPreflightFailure(UploadError.rejected("Rejected before SendObjectInfo"))
        }
    }
}

@MainActor @Test func cancelTransferInterruptsUploadPlanning() async throws {
    let local = try CancellationTestDirectory()
    let source = try local.file("planning.txt")
    let probe = CancellationPreparationProbe()
    let backend = CancellableUploadBackend(
        cancellationOutcome: .unexpectedInvocation, canCancelActiveTransfer: false)
    let coordinator = TransferCoordinator(
        uploadPlanner: { _, cancellation in
            probe.markStarted()
            while !cancellation.isCancelled, !Task.isCancelled { usleep(1_000) }
            throw CancellationError()
        })

    let task = Task {
        try await coordinator.upload(
            backend: backend, storageID: 1, sources: [source], directory: "/")
    }
    try await waitForStart(probe)
    #expect(!coordinator.canCancelActiveTransfer)
    coordinator.cancelTransfer()

    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(await backend.uploadCalls == 0)
    #expect(coordinator.results.isEmpty)
    #expect(!coordinator.isRunning)
}

@MainActor @Test func cancelTransferInterruptsSnapshotBeforeAnyRemoteWrite() async throws {
    let local = try CancellationTestDirectory()
    let source = try local.file("snapshot.txt")
    let probe = CancellationPreparationProbe()
    let backend = CancellableUploadBackend(
        cancellationOutcome: .unexpectedInvocation, canCancelActiveTransfer: false)
    let coordinator = TransferCoordinator(
        uploadSnapshotter: { _ in
            probe.markStarted()
            while !Task.isCancelled { usleep(1_000) }
            throw CancellationError()
        })

    let task = Task {
        try await coordinator.upload(
            backend: backend, storageID: 1, sources: [source], directory: "/")
    }
    try await waitForStart(probe)
    #expect(coordinator.isPlanning)
    coordinator.cancelTransfer()

    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(await backend.uploadCalls == 0)
    #expect(coordinator.results.map(\.outcome) == [.notAttempted])
}

@MainActor @Test func cancelledBackendPreflightIsDefiniteAndNotAttempted() async throws {
    let local = try CancellationTestDirectory()
    let source = try local.file("preflight.txt")
    let backend = CancellableUploadBackend(cancellationOutcome: .preflight)
    let coordinator = TransferCoordinator()
    let task = Task {
        try await coordinator.upload(
            backend: backend, storageID: 1, sources: [source], directory: "/")
    }
    await backend.waitUntilUploadStarted()
    coordinator.cancelTransfer()

    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(coordinator.results.map(\.outcome) == [.notAttempted])
    #expect(coordinator.results.allSatisfy {
        if case .uploadUncertain = $0.outcome { false } else { true }
    })
}

@MainActor @Test func cancelledRemoteWriteRemainsUncertainAndRequiresReconnect() async throws {
    let local = try CancellationTestDirectory()
    let source = try local.file("remote-write.txt")
    let backend = CancellableUploadBackend(cancellationOutcome: .remoteWrite)
    let coordinator = TransferCoordinator()
    let task = Task {
        try await coordinator.upload(
            backend: backend, storageID: 1, sources: [source], directory: "/")
    }
    await backend.waitUntilUploadStarted()
    coordinator.cancelTransfer()

    await #expect(throws: BackendSessionError.reconnectRequired) { try await task.value }
    #expect(coordinator.results.count == 1)
    #expect({
        if case .uploadUncertain = coordinator.results[0].outcome { true } else { false }
    }())
}

@MainActor @Test func protocolRecoveredCancellationDoesNotRequireReconnect() async throws {
    let local = try CancellationTestDirectory()
    let source = try local.file("recovered-write.txt")
    let backend = CancellableUploadBackend(cancellationOutcome: .recoveredRemoteWrite)
    let coordinator = TransferCoordinator()
    let task = Task {
        try await coordinator.upload(
            backend: backend, storageID: 1, sources: [source], directory: "/")
    }
    await backend.waitUntilUploadStarted()
    coordinator.cancelTransfer()

    try await task.value
    #expect(coordinator.results.count == 1)
    #expect({
        if case .uploadCancelled = coordinator.results[0].outcome { true } else { false }
    }())
    #expect(coordinator.results.allSatisfy {
        if case .uploadUncertain = $0.outcome { false } else { true }
    })
}

@MainActor @Test func browserPreservesListingAfterRecoveredUploadCancellationUntilManualRefresh()
    async throws
{
    let local = try CancellationTestDirectory()
    let source = try local.file("browser-recovered.txt")
    let backend = CancellableUploadBackend(cancellationOutcome: .recoveredRemoteWrite)
    let model = DeviceBrowserModel(client: PreparedBinFixture(backend))
    await model.connectAndLoad()
    #expect(model.canUpload)
    let initialListingCalls = await backend.listingCalls

    let task = Task { await model.upload(sources: [source]) }
    await backend.waitUntilUploadStarted()
    model.transfers.cancelTransfer()
    await task.value

    #expect(model.state == .connected)
    #expect(!model.uploadNeedsReconnect)
    #expect(model.canUpload)
    #expect(model.transferConfirmation?.contains("1 cancelled") == true)
    #expect(await backend.listingCalls == initialListingCalls)

    await model.load(path: model.currentPath)
    #expect(await backend.listingCalls > initialListingCalls)
}

@MainActor @Test func browserPreservesListingAfterCleanDownloadCancellationUntilManualRefresh()
    async throws
{
    let output = try CancellationTestDirectory()
    let backend = CancellableDownloadBackend()
    let log = DiagnosticLog()
    let model = DeviceBrowserModel(client: backend, diagnostics: log)
    await model.connectAndLoad()
    let file = try #require(model.files.first)
    #expect(await backend.listingCalls == 1)

    let task = Task { await model.download(files: [file], to: output.url) }
    await backend.waitUntilStarted()
    model.transfers.cancelTransfer()
    await task.value

    #expect(model.state == .connected)
    #expect(model.transferConfirmation == nil)
    #expect(model.files == [file])
    #expect(await backend.listingCalls == 1)
    let cancellation = try #require(log.snapshot().events.first { $0.kind == .cancelRequested })
    let download = try #require(log.snapshot().events.last { $0.kind == .download })
    #expect(cancellation.transferDirection == .download)
    #expect(cancellation.transferID != nil)
    #expect(download.transferID == cancellation.transferID)

    await model.load(path: model.currentPath)
    #expect(await backend.listingCalls == 2)
}

@MainActor @Test func oversizedUploadIsRejectedBeforeSnapshotOrBackendCall() async throws {
    let local = try CancellationTestDirectory()
    let source = try local.file("too-large.bin", bytes: Data([1, 2]))
    let probe = CancellationPreparationProbe()
    let backend = CancellableUploadBackend(
        cancellationOutcome: .unexpectedInvocation, maximumUploadFileSize: 1)
    let coordinator = TransferCoordinator(
        uploadSnapshotter: { item in
            probe.markSnapshotAttempt()
            return try UploadSnapshot(source: item.source)
        })

    try await coordinator.upload(
        backend: backend, storageID: 1, sources: [source], directory: "/")

    #expect(probe.snapshotAttempts == 0)
    #expect(await backend.uploadCalls == 0)
    #expect(coordinator.results.count == 1)
    #expect({ if case .failed = coordinator.results[0].outcome { true } else { false } }())
}

@MainActor @Test func cancelTransferInterruptsActiveDownloadAndKeepsStagingPrivate() async throws {
    let output = try CancellationTestDirectory()
    let backend = CancellableDownloadBackend()
    let coordinator = TransferCoordinator()
    let file = DemoBackend.entry(id: 91, name: "cancelled.bin", parent: "/", folder: false)
    let task = Task {
        try await coordinator.run(
            backend: backend, storageID: 1, files: [file], destination: output.url)
    }
    await backend.waitUntilStarted()
    #expect(coordinator.canCancelActiveTransfer)
    coordinator.cancelTransfer()

    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(coordinator.results.map(\.outcome) == [.notAttempted])
    #expect(try FileManager.default.contentsOfDirectory(atPath: output.url.path).isEmpty)
}

@MainActor @Test func cancelTransferInterruptsBlockedDownloadFolderPlanning() async throws {
    let output = try CancellationTestDirectory()
    let backend = BlockingDownloadPlanningBackend()
    let coordinator = TransferCoordinator()
    let folder = DemoBackend.entry(id: 92, name: "Blocked", parent: "/", folder: true)
    let task = Task {
        try await coordinator.run(
            backend: backend, storageID: 1, files: [folder], destination: output.url)
    }
    await backend.waitUntilListingStarts()
    #expect(coordinator.isPlanning)
    #expect(coordinator.canCancelActiveTransfer)
    coordinator.cancelTransfer()

    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(await backend.observedCancellation)
    #expect(coordinator.results.isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath: output.url.path).isEmpty)
}

@MainActor @Test func reconnectingPreflightFailureIsNotMisclassifiedAsCancellation() async throws {
    let local = try CancellationTestDirectory()
    let sources = try ["first.bin", "second.bin"].map { try local.file($0) }
    let backend = ImmediatePreflightFailureBackend(.reconnect)
    let coordinator = TransferCoordinator()

    await #expect(throws: BackendSessionError.reconnectRequired) {
        try await coordinator.upload(
            backend: backend, storageID: 1, sources: sources, directory: "/")
    }

    #expect(await backend.uploadCalls == 1)
    #expect(coordinator.results.count == 2)
    #expect({ if case .failed = coordinator.results[0].outcome { true } else { false } }())
    #expect(coordinator.results[1].outcome == .notAttempted)
    #expect(coordinator.results.allSatisfy {
        if case .uploadUncertain = $0.outcome { false } else { true }
    })
}

@MainActor @Test func rejectedPreflightFailureIsFailedAndBatchContinues() async throws {
    let local = try CancellationTestDirectory()
    let sources = try ["first.bin", "second.bin"].map { try local.file($0) }
    let backend = ImmediatePreflightFailureBackend(.rejected)
    let coordinator = TransferCoordinator()

    try await coordinator.upload(
        backend: backend, storageID: 1, sources: sources, directory: "/")

    #expect(await backend.uploadCalls == 2)
    #expect(coordinator.results.count == 2)
    #expect(coordinator.results.allSatisfy {
        if case .failed = $0.outcome { true } else { false }
    })
    #expect(!coordinator.stopRequested)
}
