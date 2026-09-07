import Foundation
import Testing

@testable import Piko

private actor ShutdownBackend: MTPFreshSessionBackend {
    nonisolated let capabilities = BackendCapabilities(reportsProgress: false, canCancelActiveTransfer: false)
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var replacements = 0
    private let physicalCancellationFailure: Bool
    private let failureAfterRelease: Bool
    init(physicalCancellationFailure: Bool = false, failureAfterRelease: Bool = false) {
        self.physicalCancellationFailure = physicalCancellationFailure
        self.failureAfterRelease = failureAfterRelease
    }
    func replaceSession() async throws -> [MTPStorage] { replacements += 1; return [DemoBackend.storage] }
    private(set) var downloads = 0
    private(set) var disconnected = false
    private(set) var interrupted = false
    let files = [
        DemoBackend.entry(id: 10, name: "first.txt", parent: "/", folder: false),
        DemoBackend.entry(id: 11, name: "second.txt", parent: "/", folder: false),
    ]

    func connect() async throws -> [MTPStorage] { [DemoBackend.storage] }
    func contents(storageID: UInt32, path: String, showHiddenFiles: Bool) async throws -> [MTPFile] { files }
    func download(storageID: UInt32, files: [MTPFile], to destination: URL, progress: @escaping ProgressHandler) async throws {
        downloads += 1
        if physicalCancellationFailure { throw BackendSessionError.physicalReconnectRequired }
        await withCheckedContinuation { continuation = $0 }
        if failureAfterRelease { throw BackendSessionError.reconnectRequired }
        interrupted = Task.isCancelled || disconnected
        for file in files {
            try Data(repeating: 0x41, count: Int(file.size)).write(to: destination.appendingPathComponent(file.name))
        }
    }
    func releaseDownload() { continuation?.resume(); continuation = nil }
    func disconnect() async throws -> Bool { disconnected = true; return true }
}

@MainActor struct ShutdownTests {
    @Test func gracefulQuitFinishesCurrentFileSkipsQueueAndDisconnects() async throws {
        let backend = ShutdownBackend()
        let model = DeviceBrowserModel(client: backend)
        await model.connectAndLoad()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let download = Task { await model.download(files: model.files, to: directory) }
        for _ in 0..<1000 {
            if await backend.downloads > 0 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await backend.downloads == 1)
        let shutdown = Task { await model.prepareToQuit() }
        for _ in 0..<1000 {
            if model.isQuitting { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(model.isQuitting)
        #expect(model.transfers.stopRequested)
        #expect(await backend.disconnected == false)
        #expect(!model.canDownload)
        await backend.releaseDownload()
        await download.value
        await shutdown.value
        #expect(await backend.downloads == 1)
        #expect(await backend.interrupted == false)
        #expect(await backend.disconnected)
        #expect(model.state == .disconnected)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("first.txt").path))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("second.txt").path))
        await model.connectAndLoad()
        #expect(model.state == .disconnected)
    }

    @Test func idleQuitDisconnectsBeforeReturning() async {
        let backend = ShutdownBackend()
        let model = DeviceBrowserModel(client: backend)
        await model.connectAndLoad()
        await model.prepareToQuit()
        #expect(await backend.disconnected)
        #expect(model.state == .disconnected)
        #expect(model.isQuitting)
    }

    @Test func failedTransferDuringQuitDoesNotOpenReplacementSession() async throws {
        let backend = ShutdownBackend(failureAfterRelease: true)
        let model = DeviceBrowserModel(client: backend)
        await model.connectAndLoad()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let download = Task { await model.download(files: model.files, to: directory) }
        for _ in 0..<1000 {
            if await backend.downloads > 0 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await backend.downloads == 1)
        let shutdown = Task { await model.prepareToQuit() }
        for _ in 0..<1000 {
            if model.isQuitting { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(model.isQuitting)
        await backend.releaseDownload()
        await download.value
        await shutdown.value
        #expect(await backend.replacements == 0)
        #expect(await backend.disconnected)
        #expect(model.state == .disconnected)
        #expect(!model.isBusy)
    }
    @Test func failedCancellationDoesNotAutomaticallyReopenSession() async throws {
        let backend = ShutdownBackend(physicalCancellationFailure: true)
        let model = DeviceBrowserModel(client: backend)
        await model.connectAndLoad()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        await model.download(files: model.files, to: directory)
        #expect(await backend.replacements == 0)
        #expect(!model.isConnected)
        #expect(model.operationError?.contains("Unplug") == true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

}
