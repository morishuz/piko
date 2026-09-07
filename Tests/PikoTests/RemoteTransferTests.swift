import Foundation
import MTPWire
import Testing
@testable import Piko

actor RelayDevice: MTPBinBackend {
    enum Pause { case none, download, upload, uncertainUpload, move, unverifiedMove, recoveredMove, moveNotApplied, moveRecoveryUnavailable, moveRecoveryFailed }
    nonisolated let capabilities = BackendCapabilities(reportsProgress: true, canCancelActiveTransfer: true)
    let pause: Pause
    let writable: Bool
    let uploadAllowed: Bool
    let rejectDirectoryStorage: UInt32?
    private var connected = false
    private var nextID: UInt32 = 100
    private var entries: [UInt32: [MTPFile]] = [:]
    private var payloads: [UInt32: [UInt32: Data]] = [:]
    private(set) var downloads = 0
    private(set) var uploads = 0
    private(set) var moves = 0
    private(set) var active = false
    private(set) var disconnects = 0
    private var directoryCreationFailure: (any Error)?
    private var pendingMove: CheckedContinuation<Void, Never>?
    func finishPendingMove() { pendingMove?.resume(); pendingMove = nil }
    func failDirectoryCreation(with error: any Error) { directoryCreationFailure = error }

    init(seed: Bool = true, pause: Pause = .none, writable: Bool = true, uploadAllowed: Bool = true, rejectDirectoryStorage: UInt32? = nil) {
        self.rejectDirectoryStorage = rejectDirectoryStorage
        self.pause = pause; self.writable = writable; self.uploadAllowed = uploadAllowed
        entries = [1: [], 2: []]; payloads = [1: [:], 2: [:]]
        if seed {
            entries[1] = [Self.file(1, "/Album", folder: true), Self.file(2, "/Album/Empty", folder: true),
                          Self.file(3, "/photo.txt"), Self.file(4, "/second.txt"), Self.file(5, "/Album/nested.txt")]
            payloads[1] = [3: Data("PHOTO".utf8), 4: Data("OTHER".utf8), 5: Data("INNER".utf8)]
        }
    }
    static func file(_ id: UInt32, _ path: String, folder: Bool = false, size: Int64 = 5, sessionID: UUID? = nil) -> MTPFile {
        MTPFile(sessionID: sessionID, size: folder ? 0 : size, isFolder: folder, dateAdded: "2026", name: (path as NSString).lastPathComponent,
            path: path, parentPath: (path as NSString).deletingLastPathComponent, fileExtension: folder ? "" : "txt", parentID: 0, id: id)
    }
    func connect() -> [MTPStorage] {
        connected = true
        return [1, 2].map { MTPStorage(id: $0, info: MTPStorageInfo(storageType: 3, filesystemType: 2,
            accessCapability: writable ? 0 : 1, maxCapacity: 1000000, freeSpaceInBytes: 900000,
            freeSpaceInImages: 0, storageDescription: "Storage \($0)", volumeLabel: "")) }
    }
    func disconnect() -> Bool { connected = false; disconnects += 1; return true }
    func supportsUpload(to storageID: UInt32) async -> Bool { connected && writable && uploadAllowed }
    func binIdentity(storageID: UInt32) async throws -> BinStorageIdentity {
        BinStorageIdentity(manufacturer: "Fixture", model: "Relay", serialNumber: "test",
            volumeLabel: String(storageID), storageDescription: "Storage", capacity: 1_000_000)
    }
    func supportsBin(storageID: UInt32) async -> Bool { connected && writable && uploadAllowed }
    func supportsMove(storageID: UInt32) async -> Bool { connected && writable }
    func contents(storageID: UInt32, path: String, showHiddenFiles: Bool) throws -> [MTPFile] {
        guard connected else { throw BackendError.disconnected }
        guard path == "/" || entries[storageID]?.contains(where: { $0.path == path && $0.isFolder }) == true else { throw BackendError.invalidPath(path) }
        return entries[storageID, default: []].filter { $0.parentPath == path }
    }
    func bytes(_ path: String, storage: UInt32 = 1) -> Data? {
        guard let item = entries[storage]?.first(where: { $0.path == path }) else { return nil }
        return payloads[storage]?[item.id]
    }
    func exists(_ path: String, storage: UInt32 = 1) -> Bool { entries[storage]?.contains { $0.path == path } == true }
    func addConflict(_ path: String, folder: Bool = false, storage: UInt32 = 1) {
        nextID += 1
        entries[storage, default: []].append(Self.file(nextID, path, folder: folder))
        if !folder { payloads[storage, default: [:]][nextID] = Data("OLD!!".utf8) }
    }
    func createUploadDirectory(storageID: UInt32, parent: String, name: String) throws -> UploadDirectoryDisposition {
        if let directoryCreationFailure { throw directoryCreationFailure }
        guard storageID != rejectDirectoryStorage else { throw UploadError.rejected("Folder creation denied") }
        let current = try contents(storageID: storageID, path: parent, showHiddenFiles: true)
        if current.contains(where: { RemotePath.collisionKey($0.name) == RemotePath.collisionKey(name) }) { return .skippedExisting }
        nextID += 1
        entries[storageID, default: []].append(Self.file(nextID, RemotePath.appending(name, to: parent), folder: true))
        return .created
    }
    func download(storageID: UInt32, files: [MTPFile], to destination: URL, progress: @escaping ProgressHandler) async throws {
        downloads += 1; active = true
        defer { active = false }
        if pause == .download { try await Task.sleep(for: .seconds(60)) }
        for file in files {
            guard entries[storageID]?.contains(file) == true, let bytes = payloads[storageID]?[file.id] else { throw SwiftBackendError.staleSelection }
            try bytes.write(to: destination.appendingPathComponent(file.name), options: .withoutOverwriting)
        }
    }
    func upload(storageID: UInt32, source: URL, to directory: String, progress: @escaping ProgressHandler) async throws -> UploadDisposition {
        let current = try contents(storageID: storageID, path: directory, showHiddenFiles: true)
        if current.contains(where: { RemotePath.collisionKey($0.name) == RemotePath.collisionKey(source.lastPathComponent) }) { return .skippedExisting }
        uploads += 1; active = true
        defer { active = false }
        nextID += 1
        let id = nextID, bytes = try Data(contentsOf: source)
        let item = Self.file(id, RemotePath.appending(source.lastPathComponent, to: directory), size: Int64(bytes.count))
        entries[storageID, default: []].append(item)
        payloads[storageID, default: [:]][id] = bytes
        if pause == .upload || pause == .uncertainUpload {
            do { try await Task.sleep(for: .seconds(60)) } catch {
                if pause == .uncertainUpload { throw BackendSessionError.physicalReconnectRequired }
                entries[storageID]?.removeAll { $0.id == id }; payloads[storageID]?[id] = nil
                throw UploadError.cancelledAndRemoved
            }
        }
        return .uploadedVerified(item)
    }
    func move(storageID: UInt32, file: MTPFile, to directory: String) async throws -> MTPFile {
        let current = try contents(storageID: storageID, path: directory, showHiddenFiles: true)
        guard entries[storageID]?.contains(file) == true else { throw SwiftBackendError.staleSelection }
        if current.contains(where: { RemotePath.collisionKey($0.name) == RemotePath.collisionKey(file.name) }) { throw BinError.conflict(directory) }
        moves += 1; active = true
        defer { active = false }
        if pause == .move { await withCheckedContinuation { pendingMove = $0 } }
        if pause == .moveNotApplied { throw MoveError.notApplied }
        let newPath = RemotePath.appending(file.name, to: directory)
        entries[storageID] = entries[storageID]?.map { item in
            guard item.path == file.path || file.isFolder && item.path.hasPrefix(file.path + "/") else { return item }
            return Self.file(item.id, newPath + item.path.dropFirst(file.path.count), folder: item.isFolder,
                size: item.size, sessionID: pause == .recoveredMove ? UUID() : nil)
        }
        if pause == .unverifiedMove { throw MoveError.unverified }
        if pause == .moveRecoveryUnavailable { throw MoveError.recoveryUnavailable }
        if pause == .moveRecoveryFailed { throw MoveError.recoveryFailed }
        return entries[storageID]!.first { $0.id == file.id }!
    }
}

@MainActor
struct RemoteTransferTests {
    private func setup(_ source: RelayDevice = RelayDevice(), _ destination: RelayDevice = RelayDevice(seed: false)) async -> DeviceManager {
        let found = [DiscoveredDevice(id: "a", name: "Source"), DiscoveredDevice(id: "b", name: "Destination")]
        let manager = DeviceManager(preferences: DevicePreferences(defaults: UserDefaults(suiteName: "Piko.RemoteTests.\(UUID())")!),
            discover: { found }, makeBackend: { descriptor, _ in PreparedBinFixture(descriptor.id == "a" ? source : destination) })
        await manager.scan()
        for device in manager.devices { await device.browser.connectAndLoad() }
        return manager
    }
    private func drag(_ manager: DeviceManager, names: [String]) -> [RemoteDragItem] {
        let source = manager.devices[0]
        let files = source.browser.files.filter { names.contains($0.name) }
        manager.beginRemoteDrag(device: source, files: files, browserID: source.browser.browserDragID)
        return manager.dragSelection?.tokens ?? []
    }
    private func waitFor(_ predicate: () async -> Bool) async throws {
        for _ in 0..<2000 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw SimulatedDeviceError.failure("Timed out")
    }
    private func accept(_ manager: DeviceManager, _ tokens: [RemoteDragItem], to device: ManagedDevice,
                        storageID: UInt32, directory: String) async throws -> RemoteTransferCoordinator {
        var observed: RemoteTransferCoordinator?
        let observation = device.browser.$remoteTransfer.sink { if let job = $0 { observed = job } }
        defer { observation.cancel() }
        #expect(manager.acceptRemoteDrop(tokens, to: device, storageID: storageID, directory: directory))
        try await waitFor { observed != nil }
        return try #require(observed)
    }

    private func finish(_ job: RemoteTransferCoordinator) async throws {
        try await waitFor { job.phase == .finished && job.request.participants.allSatisfy { !$0.isBusy } }
    }

    @Test func unverifiedMoveStopsBatchWithoutDisconnectingOrReplaying() async throws {
        let backend = RelayDevice(pause: .unverifiedMove)
        let manager = await setup(backend)
        let device = manager.devices[0]
        let tokens = drag(manager, names: ["photo.txt", "second.txt"])
        let job = try await accept(manager, tokens, to: device, storageID: 1, directory: "/Album")
        try await finish(job)
        #expect(job.results.map(\.outcome) == [.uncertain(MoveError.unverified.localizedDescription), .notAttempted])
        #expect(await backend.moves == 1)
        #expect(await backend.disconnects == 0)
        #expect(job.sourceSessionError == nil && device.browser.isConnected)
        #expect(await backend.exists("/Album/photo.txt"))
        #expect(await backend.exists("/second.txt"))
        await manager.prepareToQuit()
    }

    @Test(arguments: [RelayDevice.Pause.recoveredMove, .moveNotApplied, .moveRecoveryUnavailable, .moveRecoveryFailed])
    func moveRecoveryStopsBatchAndReportsActualRecoveryState(pause: RelayDevice.Pause) async throws {
        let backend = RelayDevice(pause: pause)
        let manager = await setup(backend)
        let device = manager.devices[0]
        let tokens = drag(manager, names: ["photo.txt", "second.txt"])
        let job = try await accept(manager, tokens, to: device, storageID: 1, directory: "/Album")
        try await finish(job)
        let expected: RemoteTransferResult.Outcome = switch pause {
        case .recoveredMove: .moved
        case .moveNotApplied: .failed(MoveError.notApplied.localizedDescription)
        case .moveRecoveryUnavailable: .uncertain(MoveError.recoveryUnavailable.localizedDescription)
        default: .uncertain(MoveError.recoveryFailed.localizedDescription)
        }
        #expect(job.results.map(\.outcome) == [expected, .notAttempted])
        #expect(device.browser.transferConfirmation != nil)
        #expect(await backend.moves == 1)
        #expect(device.browser.isConnected == (pause != .moveRecoveryFailed))
        #expect(job.sourceSessionError == (pause == .moveRecoveryFailed ? .listingRecoveryFailed : nil))
        #expect(await backend.exists("/second.txt"))
        await manager.prepareToQuit()
    }

    @Test func successfulMoveHasNoCompletionPopup() async throws {
        let backend = RelayDevice()
        let manager = await setup(backend)
        let device = manager.devices[0]
        let job = try await accept(manager, drag(manager, names: ["photo.txt"]),
            to: device, storageID: 1, directory: "/Album")
        try await finish(job)
        #expect(job.results.map(\.outcome) == [.moved])
        #expect(device.browser.transferConfirmation == nil && device.browser.operationError == nil)
        #expect(await backend.exists("/Album/photo.txt"))
        await manager.prepareToQuit()
    }

    @Test func sameStorageMoveUsesNoPayloadAndSkipsConflicts() async throws {
        let backend = RelayDevice(uploadAllowed: false)
        await backend.addConflict("/Album/second.txt")
        let manager = await setup(backend)
        let tokens = drag(manager, names: ["photo.txt", "second.txt"])
        let device = manager.devices[0]
        #expect(!device.browser.canUpload)
        #expect(manager.remoteDropOperation(tokens, to: device, storageID: 1, directory: "/Album") == .move)
        let job = try await accept(manager, tokens, to: device, storageID: 1, directory: "/Album")
        try await finish(job)
        #expect(await backend.bytes("/Album/photo.txt") == Data("PHOTO".utf8))
        #expect(await backend.bytes("/photo.txt") == nil)
        #expect(await backend.bytes("/second.txt") == Data("OTHER".utf8))
        #expect(await backend.bytes("/Album/second.txt") == Data("OLD!!".utf8))
        #expect(await backend.downloads == 0)
        #expect(await backend.uploads == 0)
        #expect(job.results.map(\.outcome) == [.moved, .skipped])
        #expect(device.browser.transferConfirmation?.contains("1 conflicts skipped") == true)
        await manager.prepareToQuit()
    }

    @Test func copyBetweenDevicesPreservesHierarchyEmptyFoldersAndSource() async throws {
        let source = RelayDevice(), destination = RelayDevice(seed: false)
        let manager = await setup(source, destination)
        let tokens = drag(manager, names: ["Album", "photo.txt"])
        let target = manager.devices[1]
        #expect(manager.remoteDropOperation(tokens, to: target, storageID: 1, directory: "/") == .copy)
        let job = try await accept(manager, tokens, to: target, storageID: 1, directory: "/")
        try await finish(job)
        #expect(await destination.bytes("/Album/nested.txt") == Data("INNER".utf8))
        #expect(await destination.exists("/Album/Empty"))
        #expect(await destination.bytes("/photo.txt") == Data("PHOTO".utf8))
        #expect(await source.bytes("/photo.txt") == Data("PHOTO".utf8))
        #expect(await source.bytes("/Album/nested.txt") == Data("INNER".utf8))
        #expect(job.results.filter { $0.outcome == .copied }.count == 2)
        #expect(source !== destination)
        #expect(target.browser.transferConfirmation == nil)
        await manager.prepareToQuit()
    }

    @Test func copyAcrossStoragesOnOneDeviceDoesNotMoveOrReuseStorageHandles() async throws {
        let backend = RelayDevice()
        let manager = await setup(backend)
        let tokens = drag(manager, names: ["photo.txt"]), device = manager.devices[0]
        let job = try await accept(manager, tokens, to: device, storageID: 2, directory: "/")
        #expect(job.request.participants.count == 1)
        try await finish(job)
        #expect(await backend.bytes("/photo.txt", storage: 1) == Data("PHOTO".utf8))
        #expect(await backend.bytes("/photo.txt", storage: 2) == Data("PHOTO".utf8))
        #expect(await backend.moves == 0)
        await manager.prepareToQuit()
    }

    @Test func existingFolderSkipsWholeTreeWithoutDownloadingOrMerging() async throws {
        let source = RelayDevice(), destination = RelayDevice(seed: false)
        await destination.addConflict("/album", folder: true)
        await destination.addConflict("/PHOTO.txt")
        let manager = await setup(source, destination)
        let tokens = drag(manager, names: ["Album", "photo.txt"]), target = manager.devices[1]
        let job = try await accept(manager, tokens, to: target, storageID: 1, directory: "/")
        try await finish(job)
        #expect(await source.downloads == 0)
        #expect(await destination.uploads == 0)
        #expect(await destination.exists("/album/nested.txt") == false)
        #expect(await destination.bytes("/PHOTO.txt") == Data("OLD!!".utf8))
        #expect(job.results.allSatisfy { $0.outcome == .skipped })
        await manager.prepareToQuit()
    }

    @Test(arguments: [UploadError.rejected("Folder creation denied"), .readOnlyStorage])
    func folderPreflightFailureKeepsDestinationConnectedAndCopiesRemainingFiles(failure: UploadError) async throws {
        let source = RelayDevice(), destination = RelayDevice(seed: false)
        let manager = await setup(source, destination)
        await destination.failDirectoryCreation(with: UploadPreflightFailure(failure))
        let tokens = drag(manager, names: ["Album", "photo.txt"]), target = manager.devices[1]
        let job = try await accept(manager, tokens, to: target, storageID: 1, directory: "/")
        try await finish(job)

        #expect(job.results.map(\.outcome) == [
            .failed(failure.localizedDescription), .notAttempted, .notAttempted, .copied,
        ])
        #expect(job.destinationSessionError == nil)
        #expect(target.browser.isConnected)
        #expect(await destination.disconnects == 0)
        #expect(await destination.bytes("/photo.txt") == Data("PHOTO".utf8))
        #expect(await destination.exists("/Album") == false)
        await manager.prepareToQuit()
    }

    @Test(arguments: [false, true])
    func folderSessionFailurePreservesPhysicalReconnectRequirement(preflight: Bool) async throws {
        let source = RelayDevice(), destination = RelayDevice(seed: false)
        let manager = await setup(source, destination)
        let failure = BackendSessionError.physicalReconnectRequired
        await destination.failDirectoryCreation(with: preflight ? UploadPreflightFailure(failure) : failure)
        let tokens = drag(manager, names: ["Album", "photo.txt"]), target = manager.devices[1]
        let job = try await accept(manager, tokens, to: target, storageID: 1, directory: "/")
        try await finish(job)

        #expect(job.results.map(\.outcome) == [
            preflight ? .failed(failure.localizedDescription) : .uncertain(failure.localizedDescription),
            .notAttempted, .notAttempted, .notAttempted,
        ])
        #expect(job.destinationSessionError == .physicalReconnectRequired)
        #expect(!target.browser.isConnected)
        #expect(await destination.uploads == 0)
        #expect(manager.devices[0].browser.isConnected)
        await manager.prepareToQuit()
    }

    @Test func hoverNavigationKeepsSourceAndReconnectInvalidatesDrag() async throws {
        let manager = await setup()
        let source = manager.devices[0], target = manager.devices[1]
        let tokens = drag(manager, names: ["photo.txt"])
        await source.browser.load(path: "/Album")
        #expect(manager.remoteRequest(tokens, to: source, storageID: 1, directory: "/") == nil)
        #expect(manager.remoteRequest(tokens, to: source, storageID: 1, directory: "/", forNavigation: true) != nil)
        manager.select(target)
        #expect(manager.remoteRequest(tokens, to: target, storageID: 1, directory: "/") != nil)
        #expect(manager.dragSelection?.files.first?.path == "/photo.txt")
        await source.browser.disconnectAndReset(); await source.browser.connectAndLoad()
        #expect(manager.remoteRequest(tokens, to: target, storageID: 1, directory: "/") == nil)
        await manager.prepareToQuit()
    }

    @Test func deviceHoverStartsOnUpdateOpensRootThenAllowsDrillingDown() async throws {
        let source = RelayDevice(writable: false), destination = RelayDevice(seed: false)
        await destination.addConflict("/Album", folder: true)
        let manager = await setup(source, destination), target = manager.devices[1]
        await target.browser.load(path: "/Album")
        let header = try #require(target.remoteDropDestination)
        #expect(header.directory == "/")
        let delegate = RemoteStorageDropDelegate(manager: manager, device: target,
            storageID: header.storageID, directory: header.directory,
            navigate: { Task { await manager.navigateForDrop(to: target, storageID: header.storageID, directory: "/") } })
        // Initial entry can arrive before the source announces its selection.
        #expect(delegate.updateHover() == nil)
        let tokens = drag(manager, names: ["photo.txt"])
        #expect(delegate.updateHover() == .copy)
        try await waitFor { manager.selectedDevice === target && target.browser.currentPath == "/" && !target.browser.isBusy }
        #expect(manager.dragSelection?.source === manager.devices[0])
        #expect(await source.downloads == 0)
        await target.browser.load(path: "/Album")
        let job = try await accept(manager, tokens, to: target, storageID: header.storageID, directory: "/Album")
        try await finish(job)
        #expect(await destination.bytes("/Album/photo.txt") == Data("PHOTO".utf8))
        #expect(await source.bytes("/photo.txt") == Data("PHOTO".utf8))
        await manager.prepareToQuit()
        #expect(target.remoteDropDestination == nil)
    }

    @Test func sameStorageRootHoverNavigatesEvenWhenAlreadySelected() async throws {
        let source = RelayDevice(), manager = await setup(source), device = manager.devices[0]
        let tokens = drag(manager, names: ["photo.txt"])
        await device.browser.load(path: "/Album/Empty")
        let header = try #require(device.remoteDropDestination)
        let delegate = RemoteStorageDropDelegate(manager: manager, device: device,
            storageID: header.storageID, directory: "/",
            navigate: { Task { await manager.navigateForDrop(to: device, storageID: header.storageID, directory: "/") } })
        #expect(delegate.updateHover() == nil) // Dropping back in the source folder is a no-op; navigation must still work.
        try await waitFor { device.browser.currentPath == "/" && !device.browser.isBusy }
        #expect(manager.dragSelection?.tokens == tokens)
        #expect(await source.moves == 0)
        await manager.prepareToQuit()
    }

    @Test func ancestorHoverKeepsDragAndAllowsMoveUp() async throws {
        let source = RelayDevice(), manager = await setup(source), device = manager.devices[0]
        await device.browser.load(path: "/Album")
        let tokens = drag(manager, names: ["nested.txt"])
        let root = try #require(RemoteBreadcrumb.items(for: device.browser.currentPath).first)
        let delegate = RemoteStorageDropDelegate(manager: manager, device: device,
            storageID: 1, directory: root.path,
            navigate: { Task { await manager.navigateForDrop(to: device, storageID: 1, directory: root.path) } })
        #expect(delegate.updateHover() == .move)
        try await waitFor { device.browser.currentPath == "/" && !device.browser.isBusy }
        let job = try await accept(manager, tokens, to: device, storageID: 1, directory: root.path)
        try await finish(job)
        #expect(await source.bytes("/nested.txt") == Data("INNER".utf8))
        #expect(await source.bytes("/Album/nested.txt") == nil)
        await manager.prepareToQuit()
    }

    @Test func upHoverPinsParentUntilPointerLeavesControl() async throws {
        let source = RelayDevice()
        await source.addConflict("/Album/Empty/child.txt")
        let manager = await setup(source), device = manager.devices[0]
        await device.browser.load(path: "/Album/Empty")
        let tokens = drag(manager, names: ["child.txt"])
        let original = RemoteStorageDropDelegate(manager: manager, device: device,
            storageID: 1, directory: "/Album",
            navigate: { Task { await manager.navigateForDrop(to: device, storageID: 1, directory: "/Album") } }, hoverID: "up")
        #expect(original.updateHover() == .move)
        try await waitFor { device.browser.currentPath == "/Album" && !device.browser.isBusy }
        let updated = RemoteStorageDropDelegate(manager: manager, device: device,
            storageID: 1, directory: "/", navigate: {}, hoverID: "up")
        #expect(updated.updateHover() == .move)
        #expect(manager.navigationHover?.directory == "/Album")
        let job = try await accept(manager, tokens, to: device, storageID: 1,
            directory: try #require(manager.navigationHover?.directory))
        try await finish(job)
        #expect(await source.bytes("/Album/child.txt") == Data("OLD!!".utf8))
        #expect(await source.bytes("/child.txt") == nil)
        await manager.prepareToQuit()
    }

    @Test func breadcrumbPathsAreStableAbsoluteAncestors() {
        #expect(RemoteBreadcrumb.items(for: "/DCIM/Camera").map(\.path) == ["/", "/DCIM", "/DCIM/Camera"])
        #expect(RemoteBreadcrumb.items(for: "/").map(\.path) == ["/"])
        #expect(RemoteBreadcrumb.items(for: "/../bad").isEmpty)
    }

    @Test func invalidSameFolderSelfDescendantForeignTokensAndReadOnlyAreRejected() async throws {
        let manager = await setup(RelayDevice(), RelayDevice(seed: false, writable: false))
        let tokens = drag(manager, names: ["Album"]), source = manager.devices[0], target = manager.devices[1]
        for path in ["/", "/Album", "/Album/Empty", BinLayout.root, "/../bad"] {
            #expect(manager.remoteRequest(tokens, to: source, storageID: 1, directory: path) == nil)
        }
        #expect(manager.remoteRequest(tokens, to: target, storageID: 1, directory: "/") == nil)
        #expect(manager.remoteRequest([RemoteDragItem(browserID: UUID(), handle: 1)], to: source, storageID: 1, directory: "/Other") == nil)
        manager.endRemoteDrag()
        #expect(manager.remoteRequest(tokens, to: source, storageID: 1, directory: "/Other") == nil)
        await manager.prepareToQuit()
    }

    @Test(arguments: [RelayDevice.Pause.download, .upload, .uncertainUpload])
    fileprivate func cancellationInEitherCopyStageKeepsOriginal(pause: RelayDevice.Pause) async throws {
        let source = RelayDevice(pause: pause == .download ? pause : .none)
        let destination = RelayDevice(seed: false, pause: pause == .download ? .none : pause)
        let manager = await setup(source, destination)
        let tokens = drag(manager, names: ["photo.txt", "second.txt"]), target = manager.devices[1]
        let job = try await accept(manager, tokens, to: target, storageID: 1, directory: "/")
        try await waitFor { await (pause == .download ? source : destination).active }
        #expect(manager.devices[0].browser.remoteTransfer === job)
        #expect(!manager.devices[0].browser.canDownload && !target.browser.canUpload)
        manager.devices[0].browser.remoteTransfer?.cancel()
        try await finish(job)
        #expect(await source.bytes("/photo.txt") == Data("PHOTO".utf8))
        #expect(await source.bytes("/second.txt") == Data("OTHER".utf8))
        #expect(await destination.exists("/second.txt") == false)
        if pause == .uncertainUpload {
            #expect(target.browser.transferConfirmation != nil)
            #expect(!target.browser.isConnected)
            #expect(job.results.contains { if case .uncertain = $0.outcome { true } else { false } })
        } else {
            #expect(await destination.exists("/photo.txt") == false)
            #expect(target.browser.transferConfirmation == nil)
            #expect(target.browser.isConnected)
        }
        #expect(manager.devices[0].browser.isConnected)
        await manager.prepareToQuit()
    }

    @Test func stoppingMoveFinishesCurrentMoveAndLeavesRemainingSource() async throws {
        let backend = RelayDevice(pause: .move), manager: DeviceManager
        manager = await setup(backend)
        let tokens = drag(manager, names: ["photo.txt", "second.txt"]), source = manager.devices[0]
        let job = try await accept(manager, tokens, to: source, storageID: 1, directory: "/Album")
        try await waitFor { await backend.active }
        job.cancel()
        await backend.finishPendingMove()
        try await finish(job)
        #expect(await backend.bytes("/Album/photo.txt") == Data("PHOTO".utf8))
        #expect(await backend.bytes("/second.txt") == Data("OTHER".utf8))
        #expect(job.results.map(\.outcome) == [.moved, .notAttempted])
        #expect(source.browser.transferConfirmation == nil)
        await manager.prepareToQuit()
    }

    @Test func quitCancelsRelayAndClosesBothParticipants() async throws {
        let source = RelayDevice(), destination = RelayDevice(seed: false, pause: .upload)
        let manager = await setup(source, destination)
        let tokens = drag(manager, names: ["photo.txt"])
        #expect(manager.acceptRemoteDrop(tokens, to: manager.devices[1], storageID: 1, directory: "/"))
        try await waitFor { await destination.active }
        await manager.prepareToQuit()
        #expect(await source.disconnects == 1)
        #expect(await destination.disconnects == 1)
        #expect(await source.bytes("/photo.txt") == Data("PHOTO".utf8))
        #expect(await destination.exists("/photo.txt") == false)
    }

    @Test func removalDuringCopyStopsBothAndKeepsOtherDeviceUsable() async throws {
        let source = RelayDevice(), destination = RelayDevice(seed: false, pause: .upload)
        let manager = await setup(source, destination)
        let tokens = drag(manager, names: ["photo.txt", "second.txt"]), target = manager.devices[1]
        let job = try await accept(manager, tokens, to: target, storageID: 1, directory: "/")
        try await waitFor { await destination.active }
        target.markRemoved()
        try await finish(job)
        try await waitFor { target.browser.state == .disconnected }
        #expect(manager.devices[0].browser.isConnected)
        #expect(await source.bytes("/photo.txt") == Data("PHOTO".utf8))
        #expect(await destination.exists("/second.txt") == false)
        await manager.prepareToQuit()
    }

    @Test func changedSourceIsRejectedBeforeAnyPayloadTransfer() async throws {
        let source = RelayDevice(), destination = RelayDevice(seed: false)
        let manager = await setup(source, destination)
        let tokens = drag(manager, names: ["photo.txt"]), target = manager.devices[1]
        let file = try #require(manager.dragSelection?.files.first)
        _ = try await source.move(storageID: 1, file: file, to: "/Album")
        let job = try await accept(manager, tokens, to: target, storageID: 1, directory: "/")
        try await finish(job)
        #expect(await source.downloads == 0)
        #expect(await destination.uploads == 0)
        #expect(job.results.contains { if case .failed = $0.outcome { true } else { false } })
        await manager.prepareToQuit()
    }

    @Test func springLoadingRunsOnceAndCancelledHoverNeverNavigates() async throws {
        let spring = SpringLoadedNavigation()
        var opened: [String] = []
        spring.schedule(key: "old") { opened.append("old") }
        spring.schedule(key: "new") { opened.append("new") }
        spring.cancel(key: "old")
        // Wait for the callback rather than assuming a 100 ms scheduling margin
        // while ASAN and other UI tests compete for the main actor.
        try await waitFor { !opened.isEmpty }
        spring.schedule(key: "new") { opened.append("duplicate") }
        #expect(opened == ["new"])
        spring.schedule(key: "cancelled") { opened.append("cancelled") }
        spring.cancel()
        try await Task.sleep(for: .milliseconds(850))
        #expect(opened == ["new"])
    }
}
