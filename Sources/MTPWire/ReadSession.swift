import Foundation

public enum BulkRead: Sendable {
    case bytes(Data)
    case zeroLengthPacket
}

/// How a host-to-device write relates to its MTP and underlying USB transfer
/// boundaries. This prevents accidental short packets/ZLPs between streamed
/// object chunks while still supporting devices that divide DATA headers.
public enum BulkWriteBoundary: Sendable, Equatable {
    case continuesContainer
    /// A 12-byte DATA header that ends its underlying USB transfer (with a ZLP
    /// when packet-aligned). The MTP container continues with its payload.
    case separateDataHeader
    case endsContainer
}

public typealias ObjectDataReader = @Sendable (Int) throws -> Data
public typealias ObjectDataProgress = @Sendable (UInt64) -> Void

public struct ObjectCreationResult: Equatable, Sendable {
    public let storageID: UInt32
    public let parent: UInt32
    public let handle: UInt32

    public init(response: MTPResponse) throws {
        guard response.code == 0x2001 else { throw WireError.response(response.code) }
        guard response.parameters.count == 3 else { throw WireError.invalidLength }
        storageID = response.parameters[0]
        parent = response.parameters[1]
        handle = response.parameters[2]
        guard storageID != 0, storageID != UInt32.max,
            handle != 0, handle != UInt32.max
        else { throw WireError.invalidLength }
    }
}

/// Preliminary bulk transport boundary for the native engine. Implementations
/// must provide bounded I/O deadlines; a read may return a fragmented container.
/// Endpoint/control/event/abort conformance will be expanded before production use.
public protocol MTPBulkTransport: Sendable {
    /// True only when each non-ZLP `readBulk` result represents exactly one
    /// underlying USB transfer rather than an arbitrary byte-stream fragment.
    var preservesReadTransferBoundaries: Bool { get }
    /// Process-local diagnostic correlation only; never a USB/device identifier.
    var diagnosticTransportID: UInt64? { get }
    func write(_ data: Data) async throws
    func write(_ data: Data, boundary: BulkWriteBoundary) async throws
    func read(maxBytes: Int) async throws -> Data
    func readBulk(maxBytes: Int) async throws -> BulkRead
    /// Abandons an interrupted transaction and disposes this transport. The
    /// implementation may issue protocol reset requests first, but callers
    /// must always create a fresh transport and MTP session afterward.
    var cancellationNeedsPhysicalReconnect: Bool { get async }
    func cancel(transaction: UInt32) async -> Bool
    func abort(transaction: UInt32?) async
    func close() async
}

public enum MTPResponderResetResult: Sendable, Equatable {
    case notAttempted, rejected, acknowledged, failed
}

/// Optional Still Image class responder reset on the claimed MTP interface.
/// A control-request rejection preserves the transport. An acknowledged reset
/// or an ambiguous failure retires it and requires a fresh session.
public protocol MTPResponderResetTransport: MTPBulkTransport {
    func resetResponder() async -> MTPResponderResetResult
}

extension MTPBulkTransport {
    public var preservesReadTransferBoundaries: Bool { false }
    public var diagnosticTransportID: UInt64? { nil }

    /// Existing transports are safe for a complete small container. Streaming
    /// requires an implementation that understands intermediate boundaries.
    public func write(_ data: Data, boundary: BulkWriteBoundary) async throws {
        guard boundary == .endsContainer else { throw WireError.streamingWriteUnsupported }
        try await write(data)
    }

    // Legacy/simulated byte streams retain empty-read-as-EOF semantics. Only a
    // USB-aware transport may explicitly report a successful zero-length packet.
    public func readBulk(maxBytes: Int) async throws -> BulkRead {
        .bytes(try await read(maxBytes: maxBytes))
    }

    public var cancellationNeedsPhysicalReconnect: Bool { false }
    public func cancel(transaction: UInt32) async -> Bool { await abort(transaction: transaction); return false }
    public func abort(transaction: UInt32?) async { await close() }
}

/// Transaction engine for MTP operations over a packet-aware transport.
/// Callers must serialize work; concurrent commands fail explicitly with busy.
public actor ReadSession {
    private let transport: any MTPBulkTransport
    private let diagnostics: DiagnosticLog?
    /// Correlates optional app-layer metadata with this session's wire events.
    public nonisolated let diagnosticSessionID: UInt64?
    private let diagnosticTransportID: UInt64?
    public private(set) var cancellationNeedsPhysicalReconnect = false
    private var pending = Data()
    private var opened = false
    private var opening = false
    private var valid = true
    private var busy = false
    private var transportClosed = false
    private var nextTransaction: UInt32 = 1
    private var dataHeaderMode = DataHeaderMode.unknown
    public static let metadataLimit = 8 * 1024 * 1024
    private static let outboundChunkSize = 64 * 1024

    private struct ExchangeResult: Sendable {
        let data: Data
        let response: MTPResponse
    }

    private enum DataHeaderMode: Sendable {
        case unknown, combined, separate
    }

    private struct ExactRead: Sendable {
        let data: Data
        let startedAtTransferBoundary: Bool
        let firstTransferLength: Int?
    }

    public init(transport: any MTPBulkTransport, diagnostics: DiagnosticLog? = nil) {
        self.transport = transport
        self.diagnostics = diagnostics
        diagnosticSessionID = diagnostics?.nextCorrelationID()
        diagnosticTransportID = transport.diagnosticTransportID
    }

    /// Test-only seam for exercising rollover without issuing billions of
    /// commands. Transaction zero and 0xFFFFFFFF are reserved by PTP/MTP.
    init(
        transport: any MTPBulkTransport, diagnostics: DiagnosticLog? = nil,
        startingTransaction: UInt32
    ) {
        precondition(startingTransaction > 0 && startingTransaction < UInt32.max)
        self.transport = transport
        self.diagnostics = diagnostics
        diagnosticSessionID = diagnostics?.nextCorrelationID()
        diagnosticTransportID = transport.diagnosticTransportID
        nextTransaction = startingTransaction
    }

    public func deviceInfo() async throws -> DeviceInfo {
        let data = try await metadata(code: 0x1001, needsSession: false)
        return try await decode { try DeviceInfo(data: data) }
    }

    public func open(sessionID: UInt32 = 1) async throws {
        guard !opened else { throw WireError.sessionAlreadyOpen }
        guard !opening else { throw WireError.busy }
        guard sessionID != 0 else { throw WireError.invalidLength }
        opening = true
        defer { opening = false }
        do {
            try await openCommand(sessionID: sessionID)
            opened = true
        } catch let WireError.response(code) where code == 0x201E {
            do {
                // Android can retain an MTP session after the previous host
                // process releases its USB handle. Match the compatibility
                // backend's bounded recovery: close that stale session with
                // transaction zero, then make one fresh OpenSession attempt.
                _ = try await exchange(
                    code: 0x1003, parameters: [], needsSession: false,
                    expectsData: false, limit: 0, partOfOpening: true, sink: { _ in })
                try await openCommand(sessionID: sessionID)
                opened = true
            } catch {
                // A failed recovery must never leave a connection whose session
                // ownership or transaction state is ambiguous.
                await invalidate()
                throw error
            }
        } catch {
            // Even if OpenSession's response completed before cancellation was
            // observed, the public state transition did not. Release this
            // ambiguous responder session rather than retaining a valid
            // transport whose local `opened` flag is false.
            await invalidate()
            throw error
        }
    }

    private func openCommand(sessionID: UInt32) async throws {
        _ = try await exchange(
            code: 0x1002, parameters: [sessionID], needsSession: false,
            expectsData: false, limit: 0, recoverableResponses: [0x201E],
            partOfOpening: true, sink: { _ in })
    }

    public func storageIDs() async throws -> [UInt32] {
        let data = try await metadata(code: 0x1004)
        return try await decode {
            var reader = DatasetReader(data)
            let ids = try reader.readUInt32Array()
            try reader.requireEnd()
            return ids
        }
    }

    public func storageInfo(storageID: UInt32) async throws -> StorageInfo {
        let data = try await metadata(code: 0x1005, parameters: [storageID])
        return try await decode { try StorageInfo(data: data) }
    }
    public func objectHandles(storageID: UInt32, parent: UInt32 = 0xFFFF_FFFF) async throws
        -> [UInt32]
    {
        let data = try await metadata(code: 0x1007, parameters: [storageID, 0, parent])
        return try await decode {
            var reader = DatasetReader(data)
            let handles = try reader.readUInt32Array()
            try reader.requireEnd()
            return handles
        }
    }
    public func objectInfo(handle: UInt32) async throws -> ObjectInfo {
        let data = try await metadata(code: 0x1008, parameters: [handle])
        return try await decode { try ObjectInfo(data: data) }
    }

    public static let getThumbnailCode: UInt16 = 0x100A
    public static let maximumThumbnailBytes = 512 * 1024

    /// Optional GetThumb, never a fallback to GetObject. Advertised thumbnail
    /// sizes may be estimates; bound the actual container instead of requiring
    /// an exact match. The caller decides whether the image itself is usable.
    public func thumbnail(handle: UInt32) async throws -> Data {
        guard handle != 0, handle != UInt32.max else { throw WireError.invalidLength }
        return try await exchange(code: Self.getThumbnailCode, parameters: [handle],
            needsSession: true, expectsData: true, limit: Self.maximumThumbnailBytes, sink: nil).data
    }

    /// Only for an explicitly identified, small thumbnail companion file.
    public func thumbnailFile(handle: UInt32, expectedSize: UInt64) async throws -> Data {
        guard handle != 0, handle != UInt32.max, expectedSize > 0,
            expectedSize <= Self.maximumThumbnailBytes else { throw WireError.sizeLimit }
        return try await exchange(code: 0x1009, parameters: [handle], needsSession: true,
            expectsData: true, limit: Self.maximumThumbnailBytes, expectedSize: expectedSize, sink: nil).data
    }

    public static let getObjectPropertiesSupportedCode: UInt16 = 0x9801
    public static let getObjectPropertyValueCode: UInt16 = 0x9803
    public static let representativeSampleProperties: Set<UInt16> = [0xDC81, 0xDC82, 0xDC86]

    public func objectPropertiesSupported(format: UInt16) async throws -> Set<UInt16> {
        let data = try await exchange(code: Self.getObjectPropertiesSupportedCode,
            parameters: [UInt32(format)], needsSession: true, expectsData: true, limit: 8192, sink: nil).data
        return try await decode {
            var reader = DatasetReader(data)
            let properties = try reader.readUInt16Array()
            try reader.requireEnd()
            return Set(properties)
        }
    }

    /// The standard MTP representative sample is an optional byte-array property,
    /// not a read of the media object. Accept only advertised JPEG/PNG stills.
    public func representativeSample(handle: UInt32) async throws -> Data? {
        guard handle != 0, handle != UInt32.max else { throw WireError.invalidLength }
        let formatData = try await sampleProperty(handle: handle, property: 0xDC81, limit: 2)
        let format = try await decode {
            var reader = DatasetReader(formatData)
            let value = try reader.readUInt16()
            try reader.requireEnd()
            return value
        }
        guard [UInt16(0x3801), 0x380B].contains(format) else { return nil }
        let sizeData = try await sampleProperty(handle: handle, property: 0xDC82, limit: 4)
        let size = try await decode {
            var reader = DatasetReader(sizeData)
            let value = try reader.readUInt32()
            try reader.requireEnd()
            return value
        }
        guard size > 0, size <= Self.maximumThumbnailBytes else { return nil }
        let data = try await sampleProperty(handle: handle, property: 0xDC86, limit: Self.maximumThumbnailBytes + 4)
        return try await decode {
            var reader = DatasetReader(data)
            let count = try reader.readUInt32()
            guard count == reader.remaining, count <= Self.maximumThumbnailBytes else { throw WireError.invalidLength }
            return Data(data.dropFirst(4))
        }
    }

    private func sampleProperty(handle: UInt32, property: UInt16, limit: Int) async throws -> Data {
        try Task.checkCancellation()
        // Drain one started property transaction, then honour cancellation before
        // requesting another property. Cancellation never interrupts USB framing.
        let request = Task {
            try await exchange(code: Self.getObjectPropertyValueCode, parameters: [handle, UInt32(property)],
                needsSession: true, expectsData: true, limit: limit, sink: nil).data
        }
        let data = try await request.value
        try Task.checkCancellation()
        return data
    }

    /// Streams chunks synchronously to a bounded sink. Files using the 0xFFFFFFFF
    /// unknown/extended container length need additional support and are rejected.
    public func download(
        handle: UInt32, expectedSize: UInt64? = nil,
        sink: @escaping @Sendable (Data) throws -> Void
    ) async throws {
        if let expectedSize, expectedSize > UInt64(UInt32.max) - 13 { throw WireError.sizeLimit }
        _ = try await exchange(
            code: 0x1009, parameters: [handle], needsSession: true,
            expectsData: true, limit: Int(UInt32.max) - 13, expectedSize: expectedSize, sink: sink)
    }

    public static let getPartialObjectCode: UInt16 = 0x101B
    public static let maximumPartialObjectBytes: UInt32 = 1024 * 1024

    /// One complete, bounded read transaction. The caller can stop between
    /// ranges without sending CancelTransaction or replacing this session.
    public func partialObject(handle: UInt32, offset: UInt32, count: UInt32) async throws -> Data {
        guard handle != 0, handle != UInt32.max, count <= Self.maximumPartialObjectBytes,
            UInt64(offset) + UInt64(count) <= UInt64(UInt32.max) + 1 else { throw WireError.invalidLength }
        let result = try await exchange(code: Self.getPartialObjectCode,
            parameters: [handle, offset, count], needsSession: true, expectsData: true,
            limit: Int(count), expectedSize: UInt64(count), sink: nil)
        guard result.response.parameters == [count] else {
            await invalidate()
            throw WireError.objectSizeMismatch
        }
        return result.data
    }

    public static let sendPartialObjectCode: UInt16 = 0x95C2
    public static let beginEditObjectCode: UInt16 = 0x95C4
    public static let endEditObjectCode: UInt16 = 0x95C5

    /// Android direct-file-I/O extensions. The caller owns the edit lifecycle
    /// and must await each entire transaction before observing cancellation.
    public func beginEditObject(handle: UInt32) async throws {
        try await editObject(code: Self.beginEditObjectCode, handle: handle)
    }

    public func endEditObject(handle: UInt32) async throws {
        try await editObject(code: Self.endEditObjectCode, handle: handle)
    }

    private func editObject(code: UInt16, handle: UInt32) async throws {
        guard handle != 0, handle != UInt32.max else { throw WireError.invalidLength }
        let result = try await exchange(code: code, parameters: [handle], needsSession: true,
            expectsData: false, limit: 0, sink: nil)
        guard result.response.parameters.isEmpty else {
            await invalidate()
            throw WireError.invalidLength
        }
    }

    public func sendPartialObject(handle: UInt32, offset: UInt64, data: Data) async throws {
        guard handle != 0, handle != UInt32.max, !data.isEmpty,
            data.count <= Int(Self.maximumPartialObjectBytes),
            offset <= UInt64.max - UInt64(data.count) else { throw WireError.invalidLength }
        try beginExclusiveWrite()
        defer { busy = false }
        let response = try await outboundTransaction(operation: Self.sendPartialObjectCode,
            parameters: [handle, UInt32(truncatingIfNeeded: offset), UInt32(offset >> 32), UInt32(data.count)],
            payload: .range(data))
        guard response.parameters == [UInt32(data.count)] else {
            await invalidate()
            throw WireError.objectSizeMismatch
        }
        try Task.checkCancellation()
    }

    /// Delete exactly one object. Wildcards and format-wide deletion are forbidden.
    public func deleteObject(handle: UInt32) async throws {
        guard handle != 0, handle != UInt32.max else { throw WireError.invalidLength }
        let result = try await exchange(code: 0x100B, parameters: [handle, 0],
            needsSession: true, expectsData: false, limit: 0, sink: nil)
        guard result.response.parameters.isEmpty else {
            await invalidate()
            throw WireError.invalidLength
        }
    }

    /// Moves one object within a storage. No copy/delete fallback or retry.
    public func moveObject(handle: UInt32, storageID: UInt32, parent: UInt32) async throws {
        guard handle != 0, handle != UInt32.max, storageID != 0,
            storageID != UInt32.max, parent != handle else { throw WireError.invalidLength }
        let result = try await exchange(
            code: WriteOperation.moveObject.rawValue, parameters: [handle, storageID, parent == UInt32.max ? 0 : parent],
            needsSession: true, expectsData: false, limit: 0, sink: nil)
        guard result.response.parameters.isEmpty else {
            await invalidate()
            throw WireError.invalidLength
        }
    }

    /// Creates a GenericFolder association. SendObjectInfo is the entire folder
    /// operation; no zero-byte SendObject transaction follows it.
    public func createDirectory(info: ObjectInfo) async throws -> ObjectCreationResult {
        guard info.format == 0x3001, info.compressedSize == 0,
            info.associationType == 1
        else { throw WireError.invalidLength }
        let encodedInfo = try info.encoded()
        try beginExclusiveWrite()
        defer { busy = false }

        var objectInfoAccepted = false
        do {
            let response = try await outboundDataTransaction(
                operation: .sendObjectInfo,
                parameters: [info.storageID, info.uploadCommandParent],
                payload: encodedInfo)
            objectInfoAccepted = true
            let result = try creationResult(response, matching: info)
            try Task.checkCancellation()
            return result
        } catch {
            if error is CancellationError, valid { throw error }
            if !objectInfoAccepted, Self.isRecoverableFramedResponse(error) { throw error }
            await invalidate()
            throw error
        }
    }

    /// Uploads one ordinary-length object. SendObjectInfo and SendObject remain
    /// under one actor-level exclusion flag, so another command cannot enter at
    /// an `await` between the two protocol transactions.
    public func uploadObject(
        info: ObjectInfo, read: @escaping ObjectDataReader,
        progress: @escaping ObjectDataProgress = { _ in }
    ) async throws -> ObjectCreationResult {
        guard info.format != 0x3001, info.associationType == 0,
            UInt64(info.compressedSize) <= ObjectInfo.maximumOrdinaryObjectSize
        else { throw WireError.invalidLength }
        let encodedInfo = try info.encoded()
        try beginExclusiveWrite()
        defer { busy = false }

        var objectInfoAccepted = false
        var objectDataSent = false
        do {
            let infoResponse = try await outboundDataTransaction(
                operation: .sendObjectInfo,
                parameters: [info.storageID, info.uploadCommandParent],
                payload: encodedInfo)
            objectInfoAccepted = true
            let result = try creationResult(infoResponse, matching: info)
            _ = try await outboundObjectTransaction(
                length: UInt64(info.compressedSize), read: read, progress: progress)
            objectDataSent = true
            try Task.checkCancellation()
            return result
        } catch {
            // A fully framed rejection of SendObjectInfo is known not to have
            // accepted the object and leaves the session reusable. Once it was
            // accepted, errors have an uncertain remote result. A standards-
            // compliant USB CancelTransaction may help the responder recover,
            // but an interrupted session is always replaced.
            // A completed SendObjectInfo reserves the object; cancellation
            // before SendObject completes must retire that pending upload.
            if error is CancellationError, valid, !objectInfoAccepted || objectDataSent { throw error }
            if !objectInfoAccepted, Self.isRecoverableFramedResponse(error) { throw error }
            await invalidate()
            throw error
        }
    }

    private func creationResult(_ response: MTPResponse, matching info: ObjectInfo) throws -> ObjectCreationResult {
        let result = try ObjectCreationResult(response: response)
        let requestedParent = info.uploadCommandParent
        // Harden SendObjectInfo against a contradictory destination before
        // sending any file data. A root response may use either 0 or 0xFFFFFFFF.
        guard result.storageID == info.storageID,
            result.parent == requestedParent || (requestedParent == UInt32.max && result.parent == 0)
        else { throw WireError.invalidLength }
        return result
    }

    public var isUsable: Bool { valid }

    /// Framing is consumed before decoding, but malformed metadata is not safe to
    /// reuse as a device model. Reconnect explicitly instead of guessing a quirk.
    private func decode<T: Sendable>(_ body: () throws -> T) async throws -> T {
        do { return try body() } catch {
            diagnostics?.record(
                .datasetRejected, failure: .classify(error),
                transportID: diagnosticTransportID, sessionID: diagnosticSessionID)
            await invalidate()
            throw error
        }
    }

    public func close() async throws {
        guard !busy, !opening else { throw WireError.busy }
        if valid && opened {
            do {
                _ = try await exchange(
                    code: 0x1003, parameters: [], needsSession: true,
                    expectsData: false, limit: 0, sink: { _ in })
            } catch {
                await invalidate()
                throw error
            }
        }
        await invalidate()
    }

    /// Only available between completed transactions. Retire the old session
    /// unless the control request was explicitly rejected or never attempted.
    public func resetResponder() async -> MTPResponderResetResult {
        guard valid, opened, !busy, !opening, !transportClosed, !Task.isCancelled,
              let resetting = transport as? any MTPResponderResetTransport else { return .notAttempted }
        busy = true
        defer { busy = false }
        let result = await resetting.resetResponder()
        if result == .acknowledged || result == .failed { await invalidate() }
        return result
    }

    private func invalidate() async {
        valid = false
        opened = false
        pending = Data()
        await releaseTransport()
    }

    private func releaseTransport() async {
        guard !transportClosed else { return }
        transportClosed = true
        await transport.close()
        diagnostics?.record(
            .sessionReleased, transportID: diagnosticTransportID,
            sessionID: diagnosticSessionID)
    }

    private func metadata(code: UInt16, parameters: [UInt32] = [], needsSession: Bool = true)
        async throws
        -> Data
    {
        // Data collection is actor-local, while the streaming sink remains Sendable.
        try await exchange(
            code: code, parameters: parameters, needsSession: needsSession,
            expectsData: true, limit: Self.metadataLimit, sink: nil
        ).data
    }

    private func exchange(
        code: UInt16, parameters: [UInt32], needsSession: Bool,
        expectsData: Bool, limit: Int, expectedSize: UInt64? = nil,
        recoverableResponses: Set<UInt16> = [],
        partOfOpening: Bool = false,
        sink: (@Sendable (Data) throws -> Void)?
    ) async throws -> ExchangeResult {
        guard valid else { throw WireError.disconnected }
        guard !opening || partOfOpening else { throw WireError.busy }
        guard !busy else { throw WireError.busy }
        guard !needsSession || opened else { throw WireError.sessionRequired }
        busy = true
        defer { busy = false }
        let transaction = opened ? reserveTransaction() : 0
        var canReuseFraming = false
        let started = DiagnosticLog.start()
        var deliveredBytes = 0
        var responseCode: UInt16?
        var phase = DiagnosticPhase.command
        var wireStarted = false
        var transactionComplete = false
        var finalSinkCancelled = false
        do {
            try Task.checkCancellation()
            let command = try ContainerHeader.command(
                code: code, transaction: transaction, parameters: parameters)
            wireStarted = true
            try await transport.write(command)
            // Once a no-data command has physically crossed the wire, the
            // responder is already in its response phase. Drain that bounded
            // response before observing cancellation; CancelTransaction here
            // could otherwise target a completed or subsequent transaction.
            phase = expectsData ? .firstHeader : .responseHeader
            var header = try await readHeader(
                transaction: transaction, observingCancellation: expectsData,
                finishHeaderAfterFirstBytes: expectsData)
            var result = Data()
            var receivedData = false
            if header.type == .data {
                guard expectsData, header.code == code else { throw WireError.unexpectedContainer }
                guard header.length != UInt32.max, header.payloadLength <= limit else {
                    throw WireError.sizeLimit
                }
                if let expectedSize, UInt64(header.payloadLength) != expectedSize {
                    throw WireError.objectSizeMismatch
                }
                receivedData = true
                phase = .dataPayload
                var remaining = header.payloadLength
                while remaining > 0 {
                    // A combined header/payload read can already contain the
                    // entire file. Only cancel while payload remains on the
                    // wire; otherwise drain the bounded response first.
                    if pending.count < remaining { try Task.checkCancellation() }
                    let chunk = try await readExactly(min(remaining, 64 * 1024))
                    do {
                        if let sink { try sink(chunk) } else { result.append(chunk) }
                    } catch {
                        guard error is CancellationError, chunk.count == remaining else { throw error }
                        // A sink can observe cancellation after the last USB
                        // read. Defer it until the response has been consumed.
                        finalSinkCancelled = true
                    }
                    deliveredBytes += chunk.count
                    remaining -= chunk.count
                }
                // The final DATA-IN transfer is now physically complete. A
                // cancellation observed from here onward must not issue
                // CancelTransaction for a transaction the responder is
                // already finishing; consume its bounded response first.
                phase = .responseHeader
                header = try await readHeader(
                    transaction: transaction, observingCancellation: false)
            }
            guard header.type == .response else { throw WireError.unexpectedContainer }
            phase = .responsePayload
            let responsePayload = try await readExactly(
                header.payloadLength, observingCancellation: false)
            guard pending.isEmpty else { throw WireError.unexpectedContainer }
            let response = try MTPResponse(header: header, payload: responsePayload)
            responseCode = response.code
            guard Self.isResponseCode(header.code) else {
                // A command/data/event code in a response container is still
                // malformed protocol data; framing alone cannot make it safe
                // to reuse this session.
                throw WireError.unexpectedContainer
            }
            guard header.code == 0x2001 else {
                // SessionNotOpen, InvalidTransactionID and SessionAlreadyOpen
                // normally contradict our session model even when correctly
                // framed. OpenSession may explicitly preserve 0x201E just long
                // enough to perform one bounded stale-session recovery.
                canReuseFraming = recoverableResponses.contains(header.code)
                    || !Self.isSessionStateResponse(header.code)
                throw WireError.response(header.code)
            }
            guard !expectsData || receivedData else { throw WireError.unexpectedContainer }
            transactionComplete = true
            if finalSinkCancelled { throw CancellationError() }
            try Task.checkCancellation()
            diagnostics?.record(
                .transaction, since: started, operation: code,
                response: responseCode, bytes: deliveredBytes, phase: .complete,
                transportID: diagnosticTransportID, sessionID: diagnosticSessionID,
                transaction: transaction)
            return ExchangeResult(data: result, response: response)
        } catch {
            diagnostics?.record(
                .transaction, since: started, operation: code,
                response: responseCode, bytes: deliveredBytes, failure: .classify(error), phase: phase,
                transportID: diagnosticTransportID, sessionID: diagnosticSessionID,
                transaction: transaction)
            if error is CancellationError, !wireStarted || transactionComplete { throw error }
            // A fully framed device rejection leaves the session intact. Every
            // other error after touching the wire abandons the transport; an
            // interrupted MTP transaction is never reused or replayed.
            if canReuseFraming { throw error }
            if wireStarted {
                await abortTransport(
                    transaction: transaction != 0 ? transaction : nil, cancelled: error is CancellationError)
            }
            await invalidate()
            throw error
        }
    }

    private enum OutboundPayload: Sendable {
        case buffered(Data)
        case range(Data)
        case object(length: UInt64, read: ObjectDataReader, progress: ObjectDataProgress)
    }

    private func beginExclusiveWrite() throws {
        guard valid else { throw WireError.disconnected }
        guard !opening else { throw WireError.busy }
        guard !busy else { throw WireError.busy }
        guard opened else { throw WireError.sessionRequired }
        busy = true
    }

    private func outboundDataTransaction(
        operation: WriteOperation, parameters: [UInt32], payload: Data
    ) async throws -> MTPResponse {
        try await outboundTransaction(
            operation: operation.rawValue, parameters: parameters, payload: .buffered(payload))
    }

    private func outboundObjectTransaction(
        length: UInt64, read: @escaping ObjectDataReader,
        progress: @escaping ObjectDataProgress
    ) async throws -> MTPResponse {
        try await outboundTransaction(
            operation: WriteOperation.sendObject.rawValue, parameters: [],
            payload: .object(length: length, read: read, progress: progress))
    }

    /// Executes one command -> DATA-OUT -> response transaction. The enclosing
    /// public write operation owns `busy`, allowing two such transactions to be
    /// adjacent even though this actor is reentrant while awaiting USB I/O.
    /// After success, the caller updates its operation state before observing
    /// cancellation: SendObjectInfo alone does not complete a file upload.
    private func outboundTransaction(
        operation: UInt16, parameters: [UInt32], payload: OutboundPayload
    ) async throws -> MTPResponse {
        let transaction = reserveTransaction()
        let started = DiagnosticLog.start()
        var responseCode: UInt16?
        var sentBytes = 0
        var phase = DiagnosticPhase.command
        var wireStarted = false
        var canReuseFraming = false
        do {
            try Task.checkCancellation()
            let command = try ContainerHeader.command(
                code: operation, transaction: transaction, parameters: parameters)
            wireStarted = true
            try await transport.write(command, boundary: .endsContainer)
            try Task.checkCancellation()

            phase = .dataPayload
            switch payload {
            case .buffered(let data):
                guard data.count <= Self.outboundChunkSize - 12 else { throw WireError.sizeLimit }
                let header = try ContainerHeader.data(
                    code: operation, transaction: transaction,
                    payloadLength: UInt64(data.count))
                if dataHeaderMode == .separate, !data.isEmpty {
                    try await transport.write(header, boundary: .separateDataHeader)
                    try Task.checkCancellation()
                    try await transport.write(data, boundary: .endsContainer)
                } else {
                    try await transport.write(header + data, boundary: .endsContainer)
                }
                sentBytes = data.count
            case .range(let data):
                // Android reports the bytes received after its initial header
                // read. A separate short header transfer makes that count the
                // whole range, so short writes cannot masquerade as success.
                let header = try ContainerHeader.data(
                    code: operation, transaction: transaction, payloadLength: UInt64(data.count))
                try await transport.write(header, boundary: .separateDataHeader)
                try Task.checkCancellation()
                // A range is one MTP transaction, but the USB transport still
                // accepts at most 64 KiB per write. Only its final write may
                // terminate the payload transfer (including an aligned ZLP).
                while sentBytes < data.count {
                    let count = min(Self.outboundChunkSize, data.count - sentBytes)
                    let chunk = Data(data.dropFirst(sentBytes).prefix(count))
                    let isFinal = sentBytes + count == data.count
                    try await transport.write(chunk, boundary: isFinal ? .endsContainer : .continuesContainer)
                    sentBytes += count
                    if !isFinal { try Task.checkCancellation() }
                }
            case .object(let length, let read, let progress):
                sentBytes = try await streamObjectData(
                    transaction: transaction, length: length, read: read, progress: progress)
            }
            // A successful return from the payload writer means the final
            // DATA-OUT transfer (including any required terminal ZLP) has
            // physically completed. Drain and parse the bounded response even
            // if cancellation arrived during that final transfer.
            phase = .responseHeader
            let header = try await readHeader(
                transaction: transaction, observingCancellation: false)
            guard header.type == .response else { throw WireError.unexpectedContainer }
            phase = .responsePayload
            let responsePayload = try await readExactly(
                header.payloadLength, observingCancellation: false)
            guard pending.isEmpty else { throw WireError.unexpectedContainer }
            let response = try MTPResponse(header: header, payload: responsePayload)
            responseCode = response.code
            guard Self.isResponseCode(response.code) else { throw WireError.unexpectedContainer }
            canReuseFraming = !Self.isSessionStateResponse(response.code)
            guard response.code == 0x2001 else { throw WireError.response(response.code) }
            diagnostics?.record(
                .transaction, since: started, operation: operation,
                response: response.code, bytes: sentBytes, phase: .complete,
                transportID: diagnosticTransportID, sessionID: diagnosticSessionID,
                transaction: transaction)
            return response
        } catch {
            diagnostics?.record(
                .transaction, since: started, operation: operation,
                response: responseCode, bytes: sentBytes,
                failure: .classify(error), phase: phase,
                transportID: diagnosticTransportID, sessionID: diagnosticSessionID,
                transaction: transaction)
            if error is CancellationError, !wireStarted { throw error }
            if canReuseFraming { throw error }
            if wireStarted {
                await abortTransport(transaction: transaction, cancelled: error is CancellationError)
            }
            await invalidate()
            throw error
        }
    }

    private func streamObjectData(
        transaction: UInt32, length: UInt64, read: ObjectDataReader,
        progress: ObjectDataProgress
    ) async throws -> Int {
        guard length <= ObjectInfo.maximumOrdinaryObjectSize else { throw WireError.sizeLimit }
        let total = Int(length)
        var sent = 0
        let header = try ContainerHeader.data(
            code: WriteOperation.sendObject.rawValue, transaction: transaction,
            payloadLength: length)

        if dataHeaderMode == .separate, total > 0 {
            try await transport.write(header, boundary: .separateDataHeader)
            try Task.checkCancellation()
        } else {
            let firstCount = min(total, Self.outboundChunkSize - 12)
            let firstPayload = try readSourceExactly(firstCount, read: read)
            if firstCount == total { try requireSourceEnd(read) }
            try await transport.write(
                header + firstPayload,
                boundary: firstCount == total ? .endsContainer : .continuesContainer)
            if firstCount < total { try Task.checkCancellation() }
            sent = firstCount
            progress(UInt64(sent))
        }

        while sent < total {
            let count = min(total - sent, Self.outboundChunkSize)
            let chunk = try readSourceExactly(count, read: read)
            let isFinal = sent + count == total
            if isFinal { try requireSourceEnd(read) }
            try await transport.write(
                chunk, boundary: isFinal ? .endsContainer : .continuesContainer)
            if !isFinal { try Task.checkCancellation() }
            sent += count
            progress(UInt64(sent))
        }
        return sent
    }

    private func readSourceExactly(_ count: Int, read: ObjectDataReader) throws -> Data {
        var result = Data()
        result.reserveCapacity(count)
        while result.count < count {
            try Task.checkCancellation()
            let maximum = count - result.count
            let chunk = try read(maximum)
            guard !chunk.isEmpty, chunk.count <= maximum else {
                throw WireError.objectSizeMismatch
            }
            result.append(chunk)
        }
        return result
    }

    private func requireSourceEnd(_ read: ObjectDataReader) throws {
        try Task.checkCancellation()
        guard try read(1).isEmpty else { throw WireError.objectSizeMismatch }
    }

    private func reserveTransaction() -> UInt32 {
        // 0 is reserved for commands outside a session and 0xFFFFFFFF is
        // reserved. PTP permits transaction IDs to wrap within a session.
        let transaction = nextTransaction
        nextTransaction = transaction == UInt32.max - 1 ? 1 : transaction + 1
        return transaction
    }

    private func abortTransport(transaction: UInt32?, cancelled: Bool = false) async {
        guard !transportClosed else { return }
        if cancelled, let transaction {
            _ = await transport.cancel(transaction: transaction)
            cancellationNeedsPhysicalReconnect = await transport.cancellationNeedsPhysicalReconnect
        } else {
            await transport.abort(transaction: transaction)
        }
        transportClosed = true
        diagnostics?.record(
            .sessionReleased, transportID: diagnosticTransportID,
            sessionID: diagnosticSessionID)
    }

    private static func isRecoverableFramedResponse(_ error: any Error) -> Bool {
        guard let wireError = error as? WireError,
            case .response(let code) = wireError
        else { return false }
        return isResponseCode(code) && !isSessionStateResponse(code)
    }

    private func readHeader(
        transaction: UInt32, observingCancellation: Bool = true,
        finishHeaderAfterFirstBytes: Bool = false
    ) async throws -> ContainerHeader {
        let read = try await readExactlyWithTransferObservation(
            12, allowBoundaryZLP: true, observingCancellation: observingCancellation,
            finishAfterFirstBytes: finishHeaderAfterFirstBytes)
        let observed = Self.untrustedHeaderFields(read.data)
        let header: ContainerHeader
        do {
            header = try ContainerHeader(data: read.data)
        } catch {
            diagnostics?.record(
                .malformedHeader, failure: .classify(error),
                transportID: diagnosticTransportID, sessionID: diagnosticSessionID,
                transaction: transaction, containerLength: observed.length,
                containerType: observed.type, containerCode: observed.code,
                containerTransaction: observed.transaction)
            throw error
        }
        guard header.transaction == transaction else {
            diagnostics?.record(
                .malformedHeader, failure: .unexpectedTransaction,
                transportID: diagnosticTransportID, sessionID: diagnosticSessionID,
                transaction: transaction, containerLength: header.length,
                containerType: header.type.rawValue, containerCode: header.code,
                containerTransaction: header.transaction)
            throw WireError.unexpectedTransaction
        }
        if dataHeaderMode == .unknown, header.type == .data, header.payloadLength > 0,
            transport.preservesReadTransferBoundaries,
            read.startedAtTransferBoundary, let firstLength = read.firstTransferLength
        {
            if firstLength == 12 {
                dataHeaderMode = .separate
            } else if firstLength > 12 {
                dataHeaderMode = .combined
            }
        }
        return header
    }

    private static func untrustedHeaderFields(_ data: Data) -> (
        length: UInt32?, type: UInt16?, code: UInt16?, transaction: UInt32?
    ) {
        guard data.count == 12 else { return (nil, nil, nil, nil) }
        let bytes = [UInt8](data)
        func uint16(_ offset: Int) -> UInt16 {
            UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
        }
        func uint32(_ offset: Int) -> UInt32 {
            UInt32(uint16(offset)) | (UInt32(uint16(offset + 2)) << 16)
        }
        return (uint32(0), uint16(4), uint16(6), uint32(8))
    }

    private static func isResponseCode(_ code: UInt16) -> Bool {
        // PTP reserves 0x2000...0x2FFF for standard responses and
        // 0xA000...0xAFFF for vendor/MTP-extension responses.
        (0x2000...0x2FFF).contains(code) || (0xA000...0xAFFF).contains(code)
    }

    private static func isSessionStateResponse(_ code: UInt16) -> Bool {
        code == 0x2003 || code == 0x2004 || code == 0x201E
    }

    private func readExactly(
        _ count: Int, allowBoundaryZLP: Bool = false,
        observingCancellation: Bool = true
    ) async throws -> Data {
        try await readExactlyWithTransferObservation(
            count, allowBoundaryZLP: allowBoundaryZLP,
            observingCancellation: observingCancellation
        ).data
    }

    private func readExactlyWithTransferObservation(
        _ count: Int, allowBoundaryZLP: Bool = false,
        observingCancellation: Bool = true,
        finishAfterFirstBytes: Bool = false
    ) async throws -> ExactRead {
        let startedAtTransferBoundary = pending.isEmpty
        var firstTransferLength: Int?
        var maySkipZLP = allowBoundaryZLP && pending.isEmpty
        var receivedBytes = !pending.isEmpty
        while pending.count < count {
            let result: BulkRead
            if observingCancellation && !(finishAfterFirstBytes && receivedBytes) {
                try Task.checkCancellation()
                result = try await transport.readBulk(maxBytes: 64 * 1024)
            } else {
                // A cancelled parent task cannot call cancellation-aware USB
                // transport methods directly. The detached child performs only
                // this one bounded read and is still serialized by `busy`.
                let transport = self.transport
                result = try await Task.detached {
                    try await transport.readBulk(maxBytes: 64 * 1024)
                }.value
            }
            // Treat one completed USB read atomically. In particular, once a
            // response container has physically arrived it must be parsed and
            // marked complete before observing task cancellation; issuing
            // CancelTransaction after consuming that response would target a
            // transaction the responder has already finished.
            guard case .bytes(let chunk) = result else {
                guard maySkipZLP else { throw WireError.unexpectedContainer }
                maySkipZLP = false
                continue
            }
            maySkipZLP = false
            guard !chunk.isEmpty else { throw WireError.truncated }
            guard chunk.count <= 64 * 1024 else { throw WireError.sizeLimit }
            if firstTransferLength == nil { firstTransferLength = chunk.count }
            pending.append(chunk)
            receivedBytes = true
        }
        let result = Data(pending.prefix(count))
        pending.removeFirst(count)
        return ExactRead(
            data: result, startedAtTransferBoundary: startedAtTransferBoundary,
            firstTransferLength: firstTransferLength)
    }
}
