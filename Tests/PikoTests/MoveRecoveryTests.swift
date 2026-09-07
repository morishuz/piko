import Foundation
import MTPWire
import Testing
@testable import Piko

actor MoveResponderFixture {
    enum Recovery: CaseIterable, Sendable { case original, moved, rejected, rejectedProbeFailure, failed, persistent, openFailure }
    let device: SyntheticUploadDevice
    let recovery: Recovery
    let unavailableOnMove: Int?
    private var moveWrites = 0
    private(set) var opens = 0
    private(set) var resets = 0
    init(_ recovery: Recovery, unavailableOnMove: Int? = nil) throws {
        self.recovery = recovery
        self.unavailableOnMove = unavailableOnMove
        device = try SyntheticUploadDevice(existingNames: ["photo.jpg", "second.jpg"])
    }
    func didWrite(_ data: Data) async throws {
        guard let unavailableOnMove,
            let header = try? ContainerHeader(data: Data(data.prefix(12))),
            header.type == .command, header.code == 0x1019 else { return }
        moveWrites += 1
        if moveWrites == unavailableOnMove {
            var parameters = DatasetReader(Data(data.dropFirst(12)))
            await device.configureUnavailable([try parameters.readUInt32()])
        }
    }
    func open() async throws -> any MTPBulkTransport {
        opens += 1
        if opens > 1, recovery == .openFailure { throw BackendError.disconnected }
        await device.prepareReconnect()
        return MoveResetTransport(device: device, owner: self)
    }
    func reset() async -> MTPResponderResetResult {
        resets += 1
        if recovery == .rejected { return .rejected }
        if recovery == .rejectedProbeFailure {
            await device.configureFault(reject: 0x1004, rejectionCode: 0x2003)
            return .rejected
        }
        await device.close()
        if recovery == .failed { return .failed }
        if recovery != .persistent { await device.configureUnavailable([]) }
        if recovery == .original { try? await device.restoreFixtureParent(handle: 10, parent: .max) }
        return .acknowledged
    }
}

private actor MoveResetTransport: MTPResponderResetTransport {
    let device: SyntheticUploadDevice
    let owner: MoveResponderFixture
    private var retired = false
    init(device: SyntheticUploadDevice, owner: MoveResponderFixture) { self.device = device; self.owner = owner }
    func write(_ data: Data) async throws { try await write(data, boundary: .endsContainer) }
    func write(_ data: Data, boundary: BulkWriteBoundary) async throws {
        guard !retired else { throw WireError.disconnected }
        try await device.write(data, boundary: boundary)
        try await owner.didWrite(data)
    }
    func read(maxBytes: Int) async throws -> Data {
        guard !retired else { throw WireError.disconnected }
        return try await device.read(maxBytes: maxBytes)
    }
    func close() async { if !retired { retired = true; await device.close() } }
    func resetResponder() async -> MTPResponderResetResult {
        guard !retired else { return .notAttempted }
        let result = await owner.reset()
        retired = result == .acknowledged || result == .failed
        return result
    }
}

struct MoveRecoveryTests {
    @MainActor @Test(arguments: [1, 2])
    func binProbeRecoveryStopsBeforeMovingOriginalAndRefreshesSelection(probe: Int) async throws {
        let fixture = try MoveResponderFixture(.moved, unavailableOnMove: probe)
        let backend = SwiftMTPBackend(connectionRecovery: .init(retryDelays: [], wait: { _ in })) {
            try await fixture.open()
        }
        let browser = DeviceBrowserModel(client: backend)
        await browser.connectAndLoad()
        let original = try #require(browser.files.first { $0.name == "photo.jpg" })
        await browser.performBinAction(files: [original], action: .trash)
        #expect(browser.isConnected)
        #expect(browser.operationError?.contains("selected item was not moved") == true)
        let refreshed = try #require(browser.files.first { $0.name == original.name })
        #expect(refreshed.sessionID != original.sessionID)
        #expect(refreshed.path == original.path)
        #expect(await fixture.resets == 1)
        #expect(await fixture.device.snapshot().commands.filter { $0 == 0x1019 }.count == 2)
        #expect(try await DeviceBin(backend: backend).contents(storageID: 1).files.isEmpty)
        await browser.performBinAction(files: [refreshed], action: .trash)
        #expect(browser.operationError == nil)
        #expect(browser.binCount == 1)
        #expect(!browser.files.contains { $0.name == original.name })
        #expect(await fixture.device.snapshot().commands.filter { $0 == 0x1019 }.count == 5)
        await browser.disconnectAndReset()
    }

    private func setup(_ fixture: MoveResponderFixture) async throws -> (SwiftMTPBackend, MTPFile) {
        let backend = SwiftMTPBackend(connectionRecovery: .init(retryDelays: [], wait: { _ in })) {
            try await fixture.open()
        }
        _ = try await backend.connect()
        _ = try await backend.createUploadDirectory(storageID: 1, parent: "/", name: "Target")
        let file = try #require(try await backend.contents(storageID: 1, path: "/", showHiddenFiles: true)
            .first { $0.name == "photo.jpg" })
        return (backend, file)
    }

    @Test func resetRecoversOriginalFileAndRejectsOldSelectionsWithoutReplayingMove() async throws {
        let fixture = try MoveResponderFixture(.original)
        let (backend, file) = try await setup(fixture)
        await fixture.device.configureUnavailable([file.id], afterMove: true)
        await #expect(throws: MoveError.notApplied) {
            try await backend.move(storageID: 1, file: file, to: "/Target")
        }
        let root = try await backend.contents(storageID: 1, path: "/", showHiddenFiles: true)
        let original = try #require(root.first { $0.name == file.name })
        #expect(original.sessionID != file.sessionID)
        #expect(try await backend.contents(storageID: 1, path: "/Target", showHiddenFiles: true).isEmpty)
        await #expect(throws: SwiftBackendError.staleSelection) {
            try await backend.move(storageID: 1, file: file, to: "/Target")
        }
        #expect(await fixture.resets == 1)
        #expect(await fixture.opens == 2)
        #expect(await fixture.device.snapshot().commands.filter { $0 == 0x1019 }.count == 1)
        #expect(await backend.supportsMove(storageID: 1))
        try await backend.disconnect()
    }

    @Test func resetCanConfirmCompletedMoveUsingFreshSessionMetadata() async throws {
        let fixture = try MoveResponderFixture(.moved)
        let (backend, file) = try await setup(fixture)
        await fixture.device.configureUnavailable([file.id], afterMove: true)
        let moved = try await backend.move(storageID: 1, file: file, to: "/Target")
        #expect(moved.path == "/Target/photo.jpg" && moved.sessionID != file.sessionID)
        #expect(try await backend.contents(storageID: 1, path: "/", showHiddenFiles: true)
            .allSatisfy { $0.name != file.name })
        #expect(await fixture.resets == 1)
        #expect(await fixture.opens == 2)
        #expect(await fixture.device.snapshot().commands.filter { $0 == 0x1019 }.count == 1)
        try await backend.disconnect()
    }

    @Test func delayedCatalogueUpdateRecoversWithoutResettingOrChangingSession() async throws {
        let fixture = try MoveResponderFixture(.moved)
        let backend = SwiftMTPBackend(connectionRecovery: .init(
            replacementSettleDelay: .milliseconds(1), retryDelays: [],
            wait: { _ in await fixture.device.configureUnavailable([]) })) { try await fixture.open() }
        _ = try await backend.connect()
        _ = try await backend.createUploadDirectory(storageID: 1, parent: "/", name: "Target")
        let file = try #require(try await backend.contents(storageID: 1, path: "/", showHiddenFiles: true)
            .first { $0.name == "photo.jpg" })
        await fixture.device.configureUnavailable([file.id], afterMove: true)
        let moved = try await backend.move(storageID: 1, file: file, to: "/Target")
        #expect(moved.path == "/Target/photo.jpg" && moved.sessionID == file.sessionID)
        #expect(await fixture.resets == 0)
        #expect(await fixture.opens == 1)
        #expect(await fixture.device.snapshot().commands.filter { $0 == 0x1019 }.count == 1)
        try await backend.disconnect()
    }

    @Test func rejectedResetKeepsResponsiveSessionAndUnavailableFileWarning() async throws {
        let fixture = try MoveResponderFixture(.rejected)
        let (backend, file) = try await setup(fixture)
        await fixture.device.configureUnavailable([file.id], afterMove: true)
        await #expect(throws: MoveError.recoveryUnavailable) {
            try await backend.move(storageID: 1, file: file, to: "/Target")
        }
        #expect(await fixture.opens == 1)
        #expect(await fixture.resets == 1)
        let snapshot = await fixture.device.snapshot()
        #expect(!snapshot.closed)
        #expect(snapshot.commands.last == 0x1004) // Same-session liveness check.
        #expect(snapshot.commands.filter { $0 == 0x1019 }.count == 1)
        let root = try await backend.browseContents(storageID: 1, path: "/", showHiddenFiles: true)
        let other = try #require(root.files.first { $0.name == "second.jpg" })
        #expect(other.sessionID == file.sessionID)
        let destination = try await backend.browseContents(storageID: 1, path: "/Target", showHiddenFiles: true)
        #expect(destination.files.isEmpty && destination.unavailableCount == 1)
        // Strict checks still reject the inconsistent listing before another move.
        await #expect(throws: WireError.response(0x2009)) {
            try await backend.move(storageID: 1, file: other, to: "/Target")
        }
        #expect(await fixture.device.snapshot().commands.filter { $0 == 0x1019 }.count == 1)
        try await backend.disconnect()
    }

    @Test(arguments: [MoveResponderFixture.Recovery.failed, .persistent, .openFailure, .rejectedProbeFailure])
    func failedRecoveryClosesSessionAndRequiresPhysicalReconnect(recovery: MoveResponderFixture.Recovery) async throws {
        let fixture = try MoveResponderFixture(recovery)
        let (backend, file) = try await setup(fixture)
        await fixture.device.configureUnavailable([file.id], afterMove: true)
        await #expect(throws: MoveError.recoveryFailed) {
            try await backend.move(storageID: 1, file: file, to: "/Target")
        }
        #expect(await fixture.resets == 1)
        #expect(await fixture.device.snapshot().closed)
        #expect(await fixture.device.snapshot().commands.filter { $0 == 0x1019 }.count == 1)
        #expect(!(await backend.supportsMove(storageID: 1)))
        await #expect(throws: BackendSessionError.reconnectRequired) {
            try await backend.contents(storageID: 1, path: "/", showHiddenFiles: true)
        }
    }

    @Test func rejectedMoveAndPreexistingListingErrorDoNotReset() async throws {
        let fixture = try MoveResponderFixture(.original)
        let (backend, file) = try await setup(fixture)
        await fixture.device.configureFault(reject: 0x1019)
        await #expect(throws: WireError.response(0x200F)) {
            try await backend.move(storageID: 1, file: file, to: "/Target")
        }
        await fixture.device.configureFault()
        await fixture.device.configureUnavailable([file.id])
        await #expect(throws: WireError.response(0x2009)) {
            try await backend.move(storageID: 1, file: file, to: "/Target")
        }
        #expect(await fixture.resets == 0)
        #expect(await fixture.opens == 1)
        #expect(!(await fixture.device.snapshot().closed))
        try await backend.disconnect()
    }
}
