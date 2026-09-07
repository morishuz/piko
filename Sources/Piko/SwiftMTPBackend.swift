import Foundation
import MTPUSB
import MTPWire

enum SwiftBackendError: LocalizedError, Equatable {
    case missingOperations([UInt16])
    case invalidMetadata, staleSelection, unsupportedSize

    var errorDescription: String? {
        switch self {
        case .missingOperations(let codes):
            "This device does not advertise the required read operations: "
                + codes.map { String(format: "0x%04x", $0) }.joined(separator: ", ")
        case .invalidMetadata:
            "The device returned inconsistent or ambiguous metadata. Reconnect before trying again."
        case .staleSelection:
            "The selection belongs to an earlier session or its metadata changed. Refresh and select it again."
        case .unsupportedSize:
            "Files with an unknown size or extended-length format are not supported."
        }
    }
}

struct MTPConnectionOutOfSync: LocalizedError, DiagnosticError {
    let underlying: any Error
    var errorDescription: String? {
        "The device is not ready for a new MTP session. An interrupted transfer may still be active. Unplug the phone or camera's USB cable, reconnect it, unlock it and select File Transfer, then click Connect. Reopening the app alone may not clear this state."
    }
    var diagnosticFailure: DiagnosticFailure { .classify(underlying) }
}

/// Some Android devices acknowledge OpenSession before publishing their
/// storage. Retrying only a fully successful, empty GetStorageIDs response is
/// read-only and cannot replay a partial USB/MTP transaction.
struct StorageReadinessPolicy: Sendable {
    let retryDelays: [Duration]
    let wait: @Sendable (Duration) async throws -> Void

    static let standard = StorageReadinessPolicy(
        retryDelays: [
            .zero, .milliseconds(150), .milliseconds(350), .milliseconds(750),
            .milliseconds(1_500),
        ],
        wait: { try await Task.sleep(for: $0) })
}

/// Connection setup may race a device still releasing its USB interface.
/// Retry only transient setup failures, including when restoring a session;
/// the interrupted file operation is never replayed.
struct ConnectionRecoveryPolicy: Sendable {
    let replacementSettleDelay: Duration
    let retryDelays: [Duration]
    let wait: @Sendable (Duration) async throws -> Void

    init(
        replacementSettleDelay: Duration = .zero, retryDelays: [Duration],
        wait: @escaping @Sendable (Duration) async throws -> Void
    ) {
        self.replacementSettleDelay = replacementSettleDelay
        self.retryDelays = retryDelays
        self.wait = wait
    }

    static let standard = ConnectionRecoveryPolicy(
        replacementSettleDelay: .milliseconds(750),
        retryDelays: [
            .milliseconds(500), .milliseconds(1_500), .milliseconds(3_000),
        ],
        wait: { try await Task.sleep(for: $0) })
}

/// Native app adapter. A fresh transport factory is required for every
/// connection. Initial hardware access starts on Connect; recovery can replace
/// an already connected device's session after a failed operation.
actor SwiftMTPBackend: MTPFolderUploadBackend, MTPFreshSessionBackend, MTPBinBackend, MTPThumbnailBackend {
    nonisolated let capabilities: BackendCapabilities
    nonisolated let maximumUploadFileSize: Int64? = Int64(UInt32.max) - 13
    private let makeTransport: @Sendable () async throws -> any MTPBulkTransport
    private let gate = OperationGate()
    private let diagnostics: DiagnosticLog?
    private let connectionRecovery: ConnectionRecoveryPolicy
    private let storageReadiness: StorageReadinessPolicy
    /// Installed atomically after connection succeeds; cleared as one unit.
    private struct ConnectedSession {
        let session: ReadSession
        let details: MTPDeviceDetails
        let generation: UUID
        let storageIDs: Set<UInt32>
        var writableStorageIDs: Set<UInt32>
        let operations: Set<UInt16>
        let binIdentities: [UInt32: BinStorageIdentity]
        var sampleSupport: [UInt16: Bool] = [:]
    }
    private var connection: ConnectedSession?
    private static let listingLimit = 100_000

    init(
        canCancelActiveTransfer: Bool = false,
        diagnostics: DiagnosticLog? = nil,
        connectionRecovery: ConnectionRecoveryPolicy = .standard,
        storageReadiness: StorageReadinessPolicy = .standard,
        makeTransport: @escaping @Sendable () async throws -> any MTPBulkTransport
    ) {
        self.capabilities = BackendCapabilities(reportsProgress: true, canCancelActiveTransfer: canCancelActiveTransfer)
        self.diagnostics = diagnostics
        self.connectionRecovery = connectionRecovery
        self.storageReadiness = storageReadiness
        self.makeTransport = makeTransport
    }

    func deviceDetails() async -> MTPDeviceDetails? { connection?.details }

    func connect() async throws -> [MTPStorage] {
        try await gate.run { try await self.connectImpl() }
    }

    func replaceSession() async throws -> [MTPStorage] {
        try await gate.run { try await self.replaceSessionImpl() }
    }

    private func replaceSessionImpl() async throws -> [MTPStorage] {
        if let connection { await discard(connection.session) }
        let settle = connectionRecovery.replacementSettleDelay
        if settle > .zero {
            diagnostics?.record(
                .recoveryWait, recoveryAttempt: 1,
                delayMilliseconds: Self.milliseconds(settle))
            try await connectionRecovery.wait(settle)
        }
        return try await connectImpl()
    }

    private func connectImpl() async throws -> [MTPStorage] {
        guard connection == nil else { throw BackendError.busy }
        diagnostics?.resetCapabilities()
        var retryDelays = connectionRecovery.retryDelays.makeIterator()
        var attempt = 1
        while true {
            try Task.checkCancellation()
            let started = DiagnosticLog.start()
            do {
                let result = try await DiagnosticContext.$recoveryAttempt.withValue(
                    DiagnosticContext.recoveryID == nil ? nil : attempt
                ) {
                    try await connectOnce()
                }
                if DiagnosticContext.recoveryID != nil {
                    diagnostics?.record(
                        .recoveryAttempt, since: started, recoveryAttempt: attempt)
                }
                return result
            } catch {
                if DiagnosticContext.recoveryID != nil {
                    diagnostics?.record(
                        .recoveryAttempt, since: started, failure: .classify(error),
                        recoveryAttempt: attempt)
                }
                try Task.checkCancellation()
                guard Self.isTransientConnectionError(error), let delay = retryDelays.next()
                else { throw error }
                attempt += 1
                if DiagnosticContext.recoveryID != nil {
                    diagnostics?.record(
                        .recoveryWait, recoveryAttempt: attempt,
                        delayMilliseconds: Self.milliseconds(delay))
                }
                try await connectionRecovery.wait(delay)
            }
        }
    }

    private static func milliseconds(_ duration: Duration) -> UInt64 {
        let components = duration.components
        guard components.seconds >= 0, components.attoseconds >= 0 else { return 0 }
        let seconds = UInt64(components.seconds)
        let fractional = UInt64(components.attoseconds) / 1_000_000_000_000_000
        return seconds.multipliedReportingOverflow(by: 1_000).partialValue + fractional
    }

    private func connectOnce() async throws -> [MTPStorage] {
        let fresh = ReadSession(transport: try await makeTransport(), diagnostics: diagnostics)
        do {
            // Establish/recover the MTP session before querying device data.
            // This opens the session before querying device information and lets ReadSession
            // clean up an Android session retained from an earlier app process.
            do {
                try await fresh.open()
            } catch let error as WireError {
                switch error {
                case .invalidType, .invalidLength, .unexpectedContainer, .unexpectedTransaction, .truncated:
                    // A new USB handle does not reset an in-flight device stream.
                    // Do not send another OpenSession into leftover file payload.
                    throw MTPConnectionOutOfSync(underlying: error)
                default: throw error
                }
            }
            let device = try await fresh.deviceInfo()
            let missing = ReadOperation.allCases.filter { !device.supports($0) }.map(\.rawValue)
            guard missing.isEmpty else { throw SwiftBackendError.missingOperations(missing) }
            let ids = try await storageIDsWhenReady(session: fresh)
            guard ids.count <= 256, Set(ids).count == ids.count,
                ids.allSatisfy({ $0 != 0 && $0 != UInt32.max })
            else { throw SwiftBackendError.invalidMetadata }
            var result: [MTPStorage] = []
            var writable: Set<UInt32> = []
            var binIdentities: [UInt32: BinStorageIdentity] = [:]
            for id in ids {
                try Task.checkCancellation()
                let info = try await fresh.storageInfo(storageID: id)
                binIdentities[id] = BinStorageIdentity(
                    manufacturer: device.manufacturer, model: device.model,
                    serialNumber: device.serialNumber, volumeLabel: info.volumeLabel,
                    storageDescription: info.storageDescription, capacity: info.maxCapacity)
                if info.accessCapability == 0 { writable.insert(id) }
                result.append(
                    MTPStorage(
                        id: id,
                        info: MTPStorageInfo(
                            storageType: info.storageType, filesystemType: info.filesystemType,
                            accessCapability: info.accessCapability, maxCapacity: info.maxCapacity,
                            freeSpaceInBytes: info.freeSpaceInBytes,
                            freeSpaceInImages: info.freeSpaceInImages,
                            storageDescription: info.storageDescription, volumeLabel: info.volumeLabel)))
            }
            connection = ConnectedSession(
                session: fresh, details: MTPDeviceDetails(manufacturer: device.manufacturer, model: device.model,
                    firmware: device.deviceVersion, serialNumber: device.serialNumber), generation: UUID(), storageIDs: Set(ids),
                writableStorageIDs: writable, operations: Set(device.operations),
                binIdentities: binIdentities)
            diagnostics?.record(.deviceDetails, sessionID: fresh.diagnosticSessionID,
                details: .device(manufacturer: device.manufacturer, model: device.model, firmware: device.deviceVersion))
            let monitoredOperations = Set(ReadOperation.allCases.map(\.rawValue) + WriteOperation.allCases.map(\.rawValue))
                .union(RangedUpload.requiredOperations).union([ReadSession.getPartialObjectCode])
            for (index, storage) in result.enumerated() {
                diagnostics?.record(.deviceCapabilities, capabilities: DiagnosticCapabilities(
                    storageIndex: index, storageAccess: storage.info.accessCapability,
                    supportedOperations: Set(device.operations).intersection(monitoredOperations).sorted(),
                    uploadEnabled: await supportsUpload(to: storage.id),
                    binEnabled: await supportsBin(storageID: storage.id)))
            }
            return result
        } catch {
            try? await fresh.close()
            throw error
        }
    }

    private static func isTransientConnectionError(_ error: any Error) -> Bool {
        if let usbError = error as? USBError {
            switch usbError {
            case .noCandidate:
                return false
            case .status(let code, _):
                // NO_DEVICE, NOT_FOUND, BUSY and TIMEOUT can all occur while a
                // cancelled responder or macOS is still releasing the interface.
                return code == -4 || code == -5 || code == -6 || code == -7
            default:
                return false
            }
        }
        // A responder may be visible and claimable before it has returned to
        // the command-ready state. Retrying a framed DeviceBusy response is
        // safe only here: each explicit Connect attempt closes the old session
        // and starts a fresh one, and no file operation is replayed.
        guard let wireError = error as? WireError else { return false }
        switch wireError {
        case .response(0x2019), .response(0x201E), .unexpectedTransaction,
            .unexpectedContainer, .truncated, .invalidLength, .invalidType:
            return true
        default:
            return false
        }
    }

    private func storageIDsWhenReady(session: ReadSession) async throws -> [UInt32] {
        var ids = try await session.storageIDs()
        for delay in storageReadiness.retryDelays where ids.isEmpty {
            try Task.checkCancellation()
            try await storageReadiness.wait(delay)
            ids = try await session.storageIDs()
        }
        guard !ids.isEmpty else { throw BackendError.noStorage }
        return ids
    }

    func supportsUpload(to storageID: UInt32) async -> Bool {
        guard let connection else { return false }
        return connection.storageIDs.contains(storageID) && connection.writableStorageIDs.contains(storageID)
            && connection.operations.contains(WriteOperation.sendObjectInfo.rawValue)
            && connection.operations.contains(WriteOperation.sendObject.rawValue)
    }

    func supportsDownloadCancellation() async -> Bool {
        capabilities.canCancelActiveTransfer
            && connection?.operations.contains(ReadSession.getPartialObjectCode) == true
    }

    func supportsUploadCancellation(to storageID: UInt32) async -> Bool {
        guard capabilities.canCancelActiveTransfer, let connection else { return false }
        return connection.writableStorageIDs.contains(storageID)
            && RangedUpload.requiredOperations.isSubset(of: connection.operations)
    }

    func supportsBinDeletion(storageID: UInt32) async -> Bool {
        guard let connection else { return false }
        return connection.writableStorageIDs.contains(storageID)
            && connection.operations.contains(0x100B)
    }

    func deleteBinItem(storageID: UInt32, file: MTPFile, within root: String) async throws {
        try await gate.run { try await self.deleteBinItemImpl(storageID: storageID, file: file, root: root) }
    }

    private func deleteBinItemImpl(storageID: UInt32, file: MTPFile, root: String) async throws {
        try RemotePath.validate(file.parentPath)
        try RemotePath.validateName(file.name)
        guard BinLayout.isCandidateRoot(root), file.path != root,
            file.path.utf8.starts(with: (root + "/").utf8),
            file.path != RemotePath.appending(BinLayout.markerName, to: root),
            file.path == RemotePath.appending(file.name, to: file.parentPath) else { throw BinError.invalidEntry }
        guard let connection, file.sessionID == connection.generation else { throw BinError.changed }
        guard await supportsBinDeletion(storageID: storageID) else { throw BinError.unsupported }
        let session = connection.session
        var invokedDelete = false
        var acceptedDelete = false
        do {
            let source = try await resolveDirectory(session: session, generation: connection.generation,
                storageID: storageID, path: file.parentPath)
            guard source.entries.contains(file) else { throw BinError.changed }
            let info = try await session.objectInfo(handle: file.id)
            guard info.protectionStatus == 0, try makeFile(info, handle: file.id,
                storageID: storageID, parent: source.handle, path: file.parentPath,
                generation: connection.generation) == file else { throw BinError.changed }
            if file.isFolder {
                let children = try await session.objectHandles(storageID: storageID, parent: file.id)
                guard children.isEmpty else { throw BinError.changed }
            }
            try Task.checkCancellation()
            invokedDelete = true
            try await session.deleteObject(handle: file.id)
            acceptedDelete = true
            let after = try await resolveDirectory(session: session, generation: connection.generation,
                storageID: storageID, path: file.parentPath)
            guard !after.entries.contains(where: { $0.id == file.id || $0.path == file.path }) else {
                throw BinError.changed
            }
        } catch {
            if invokedDelete {
                // PartialDeletion explicitly permits side effects. Other
                // framed refusals leave the rejected item and session usable.
                if !acceptedDelete, case WireError.response(let code) = error,
                    code != 0x2012, await session.isUsable {
                    rememberReadOnlyStorage(error, session: session, storageID: storageID)
                    throw error
                }
                await discard(session)
                throw BinError.deletionUncertain
            }
            if await invalidateIfNeeded(error, session: session) { throw await sessionFailure(session) }
            throw error
        }
    }

    func binIdentity(storageID: UInt32) async throws -> BinStorageIdentity {
        guard let identity = connection?.binIdentities[storageID] else {
            throw BackendSessionError.reconnectRequired
        }
        return identity
    }

    func supportsMove(storageID: UInt32) async -> Bool {
        connection?.writableStorageIDs.contains(storageID) == true
            && connection?.operations.contains(WriteOperation.moveObject.rawValue) == true
    }

    func supportsBin(storageID: UInt32) async -> Bool {
        let move = await supportsMove(storageID: storageID)
        return await supportsUpload(to: storageID) && move
    }

    func move(storageID: UInt32, file: MTPFile, to directory: String) async throws -> MTPFile {
        try await gate.run {
            try await self.moveImpl(storageID: storageID, file: file, directory: directory)
        }
    }

    private func moveImpl(storageID: UInt32, file: MTPFile, directory: String) async throws -> MTPFile {
        try RemotePath.validate(directory)
        try RemotePath.validate(file.parentPath)
        try RemotePath.validateName(file.name)
        guard let connection, connection.storageIDs.contains(storageID) else {
            throw BackendSessionError.reconnectRequired
        }
        guard await supportsMove(storageID: storageID) else { throw BinError.unsupported }
        guard file.sessionID == connection.generation, file.id != 0, file.id != UInt32.max,
            file.path == RemotePath.appending(file.name, to: file.parentPath) else {
            throw SwiftBackendError.staleSelection
        }
        guard !file.isFolder || !BinLayout.contains(directory, in: file.path) else {
            throw BinError.invalidEntry
        }
        let session = connection.session
        var invokedMove = false
        var acceptedMove = false
        do {
            let source = try await resolveDirectory(
                session: session, generation: connection.generation,
                storageID: storageID, path: file.parentPath)
            guard source.entries.contains(file) else { throw SwiftBackendError.staleSelection }
            let target = try await resolveDirectory(
                session: session, generation: connection.generation,
                storageID: storageID, path: directory)
            guard !target.entries.contains(where: {
                RemotePath.collisionKey($0.name) == RemotePath.collisionKey(file.name)
            }) else { throw BinError.conflict(directory) }
            let info = try await session.objectInfo(handle: file.id)
            let fresh = try makeFile(info, handle: file.id, storageID: storageID,
                parent: source.handle, path: file.parentPath, generation: connection.generation)
            guard fresh == file, info.protectionStatus == 0 else {
                throw SwiftBackendError.staleSelection
            }
            try Task.checkCancellation()
            invokedMove = true
            diagnostics?.record(.moveDetails, operation: 0x1019, phase: .command,
                sessionID: session.diagnosticSessionID,
                details: .move(sourcePath: file.path, destinationPath: directory,
                    storageID: storageID, objectHandle: file.id))
            try await session.moveObject(handle: file.id, storageID: storageID, parent: target.handle)
            acceptedMove = true
            let after = try await resolveDirectory(
                session: session, generation: connection.generation,
                storageID: storageID, path: directory)
            let matches = after.entries.filter { Data($0.name.utf8) == Data(file.name.utf8) }
            guard matches.count == 1, let moved = matches.first,
                moved.size == file.size, moved.isFolder == file.isFolder else {
                throw SwiftBackendError.invalidMetadata
            }
            let original = try await resolveDirectory(
                session: session, generation: connection.generation,
                storageID: storageID, path: file.parentPath)
            guard !original.entries.contains(where: {
                RemotePath.collisionKey($0.name) == RemotePath.collisionKey(file.name)
            }) else { throw SwiftBackendError.invalidMetadata }
            return moved
        } catch {
            if invokedMove {
                let usable = await session.isUsable
                if !acceptedMove, case WireError.response = error, usable {
                    rememberReadOnlyStorage(error, session: session, storageID: storageID)
                    throw error
                }
                // A clean metadata response after an accepted move does not
                // poison the command stream. Stop the batch without replaying.
                if acceptedMove && usable {
                    if case WireError.response(0x2009) = error,
                       let moved = try await recoverMoveListing(connection, file: file,
                            storageID: storageID, directory: directory) { return moved }
                    throw MoveError.unverified
                }
                await discard(session)
                throw BinError.uncertain
            }
            if await invalidateIfNeeded(error, session: session) {
                throw await sessionFailure(session)
            }
            throw error
        }
    }

    /// A successful MoveObject followed by an invalid listed handle is a
    /// responder inconsistency, not a rejected write or a broken bulk stream.
    /// Recheck after a delay, then try one interface reset if needed. Never
    /// replay the move, undo it, delete anything, or reuse an old object handle.
    private func recoverMoveListing(
        _ previous: ConnectedSession, file: MTPFile, storageID: UInt32, directory: String
    ) async throws -> MTPFile? {
        let started = DiagnosticLog.start()
        diagnostics?.record(.moveRecovery, phase: .command, sessionID: previous.session.diagnosticSessionID)
        // A responder may acknowledge the move before its catalogue settles.
        // Re-read once after a short delay before considering any reset.
        do {
            let settle = connectionRecovery.replacementSettleDelay
            if settle > .zero { try await connectionRecovery.wait(settle) }
            let moved = try await verifyMoveLocations(previous, file: file,
                storageID: storageID, directory: directory)
            diagnostics?.record(.moveRecovery, since: started, phase: .complete,
                sessionID: previous.session.diagnosticSessionID)
            return moved
        } catch let error as MoveError {
            diagnostics?.record(.moveRecovery, since: started,
                failure: error == .notApplied ? .deviceRejected : .other, phase: .complete,
                sessionID: previous.session.diagnosticSessionID)
            throw error
        } catch {
            guard await previous.session.isUsable else {
                await discard(previous.session)
                diagnostics?.record(.moveRecovery, since: started, failure: .classify(error), phase: .complete)
                throw BinError.uncertain
            }
            guard case WireError.response(0x2009) = error else {
                diagnostics?.record(.moveRecovery, since: started, failure: .classify(error), phase: .complete)
                throw MoveError.unverified
            }
        }
        let reset = await previous.session.resetResponder()
        if reset == .notAttempted {
            diagnostics?.record(.moveRecovery, since: started, failure: .other,
                phase: .complete, sessionID: previous.session.diagnosticSessionID)
            return nil
        }
        if reset == .rejected {
            // A control STALL does not establish a lost bulk session. Confirm
            // that this session still responds before retaining partial browsing.
            do {
                guard try await previous.session.storageIDs().contains(storageID) else {
                    throw SwiftBackendError.invalidMetadata
                }
            } catch {
                await discard(previous.session)
                diagnostics?.record(.moveRecovery, since: started, failure: .classify(error), phase: .complete)
                throw MoveError.recoveryFailed
            }
            diagnostics?.record(.moveRecovery, since: started, failure: .other,
                phase: .complete, sessionID: previous.session.diagnosticSessionID)
            throw MoveError.recoveryUnavailable
        }
        connection = nil
        do {
            guard reset == .acknowledged else { throw MoveError.recoveryFailed }
            let settle = connectionRecovery.replacementSettleDelay
            if settle > .zero { try await connectionRecovery.wait(settle) }
            _ = try await connectImpl()
            guard let fresh = connection, fresh.details == previous.details,
                let identity = previous.binIdentities[storageID],
                fresh.binIdentities[storageID] == identity else { throw SwiftBackendError.invalidMetadata }
            let moved = try await verifyMoveLocations(fresh, file: file,
                storageID: storageID, directory: directory)
            diagnostics?.record(.moveRecovery, since: started, phase: .complete,
                sessionID: fresh.session.diagnosticSessionID)
            return moved
        } catch let error as MoveError where error != .recoveryFailed {
            diagnostics?.record(.moveRecovery, since: started,
                failure: error == .notApplied ? .deviceRejected : .other,
                phase: .complete, sessionID: connection?.session.diagnosticSessionID)
            throw error
        } catch {
            diagnostics?.record(.moveRecovery, since: started, failure: .classify(error), phase: .complete)
            if let current = connection { await discard(current.session) }
            throw MoveError.recoveryFailed
        }
    }

    private func verifyMoveLocations(
        _ current: ConnectedSession, file: MTPFile, storageID: UInt32, directory: String
    ) async throws -> MTPFile {
        let destination = try await resolveDirectory(session: current.session,
            generation: current.generation, storageID: storageID, path: directory)
        let source = try await resolveDirectory(session: current.session,
            generation: current.generation, storageID: storageID, path: file.parentPath)
        let key = RemotePath.collisionKey(file.name)
        let atDestination = destination.entries.filter { RemotePath.collisionKey($0.name) == key }
        let atSource = source.entries.filter { RemotePath.collisionKey($0.name) == key }
        func matches(_ candidate: MTPFile) -> Bool {
            Data(candidate.name.utf8) == Data(file.name.utf8)
                && candidate.size == file.size && candidate.isFolder == file.isFolder
        }
        if atDestination.count == 1, let moved = atDestination.first, matches(moved), atSource.isEmpty {
            return moved
        }
        if atSource.count == 1, let original = atSource.first, matches(original), atDestination.isEmpty {
            throw MoveError.notApplied
        }
        throw MoveError.unverified
    }

    func thumbnail(storageID: UInt32, file: MTPFile) async throws -> Data? {
        try await gate.runIfIdle { try await self.thumbnailImpl(storageID: storageID, file: file) }
    }

    private func thumbnailImpl(storageID: UInt32, file: MTPFile) async throws -> Data? {
        try Task.checkCancellation()
        guard let connection else { throw BackendSessionError.reconnectRequired }
        guard file.sessionID == connection.generation, connection.storageIDs.contains(storageID) else {
            throw SwiftBackendError.staleSelection
        }
        let supportsThumb = connection.operations.contains(ReadSession.getThumbnailCode)
        let supportsSamples = file.isVideoThumbnailCandidate &&
            connection.operations.isSuperset(of: [ReadSession.getObjectPropertiesSupportedCode, ReadSession.getObjectPropertyValueCode])
        guard file.isThumbnailSidecar || (file.isDeviceThumbnailCandidate && (supportsThumb || supportsSamples)) else { return nil }
        if file.isThumbnailSidecar, file.size <= 0 || file.size > ReadSession.maximumThumbnailBytes { return nil }
        let session = connection.session
        do {
            // Revalidate only this selection. Do not resolve/list its ancestors
            // or change the identity checks used by actual file transfers.
            let info = try await finishTransaction { try await session.objectInfo(handle: file.id) }
            try Task.checkCancellation()
            let fresh = try makeFile(info, handle: file.id, storageID: storageID,
                parent: file.parentID, path: file.parentPath, generation: connection.generation)
            guard fresh == file else { throw SwiftBackendError.staleSelection }
            if file.isThumbnailSidecar {
                let data = try await finishTransaction { try await session.thumbnailFile(handle: file.id, expectedSize: UInt64(file.size)) }
                try Task.checkCancellation()
                return data
            }
            if supportsThumb, [UInt16(0x3801), 0x380B].contains(info.thumbnailFormat),
                info.thumbnailSize > 0, info.thumbnailSize <= ReadSession.maximumThumbnailBytes {
                do {
                    let data = try await finishTransaction { try await session.thumbnail(handle: file.id) }
                    try Task.checkCancellation()
                    if !data.isEmpty { return data }
                } catch let error as WireError {
                    // Only a complete refusal on a healthy session permits fallback.
                    guard case .response = error, await session.isUsable else { throw error }
                }
            }
            guard supportsSamples else { return nil }
            var sampleSupported = connection.sampleSupport[info.format]
            if sampleSupported == nil {
                do {
                    let properties = try await finishTransaction { try await session.objectPropertiesSupported(format: info.format) }
                    sampleSupported = properties.isSuperset(of: ReadSession.representativeSampleProperties)
                } catch let error as WireError {
                    guard case .response = error, await session.isUsable else { throw error }
                    sampleSupported = false
                }
                self.connection?.sampleSupport[info.format] = sampleSupported
            }
            try Task.checkCancellation()
            guard sampleSupported == true else { return nil }
            let data = try await session.representativeSample(handle: file.id)
            try Task.checkCancellation()
            return data
        } catch {
            if await invalidateIfNeeded(error, session: session) { throw await sessionFailure(session) }
            // Fully framed rejections, including NoThumbnailPresent, are an
            // optional-feature miss. Malformed/unfinished transactions still
            // follow the existing session disposal rules above.
            if case WireError.response = error { return nil }
            throw error
        }
    }

    func contents(storageID: UInt32, path: String, showHiddenFiles: Bool) async throws -> [MTPFile] {
        try await gate.run {
            try await self.contentsImpl(storageID: storageID, path: path,
                showHiddenFiles: showHiddenFiles, allowUnavailable: false).files
        }
    }

    func browseContents(storageID: UInt32, path: String, showHiddenFiles: Bool) async throws -> MTPDirectoryListing {
        try await gate.run {
            try await self.contentsImpl(storageID: storageID, path: path,
                showHiddenFiles: showHiddenFiles, allowUnavailable: true)
        }
    }

    private func contentsImpl(storageID: UInt32, path: String, showHiddenFiles: Bool,
                              allowUnavailable: Bool) async throws -> MTPDirectoryListing {
        try RemotePath.validate(path)
        guard let connection, connection.storageIDs.contains(storageID) else {
            throw BackendSessionError.reconnectRequired
        }
        let session = connection.session
        do {
            let directory = try await resolveDirectory(session: session, generation: connection.generation,
                storageID: storageID, path: path, allowUnavailable: allowUnavailable)
            let files = directory.entries.filter { showHiddenFiles || !$0.name.hasPrefix(".") }.sorted {
                if $0.isFolder != $1.isFolder { return $0.isFolder }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            return MTPDirectoryListing(files: files, unavailableCount: directory.unavailableCount)
        } catch {
            if await invalidateIfNeeded(error, session: session) {
                throw await sessionFailure(session)
            }
            throw error
        }
    }

    private struct ResolvedDirectory: Sendable {
        let handle: UInt32
        let entries: [MTPFile]
        let unavailableCount: Int
    }

    /// Resolves every path from fresh device metadata. Writes and transfer
    /// planning require a complete, hidden-inclusive view. Only UI browsing may
    /// skip a handle the device explicitly reports as no longer existing.
    private func resolveDirectory(
        session: ReadSession, generation: UUID, storageID: UInt32, path: String,
        allowUnavailable: Bool = false
    ) async throws -> ResolvedDirectory {
        let components = path.split(separator: "/")
        guard components.count <= 128 else { throw BackendError.invalidPath(path) }
        var parent = UInt32.max
        var parentPath = "/"
        var ancestors: Set<UInt32> = []
        var unavailableCount = 0
        for component in components {
            let listing = try await list(session: session, generation: generation, storageID: storageID,
                parent: parent, path: parentPath, allowUnavailable: allowUnavailable)
            unavailableCount += listing.unavailableCount
            let componentBytes = Data(component.utf8)
            guard let folder = listing.files.first(where: {
                Data($0.name.utf8) == componentBytes && $0.isFolder
            }) else { throw BackendError.invalidPath(path) }
            guard ancestors.insert(folder.id).inserted else { throw SwiftBackendError.invalidMetadata }
            parent = folder.id
            parentPath = folder.path
        }
        let listing = try await list(session: session, generation: generation, storageID: storageID,
            parent: parent, path: path, allowUnavailable: allowUnavailable)
        return ResolvedDirectory(handle: parent, entries: listing.files,
            unavailableCount: unavailableCount + listing.unavailableCount)
    }

    private func list(
        session: ReadSession, generation: UUID, storageID: UInt32, parent: UInt32, path: String,
        allowUnavailable: Bool
    ) async throws -> MTPDirectoryListing {
        let handles: [UInt32]
        do {
            handles = try await session.objectHandles(storageID: storageID, parent: parent)
            diagnostics?.record(.directoryDetails, operation: 0x1007, response: 0x2001,
                sessionID: session.diagnosticSessionID,
                details: .directory(path: path, storageID: storageID, parentHandle: parent,
                    handles: handles, totalHandles: handles.count))
        } catch {
            diagnostics?.record(.directoryDetails, operation: 0x1007,
                response: Self.responseCode(error), failure: .classify(error),
                sessionID: session.diagnosticSessionID,
                details: .directory(path: path, storageID: storageID, parentHandle: parent,
                    handles: [], totalHandles: nil))
            throw error
        }
        guard handles.count <= Self.listingLimit, Set(handles).count == handles.count,
            handles.allSatisfy({ $0 != 0 && $0 != UInt32.max && $0 != parent })
        else { throw SwiftBackendError.invalidMetadata }
        var result: [MTPFile] = []
        var unavailableCount = 0
        var names: Set<Data> = []
        for handle in handles {
            try Task.checkCancellation()
            let info: ObjectInfo
            do {
                info = try await session.objectInfo(handle: handle)
                if diagnostics?.recordsDetails == true {
                    diagnostics?.record(.objectDetails, operation: 0x1008, response: 0x2001,
                        sessionID: session.diagnosticSessionID,
                        details: .object(directory: path, storageID: storageID, parentHandle: parent,
                            objectHandle: handle, metadata: DiagnosticFileMetadata(info)))
                }
            } catch {
                diagnostics?.record(.objectDetails, operation: 0x1008,
                    response: Self.responseCode(error), failure: .classify(error),
                    sessionID: session.diagnosticSessionID,
                    details: .object(directory: path, storageID: storageID, parentHandle: parent,
                        objectHandle: handle, metadata: nil))
                if case WireError.response(0x2009) = error, allowUnavailable {
                    unavailableCount += 1
                    continue
                }
                throw error
            }
            let file = try makeFile(info, handle: handle, storageID: storageID,
                parent: parent, path: path, generation: generation)
            // Reject literally indistinguishable siblings; retain exact names.
            guard names.insert(Data(file.name.utf8)).inserted else {
                throw SwiftBackendError.invalidMetadata
            }
            result.append(file)
        }
        return MTPDirectoryListing(files: result, unavailableCount: unavailableCount)
    }

    private static func responseCode(_ error: any Error) -> UInt16? {
        if case WireError.response(let code) = error { return code }
        return nil
    }

    private func makeFile(
        _ info: ObjectInfo, handle: UInt32, storageID: UInt32, parent: UInt32,
        path: String, generation: UUID
    ) throws -> MTPFile {
        guard info.storageID == storageID,
            parentMatches(info.parent, expected: parent)
        else { throw SwiftBackendError.invalidMetadata }
        do { try RemotePath.validateName(info.filename) } catch { throw SwiftBackendError.invalidMetadata }
        return MTPFile(
            sessionID: generation,
            size: info.isDirectory ? 0 : info.byteCount.map { Int64($0) } ?? -1,
            isFolder: info.isDirectory,
            dateAdded: info.modificationDate.isEmpty ? info.captureDate : info.modificationDate,
            name: info.filename, path: RemotePath.appending(info.filename, to: path),
            parentPath: path, fileExtension: (info.filename as NSString).pathExtension,
            parentID: info.parent, id: handle)
    }

    func upload(
        storageID: UInt32, source: URL, to directory: String,
        progress: @escaping ProgressHandler
    ) async throws -> UploadDisposition {
        try await runUploadOperation {
            try await self.uploadImpl(
                storageID: storageID, source: source, directory: directory, progress: progress)
        }
    }

    private func uploadImpl(
        storageID: UInt32, source: URL, directory: String,
        progress: @escaping ProgressHandler
    ) async throws -> UploadDisposition {
        var activeSession: ReadSession?
        var invokedRemoteWrite = false
        var objectMayExist = false
        do {
            try RemotePath.validate(directory)
            let sourceSize = try LocalFileIO.sourceSize(source)
            guard sourceSize >= 0, sourceSize <= Int64(UInt32.max) - 13 else {
                throw UploadError.rejected(
                    "This file is too large for an ordinary MTP upload. Extended-length uploads are not supported yet.")
            }
            let name = source.lastPathComponent
            try RemotePath.validateName(name)
            guard name.utf16.count <= 254 else {
                throw UploadError.rejected("The filename is too long for MTP (maximum 254 UTF-16 units).")
            }
            guard let connection, connection.storageIDs.contains(storageID) else {
                throw BackendSessionError.reconnectRequired
            }
            let session = connection.session
            let generation = connection.generation
            activeSession = session
            guard connection.writableStorageIDs.contains(storageID) else { throw UploadError.readOnlyStorage }
            guard connection.operations.contains(WriteOperation.sendObjectInfo.rawValue),
                connection.operations.contains(WriteOperation.sendObject.rawValue)
            else { throw UploadError.unsupportedBackend }

            let target = try await finishTransaction {
                try await self.resolveDirectory(
                    session: session, generation: generation, storageID: storageID, path: directory)
            }
            let key = RemotePath.collisionKey(name)
            guard !target.entries.contains(where: { RemotePath.collisionKey($0.name) == key }) else {
                return .skippedExisting
            }
            try Task.checkCancellation()
            let reader = try UploadFileReader(source: source, expectedSize: sourceSize)
            let info = try ObjectInfo.uploadFile(
                storageID: storageID, parent: target.handle, size: UInt64(sourceSize),
                filename: name, modificationDate: reader.modificationDate)
            progress(
                TransferProgress(fileName: name, bytesTransferred: 0, totalBytes: sourceSize))
            invokedRemoteWrite = true
            let ranged = await supportsUploadCancellation(to: storageID)
            diagnostics?.record(.uploadStrategy,
                operation: ranged ? ReadSession.sendPartialObjectCode : WriteOperation.sendObject.rawValue,
                requestedBytes: ranged ? Int(ReadSession.maximumPartialObjectBytes) : nil)
            let created: ObjectCreationResult
            if ranged {
                // A framed creation rejection leaves the session usable. Track
                // the new object only once creation succeeds, before editing.
                let empty = try ObjectInfo.uploadFile(storageID: info.storageID,
                    parent: info.parent, size: 0, filename: info.filename,
                    modificationDate: info.modificationDate)
                created = try await finishTransaction {
                    try await session.uploadObject(info: empty, read: { _ in Data() })
                }
                objectMayExist = true
                try await RangedUpload.send(session: session, created: created, info: info, reader: reader,
                    existingHandles: Set(target.entries.map(\.id)), diagnostics: diagnostics, progress: progress)
            } else {
                created = try await session.uploadObject(
                    info: info,
                    read: { try reader.read(maxBytes: $0) },
                    progress: { count in
                        progress(TransferProgress(
                            fileName: name, bytesTransferred: Int64(count), totalBytes: sourceSize))
                    })
                try reader.finish()
            }
            objectMayExist = true
            let confirmed = try await finishTransaction { try await session.objectInfo(handle: created.handle) }
            guard confirmed.storageID == storageID,
                parentMatches(confirmed.parent, expected: target.handle),
                Data(confirmed.filename.utf8) == Data(name.utf8),
                !confirmed.isDirectory, confirmed.byteCount == UInt64(sourceSize)
            else { throw SwiftBackendError.invalidMetadata }
            let uploaded = try makeFile(
                confirmed, handle: created.handle, storageID: storageID,
                parent: target.handle, path: directory, generation: generation)
            return .uploadedVerified(uploaded)
        } catch {
            if invokedRemoteWrite { rememberReadOnlyStorage(error, session: activeSession, storageID: storageID) }
            let failure = await normalizeUploadFailure(
                error, session: activeSession, objectMayExist: objectMayExist)
            if !invokedRemoteWrite { throw UploadPreflightFailure(failure) }
            throw failure
        }
    }

    func createUploadDirectory(storageID: UInt32, parent: String, name: String) async throws
        -> UploadDirectoryDisposition
    {
        try await runUploadOperation {
            try await self.createUploadDirectoryImpl(
                storageID: storageID, parentPath: parent, name: name)
        }
    }

    /// Distinguishes cancellation while waiting at the serialization gate from
    /// a failure returned after the upload implementation has started. The
    /// former cannot have issued SendObjectInfo and is therefore definite.
    private struct EnteredUploadOperationFailure: Error {
        let underlying: any Error
    }

    private func runUploadOperation<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        do {
            return try await gate.run {
                do { return try await operation() }
                catch { throw EnteredUploadOperationFailure(underlying: error) }
            }
        } catch let entered as EnteredUploadOperationFailure {
            throw entered.underlying
        } catch {
            throw UploadPreflightFailure(error)
        }
    }

    private func createUploadDirectoryImpl(
        storageID: UInt32, parentPath: String, name: String
    ) async throws -> UploadDirectoryDisposition {
        var activeSession: ReadSession?
        var invokedRemoteWrite = false
        var objectMayExist = false
        do {
            try RemotePath.validate(parentPath)
            try RemotePath.validateName(name)
            guard name.utf16.count <= 254 else {
                throw UploadError.rejected("The folder name is too long for MTP (maximum 254 UTF-16 units).")
            }
            guard let connection, connection.storageIDs.contains(storageID) else {
                throw BackendSessionError.reconnectRequired
            }
            let session = connection.session
            let generation = connection.generation
            activeSession = session
            guard connection.writableStorageIDs.contains(storageID) else { throw UploadError.readOnlyStorage }
            guard connection.operations.contains(WriteOperation.sendObjectInfo.rawValue) else {
                throw UploadError.unsupportedBackend
            }

            let target = try await resolveDirectory(
                session: session, generation: generation, storageID: storageID, path: parentPath)
            let key = RemotePath.collisionKey(name)
            guard !target.entries.contains(where: { RemotePath.collisionKey($0.name) == key }) else {
                return .skippedExisting
            }
            try Task.checkCancellation()
            let info = try ObjectInfo.uploadDirectory(
                storageID: storageID, parent: target.handle, filename: name)
            invokedRemoteWrite = true
            let created = try await session.createDirectory(info: info)
            objectMayExist = true
            let confirmed = try await session.objectInfo(handle: created.handle)
            guard confirmed.storageID == storageID,
                parentMatches(confirmed.parent, expected: target.handle),
                Data(confirmed.filename.utf8) == Data(name.utf8), confirmed.isDirectory
            else { throw SwiftBackendError.invalidMetadata }
            return .created
        } catch {
            if invokedRemoteWrite { rememberReadOnlyStorage(error, session: activeSession, storageID: storageID) }
            let failure = await normalizeUploadFailure(
                error, session: activeSession, objectMayExist: objectMayExist)
            if !invokedRemoteWrite { throw UploadPreflightFailure(failure) }
            throw failure
        }
    }

    /// Learn only from an actual attempted write, scoped to this connection.
    /// AccessDenied describes one request, not a persistent folder restriction.
    private func rememberReadOnlyStorage(_ error: any Error, session: ReadSession?, storageID: UInt32) {
        guard let session, connection?.session === session,
            case WireError.response(let code) = error else { return }
        if code == 0x200E { connection?.writableStorageIDs.remove(storageID) }
    }

    private func normalizeUploadFailure(
        _ error: any Error, session: ReadSession?, objectMayExist: Bool
    ) async -> any Error {
        guard let session else { return error }
        if error as? UploadError == .cancelledAndRemoved { return error }
        if error is CancellationError, await session.isUsable {
            return UploadError.cancelledSessionRecovered
        }
        if objectMayExist {
            await discard(session)
            return await sessionFailure(session)
        }
        if case WireError.response(let code) = error, await session.isUsable {
            return UploadError.rejected(uploadRejection(code))
        }
        if await invalidateIfNeeded(error, session: session) {
            return await sessionFailure(session)
        }
        return error
    }

    private func parentMatches(_ actual: UInt32, expected: UInt32) -> Bool {
        actual == expected || (expected == UInt32.max && actual == 0)
    }

    private func uploadRejection(_ code: UInt16) -> String {
        let reason: String
        switch code {
        case 0x2007: reason = "The device reported an incomplete transfer."
        case 0x200C: reason = "The device storage is full."
        case 0x200E: reason = "The device storage is read-only."
        case 0x200F: reason = "The device denied this write request."
        case 0x2015: reason = "The device rejected the file metadata."
        case 0x2019: reason = "The device is busy."
        case 0x201A: reason = "The destination folder is not valid."
        case 0x201F: reason = "The device cancelled the transfer."
        case 0x2023: reason = "The device rejected the MTP dataset."
        case 0xA809: reason = "The file is too large for this device."
        default: reason = "The device rejected the upload."
        }
        return "\(reason) (\(String(format: "0x%04x", code)))"
    }

    func download(
        storageID: UInt32, files: [MTPFile], to destination: URL, progress: @escaping ProgressHandler
    ) async throws {
        try await gate.run {
            try await self.downloadImpl(
                storageID: storageID, files: files, to: destination, progress: progress)
        }
    }

    private func downloadImpl(
        storageID: UInt32, files: [MTPFile], to destination: URL, progress: @escaping ProgressHandler
    ) async throws {
        guard let connection, connection.storageIDs.contains(storageID) else {
            throw BackendSessionError.reconnectRequired
        }
        let session = connection.session
        let generation = connection.generation
        guard destination.isFileURL,
            try FileManager.default.attributesOfItem(atPath: destination.path)[.type]
                as? FileAttributeType
                == .typeDirectory
        else { throw TransferError.invalidDestination }
        do {
            // Validate every selection before opening any local output.
            for file in files {
                guard file.sessionID == generation, !file.isFolder, file.id != 0, file.id != UInt32.max
                else {
                    throw SwiftBackendError.staleSelection
                }
                try RemotePath.validateName(file.name)
                try RemotePath.validate(file.parentPath)
                guard file.size >= 0, file.size <= Int64(UInt32.max) - 13 else {
                    throw SwiftBackendError.unsupportedSize
                }
            }
            for file in files {
                try Task.checkCancellation()
                let info = try await session.objectInfo(handle: file.id)
                let fresh = try makeFile(
                    info, handle: file.id, storageID: storageID,
                    parent: file.parentID, path: file.parentPath, generation: generation)
                guard fresh == file else { throw SwiftBackendError.staleSelection }
                let sink = try DownloadFileSink(
                    url: destination.appendingPathComponent(file.name), expectedSize: file.size,
                    name: file.name, progress: progress)
                do {
                    let ranged = connection.operations.contains(ReadSession.getPartialObjectCode)
                    diagnostics?.record(.downloadStrategy,
                        operation: ranged ? ReadSession.getPartialObjectCode : 0x1009,
                        requestedBytes: ranged ? Int(ReadSession.maximumPartialObjectBytes) : nil)
                    if ranged {
                        try await downloadRanges(session: session, file: file, sink: sink)
                        // Recheck the source before publishing a file assembled
                        // across transactions. A changed object is discarded.
                        guard try await session.objectInfo(handle: file.id) == info else {
                            throw SwiftBackendError.staleSelection
                        }
                    } else {
                        try await session.download(handle: file.id, expectedSize: UInt64(file.size)) {
                            try sink.append($0)
                        }
                    }
                    try sink.finish()
                } catch {
                    sink.discard()
                    throw error
                }
            }
        } catch {
            if await invalidateIfNeeded(error, session: session) {
                throw await sessionFailure(session)
            }
            throw error
        }
    }

    private func downloadRanges(session: ReadSession, file: MTPFile, sink: DownloadFileSink) async throws {
        var offset: UInt32 = 0
        repeat {
            try Task.checkCancellation()
            let start = offset
            let count = min(ReadSession.maximumPartialObjectBytes, UInt32(file.size) - start)
            // This unstructured task inherits diagnostic context but not parent
            // cancellation. Always await its complete data + response before
            // observing Cancel; at most this one 1 MiB range remains in flight.
            let range = Task { try await session.partialObject(handle: file.id, offset: start, count: count) }
            let data = try await range.value
            try Task.checkCancellation()
            try sink.append(data)
            offset += count
        } while offset < UInt32(file.size)
    }

    private func sessionFailure(_ session: ReadSession) async -> BackendSessionError {
        await session.cancellationNeedsPhysicalReconnect ? .physicalReconnectRequired : .reconnectRequired
    }

    /// Returns true when the caller's selection/session is no longer usable.
    private func invalidateIfNeeded(_ error: any Error, session: ReadSession) async -> Bool {
        let usable = await session.isUsable
        if error as? SwiftBackendError == .invalidMetadata || !usable {
            await discard(session)
            return true
        }
        return false
    }

    private func discard(_ current: ReadSession) async {
        connection = nil
        try? await current.close()
    }

    @discardableResult func disconnect() async throws -> Bool {
        try await gate.run { try await self.disconnectImpl() }
    }

    private func disconnectImpl() async throws -> Bool {
        let previous = connection?.session
        connection = nil
        try await previous?.close()
        return true
    }
}
