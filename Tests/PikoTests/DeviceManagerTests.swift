import Foundation
import MTPWire
import Testing
@testable import Piko

private actor DiscoveryFixture {
    var devices: [DiscoveredDevice]
    var fails = false
    init(_ devices: [DiscoveredDevice]) { self.devices = devices }
    func set(_ devices: [DiscoveredDevice]) { self.devices = devices }
    func fail() { fails = true }
    func scan() throws -> [DiscoveredDevice] {
        if fails { throw SimulatedDeviceError.failure("Discovery unavailable") }
        return devices
    }
}

private actor MultiDeviceBackend: MTPUploadBackend, MTPFreshSessionBackend {
    nonisolated let capabilities = BackendCapabilities(reportsProgress: true, canCancelActiveTransfer: false)
    private var connected = false
    private var locked = false
    private var failedPath: String?
    private var loseSessionOnNextListing = false
    func failRecoveryListing() { loseSessionOnNextListing = true; failedPath = "/" }
    func replaceSession() throws -> [MTPStorage] { _ = disconnect(); return try connect() }
    func setLocked(_ locked: Bool) { self.locked = locked }
    func failListing(_ path: String?) { failedPath = path }

    private var paused: CheckedContinuation<Void, Never>?
    private(set) var downloads = 0
    private(set) var disconnects = 0
    private(set) var uploads = 0
    let marker: UInt8
    let holdDownload: Bool
    let serial: String
    init(marker: UInt8 = 65, holdDownload: Bool = false, serial: String = "") {
        self.marker = marker; self.holdDownload = holdDownload; self.serial = serial
    }
    func deviceDetails() -> MTPDeviceDetails? {
        connected ? MTPDeviceDetails(manufacturer: "Example", model: "Phone", firmware: "1.2", serialNumber: serial) : nil
    }
    func connect() throws -> [MTPStorage] {
        guard !connected else { throw BackendError.busy }
        if locked { throw BackendError.noStorage }
        connected = true
        return [DemoBackend.storage]
    }
    func contents(storageID: UInt32, path: String, showHiddenFiles: Bool) throws -> [MTPFile] {
        guard connected else { throw BackendError.disconnected }
        if loseSessionOnNextListing {
            loseSessionOnNextListing = false
            throw BackendSessionError.reconnectRequired
        }
        if failedPath == path { throw SimulatedDeviceError.failure("Cannot read folder") }
        if path == "/" { return [DemoBackend.entry(id: 1, name: "Files", parent: "/", folder: true)] }
        return [DemoBackend.entry(id: 10, name: "first.txt", parent: path, folder: false),
                DemoBackend.entry(id: 11, name: "second.txt", parent: path, folder: false)]
    }
    func download(storageID: UInt32, files: [MTPFile], to destination: URL, progress: @escaping ProgressHandler) async throws {
        guard connected else { throw BackendError.disconnected }
        downloads += 1
        if holdDownload && downloads == 1 { await withCheckedContinuation { paused = $0 } }
        for file in files {
            try Data(repeating: marker, count: Int(file.size)).write(to: destination.appendingPathComponent(file.name), options: .withoutOverwriting)
        }
    }
    func resume() { paused?.resume(); paused = nil }
    func upload(storageID: UInt32, source: URL, to directory: String, progress: @escaping ProgressHandler) throws -> UploadDisposition {
        uploads += 1
        throw UploadError.rejected("Access denied in this folder")
    }
    func disconnect() -> Bool { disconnects += 1; connected = false; return true }
}

@MainActor
struct DeviceManagerTests {
    private func descriptor(_ id: String, serial: String = "") -> DiscoveredDevice {
        DiscoveredDevice(id: id, target: UInt64(id), vendor: 1, product: 2, name: "USB phone", serialNumber: serial)
    }
    private func preferences() -> DevicePreferences {
        DevicePreferences(defaults: UserDefaults(suiteName: "Piko.Tests.\(UUID().uuidString)")!)
    }
    private func waitUntil(_ predicate: @escaping @MainActor () async -> Bool) async throws {
        for _ in 0..<2000 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("Timed out waiting for fixture")
    }

    @Test func discoveryNeverConnectsAndSelectionRetainsIndependentBrowsers() async throws {
        let a = MultiDeviceBackend(), b = MultiDeviceBackend()
        let discovery = DiscoveryFixture([descriptor("1"), descriptor("2")])
        let manager = DeviceManager(preferences: preferences(), discover: { try await discovery.scan() },
            makeBackend: { item, _ in item.id == "1" ? a : b })
        await manager.scan()
        #expect(manager.devices.count == 2)
        #expect(manager.devices.allSatisfy { !$0.browser.isConnected })
        let first = manager.devices[0], second = manager.devices[1]
        await first.browser.connectAndLoad()
        await second.browser.connectAndLoad()
        await first.browser.load(path: "/Files")
        first.browser.replaceSelection([10])
        manager.select(second)
        await second.browser.load(path: "/Other")
        second.browser.replaceSelection([11])
        manager.select(first)
        #expect(first.browser.currentPath == "/Files")
        #expect(first.browser.selectedFileIDs == [10])
        #expect(second.browser.currentPath == "/Other")
        #expect(second.browser.selectedFileIDs == [11])
        #expect(first.browser.browserDragID != second.browser.browserDragID)
        await second.browser.disconnectAndReset()
        #expect(first.browser.isConnected)
        #expect(first.browser.selectedFileIDs == [10])
        #expect(await a.disconnects == 0)
        await manager.prepareToQuit()
    }

    @Test func concurrentDownloadsAndCancellationStayWithTheirDevice() async throws {
        let a = MultiDeviceBackend(marker: 65, holdDownload: true)
        let b = MultiDeviceBackend(marker: 66, holdDownload: true)
        let found = [descriptor("1"), descriptor("2")]
        let manager = DeviceManager(preferences: preferences(), discover: { found },
            makeBackend: { item, _ in item.id == "1" ? a : b })
        await manager.scan()
        let first = manager.devices[0], second = manager.devices[1]
        for device in manager.devices { await device.browser.connectAndLoad(); await device.browser.load(path: "/Files") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let dirA = root.appendingPathComponent("A"), dirB = root.appendingPathComponent("B")
        try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let downloadA = Task { await first.browser.download(files: first.browser.files, to: dirA) }
        let downloadB = Task { await second.browser.download(files: second.browser.files, to: dirB) }
        try await waitUntil {
            let countA = await a.downloads, countB = await b.downloads
            return countA == 1 && countB == 1
        }
        manager.select(second)
        first.browser.transfers.cancelTransfer()
        #expect(first.browser.transfers.stopRequested)
        #expect(!second.browser.transfers.stopRequested)
        #expect(first.browser.isConnected && second.browser.isConnected)
        await a.resume(); await b.resume()
        await downloadA.value; await downloadB.value
        #expect(try Data(contentsOf: dirA.appendingPathComponent("first.txt")).first == 65)
        #expect(try Data(contentsOf: dirB.appendingPathComponent("first.txt")).first == 66)
        #expect(!FileManager.default.fileExists(atPath: dirA.appendingPathComponent("second.txt").path))
        #expect(FileManager.default.fileExists(atPath: dirB.appendingPathComponent("second.txt").path))
        #expect(manager.selectedDevice === second)
        #expect(first.browser.transferConfirmation == nil && second.browser.transferConfirmation == nil)
        await manager.prepareToQuit()
    }

    @Test func rejectedUploadDoesNotChangeEitherDevicesWritePermissions() async throws {
        let a = MultiDeviceBackend(), b = MultiDeviceBackend()
        let found = [descriptor("1"), descriptor("2")]
        let manager = DeviceManager(preferences: preferences(), discover: { found },
            makeBackend: { item, _ in PreparedBinFixture(item.id == "1" ? a : b) })
        await manager.scan()
        for device in manager.devices { await device.browser.connectAndLoad(); await device.browser.load(path: "/Files") }
        let first = manager.devices[0], second = manager.devices[1]
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        try Data("test".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        manager.select(second)
        await first.browser.upload(sources: [source])
        #expect(await a.uploads == 1)
        #expect(await b.uploads == 0)
        #expect(first.browser.transferConfirmation?.contains("1 failed") == true)
        #expect(first.browser.canUpload && second.browser.canUpload)
        #expect(second.browser.transferConfirmation == nil && second.browser.operationError == nil)
        #expect(second.browser.currentPath == "/Files")
        await manager.prepareToQuit()
    }

    @Test func quittingStartsCleanupOnEveryDeviceBeforeWaiting() async throws {
        let a = MultiDeviceBackend(holdDownload: true), b = MultiDeviceBackend(holdDownload: true)
        let found = [descriptor("1"), descriptor("2")]
        let manager = DeviceManager(preferences: preferences(), discover: { found },
            makeBackend: { item, _ in item.id == "1" ? a : b })
        await manager.scan()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var jobs: [Task<Void, Never>] = []
        for device in manager.devices {
            await device.browser.connectAndLoad(); await device.browser.load(path: "/Files")
            let dir = root.appendingPathComponent(device.id)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            jobs.append(Task { await device.browser.download(files: device.browser.files, to: dir) })
        }
        try await waitUntil {
            let countA = await a.downloads, countB = await b.downloads
            return countA == 1 && countB == 1
        }
        let shutdown = Task { await manager.prepareToQuit() }
        try await waitUntil { manager.devices.allSatisfy { $0.browser.transfers.stopRequested } }
        #expect(manager.devices.allSatisfy { $0.browser.isQuitting })
        #expect(await a.disconnects == 0)
        #expect(await b.disconnects == 0)
        await b.resume()
        try await waitUntil { await b.disconnects == 1 }
        #expect(await a.disconnects == 0)
        await a.resume()
        for job in jobs { await job.value }
        await shutdown.value
        #expect(manager.devices.allSatisfy { $0.browser.state == .disconnected })
        #expect(manager.isQuitting)
    }

    @Test func lockedPhoneReenumerationReplacesFailedRowAndPreservesNotices() async throws {
        let oldBackend = MultiDeviceBackend(), freshBackend = MultiDeviceBackend()
        await oldBackend.setLocked(true)
        let discovery = DiscoveryFixture([descriptor("1", serial: "phone-serial")])
        let manager = DeviceManager(preferences: preferences(), discover: { try await discovery.scan() },
            makeBackend: { item, _ in item.id == "1" ? oldBackend : freshBackend })
        await manager.scan()
        let old = manager.devices[0]
        old.rename("My phone")
        await old.browser.connectAndLoad()
        #expect(!old.browser.isConnected && old.browser.operationError != nil)
        old.browser.transferConfirmation = "Earlier transfer result"
        // Unlocking can change both the interface registry ID and product ID.
        let unlocked = DiscoveredDevice(id: "3", target: 3, vendor: 1, product: 99,
            name: "USB phone", serialNumber: "phone-serial")
        await discovery.set([unlocked])
        await manager.scan()
        #expect(manager.devices.count == 1) // Cleanup before adding the replacement.
        try await waitUntil { old.removalComplete }
        await manager.scan()
        #expect(manager.devices.count == 1)
        let fresh = try #require(manager.selectedDevice)
        #expect(fresh !== old && fresh.descriptor.target == 3)
        #expect(fresh.displayName == "My phone" && fresh.browser.files.isEmpty)
        #expect(fresh.browser.operationError == old.browser.operationError)
        #expect(fresh.browser.transferConfirmation == "Earlier transfer result")
        await fresh.browser.connectAndLoad()
        #expect(fresh.browser.isConnected && fresh.browser.operationError == nil)
        await manager.prepareToQuit()
    }

    @Test func reappearingSameRegistryIDDoesNotLeaveUnavailableErrorRow() async throws {
        let discovery = DiscoveryFixture([descriptor("1")])
        let manager = DeviceManager(preferences: preferences(), discover: { try await discovery.scan() },
            makeBackend: { _, _ in MultiDeviceBackend() })
        await manager.scan()
        let old = manager.devices[0]
        old.browser.operationError = "Connection failed"
        await discovery.set([]); await manager.scan()
        try await waitUntil { old.removalComplete }
        await discovery.set([descriptor("1")]); await manager.scan()
        #expect(manager.devices.count == 1 && manager.devices[0] !== old)
        #expect(manager.devices[0].isAvailable)
        #expect(manager.devices[0].browser.operationError == "Connection failed")
        await manager.prepareToQuit()
    }

    @Test func sameModelOrDuplicateSerialDoesNotMergeLiveDevices() async {
        let found = [descriptor("1"), descriptor("2"), descriptor("3", serial: "shared"), descriptor("4", serial: "shared")]
        let manager = DeviceManager(preferences: preferences(), discover: { found },
            makeBackend: { _, _ in MultiDeviceBackend() })
        await manager.scan(); await manager.scan()
        #expect(manager.devices.count == 4)
        await manager.prepareToQuit()
    }

    @Test func failedRecoveryListingReleasesNewSessionBeforeManualRetry() async {
        let backend = MultiDeviceBackend()
        let browser = DeviceBrowserModel(client: backend)
        await browser.connectAndLoad()
        await backend.failRecoveryListing()
        await browser.load(path: "/")
        #expect(!browser.isConnected && !browser.isBusy)
        #expect(await backend.disconnects == 2)
        await backend.failListing(nil)
        await browser.connectAndLoad()
        #expect(browser.isConnected && browser.operationError == nil)
        await browser.disconnectAndReset()
    }

    @Test func failedInitialRootClosesSessionAndRetryStartsFresh() async {
        let backend = MultiDeviceBackend()
        await backend.failListing("/")
        let browser = DeviceBrowserModel(client: backend)
        await browser.connectAndLoad()
        #expect(!browser.isConnected && !browser.isBusy)
        #expect(browser.storages.isEmpty && browser.files.isEmpty)
        #expect(browser.operationError != nil)
        #expect(await backend.disconnects == 1)
        await backend.failListing(nil)
        await browser.connectAndLoad()
        #expect(browser.isConnected && browser.files.count == 1)
        #expect(browser.operationError == nil)
        await backend.failListing("/Files")
        await browser.load(path: "/Files")
        #expect(browser.isConnected && browser.browsingIssue != nil)
        #expect(browser.currentPath == "/")
        browser.operationError = nil
        #expect(browser.browsingIssue != nil) // Dismissing the alert does not make status green.
        await browser.load(path: "/")
        #expect(browser.browsingIssue == nil)
        await browser.disconnectAndReset()
    }

    @Test func replugCreatesFreshTargetWithoutOldHandlesAndKeepsNickname() async throws {
        let discovery = DiscoveryFixture([descriptor("1", serial: "unique-a"), descriptor("2", serial: "unique-b")])
        let manager = DeviceManager(preferences: preferences(), discover: { try await discovery.scan() },
            makeBackend: { _, _ in MultiDeviceBackend() })
        await manager.scan()
        let old = manager.devices[0], other = manager.devices[1]
        await old.browser.connectAndLoad(); await old.browser.load(path: "/Files")
        await other.browser.connectAndLoad()
        old.browser.replaceSelection([10]); old.rename("My diving phone")
        await discovery.set([descriptor("2", serial: "unique-b")]); await manager.scan()
        try await waitUntil { old.browser.state == .disconnected }
        #expect(!old.isAvailable && !old.browser.isDeviceAvailable)
        #expect(other.browser.isConnected)
        await discovery.set([descriptor("3", serial: "unique-a"), descriptor("2", serial: "unique-b")])
        await manager.scan()
        let fresh = try #require(manager.devices.first { $0.id == "3" })
        #expect(fresh !== old && fresh.browser !== old.browser)
        #expect(fresh.descriptor.target == 3)
        #expect(fresh.displayName == "My diving phone")
        #expect(fresh.browser.files.isEmpty && fresh.browser.selectedFileIDs.isEmpty)
        #expect(!fresh.browser.isConnected)
        #expect(other.browser.isConnected)
        await manager.prepareToQuit()
    }

    @Test func discoveryFailureDoesNotDisconnectExistingDevices() async {
        let discovery = DiscoveryFixture([descriptor("1")])
        let manager = DeviceManager(preferences: preferences(), discover: { try await discovery.scan() },
            makeBackend: { _, _ in MultiDeviceBackend() })
        await manager.scan()
        await manager.devices[0].browser.connectAndLoad()
        await discovery.fail(); await manager.scan()
        #expect(manager.discoveryError != nil)
        #expect(manager.devices[0].isAvailable && manager.devices[0].browser.isConnected)
        await manager.prepareToQuit()
    }

    @Test func nicknamesUseSerialIdentityAndMissingSerialsAreNotGuessed() async {
        let store = preferences()
        func entry(_ id: String, serial: String) -> ManagedDevice {
            ManagedDevice(descriptor: descriptor(id, serial: serial), browser: DeviceBrowserModel(client: MultiDeviceBackend()), preferences: store)
        }
        let first = entry("1", serial: "abc")
        first.rename("  My phone  ")
        #expect(entry("99", serial: "abc").displayName == "My phone")
        #expect(entry("2", serial: "def").nickname == nil)
        let unidentified = entry("3", serial: "")
        unidentified.rename("Temporary name")
        #expect(unidentified.nickname == "Temporary name")
        #expect(entry("4", serial: "").nickname == nil)
        first.rename("")
        #expect(entry("99", serial: "abc").nickname == nil)
    }

    @Test func protocolIdentityRemembersNameAfterFirstConnection() async {
        let store = preferences()
        func entry(_ id: String) -> ManagedDevice {
            ManagedDevice(descriptor: descriptor(id), browser: DeviceBrowserModel(client: MultiDeviceBackend(serial: "mtp-serial")), preferences: store)
        }
        let first = entry("1")
        first.rename("My phone")
        await first.browser.connectAndLoad()
        #expect(first.details?.firmware == "1.2")
        #expect(first.modelName == "Example Phone")
        let second = entry("2")
        #expect(second.nickname == nil)
        await second.browser.connectAndLoad()
        #expect(second.nickname == "My phone")
        await first.browser.disconnectAndReset(); await second.browser.disconnectAndReset()
    }
}

@Test func multipleDeviceDiagnosticsShareCorrelationButKeepCapabilitiesSeparate() async throws {
    let log = DiagnosticLog(capacity: 4)
    let a = log.forDevice(), b = log.forDevice()
    let capability = DiagnosticCapabilities(storageIndex: 0, uploadEnabled: true, binEnabled: false)
    a.record(.deviceCapabilities, capabilities: capability)
    b.record(.deviceCapabilities, capabilities: capability)
    a.record(.browserCapabilities, capabilities: capability)
    b.record(.browserCapabilities, capabilities: capability)
    let ids = Set(log.snapshot().events.compactMap(\.deviceID))
    #expect(ids.count == 2)
    #expect(log.snapshot().capabilityEvents?.count == 4)
    a.resetCapabilities()
    #expect(log.snapshot().capabilityEvents?.count == 2)
    #expect(log.snapshot().capabilityEvents?.allSatisfy { $0.deviceID == log.snapshot().events[1].deviceID } == true)
    await Task.detached { a.record(.download, transferID: a.nextCorrelationID()) }.value
    #expect(log.snapshot().events.last?.deviceID == log.snapshot().events[1].deviceID)
    let data = try JSONEncoder().encode(log.snapshot())
    let decoded = try JSONDecoder().decode(DiagnosticSnapshot.self, from: data)
    #expect(decoded.events.last?.deviceID != nil)
}
