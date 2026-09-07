import Foundation
import MTPWire

/// Packet boundaries, explicit MTP cancellation, and close-only error cleanup.
public actor USBTransport: MTPResponderResetTransport {
    public nonisolated var preservesReadTransferBoundaries: Bool { true }
    public nonisolated let diagnosticTransportID: UInt64?

    public private(set) var cancellationNeedsPhysicalReconnect = false
    private let io: any USBBulkIO
    private var closed = false
    // A NO_DEVICE result permanently retires this handle, even if the task
    // was also cancelled or the same device subsequently reappears.
    private var deviceRemoved = false
    private var busy = false
    private var responderResetRejected = false
    private let diagnostics: DiagnosticLog?
    private var writeBatch: USBEventBatch?
    private var readBatch: USBEventBatch?
    private static let diagnosticBatchSize = 64
    init(
        io: any USBBulkIO, diagnostics: DiagnosticLog? = nil,
        diagnosticTransportID: UInt64? = nil
    ) {
        self.io = io
        self.diagnostics = diagnostics
        self.diagnosticTransportID = diagnosticTransportID ?? diagnostics?.nextCorrelationID()
    }

    /// A cancelled connection must neither start device access nor retain an
    /// interface acquired while the asynchronous factory was running.
    static func opening(
        diagnostics: DiagnosticLog? = nil,
        makeDevice: @Sendable (UInt64?) async throws -> any USBBulkIO
    ) async throws -> USBTransport {
        try Task.checkCancellation()
        let transportID = diagnostics?.nextCorrelationID()
        let device = try await makeDevice(transportID)
        do { try Task.checkCancellation() } catch {
            await device.close()
            diagnostics?.record(.usbReleased, transportID: transportID)
            throw error
        }
        return USBTransport(io: device, diagnostics: diagnostics, diagnosticTransportID: transportID)
    }

    public func write(_ data: Data) async throws {
        try await write(data, boundary: .endsContainer)
    }

    public func write(_ data: Data, boundary: BulkWriteBoundary) async throws {
        try begin()
        defer { busy = false }
        let started = DiagnosticLog.start()
        var bytes: Int?
        var status: Int32?
        do {
            guard !data.isEmpty, data.count <= 65536, io.outputPacketSize > 0 else {
                throw USBError.invalidTransfer
            }
            let packetAligned = data.count % io.outputPacketSize == 0
            // A normal continuation must not end its underlying USB transfer,
            // so it must be packet-aligned and receive no ZLP. A separate DATA
            // header intentionally ends one USB transfer while its MTP
            // container continues; its short packet or aligned-write ZLP does
            // that without pretending the MTP container itself is complete.
            switch boundary {
            case .continuesContainer:
                guard packetAligned else { throw USBError.invalidTransfer }
            case .separateDataHeader:
                guard data.count == 12 else { throw USBError.invalidTransfer }
            case .endsContainer:
                break
            }
            try Task.checkCancellation()
            // Let an already-submitted USB transfer finish before observing
            // task cancellation. The MTP session then drains a completed
            // transaction or closes the interface at the next chunk boundary.
            let result = await io.send(data)
            bytes = result.transferred
            status = result.status
            guard !closed else { throw USBError.closed }
            try validate(result, maximum: data.count)
            guard result.transferred == data.count else {
                // Preserve explicit cancellation. The transaction engine will
                // dispose this handle without replaying the transaction.
                if Task.isCancelled { throw CancellationError() }
                throw USBError.shortWrite
            }
            if boundary != .continuesContainer && packetAligned {
                let zero = await io.send(Data())
                status = zero.status
                guard !closed else { throw USBError.closed }
                try validate(zero, maximum: 0)
            }
            if boundary == .continuesContainer {
                appendDiagnosticBatch(kind: .usbWrite, started: started, bytes: bytes ?? 0)
            } else {
                flushDiagnosticBatch(kind: .usbWrite)
                diagnostics?.record(
                    .usbWrite, since: started, bytes: bytes, usbStatus: status,
                    transportID: diagnosticTransportID, requestedBytes: data.count,
                    timeoutMilliseconds: diagnosticTimeout)
            }
        } catch {
            flushDiagnosticBatch(kind: .usbWrite)
            diagnostics?.record(
                .usbWrite, since: started, bytes: bytes, usbStatus: status,
                failure: .classify(error), transportID: diagnosticTransportID,
                requestedBytes: data.count, timeoutMilliseconds: diagnosticTimeout)
            // The transaction engine owns disposal after a failed operation.
            throw error
        }
    }

    public func read(maxBytes: Int) async throws -> Data {
        switch try await readBulk(maxBytes: maxBytes) {
        case .bytes(let data): return data
        case .zeroLengthPacket: return Data()
        }
    }

    public func readBulk(maxBytes: Int) async throws -> BulkRead {
        try begin()
        defer { busy = false }
        let started = DiagnosticLog.start()
        var bytes: Int?
        var status: Int32?
        do {
            guard maxBytes > 0, maxBytes <= 65536, io.inputPacketSize > 0,
                maxBytes % io.inputPacketSize == 0
            else { throw USBError.invalidTransfer }
            try Task.checkCancellation()
            // Cancellation is cooperative at USB-transfer boundaries. The
            // session drains a completed response or disposes the handle
            // without interrupting in-flight USB I/O.
            let result = await io.receive(length: maxBytes)
            bytes = result.transferred
            status = result.status
            guard !closed else { throw USBError.closed }
            // Timeout with partial bytes is still a failure. Never silently
            // convert it to success, continue a partial command or retry a stall.
            try validate(result, maximum: maxBytes)
            guard result.data.count == result.transferred else { throw USBError.invalidTransfer }
            if result.transferred == maxBytes {
                appendDiagnosticBatch(kind: .usbRead, started: started, bytes: result.transferred)
            } else {
                flushDiagnosticBatch(kind: .usbRead)
                diagnostics?.record(
                    .usbRead, since: started, bytes: bytes, usbStatus: status,
                    transportID: diagnosticTransportID, requestedBytes: maxBytes,
                    timeoutMilliseconds: diagnosticTimeout)
            }
            return result.transferred == 0 ? .zeroLengthPacket : .bytes(result.data)
        } catch {
            flushDiagnosticBatch(kind: .usbRead)
            diagnostics?.record(
                .usbRead, since: started, bytes: bytes, usbStatus: status,
                failure: .classify(error), transportID: diagnosticTransportID,
                requestedBytes: maxBytes, timeoutMilliseconds: diagnosticTimeout)
            throw error
        }
    }

    private func begin() throws {
        guard !closed else { throw USBError.closed }
        guard !deviceRemoved else { throw USBError.status(-4, transferred: 0) }
        guard !busy else { throw USBError.busy }
        busy = true
    }
    private func validate(_ result: USBTransfer, maximum: Int) throws {
        if result.status == -4 {
            deviceRemoved = true
            throw USBError.status(-4, transferred: result.transferred)
        }
        guard result.transferred >= 0, result.transferred <= maximum else {
            throw USBError.invalidTransfer
        }
        // The adapter returns INTERRUPTED for an explicit host-side
        // cancellation. If cooperative cancellation was requested while an
        // already-submitted request instead finished with TIMEOUT, STALL or
        // another USB failure, preserve the cancellation intent. The MTP
        // session then aborts and disposes the transport exactly once.
        if result.status == -10 || (result.status != 0 && Task.isCancelled) {
            throw CancellationError()
        }
        guard result.status == 0 else {
            throw USBError.status(result.status, transferred: result.transferred)
        }
    }
    public func cancel(transaction: UInt32) async -> Bool {
        guard !closed, !busy, !deviceRemoved, transaction != 0, transaction != UInt32.max,
            let control = io as? any USBMTPControlIO else {
            cancellationNeedsPhysicalReconnect = true
            await abort(transaction: transaction)
            return false
        }
        busy = true
        defer { busy = false }
        flushDiagnosticBatches()
        let started = DiagnosticLog.start()
        let recovered = await MTPCancellation.run(io: control, transaction: transaction)
        cancellationNeedsPhysicalReconnect = !recovered
        diagnostics?.record(.usbCancel, since: started, failure: recovered ? nil : .other,
            transportID: diagnosticTransportID, transaction: transaction)
        // Even a confirmed cancellation gets a fresh transport/session. Never
        // reuse handles or replay a partially completed upload.
        await fail()
        return recovered
    }

    public func abort(transaction: UInt32?) async {
        guard !closed, !busy else { return }
        busy = true
        defer { busy = false }
        flushDiagnosticBatches()
        diagnostics?.record(
            .recoveryDecision, failure: deviceRemoved ? .disconnected : nil,
            transportID: diagnosticTransportID, transaction: transaction,
            recoveryAction: .closeOnly)
        await fail()
    }

    public func resetResponder() async -> MTPResponderResetResult {
        guard !closed, !busy, !deviceRemoved, !Task.isCancelled,
              let control = io as? any USBMTPControlIO else { return .notAttempted }
        guard !responderResetRejected else { return .rejected }
        busy = true
        defer { busy = false }
        flushDiagnosticBatches()
        let started = DiagnosticLog.start()
        diagnostics?.record(.responderReset, phase: .command, transportID: diagnosticTransportID)
        // Still Image class Device Reset, no data, addressed to the selected
        // interface by the adapter. Its control deadline is one second.
        let result = await control.mtpControl(request: 0x66, data: Data(), inputLength: 0)
        let acknowledged = result.status == 0 && result.transferred == 0 && result.data.isEmpty
        // A STALL of this optional control request is a rejection, not a bulk
        // pipe error. Keep the completed MTP stream for a read-only liveness
        // check; do not clear bulk halts, replay a request or reset again.
        let rejected = result.status == -9 && result.transferred == 0 && result.data.isEmpty
        diagnostics?.record(.responderReset, since: started, usbStatus: result.status,
            failure: acknowledged ? nil : rejected ? .deviceRejected : .usbStatus, phase: .complete,
            transportID: diagnosticTransportID)
        if rejected {
            responderResetRejected = true
            return .rejected
        }
        await fail()
        return acknowledged ? .acknowledged : .failed
    }
    private func fail() async {
        if !closed {
            flushDiagnosticBatches()
            closed = true
            await io.close()
            diagnostics?.record(.usbReleased, transportID: diagnosticTransportID)
        }
    }
    public func close() async { await fail() }

    private struct USBEventBatch {
        let generation: UInt64
        let started: UInt64
        var bytes: Int
        var samples: Int
    }

    private func appendDiagnosticBatch(kind: DiagnosticEventKind, started: UInt64, bytes: Int) {
        guard let generation = diagnostics?.recordingGeneration else {
            writeBatch = nil
            readBatch = nil
            return
        }
        switch kind {
        case .usbWrite:
            if writeBatch?.generation != generation {
                writeBatch = USBEventBatch(generation: generation, started: started, bytes: 0, samples: 0)
            }
            writeBatch?.bytes += bytes
            writeBatch?.samples += 1
            if writeBatch?.samples == Self.diagnosticBatchSize { flushDiagnosticBatch(kind: kind) }
        case .usbRead:
            if readBatch?.generation != generation {
                readBatch = USBEventBatch(generation: generation, started: started, bytes: 0, samples: 0)
            }
            readBatch?.bytes += bytes
            readBatch?.samples += 1
            if readBatch?.samples == Self.diagnosticBatchSize { flushDiagnosticBatch(kind: kind) }
        default:
            break
        }
    }

    private func flushDiagnosticBatch(kind: DiagnosticEventKind) {
        let batch: USBEventBatch?
        switch kind {
        case .usbWrite:
            batch = writeBatch
            writeBatch = nil
        case .usbRead:
            batch = readBatch
            readBatch = nil
        default:
            return
        }
        guard let batch else { return }
        diagnostics?.record(
            kind, since: batch.started, bytes: batch.bytes, usbStatus: 0,
            sampleCount: batch.samples, transportID: diagnosticTransportID,
            requestedBytes: batch.bytes, timeoutMilliseconds: diagnosticTimeout,
            recordingGeneration: batch.generation)
    }

    private func flushDiagnosticBatches() {
        flushDiagnosticBatch(kind: .usbRead)
        flushDiagnosticBatch(kind: .usbWrite)
    }

    private var diagnosticTimeout: UInt64? {
        io.transferTimeoutMilliseconds == 0 ? nil : io.transferTimeoutMilliseconds
    }

}
