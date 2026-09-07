import Foundation
import Testing
@testable import Piko

private actor RecoveryListingBackend: MTPFreshSessionBackend {
    nonisolated let capabilities = BackendCapabilities(reportsProgress: false, canCancelActiveTransfer: false)
    private var failNextListing = false
    private var recovering = false
    private var readStarted = false
    private var readWaiter: CheckedContinuation<Void, Never>?
    private var pendingRead: CheckedContinuation<Void, Never>?

    func connect() -> [MTPStorage] { [DemoBackend.storage] }
    func replaceSession() -> [MTPStorage] { recovering = true; return [DemoBackend.storage] }
    func failListing() { failNextListing = true }
    func waitForRecoveryRead() async {
        if readStarted { return }
        await withCheckedContinuation { readWaiter = $0 }
    }
    func releaseRead() { pendingRead?.resume(); pendingRead = nil }
    func contents(storageID: UInt32, path: String, showHiddenFiles: Bool) async throws -> [MTPFile] {
        if failNextListing { failNextListing = false; throw BackendSessionError.reconnectRequired }
        if recovering {
            await withCheckedContinuation {
                pendingRead = $0
                readStarted = true
                readWaiter?.resume(); readWaiter = nil
            }
        }
        return [DemoBackend.entry(id: 1, name: "Files", parent: path, folder: true)]
    }
    func download(storageID: UInt32, files: [MTPFile], to destination: URL, progress: @escaping ProgressHandler) {}
    func disconnect() -> Bool { true }
}

@MainActor struct BrowserRecoveryTests {
    @Test func disconnectDiscardsPendingRecoveryDirectory() async {
        let backend = RecoveryListingBackend()
        let browser = DeviceBrowserModel(client: backend)
        await browser.connectAndLoad()
        await browser.load(path: "/Files")
        await backend.failListing()
        let recovery = Task { await browser.load(path: "/Files") }
        await backend.waitForRecoveryRead()
        #expect(browser.state == .recovering)
        await browser.disconnectAndReset()
        await backend.releaseRead()
        await recovery.value
        #expect(browser.state == .disconnected)
        #expect(browser.currentPath == "/")
        #expect(browser.files.isEmpty)
        #expect(browser.storages.isEmpty)
        #expect(browser.selectedStorageID == nil)
        #expect(!browser.isBusy)
    }
}
