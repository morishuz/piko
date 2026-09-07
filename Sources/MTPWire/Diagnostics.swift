import Foundation

/// Error categories remain a closed vocabulary. Optional detailed metadata is
/// separate; unknown errors never use their arbitrary descriptions.
public enum DiagnosticFailure: String, Codable, Sendable {
    case cancelled, truncated, invalidLength, invalidType, invalidString, sizeLimit
    case unexpectedTransaction, unexpectedContainer, objectSizeMismatch, deviceRejected
    case streamingWriteUnsupported
    case disconnected, busy, sessionRequired, sessionAlreadyOpen, transactionExhausted
    case usbStatus, libraryMissing, noCandidate, ambiguousCandidates, targetNotFound, noStorage
    case invalidTransfer, shortWrite, conflict, other

    public static func classify(_ error: any Error) -> Self {
        if error is CancellationError { return .cancelled }
        if let error = error as? any DiagnosticError { return error.diagnosticFailure }
        guard let error = error as? WireError else { return .other }
        switch error {
        case .truncated: return .truncated
        case .invalidLength: return .invalidLength
        case .invalidType: return .invalidType
        case .invalidString: return .invalidString
        case .sizeLimit: return .sizeLimit
        case .unexpectedTransaction: return .unexpectedTransaction
        case .unexpectedContainer: return .unexpectedContainer
        case .objectSizeMismatch: return .objectSizeMismatch
        case .streamingWriteUnsupported: return .streamingWriteUnsupported
        case .response: return .deviceRejected
        case .disconnected: return .disconnected
        case .busy: return .busy
        case .sessionRequired: return .sessionRequired
        case .sessionAlreadyOpen: return .sessionAlreadyOpen
        case .transactionExhausted: return .transactionExhausted
        }
    }
}

public protocol DiagnosticError: Error {
    var diagnosticFailure: DiagnosticFailure { get }
}

public enum DiagnosticEventKind: String, Codable, Sendable {
    case responderReset, moveRecovery
    case detailedRecordingStarted, detailedRecordingStopped
    case deviceDetails, directoryDetails, objectDetails, moveDetails
    // Retired discovery/cancel/reset cases remain for decoding saved reports.
    // Their presence is not a transport capability or an executable recovery path.
    case dragStarted, dragHover, dragNavigation, dragDropAccepted
    case deviceCapabilities, browserCapabilities, binLookup
    case appleUSBDiscovery, appleUSBError
    case usbDiscovery, usbOpenAttempt, usbDiscoveryRelease
    case connect, disconnect, recovery, listing, download, upload, downloadStrategy, uploadStrategy, uploadCleanup
    case transaction, datasetRejected, sessionReleased
    case usbOpen, usbRead, usbWrite, usbCancelStage, usbCancel, usbReset, usbDeviceReset
    case usbPresence, usbReleased
    case cancelRequested, stopAfterCurrentFile, recoveryDecision, recoveryWait, recoveryAttempt, malformedHeader
}

/// Numeric details only: version uses major<<24 | minor<<16 | micro;
/// list/candidate/complete use counts; descriptor uses device class;
/// probe stages use the interface-string descriptor index.
public enum DiagnosticDiscoveryStage: Int32, Codable, Sendable {
    case load = 1, version, initialize, list, descriptor, configuration
    case probeOpen, probeString, probeClose, candidate, complete
}

public enum DiagnosticPhase: String, Codable, Sendable {
    case command, firstHeader, dataPayload, responseHeader, responsePayload, complete
}

public enum DiagnosticCancelStage: String, Codable, Sendable {
    case cancelInterface, cancelLegacy
    case statusInterface64, statusLegacy64, statusInterface4, statusLegacy4
    case statusDecoded
    case clearBulkIn, clearBulkOut, drainBulkIn
    case readInterrupt, clearInterrupt, complete
    case unknown
}

public enum DiagnosticRecoveryAction: String, Codable, Sendable {
    case protocolCancel, deviceReset, closeOnly, reconnect
}

public enum DiagnosticTransferDirection: String, Codable, Sendable {
    case download, upload
}

/// Correlation values are process-local counters, never device identifiers.
/// Task-local propagation keeps app, protocol and USB records connected even
/// when a transfer runs in a detached worker task.
public enum DiagnosticContext {
    @TaskLocal public static var transferID: UInt64?
    @TaskLocal public static var recoveryID: UInt64?
    @TaskLocal public static var recoveryAttempt: Int?
}

/// Storage indices are connection-local ordinals, never device handles.
/// Device reports and the browser's actual button decisions are logged separately.
public struct DiagnosticCapabilities: Codable, Sendable {
    public let storageIndex: Int
    public let storageAccess: UInt16?
    public let supportedOperations: [UInt16]?
    public let uploadEnabled: Bool
    public let binEnabled: Bool
    public let binExists: Bool?
    public let binDropEnabled: Bool?
    public let binPrepared: Bool?
    public let binItemCount: Int?

    public init(storageIndex: Int, storageAccess: UInt16? = nil,
                supportedOperations: [UInt16]? = nil, uploadEnabled: Bool,
                binEnabled: Bool, binExists: Bool? = nil, binDropEnabled: Bool? = nil,
                binPrepared: Bool? = nil, binItemCount: Int? = nil) {
        self.storageIndex = storageIndex
        self.storageAccess = storageAccess
        self.supportedOperations = supportedOperations
        self.uploadEnabled = uploadEnabled
        self.binEnabled = binEnabled
        self.binExists = binExists
        self.binDropEnabled = binDropEnabled
        self.binPrepared = binPrepared
        self.binItemCount = binItemCount
    }
}

public struct DiagnosticEvent: Codable, Sendable {
    public let details: DiagnosticDetails?
    /// Process-local device ordinal; never a USB registry ID, serial or nickname.
    public let deviceID: UInt64?
    public let capabilities: DiagnosticCapabilities?
    public let sequence: UInt64
    public let elapsedMilliseconds: UInt64
    public let kind: DiagnosticEventKind
    public let durationMilliseconds: UInt64
    public let operation: UInt16?
    public let response: UInt16?
    public let bytes: Int?
    public let usbStatus: Int32?
    public let failure: DiagnosticFailure?
    public let phase: DiagnosticPhase?
    public let sampleCount: Int?
    public let cancelStage: DiagnosticCancelStage?
    public let usbDevicePresent: Bool?
    public let transportID: UInt64?
    public let sessionID: UInt64?
    public let transferID: UInt64?
    public let recoveryID: UInt64?
    public let recoveryAttempt: Int?
    public let transaction: UInt32?
    public let requestedBytes: Int?
    public let timeoutMilliseconds: UInt64?
    public let delayMilliseconds: UInt64?
    public let offsetMilliseconds: UInt64?
    public let recoveryAction: DiagnosticRecoveryAction?
    public let transferDirection: DiagnosticTransferDirection?
    public let usbVendor: UInt16?
    public let usbProduct: UInt16?
    public let usbConfiguration: UInt8?
    public let usbInterface: UInt8?
    public let usbInputEndpoint: UInt8?
    public let usbOutputEndpoint: UInt8?
    public let usbInterruptEndpoint: UInt8?
    public let usbInputPacketSize: Int?
    public let usbOutputPacketSize: Int?
    public let containerLength: UInt32?
    public let containerType: UInt16?
    public let containerCode: UInt16?
    public let containerTransaction: UInt32?
    public let discoveryStage: DiagnosticDiscoveryStage?
    public let discoveryValue: UInt32?
}

public struct DiagnosticSnapshot: Codable, Sendable {
    public let capacity: Int
    public let discardedEvents: UInt64
    public let events: [DiagnosticEvent]
    public let capabilityEvents: [DiagnosticEvent]?

    public init(capacity: Int, discardedEvents: UInt64, events: [DiagnosticEvent], capabilityEvents: [DiagnosticEvent]? = nil) {
        self.capabilityEvents = capabilityEvents
        self.capacity = capacity
        self.discardedEvents = discardedEvents
        self.events = events
    }

    public func excludingDetails() -> Self {
        Self(capacity: capacity, discardedEvents: discardedEvents,
             events: events.filter { $0.details == nil },
             capabilityEvents: capabilityEvents?.filter { $0.details == nil })
    }
}

/// O(1) ring insertion. Observer delivery is serialized with recording changes,
/// so disabling waits for already accepted events and blocks all later events.
/// Observers may read the log, but must not wait on another thread using it.
public final class DiagnosticLog: @unchecked Sendable {
    private final class Storage: @unchecked Sendable {
        let lock = NSRecursiveLock()
        var ring: [DiagnosticEvent?]
        var capabilityEvents: [String: DiagnosticEvent] = [:]
        var next = 0
        var total: UInt64 = 0
        var nextCorrelation: UInt64 = 1
        var started = DispatchTime.now().uptimeNanoseconds
        var recordsDetails = false
        var recordingEnabled: Bool
        var recordingGeneration: UInt64 = 0
        let observer: (@Sendable (DiagnosticEvent) -> Void)?
        init(capacity: Int, recordingEnabled: Bool, observer: (@Sendable (DiagnosticEvent) -> Void)?) {
            ring = Array(repeating: nil, count: min(4096, max(1, capacity)))
            self.recordingEnabled = recordingEnabled
            self.observer = observer
        }
    }
    private let storage: Storage
    private let deviceID: UInt64?

    public init(capacity: Int = 1024, recordingEnabled: Bool = true,
                observer: (@Sendable (DiagnosticEvent) -> Void)? = nil) {
        storage = Storage(capacity: capacity, recordingEnabled: recordingEnabled, observer: observer)
        deviceID = nil
    }

    private init(storage: Storage, deviceID: UInt64) {
        self.storage = storage
        self.deviceID = deviceID
    }

    /// Shares the ring, observer and correlation counter while tagging all
    /// device-owned app, protocol and USB events, including detached workers.
    public func forDevice() -> DiagnosticLog {
        DiagnosticLog(storage: storage, deviceID: nextCorrelationID())
    }

    public static func start() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    public var recordsDetails: Bool {
        storage.lock.lock()
        defer { storage.lock.unlock() }
        return storage.recordingEnabled && storage.recordsDetails
    }

    public func setRecordingEnabled(_ enabled: Bool) {
        storage.lock.lock()
        defer { storage.lock.unlock() }
        if storage.recordingEnabled != enabled { storage.recordingGeneration &+= 1 }
        storage.recordingEnabled = enabled
    }

    /// Batches use this token to avoid retaining activity collected while off,
    /// or publishing a batch across a disable/enable boundary.
    public var recordingGeneration: UInt64? {
        storage.lock.lock()
        defer { storage.lock.unlock() }
        return storage.recordingEnabled ? storage.recordingGeneration : nil
    }

    public func setRecordsDetails(_ enabled: Bool) {
        storage.lock.lock()
        defer { storage.lock.unlock() }
        let changed = storage.recordsDetails != enabled
        storage.recordsDetails = enabled
        if changed { record(enabled ? .detailedRecordingStarted : .detailedRecordingStopped) }
    }

    public func nextCorrelationID() -> UInt64 {
        storage.lock.lock()
        defer { storage.lock.unlock() }
        let value = storage.nextCorrelation
        storage.nextCorrelation = storage.nextCorrelation == UInt64.max ? 1 : storage.nextCorrelation + 1
        return value
    }

    public func record(
        _ kind: DiagnosticEventKind, since: UInt64? = nil,
        operation: UInt16? = nil, response: UInt16? = nil,
        bytes: Int? = nil, usbStatus: Int32? = nil, failure: DiagnosticFailure? = nil,
        phase: DiagnosticPhase? = nil, sampleCount: Int? = nil,
        cancelStage: DiagnosticCancelStage? = nil, usbDevicePresent: Bool? = nil,
        durationMilliseconds: UInt64? = nil,
        transportID: UInt64? = nil, sessionID: UInt64? = nil,
        transferID: UInt64? = nil, recoveryID: UInt64? = nil,
        recoveryAttempt: Int? = nil, transaction: UInt32? = nil,
        requestedBytes: Int? = nil, timeoutMilliseconds: UInt64? = nil,
        delayMilliseconds: UInt64? = nil,
        offsetMilliseconds: UInt64? = nil,
        recoveryAction: DiagnosticRecoveryAction? = nil,
        transferDirection: DiagnosticTransferDirection? = nil,
        usbVendor: UInt16? = nil, usbProduct: UInt16? = nil,
        usbConfiguration: UInt8? = nil, usbInterface: UInt8? = nil,
        usbInputEndpoint: UInt8? = nil, usbOutputEndpoint: UInt8? = nil,
        usbInterruptEndpoint: UInt8? = nil,
        usbInputPacketSize: Int? = nil, usbOutputPacketSize: Int? = nil,
        containerLength: UInt32? = nil, containerType: UInt16? = nil,
        containerCode: UInt16? = nil, containerTransaction: UInt32? = nil,
        discoveryStage: DiagnosticDiscoveryStage? = nil, discoveryValue: UInt32? = nil,
        capabilities: DiagnosticCapabilities? = nil,
        details: DiagnosticDetails? = nil,
        recordingGeneration: UInt64? = nil
    ) {
        storage.lock.lock()
        defer { storage.lock.unlock() }
        // Check under the same lock as insertion: disabling recording takes
        // effect even for an operation that was already awaiting its response.
        guard storage.recordingEnabled else { return }
        if let recordingGeneration, recordingGeneration != storage.recordingGeneration { return }
        if details != nil && !storage.recordsDetails { return }
        let now = Self.start()
        let event = DiagnosticEvent(
            details: details?.bounded(),
            deviceID: deviceID,
            capabilities: capabilities,
            sequence: storage.total, elapsedMilliseconds: (now - storage.started) / 1_000_000,
            kind: kind,
            durationMilliseconds: durationMilliseconds
                ?? since.map { (now - min(now, $0)) / 1_000_000 } ?? 0,
            operation: operation, response: response, bytes: bytes,
            usbStatus: usbStatus, failure: failure, phase: phase,
            sampleCount: sampleCount, cancelStage: cancelStage,
            usbDevicePresent: usbDevicePresent,
            transportID: transportID, sessionID: sessionID,
            transferID: transferID ?? DiagnosticContext.transferID,
            recoveryID: recoveryID ?? DiagnosticContext.recoveryID,
            recoveryAttempt: recoveryAttempt ?? DiagnosticContext.recoveryAttempt,
            transaction: transaction, requestedBytes: requestedBytes,
            timeoutMilliseconds: timeoutMilliseconds,
            delayMilliseconds: delayMilliseconds,
            offsetMilliseconds: offsetMilliseconds, recoveryAction: recoveryAction,
            transferDirection: transferDirection,
            usbVendor: usbVendor, usbProduct: usbProduct,
            usbConfiguration: usbConfiguration, usbInterface: usbInterface,
            usbInputEndpoint: usbInputEndpoint, usbOutputEndpoint: usbOutputEndpoint,
            usbInterruptEndpoint: usbInterruptEndpoint,
            usbInputPacketSize: usbInputPacketSize,
            usbOutputPacketSize: usbOutputPacketSize,
            containerLength: containerLength, containerType: containerType,
            containerCode: containerCode, containerTransaction: containerTransaction,
            discoveryStage: discoveryStage, discoveryValue: discoveryValue)
        if let capabilities, (0..<256).contains(capabilities.storageIndex),
            kind == .deviceCapabilities || kind == .browserCapabilities {
            storage.capabilityEvents["\(deviceID ?? 0)-\(kind.rawValue)-\(capabilities.storageIndex)"] = event
            if storage.capabilityEvents.count > 4096,
               let oldest = storage.capabilityEvents.min(by: { $0.value.sequence < $1.value.sequence })?.key {
                storage.capabilityEvents.removeValue(forKey: oldest)
            }
        }
        storage.ring[storage.next] = event
        storage.next = (storage.next + 1) % storage.ring.count
        storage.total += 1
        storage.observer?(event)
    }

    public func snapshot() -> DiagnosticSnapshot {
        storage.lock.lock()
        defer { storage.lock.unlock() }
        let ordered = (storage.ring[storage.next...] + storage.ring[..<storage.next]).compactMap { $0 }
        return DiagnosticSnapshot(
            capacity: storage.ring.count, discardedEvents: storage.total - UInt64(ordered.count), events: ordered,
            capabilityEvents: storage.capabilityEvents.values.sorted { $0.sequence < $1.sequence })
    }

    public func resetCapabilities() {
        storage.lock.lock()
        defer { storage.lock.unlock() }
        if let deviceID {
            storage.capabilityEvents = storage.capabilityEvents.filter { $0.value.deviceID != deviceID }
        } else {
            storage.capabilityEvents.removeAll()
        }
    }

    public func clear() {
        storage.lock.lock()
        defer { storage.lock.unlock() }
        storage.capabilityEvents.removeAll()
        storage.ring = Array(repeating: nil, count: storage.ring.count)
        storage.next = 0
        storage.total = 0
        storage.started = Self.start()
    }
}
