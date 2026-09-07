import Foundation
import MTPUSB
import MTPWire
import Testing

@testable import Piko

/// Generates protocol bytes, not MTPBackend return values. All integration tests
/// exercise the real Swift codec, transaction engine and app adapter together.
private actor WireDevice: MTPBulkTransport {
    enum Fault: Sendable {
        case none, missingCapability, wrongStorage, duplicateNames, duplicateHandles,
            caseDistinctNames, canonicalDistinctNames, undefinedAssociation, unsafeName,
            wrongParent, unknownSize, storageBusy, storageRejected,
            staleSession, invalidOpenHeader, timeout, shortPayload, busy, sizeMismatch,
            partialRejected, badPartialCount, changedAfterPartial
    }
    enum Failure: Error { case timeout, command }
    let fault: Fault
    let payloadSize: Int
    let fragmentSize: Int
    let emptyStorageResponses: Int
    let connectionUSBStatus: Int32?
    let partialReads: Bool
    private var header = Data()
    private var tail = Data()
    private var generated = 0
    private var delivered = 0
    private var opened = false
    private var nextTransaction: UInt32 = 1
    private var storageRequests = 0
    private var openRequests = 0
    private var staleSession = false
    private var renamed = false
    private(set) var closed = false
    private(set) var closeCount = 0
    private(set) var commands: [UInt16] = []
    private(set) var largestRead = 0
    private(set) var rangeRequests: [[UInt32]] = []
    private(set) var cancelRequests = 0
    private(set) var isPaused = false
    private(set) var sawCancelledRead = false
    private var pauseOffset: UInt32?
    private var pausedRead: CheckedContinuation<Void, Never>?
    private var partialOffset: Int?

    init(
        fault: Fault = .none, payloadSize: Int = 70003, fragmentSize: Int = 4093,
        emptyStorageResponses: Int = 0, connectionUSBStatus: Int32? = nil,
        partialReads: Bool = false
    ) {
        self.fault = fault
        self.payloadSize = payloadSize
        self.fragmentSize = fragmentSize
        self.emptyStorageResponses = emptyStorageResponses
        self.connectionUSBStatus = connectionUSBStatus
        self.partialReads = partialReads
    }

    func pauseRange(offset: UInt32) { pauseOffset = offset }
    func resumeRange() { isPaused = false; pausedRead?.resume(); pausedRead = nil }
    func cancel(transaction: UInt32) async -> Bool {
        cancelRequests += 1
        await close()
        return false // Models the G77 rejecting transaction cancellation.
    }

    func renameFile() { renamed = true }

    func write(_ data: Data) async throws {
        guard !closed, header.isEmpty, tail.isEmpty, generated == 0 else { throw Failure.command }
        if let connectionUSBStatus {
            throw USBError.status(connectionUSBStatus, transferred: 0)
        }
        let command = try ContainerHeader(data: Data(data.prefix(12)))
        guard command.type == .command, Int(command.length) == data.count,
            command.transaction == (opened ? nextTransaction : 0)
        else { throw Failure.command }
        if opened { nextTransaction += 1 }
        var reader = DatasetReader(Data(data.dropFirst(12)))
        var parameters: [UInt32] = []
        while reader.remaining > 0 { parameters.append(try reader.readUInt32()) }
        commands.append(command.code)
        var writer = DatasetWriter()
        switch command.code {
        case 0x1001:
            guard opened, parameters.isEmpty else { throw Failure.command }
            writer.append(UInt16(100))
            writer.append(UInt32(6))
            writer.append(UInt16(100))
            try writer.append(string: "microsoft.com: 1.0;")
            writer.append(UInt16(0))
            let operations = ReadOperation.allCases.filter {
                fault != .missingCapability || $0 != .getObject
            }
            writer.append(UInt32(operations.count + (partialReads ? 1 : 0)))
            for operation in operations { writer.append(operation.rawValue) }
            if partialReads { writer.append(ReadSession.getPartialObjectCode) }
            for _ in 0..<4 { writer.append(UInt32(0)) }
            for value in ["Synthetic", "Wire fixture", "1", "not-a-real-serial"] {
                try writer.append(string: value)
            }
        case 0x1002:
            guard !opened, parameters == [1] else { throw Failure.command }
            openRequests += 1
            if fault == .invalidOpenHeader {
                writer.append(UInt32(12))
                writer.append(UInt16(99))
                writer.append(UInt16(0x2001))
                writer.append(command.transaction)
                header = writer.data
                return
            }
            if fault == .staleSession && openRequests == 1 {
                staleSession = true
                header = try response(command.transaction, code: 0x201E, parameters: [77])
                return
            }
            opened = true
            header = try response(command.transaction)
            return
        case 0x1003:
            guard (opened || staleSession), parameters.isEmpty else { throw Failure.command }
            opened = false
            staleSession = false
            header = try response(command.transaction)
            return
        case 0x1004:
            guard opened, parameters.isEmpty else { throw Failure.command }
            if fault == .storageBusy {
                header = try response(command.transaction, code: 0x2019)
                return
            }
            if fault == .storageRejected {
                header = try response(command.transaction, code: 0x200F)
                return
            }
            storageRequests += 1
            if storageRequests <= emptyStorageResponses {
                writer.append(UInt32(0))
            } else {
                writer.append(UInt32(1))
                writer.append(UInt32(1))
            }
        case 0x1005:
            guard opened, parameters == [1] else { throw Failure.command }
            for value: UInt16 in [3, 2, 0] { writer.append(value) }
            writer.append(UInt64(1) << 40)
            writer.append(UInt64(1) << 39)
            writer.append(UInt32.max)
            try writer.append(string: "Wire storage")
            try writer.append(string: "")
        case 0x1007:
            guard opened, parameters.count == 3, parameters[0] == 1, parameters[1] == 0 else {
                throw Failure.command
            }
            let handles: [UInt32]
            switch parameters[2] {
            case UInt32.max: handles = fault == .duplicateHandles ? [10, 10] : [10]
            case 10: handles = [11, 12, 13]
            case 13: handles = []
            default: throw Failure.command
            }
            writer.append(UInt32(handles.count))
            for handle in handles { writer.append(handle) }
        case 0x1008:
            guard opened, parameters.count == 1, (10...13).contains(parameters[0]) else {
                throw Failure.command
            }
            let id = parameters[0]
            let folder = id == 10 || id == 13
            writer.append(UInt32(fault == .wrongStorage ? 2 : 1))
            writer.append(UInt16(folder ? 0x3001 : 0x3000))
            writer.append(UInt16(0))
            writer.append(
                UInt32(folder || id == 12 ? 0 : fault == .unknownSize ? UInt32.max : UInt32(payloadSize)))
            writer.append(UInt16(0))
            for _ in 0..<6 { writer.append(UInt32(0)) }
            writer.append(UInt32(fault == .wrongParent && id != 10 ? 99 : id == 10 ? 0 : 10))
            writer.append(UInt16(folder && fault != .undefinedAssociation ? 1 : 0))
            writer.append(UInt32(0))
            writer.append(UInt32(0))
            let name: String
            if fault == .unsafeName {
                name = "../outside"
            } else if id == 10 {
                name = "Pictures"
            } else if id == 11 {
                if renamed {
                    name = "changed.bin"
                } else if fault == .caseDistinctNames {
                    name = "photo.bin"
                } else if fault == .canonicalDistinctNames {
                    name = "é.bin"
                } else {
                    name = "日本語 📷.bin"
                }
            } else if id == 12 {
                switch fault {
                case .duplicateNames: name = "日本語 📷.bin"
                case .caseDistinctNames: name = "PHOTO.bin"
                case .canonicalDistinctNames: name = "e\u{301}.bin"
                default: name = ".empty"
                }
            } else {
                name = "Empty folder"
            }
            for value in [name, "20260831T120000", "20260831T120001", ""] {
                try writer.append(string: value)
            }
        case 0x101B:
            guard opened, partialReads, parameters.count == 3, [11, 12].contains(parameters[0]),
                parameters[2] <= ReadSession.maximumPartialObjectBytes else { throw Failure.command }
            rangeRequests.append(parameters)
            if fault == .partialRejected {
                header = try response(command.transaction, code: 0x2005)
                return
            }
            let total = parameters[0] == 11 ? payloadSize : 0
            let offset = Int(parameters[1]), count = Int(parameters[2])
            guard offset + count <= total else { throw Failure.command }
            partialOffset = offset
            header = try ContainerHeader.data(code: command.code, transaction: command.transaction, payloadLength: UInt64(count))
            generated = count
            delivered = 0
            tail = try response(command.transaction, parameters: [UInt32(count + (fault == .badPartialCount ? 1 : 0))])
            if fault == .changedAfterPartial { renamed = true }
            return
        case 0x1009:
            partialOffset = nil
            guard opened, parameters.count == 1, [11, 12].contains(parameters[0]) else {
                throw Failure.command
            }
            if fault == .busy {
                header = try response(command.transaction, code: 0x2019)
                return
            }
            let size = parameters[0] == 11 ? payloadSize : 0
            header = try ContainerHeader(
                length: UInt32(size + 12 + (fault == .sizeMismatch ? 1 : 0)),
                type: .data, code: command.code, transaction: command.transaction
            ).encoded()
            generated = size
            delivered = 0
            tail = try response(command.transaction)
            return
        default: throw Failure.command
        }
        header =
            try ContainerHeader(
                length: UInt32(12 + writer.data.count), type: .data,
                code: command.code, transaction: command.transaction
            ).encoded() + writer.data
        tail = try response(command.transaction)
    }

    func read(maxBytes: Int) async throws -> Data {
        sawCancelledRead = sawCancelledRead || Task.isCancelled
        guard !closed else { throw WireError.disconnected }
        let limit = min(maxBytes, fragmentSize)
        guard limit > 0 else { throw Failure.command }
        let result: Data
        if !header.isEmpty {
            result = Data(header.prefix(limit))
            header.removeFirst(result.count)
        } else if generated > 0 {
            if let pauseOffset, partialOffset == Int(pauseOffset), delivered >= 65536 {
                self.pauseOffset = nil
                isPaused = true
                await withCheckedContinuation { pausedRead = $0 }
            }
            if delivered >= min(payloadSize / 2, 65536) {
                if fault == .timeout { throw Failure.timeout }
                if fault == .shortPayload { return Data() }
            }
            if let partialOffset {
                result = Data((0..<min(limit, generated)).map { UInt8((partialOffset + delivered + $0) % 251) })
            } else {
                result = Data(repeating: 0x5A, count: min(limit, generated))
            }
            generated -= result.count
            delivered += result.count
        } else {
            result = Data(tail.prefix(limit))
            tail.removeFirst(result.count)
        }
        largestRead = max(largestRead, result.count)
        return result
    }
    func close() async {
        closeCount += 1
        closed = true
    }

    private func response(
        _ transaction: UInt32, code: UInt16 = 0x2001, parameters: [UInt32] = []
    ) throws -> Data {
        let header = try ContainerHeader(
            length: UInt32(12 + parameters.count * 4), type: .response,
            code: code, transaction: transaction)
        var writer = DatasetWriter()
        for parameter in parameters { writer.append(parameter) }
        return header.encoded() + writer.data
    }
}

private actor WaitStarted {
    private var started = false
    private var waiter: CheckedContinuation<Void, Never>?

    func signal() {
        started = true
        waiter?.resume()
        waiter = nil
    }

    func wait() async {
        if started { return }
        await withCheckedContinuation { waiter = $0 }
    }
}

private actor DelayRecorder {
    private var values: [Duration] = []
    func append(_ value: Duration) { values.append(value) }
    func snapshot() -> [Duration] { values }
}

private actor ConnectionDeviceFactory {
    private var statuses: [Int32?]
    private var devices: [WireDevice] = []

    init(statuses: [Int32?]) { self.statuses = statuses }

    func make() -> any MTPBulkTransport {
        let status = statuses.isEmpty ? nil : statuses.removeFirst()
        let device = WireDevice(connectionUSBStatus: status)
        devices.append(device)
        return device
    }

    func snapshot() -> [WireDevice] { devices }
}

private actor ThrowingConnectionFactory {
    enum Outcome: Sendable {
        case noCandidate
        case status(Int32)
        case success
    }

    private var outcomes: [Outcome]
    private var attempts = 0
    private var devices: [WireDevice] = []

    init(_ outcomes: [Outcome]) { self.outcomes = outcomes }

    func make() throws -> any MTPBulkTransport {
        attempts += 1
        guard !outcomes.isEmpty else { throw WireError.disconnected }
        switch outcomes.removeFirst() {
        case .noCandidate:
            throw USBError.noCandidate
        case .status(let code):
            throw USBError.status(code, transferred: 0)
        case .success:
            let device = WireDevice()
            devices.append(device)
            return device
        }
    }

    func snapshot() -> (attempts: Int, devices: [WireDevice]) { (attempts, devices) }
}

private final class WireTestDirectory {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "swift-mtp-test-\(UUID())")
    init() throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}

private func connect(_ device: WireDevice) async throws -> SwiftMTPBackend {
    let backend = SwiftMTPBackend { device }
    let storages = try await backend.connect()
    #expect(storages.count == 1)
    #expect(storages.first?.displayName == "Wire storage")
    #expect(storages.first?.info.maxCapacity == 1 << 40)
    #expect(await backend.deviceDetails() == MTPDeviceDetails(manufacturer: "Synthetic",
        model: "Wire fixture", firmware: "1", serialNumber: "not-a-real-serial"))
    return backend
}

private func picture(_ backend: SwiftMTPBackend) async throws -> MTPFile {
    let files = try await backend.contents(storageID: 1, path: "/Pictures", showHiddenFiles: true)
    return try #require(files.first { $0.id == 11 })
}

@MainActor @Test func swiftWireBackendDrivesBrowserAndRecursiveDownload() async throws {
    let device = WireDevice(fragmentSize: 7)
    let backend = SwiftMTPBackend { device }
    let model = DeviceBrowserModel(client: backend)
    await model.connectAndLoad()
    #expect(model.isConnected)
    #expect(model.files.map(\.name) == ["Pictures"])
    let root = model.files
    await model.load(path: "/Pictures")
    #expect(model.files.map(\.name) == ["Empty folder", "日本語 📷.bin"])
    let directory = try WireTestDirectory()
    let coordinator = TransferCoordinator()
    try await coordinator.run(backend: backend, storageID: 1, files: root, destination: directory.url)
    #expect(coordinator.results.count == 4)  // two folders and two files
    #expect(
        coordinator.results.filter { if case .downloaded = $0.outcome { true } else { false } }.count
            == 2)
    let bytes = try Data(contentsOf: directory.url.appendingPathComponent("Pictures/日本語 📷.bin"))
    #expect(bytes == Data(repeating: 0x5A, count: 70003))
    let empty = try Data(contentsOf: directory.url.appendingPathComponent("Pictures/.empty"))
    #expect(empty.isEmpty)
    let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.url.path)
    #expect(remaining == ["Pictures"])
    await model.disconnectAndReset()
    #expect(await device.closed)
    #expect(await device.commands.last == 0x1003)
}

@Test func swiftBackendChecksCapabilitiesAfterOpeningAndCloses() async throws {
    let device = WireDevice(fault: .missingCapability)
    let backend = SwiftMTPBackend { device }
    await #expect(throws: SwiftBackendError.missingOperations([0x1009])) {
        try await backend.connect()
    }
    #expect(await device.commands == [0x1002, 0x1001, 0x1003])
    #expect(await device.closed)
}

@Test func swiftBackendRetriesTransientConnectionFailuresWithFreshTransports() async throws {
    let factory = ConnectionDeviceFactory(statuses: [-6, -7, nil])
    let backend = SwiftMTPBackend(
        connectionRecovery: ConnectionRecoveryPolicy(
            retryDelays: [.zero, .zero], wait: { _ in })
    ) { await factory.make() }

    let storages = try await backend.connect()
    #expect(storages.count == 1)
    let devices = await factory.snapshot()
    #expect(devices.count == 3)
    #expect(await devices[0].closeCount == 1)
    #expect(await devices[1].closeCount == 1)
    #expect(await devices[2].closeCount == 0)
    #expect(await devices[0].commands.isEmpty)
    #expect(await devices[1].commands.isEmpty)
    #expect(await devices[2].commands == [0x1002, 0x1001, 0x1004, 0x1005])

    try await backend.disconnect()
    #expect(await devices[2].closeCount == 1)
}

@Test func swiftBackendRetriesTransientTransportFactoryFailures() async throws {
    let factory = ThrowingConnectionFactory([.status(-6), .status(-7), .success])
    let backend = SwiftMTPBackend(
        connectionRecovery: ConnectionRecoveryPolicy(
            retryDelays: [.zero, .zero], wait: { _ in })
    ) { try await factory.make() }

    let storages = try await backend.connect()
    #expect(storages.count == 1)
    let snapshot = await factory.snapshot()
    #expect(snapshot.attempts == 3)
    #expect(snapshot.devices.count == 1)
    #expect(await snapshot.devices[0].commands == [0x1002, 0x1001, 0x1004, 0x1005])
    try await backend.disconnect()
    #expect(await snapshot.devices[0].closeCount == 1)
}

@Test func swiftBackendDoesNotRescanWhenNoMTPDeviceIsPresent() async throws {
    let factory = ThrowingConnectionFactory([.noCandidate, .success])
    let backend = SwiftMTPBackend(
        connectionRecovery: ConnectionRecoveryPolicy(retryDelays: [.zero, .zero], wait: { _ in })
    ) { try await factory.make() }
    await #expect(throws: USBError.noCandidate) { try await backend.connect() }
    let snapshot = await factory.snapshot()
    #expect(snapshot.attempts == 1)
    #expect(snapshot.devices.isEmpty)
}

@Test func swiftBackendWaitsBeforeFirstReplacementAttempt() async throws {
    let first = WireDevice()
    let second = WireDevice()
    let factory = DeviceFactory([first, second])
    let delays = DelayRecorder()
    let log = DiagnosticLog()
    let backend = SwiftMTPBackend(
        diagnostics: log,
        connectionRecovery: ConnectionRecoveryPolicy(
            replacementSettleDelay: .milliseconds(750), retryDelays: [],
            wait: { await delays.append($0) })
    ) { try await factory.next() }

    _ = try await backend.connect()
    let recoveryID = log.nextCorrelationID()
    _ = try await DiagnosticContext.$recoveryID.withValue(recoveryID) {
        try await backend.replaceSession()
    }

    #expect(await delays.snapshot() == [.milliseconds(750)])
    #expect(await factory.attemptCount == 2)
    #expect(await first.closeCount == 1)
    let wait = try #require(log.snapshot().events.first { $0.kind == .recoveryWait })
    #expect(wait.recoveryID == recoveryID)
    #expect(wait.recoveryAttempt == 1)
    #expect(wait.delayMilliseconds == 750)
    let attempt = try #require(log.snapshot().events.first { $0.kind == .recoveryAttempt })
    #expect(attempt.recoveryID == recoveryID)
    #expect(attempt.recoveryAttempt == 1)
    #expect(attempt.failure == nil)
    try await backend.disconnect()
}

@Test func swiftBackendDoesNotRetryMalformedOpenSessionIntoLeftoverPayload() async throws {
    let malformed = WireDevice(fault: .invalidOpenHeader)
    let healthy = WireDevice()
    let factory = DeviceFactory([malformed, healthy])
    let backend = SwiftMTPBackend(
        connectionRecovery: ConnectionRecoveryPolicy(retryDelays: [.zero], wait: { _ in })
    ) { try await factory.next() }

    await #expect(throws: MTPConnectionOutOfSync.self) { try await backend.connect() }
    #expect(await factory.attemptCount == 1)
    #expect(await malformed.closeCount == 1)
    #expect(await healthy.commands.isEmpty)
    // The user can explicitly try again after physically reconnecting.
    #expect(try await backend.connect().count == 1)
    try await backend.disconnect()
}

@Test func swiftBackendSurfacesFinalTransientErrorWhenConnectionRetriesExhaust() async throws {
    let factory = ThrowingConnectionFactory([
        .status(-4), .status(-6), .status(-7), .success,
    ])
    let backend = SwiftMTPBackend(
        connectionRecovery: ConnectionRecoveryPolicy(
            retryDelays: [.zero, .zero], wait: { _ in })
    ) { try await factory.make() }

    await #expect(throws: USBError.status(-7, transferred: 0)) {
        try await backend.connect()
    }
    let snapshot = await factory.snapshot()
    #expect(snapshot.attempts == 3)
    #expect(snapshot.devices.isEmpty)
}

@Test func swiftBackendDoesNotRetryPermanentUSBConnectionFailure() async throws {
    let factory = ConnectionDeviceFactory(statuses: [-3, nil])
    let backend = SwiftMTPBackend(
        connectionRecovery: ConnectionRecoveryPolicy(
            retryDelays: [.zero], wait: { _ in })
    ) { await factory.make() }

    await #expect(throws: USBError.status(-3, transferred: 0)) {
        try await backend.connect()
    }
    let devices = await factory.snapshot()
    #expect(devices.count == 1)
    #expect(await devices[0].closeCount == 1)
}

@Test func swiftBackendConnectionRetryBackoffIsCancellable() async throws {
    let factory = ConnectionDeviceFactory(statuses: [-6, nil])
    let waitStarted = WaitStarted()
    let backend = SwiftMTPBackend(
        connectionRecovery: ConnectionRecoveryPolicy(
            retryDelays: [.seconds(60)],
            wait: { delay in
                await waitStarted.signal()
                try await Task.sleep(for: delay)
            })
    ) { await factory.make() }

    let connection = Task { try await backend.connect() }
    await waitStarted.wait()
    connection.cancel()
    await #expect(throws: CancellationError.self) { try await connection.value }
    let devices = await factory.snapshot()
    #expect(devices.count == 1)
    #expect(await devices[0].closeCount == 1)
}

@Test func swiftBackendRecoversRetainedAndroidSessionBeforeDeviceInfo() async throws {
    let device = WireDevice(fault: .staleSession)
    let backend = try await connect(device)
    #expect(await device.commands == [0x1002, 0x1003, 0x1002, 0x1001, 0x1004, 0x1005])
    try await backend.disconnect()
    #expect(await device.commands.last == 0x1003)
    #expect(await device.closed)
}

@Test func swiftBackendWaitsForAndroidStorageReadiness() async throws {
    let device = WireDevice(emptyStorageResponses: 2)
    let backend = SwiftMTPBackend(
        storageReadiness: StorageReadinessPolicy(
            retryDelays: [.zero, .zero], wait: { _ in })
    ) { device }
    let storages = try await backend.connect()
    #expect(storages.count == 1)
    #expect(await device.commands == [0x1002, 0x1001, 0x1004, 0x1004, 0x1004, 0x1005])
    try await backend.disconnect()
    #expect(await device.commands.last == 0x1003)
    #expect(await device.closed)
}

@Test func swiftBackendRejectsPersistentlyUnavailableStorageAndCloses() async throws {
    let device = WireDevice(emptyStorageResponses: .max)
    let backend = SwiftMTPBackend(
        storageReadiness: StorageReadinessPolicy(
            retryDelays: [.zero, .zero], wait: { _ in })
    ) { device }
    await #expect(throws: BackendError.noStorage) { try await backend.connect() }
    #expect(await device.commands == [0x1002, 0x1001, 0x1004, 0x1004, 0x1004, 0x1003])
    #expect(await device.closed)
}

@Test func swiftBackendRetriesFramedDeviceBusyDuringSetupWithFreshSession() async throws {
    let busy = WireDevice(fault: .storageBusy)
    let healthy = WireDevice()
    let factory = DeviceFactory([busy, healthy])
    let backend = SwiftMTPBackend(
        connectionRecovery: ConnectionRecoveryPolicy(
            retryDelays: [.zero], wait: { _ in }),
        storageReadiness: StorageReadinessPolicy(
            retryDelays: [.zero, .zero], wait: { _ in })
    ) { try await factory.next() }

    let storages = try await backend.connect()
    #expect(storages.count == 1)
    #expect(await factory.attemptCount == 2)
    #expect(await busy.commands == [0x1002, 0x1001, 0x1004, 0x1003])
    #expect(await busy.closeCount == 1)
    #expect(await healthy.commands == [0x1002, 0x1001, 0x1004, 0x1005])
    try await backend.disconnect()
    #expect(await healthy.closeCount == 1)
}

@Test func swiftBackendDoesNotRetryOtherFramedWireResponseDuringSetup() async throws {
    let rejected = WireDevice(fault: .storageRejected)
    let unused = WireDevice()
    let factory = DeviceFactory([rejected, unused])
    let backend = SwiftMTPBackend(
        connectionRecovery: ConnectionRecoveryPolicy(
            retryDelays: [.zero], wait: { _ in }),
        storageReadiness: StorageReadinessPolicy(
            retryDelays: [.zero, .zero], wait: { _ in })
    ) { try await factory.next() }

    await #expect(throws: WireError.response(0x200F)) { try await backend.connect() }
    #expect(await factory.attemptCount == 1)
    #expect(await rejected.commands == [0x1002, 0x1001, 0x1004, 0x1003])
    #expect(await rejected.closeCount == 1)
    #expect(await unused.commands.isEmpty)
    #expect(await !unused.closed)
}

@Test func swiftBackendStorageReadinessTaskCancellationReleasesTransport() async throws {
    let device = WireDevice(emptyStorageResponses: .max)
    let waitStarted = WaitStarted()
    let backend = SwiftMTPBackend(
        storageReadiness: StorageReadinessPolicy(
            retryDelays: [.seconds(60)],
            wait: { delay in
                await waitStarted.signal()
                try await Task.sleep(for: delay)
            })
    ) { device }
    let connection = Task { try await backend.connect() }
    await waitStarted.wait()
    connection.cancel()
    await #expect(throws: CancellationError.self) { try await connection.value }
    // Cancellation prevents CloseSession from being written, but the session's
    // invalidation path must still release the transport exactly once.
    #expect(await device.commands == [0x1002, 0x1001, 0x1004])
    #expect(await device.closed)
}

@Test func swiftBackendRejectsInconsistentAndUnsafeListings() async throws {
    for fault: WireDevice.Fault in [
        .wrongStorage, .duplicateNames, .duplicateHandles, .unsafeName, .wrongParent,
    ] {
        let device = WireDevice(fault: fault)
        let backend = try await connect(device)
        await #expect(throws: BackendSessionError.reconnectRequired) {
            try await backend.contents(storageID: 1, path: "/Pictures", showHiddenFiles: true)
        }
        #expect(await device.closed)
        await #expect(throws: BackendSessionError.reconnectRequired) {
            try await backend.contents(storageID: 1, path: "/", showHiddenFiles: true)
        }
    }
}

@Test func swiftBackendAcceptsCaseAndCanonicalDistinctSiblingNames() async throws {
    for fault: WireDevice.Fault in [.caseDistinctNames, .canonicalDistinctNames] {
        let device = WireDevice(fault: fault)
        let backend = try await connect(device)
        let files = try await backend.contents(
            storageID: 1, path: "/Pictures", showHiddenFiles: true)
        #expect(files.count == 3)
        #expect(Set(files.map { Data($0.name.utf8) }).count == 3)
        // A second command proves the accepted listing did not poison the session.
        #expect(try await backend.contents(storageID: 1, path: "/", showHiddenFiles: true).count == 1)
        try await backend.disconnect()
    }
}

@Test func swiftBackendBrowsesAndroidFoldersWithUndefinedAssociationType() async throws {
    let device = WireDevice(fault: .undefinedAssociation)
    let backend = try await connect(device)
    let root = try await backend.contents(storageID: 1, path: "/", showHiddenFiles: true)
    #expect(root.count == 1)
    #expect(root.first?.isFolder == true)
    let children = try await backend.contents(
        storageID: 1, path: "/Pictures", showHiddenFiles: true)
    #expect(children.first { $0.id == 13 }?.isFolder == true)
    try await backend.disconnect()
}

@Test func swiftBackendRejectsUnknownSizesBeforeOutputOrGetObject() async throws {
    let device = WireDevice(fault: .unknownSize)
    let backend = try await connect(device)
    let selected = try await picture(backend)
    #expect(selected.size == -1)
    let directory = try WireTestDirectory()
    await #expect(throws: SwiftBackendError.unsupportedSize) {
        try await backend.download(
            storageID: 1, files: [selected], to: directory.url, progress: { _ in })
    }
    #expect(await !device.commands.contains(0x1009))
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.url.path).isEmpty)
    try await backend.disconnect()
}

@Test func swiftBackendRechecksMetadataBeforeDownloading() async throws {
    let device = WireDevice()
    let backend = try await connect(device)
    let file = try await picture(backend)
    await device.renameFile()
    let directory = try WireTestDirectory()
    await #expect(throws: SwiftBackendError.staleSelection) {
        try await backend.download(storageID: 1, files: [file], to: directory.url, progress: { _ in })
    }
    #expect(await !device.commands.contains(0x1009))
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.url.path).isEmpty)
    try await backend.disconnect()
}

private actor DeviceFactory {
    private var devices: [WireDevice]
    private(set) var attemptCount = 0
    init(_ devices: [WireDevice]) { self.devices = devices }
    func next() throws -> WireDevice {
        guard !devices.isEmpty else { throw WireError.disconnected }
        attemptCount += 1
        return devices.removeFirst()
    }
}

@Test func swiftBackendRejectsSelectionAfterReconnectEvenIfHandleIsReused() async throws {
    let first = WireDevice()
    let second = WireDevice()
    let factory = DeviceFactory([first, second])
    let backend = SwiftMTPBackend { try await factory.next() }
    _ = try await backend.connect()
    let stale = try await picture(backend)
    try await backend.disconnect()
    _ = try await backend.connect()
    let fresh = try await picture(backend)
    #expect(stale.id == fresh.id)
    #expect(stale.sessionID != fresh.sessionID)
    let directory = try WireTestDirectory()
    await #expect(throws: SwiftBackendError.staleSelection) {
        try await backend.download(storageID: 1, files: [stale], to: directory.url, progress: { _ in })
    }
    #expect(await !second.commands.contains(0x1009))
    try await backend.download(storageID: 1, files: [fresh], to: directory.url, progress: { _ in })
    try await backend.disconnect()
    #expect(await first.closed)
    #expect(await second.closed)
}

@Test func swiftBackendRemovesPartialOutputOnProtocolAndTransportFailure() async throws {
    for fault: WireDevice.Fault in [.timeout, .shortPayload, .sizeMismatch] {
        let device = WireDevice(fault: fault)
        let backend = try await connect(device)
        let file = try await picture(backend)
        let directory = try WireTestDirectory()
        await #expect(throws: BackendSessionError.reconnectRequired) {
            try await backend.download(storageID: 1, files: [file], to: directory.url, progress: { _ in })
        }
        #expect(await device.closed)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.url.path).isEmpty)
        await #expect(throws: BackendSessionError.reconnectRequired) {
            try await backend.contents(storageID: 1, path: "/", showHiddenFiles: true)
        }
    }
}

@MainActor @Test func browserLeavesConnectedStateAfterFatalSwiftDownloadOrListing() async throws {
    do {
        let device = WireDevice(fault: .timeout)
        let model = DeviceBrowserModel(client: SwiftMTPBackend { device })
        await model.connectAndLoad()
        await model.load(path: "/Pictures")
        let file = try #require(model.files.first { $0.id == 11 })
        model.replaceSelection([file.id])
        let directory = try WireTestDirectory()
        await model.download(files: [file], to: directory.url)
        let reconnectRequired: Bool
        if case .reconnectRequired = model.state {
            reconnectRequired = true
        } else {
            reconnectRequired = false
        }
        #expect(reconnectRequired)
        #expect(!model.isConnected)
        #expect(model.storages.isEmpty)
        #expect(model.files.isEmpty)
        #expect(model.selectedFileIDs.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.url.path).isEmpty)
    }
    do {
        let device = WireDevice(fault: .wrongParent)
        let model = DeviceBrowserModel(client: SwiftMTPBackend { device })
        await model.connectAndLoad()
        #expect(model.isConnected)
        await model.load(path: "/Pictures")
        #expect(!model.isConnected)
        #expect(model.storages.isEmpty)
        #expect(model.currentPath == "/")
        #expect(model.state != .connected)
    }
}

@MainActor @Test func browserReplacesFatalTransferSessionWithoutReplayingIt() async throws {
    let broken = WireDevice(fault: .timeout)
    let healthy = WireDevice()
    let factory = DeviceFactory([broken, healthy])
    let backend = SwiftMTPBackend(
        connectionRecovery: ConnectionRecoveryPolicy(
            retryDelays: [.zero], wait: { _ in })
    ) { try await factory.next() }
    let model = DeviceBrowserModel(client: backend)
    await model.connectAndLoad()
    await model.load(path: "/Pictures")
    let file = try #require(model.files.first { $0.id == 11 })
    model.replaceSelection([file.id])
    let directory = try WireTestDirectory()

    await model.download(files: [file], to: directory.url)

    #expect(model.isConnected)
    #expect(model.currentPath == "/Pictures")
    #expect(model.files.map(\.name) == ["Empty folder", "日本語 📷.bin"])
    #expect(model.transferConfirmation?.contains("was not retried") == true)
    #expect(model.transferConfirmation?.contains("restored automatically") == true)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.url.path).isEmpty)
    #expect(await broken.closeCount == 1)
    #expect(await healthy.commands.filter { $0 == 0x1009 }.isEmpty)
    #expect(await factory.attemptCount == 2)
}

@Test func swiftBackendPreservesExistingOutputAndSymlinks() async throws {
    let device = WireDevice()
    let backend = try await connect(device)
    let file = try await picture(backend)
    let directory = try WireTestDirectory()
    let target = directory.url.appendingPathComponent(file.name)
    let original = Data([0x7A])
    try original.write(to: target)
    await #expect(throws: (any Error).self) {
        try await backend.download(storageID: 1, files: [file], to: directory.url, progress: { _ in })
    }
    #expect(try Data(contentsOf: target) == original)
    try FileManager.default.removeItem(at: target)
    try FileManager.default.createSymbolicLink(
        at: target, withDestinationURL: directory.url.appendingPathComponent("missing"))
    await #expect(throws: (any Error).self) {
        try await backend.download(storageID: 1, files: [file], to: directory.url, progress: { _ in })
    }
    #expect(
        try FileManager.default.attributesOfItem(atPath: target.path)[.type] as? FileAttributeType
            == .typeSymbolicLink)
    #expect(await !device.commands.contains(0x1009))
    try await backend.disconnect()
}

@Test func swiftBackendDeviceBusyKeepsSessionUsableAndRemovesOutput() async throws {
    let device = WireDevice(fault: .busy)
    let backend = try await connect(device)
    let file = try await picture(backend)
    let directory = try WireTestDirectory()
    await #expect(throws: WireError.response(0x2019)) {
        try await backend.download(storageID: 1, files: [file], to: directory.url, progress: { _ in })
    }
    #expect(await !device.closed)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.url.path).isEmpty)
    let entries = try await backend.contents(storageID: 1, path: "/", showHiddenFiles: true)
    #expect(entries.count == 1)
    try await backend.disconnect()
}

private final class WireProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var last: Int64 = 0
    private var count = 0
    private var monotonic = true
    func receive(_ update: TransferProgress) {
        lock.lock()
        defer { lock.unlock() }
        monotonic = monotonic && update.bytesTransferred >= last
        last = update.bytesTransferred
        count += 1
    }
    var snapshot: (Int64, Int, Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (last, count, monotonic)
    }
}

@Test func swiftBackendStreamsGeneratedLargeObjectAndReportsProgress() async throws {
    let size = 32 * 1024 * 1024 + 17
    let device = WireDevice(payloadSize: size, fragmentSize: 65536)
    let backend = try await connect(device)
    let file = try await picture(backend)
    let directory = try WireTestDirectory()
    let progress = WireProgress()
    try await backend.download(
        storageID: 1, files: [file], to: directory.url, progress: { progress.receive($0) })
    let snapshot = progress.snapshot
    #expect(snapshot.0 == Int64(size))
    #expect(snapshot.1 > 500)
    #expect(snapshot.2)
    #expect(await device.largestRead <= 65536)
    let handle = try FileHandle(forReadingFrom: directory.url.appendingPathComponent(file.name))
    defer { try? handle.close() }
    var verified = 0
    while let chunk = try handle.read(upToCount: 65536), !chunk.isEmpty {
        #expect(chunk.allSatisfy { $0 == 0x5A })
        verified += chunk.count
    }
    #expect(verified == size)
    try await backend.disconnect()
}

@Test func swiftBackendSerializesConcurrentListings() async throws {
    let device = WireDevice(fragmentSize: 1)
    let backend = try await connect(device)
    async let first = backend.contents(storageID: 1, path: "/Pictures", showHiddenFiles: true)
    async let second = backend.contents(storageID: 1, path: "/Pictures", showHiddenFiles: false)
    let results = try await (first, second)
    #expect(results.0.count == 3)
    #expect(results.1.count == 2)
    try await backend.disconnect()
}

@Test func robustnessBackendReconnectAfterFailedDownloadUsesFreshSession() async throws {
    for cycle in 0..<24 {
        let failed = WireDevice(
            fault: cycle % 2 == 0 ? .timeout : .shortPayload, payloadSize: 65, fragmentSize: 7)
        let healthy = WireDevice(payloadSize: 65)
        let factory = DeviceFactory([failed, healthy])
        let log = DiagnosticLog()
        let backend = SwiftMTPBackend(diagnostics: log) { try await factory.next() }
        _ = try await backend.connect()
        let stale = try await picture(backend)
        let directory = try WireTestDirectory()
        await #expect(throws: (any Error).self) {
            try await backend.download(
                storageID: 1, files: [stale], to: directory.url, progress: { _ in })
        }
        #expect(await failed.closed)
        #expect(await failed.commands.filter { $0 == 0x1009 }.count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.url.path).isEmpty)
        _ = try await backend.connect()  // Explicit reconnect, not fallback/replay.
        #expect(await !healthy.commands.contains(0x1009))
        let fresh = try await picture(backend)
        #expect(fresh.sessionID != stale.sessionID)
        await #expect(throws: SwiftBackendError.staleSelection) {
            try await backend.download(
                storageID: 1, files: [stale], to: directory.url, progress: { _ in })
        }
        try await backend.download(storageID: 1, files: [fresh], to: directory.url, progress: { _ in })
        #expect(
            try Data(contentsOf: directory.url.appendingPathComponent(fresh.name))
                == Data(repeating: 0x5A, count: 65))
        try await backend.disconnect()
        #expect(await healthy.closed)
        let json = String(decoding: try JSONEncoder().encode(log.snapshot()), as: UTF8.self)
        for secret in [
            fresh.name, "not-a-real-serial", "Wire storage", "Wire fixture", directory.url.path,
        ] {
            #expect(!json.contains(secret))
        }
        #expect(log.snapshot().events.contains { $0.kind == .transaction && $0.failure != nil })
    }
}

private struct RangedDownloadTests {
    @MainActor @Test(arguments: [UInt32(0), ReadSession.maximumPartialObjectBytes])
    func cancelDrainsOnlyCurrentRangeThenBrowsesAndDownloadsAgain(pauseAt: UInt32) async throws {
        let size = Int(ReadSession.maximumPartialObjectBytes) * 3 + 123
        let device = WireDevice(payloadSize: size, fragmentSize: 65536, partialReads: true)
        let log = DiagnosticLog(capacity: 4096)
        let backend = SwiftMTPBackend(canCancelActiveTransfer: true, diagnostics: log) { device }
        let model = DeviceBrowserModel(client: backend, diagnostics: log)
        await model.connectAndLoad()
        await model.load(path: "/Pictures")
        let file = try #require(model.files.first { !$0.isFolder })
        let empty = try #require(try await backend.contents(storageID: 1, path: "/Pictures", showHiddenFiles: true).first { $0.size == 0 && !$0.isFolder })
        let output = try WireTestDirectory()
        #expect(await backend.supportsDownloadCancellation())
        // Repeat cancellation and a successful download on this SAME session.
        for _ in 0..<2 {
            let before = await device.rangeRequests.count
            await device.pauseRange(offset: pauseAt)
            let download = Task { await model.download(files: [empty, file], to: output.url) }
            for _ in 0..<3000 {
                if await device.isPaused { break }
                try await Task.sleep(for: .milliseconds(1))
            }
            let paused = await device.isPaused
            if !paused { download.cancel() }
            try #require(paused)
            #expect(model.transfers.canCancelActiveTransfer)
            model.transfers.cancelTransfer()
            await device.resumeRange()
            await download.value
            #expect(await device.rangeRequests.count - before == 2 + Int(pauseAt / ReadSession.maximumPartialObjectBytes))
            #expect(await device.cancelRequests == 0)
            #expect(await device.closeCount == 0)
            #expect(await device.sawCancelledRead == false)
            #expect(model.isConnected)
            #expect(model.operationError == nil)
            #expect(model.transferConfirmation == nil)
            #expect(!FileManager.default.fileExists(atPath: output.url.appendingPathComponent(file.name).path))
            #expect(FileManager.default.fileExists(atPath: output.url.appendingPathComponent(empty.name).path))
            await model.load(path: "/Pictures")
            #expect(model.operationError == nil)
            let fresh = try #require(model.files.first { !$0.isFolder })
            let complete = try WireTestDirectory()
            await model.download(files: [fresh], to: complete.url)
            #expect(model.operationError == nil)
            #expect(model.isConnected)
            let bytes = try Data(contentsOf: complete.url.appendingPathComponent(fresh.name))
            #expect(bytes == Data((0..<size).map { UInt8($0 % 251) }))
        }
        #expect(await device.commands.filter { $0 == 0x1002 }.count == 1)
        #expect(await !device.commands.contains(0x1009))
        let events = log.snapshot().events
        #expect(events.contains { $0.kind == .downloadStrategy && $0.operation == 0x101B && $0.requestedBytes == 1048576 })
        #expect(events.filter { $0.kind == .transaction && $0.operation == 0x101B }.allSatisfy { $0.transferID != nil })
        #expect(!events.contains { $0.kind == .usbCancel || $0.kind == .recovery || $0.kind == .malformedHeader })
        await model.disconnectAndReset()
        #expect(await device.closeCount == 1)
    }

    @MainActor @Test func cancellingFinderRangeKeepsBrowserUsableWithoutErrorDialog() async throws {
        let device = WireDevice(payloadSize: 2_000_123, fragmentSize: 65536, partialReads: true)
        let model = DeviceBrowserModel(client: SwiftMTPBackend(canCancelActiveTransfer: true) { device })
        await model.connectAndLoad()
        await model.load(path: "/Pictures")
        let file = try #require(model.files.first { !$0.isFolder && $0.size > 0 })
        let output = try WireTestDirectory()
        let destination = output.url.appendingPathComponent(file.name)
        await device.pauseRange(offset: 0)
        let task = Task { try await model.writeFilePromise(file, to: destination) }
        for _ in 0..<3000 {
            if await device.isPaused { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(await device.isPaused)
        model.transfers.cancelTransfer()
        await device.resumeRange()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(model.operationError == nil)
        #expect(model.transferConfirmation == nil)
        #expect(model.state == .connected)
        #expect(!model.isTransferring)
        #expect(!model.transfers.isRunning)
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.url.path).isEmpty)
        await model.load(path: "/Pictures")
        #expect(model.state == .connected)
        #expect(model.files.contains { $0.name == file.name })
    }

    @Test func readCapabilityControlsCancellationAndNeverGuessesSupport() async throws {
        let device = WireDevice()
        let backend = SwiftMTPBackend(canCancelActiveTransfer: true) { device }
        _ = try await backend.connect()
        #expect(await !backend.supportsDownloadCancellation())
        let file = try await picture(backend)
        let output = try WireTestDirectory()
        try await backend.download(storageID: 1, files: [file], to: output.url, progress: { _ in })
        #expect(await device.rangeRequests.isEmpty)
        #expect(await device.commands.contains(0x1009))
        try await backend.disconnect()
    }

    @MainActor @Test func quittingDuringRangeWaitsForItsResponseThenClosesCleanly() async throws {
        let device = WireDevice(payloadSize: 3 * 1048576, fragmentSize: 65536, partialReads: true)
        let model = DeviceBrowserModel(client: SwiftMTPBackend(canCancelActiveTransfer: true) { device })
        await model.connectAndLoad()
        await model.load(path: "/Pictures")
        let file = try #require(model.files.first { !$0.isFolder })
        let output = try WireTestDirectory()
        await device.pauseRange(offset: 0)
        let download = Task { await model.download(files: [file], to: output.url) }
        for _ in 0..<3000 {
            if await device.isPaused { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let paused = await device.isPaused
        if !paused { download.cancel() }
        try #require(paused)
        let quit = Task { await model.prepareToQuit() }
        for _ in 0..<3000 {
            if model.transfers.stopRequested { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(model.transfers.stopRequested)
        #expect(await device.closeCount == 0)
        await device.resumeRange()
        await download.value
        await quit.value
        #expect(model.state == .disconnected)
        #expect(await device.rangeRequests.count == 1)
        #expect(await device.cancelRequests == 0)
        #expect(await device.closeCount == 1)
        #expect(await device.commands.last == 0x1003)
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.url.path).isEmpty)
    }

    @Test(arguments: [WireDevice.Fault.partialRejected, .badPartialCount, .changedAfterPartial, .timeout, .shortPayload])
    func failedRangeNeverFallsBackOrPublishesMixedFile(fault: WireDevice.Fault) async throws {
        let device = WireDevice(fault: fault, partialReads: true)
        let backend = try await connect(device)
        let file = try await picture(backend)
        let output = try WireTestDirectory()
        await #expect(throws: (any Error).self) {
            try await backend.download(storageID: 1, files: [file], to: output.url, progress: { _ in })
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.url.path).isEmpty)
        #expect(await device.rangeRequests.count == 1)
        #expect(await !device.commands.contains(0x1009))
        #expect(await device.cancelRequests == 0)
        _ = try? await backend.disconnect()
    }
}
