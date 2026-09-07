import Foundation
import MTPWire
import Testing

@testable import MTPUSB

private actor RawIO: USBBulkIO {
    nonisolated let inputPacketSize: Int
    nonisolated let outputPacketSize: Int
    private var reads: [USBTransfer]
    private var writes: [USBTransfer]
    private(set) var sent: [Data] = []
    private(set) var requests: [Int] = []
    private(set) var closes = 0
    init(reads: [USBTransfer] = [], writes: [USBTransfer] = [], packet: Int = 512) {
        self.reads = reads
        self.writes = writes
        inputPacketSize = packet
        outputPacketSize = packet
    }
    func send(_ data: Data) async -> USBTransfer {
        sent.append(data)
        return writes.isEmpty
            ? USBTransfer(status: 0, transferred: data.count, data: Data()) : writes.removeFirst()
    }
    func receive(length: Int) async -> USBTransfer {
        requests.append(length)
        return reads.isEmpty
            ? USBTransfer(status: -4, transferred: 0, data: Data()) : reads.removeFirst()
    }
    func close() async { closes += 1 }
}

private func bytes(_ data: Data) -> USBTransfer {
    USBTransfer(status: 0, transferred: data.count, data: data)
}

@Test func usbDiagnosticsPreserveErrorCountsWithoutPayloads() async throws {
    let secret = Data("SECRET-DEVICE-PAYLOAD".utf8)
    let io = RawIO(reads: [.init(status: -7, transferred: secret.count, data: secret)])
    let log = DiagnosticLog()
    let transport = USBTransport(io: io, diagnostics: log)
    await #expect(throws: USBError.status(-7, transferred: secret.count)) {
        try await transport.readBulk(maxBytes: 65536)
    }
    await transport.close()
    let events = log.snapshot().events
    #expect(events.first?.kind == .usbRead)
    #expect(events.first?.usbStatus == -7)
    #expect(events.first?.bytes == secret.count)
    #expect(events.first?.requestedBytes == 65536)
    #expect(events.first?.transportID != nil)
    #expect(events.first?.failure == .usbStatus)
    #expect(events.filter { $0.kind == .usbReleased }.count == 1)
    #expect(events.last?.transportID == events.first?.transportID)
    let json = String(decoding: try JSONEncoder().encode(log.snapshot()), as: UTF8.self)
    #expect(!json.contains("SECRET"))
    #expect(
        DiagnosticFailure.classify(USBError.ambiguousCandidates(["private-selector"]))
            == .ambiguousCandidates)
}

@Test func usbInterruptedResultIsCancellationEvenWithoutTaskFlagAtContinuationBoundary() async {
    let io = RawIO(
        reads: [USBTransfer(status: -10, transferred: 0, data: Data())])
    let transport = USBTransport(io: io)
    await #expect(throws: CancellationError.self) {
        try await transport.readBulk(maxBytes: 65536)
    }
    // MTP still has to perform transaction recovery, so the transport remains
    // alive until the session's abort path disposes it.
    #expect(await io.closes == 0)
    await transport.close()
    #expect(await io.closes == 1)
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
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func append(_ data: Data) {
        lock.lock()
        count += data.count
        lock.unlock()
    }
    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private final class UploadSource: @unchecked Sendable {
    private let lock = NSLock()
    private let data: Data
    private var offset = 0

    init(_ data: Data) { self.data = data }

    func read(maximum: Int) -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard offset < data.count else { return Data() }
        let count = min(maximum, data.count - offset)
        defer { offset += count }
        return Data(data[offset..<(offset + count)])
    }
}

@Test func usbPacketBoundaryDownloadAcceptsOneZLPBeforeResponse() async throws {
    for size in [0, 1, 63, 64, 65, 500, 512, 513, 65524, 65536, 65537] {
        let payload = Data(repeating: 42, count: size)
        let container =
            try ContainerHeader(length: UInt32(size + 12), type: .data, code: 0x1009, transaction: 1)
            .encoded() + payload
        var reads: [USBTransfer] = [bytes(try response(0))]
        for offset in stride(from: 0, to: container.count, by: 65536) {
            reads.append(bytes(Data(container.dropFirst(offset).prefix(65536))))
        }
        if container.count % 512 == 0 { reads.append(bytes(Data())) }
        reads += [bytes(try response(1)), bytes(try response(2))]
        let io = RawIO(reads: reads)
        let transport = USBTransport(io: io)
        let session = ReadSession(transport: transport)
        try await session.open()
        let counter = Counter()
        try await session.download(handle: 10, expectedSize: UInt64(size)) { counter.append($0) }
        #expect(counter.value == size)
        try await session.close()
        #expect(await io.closes == 1)
        #expect(await io.requests.allSatisfy { $0 == 65536 })
    }
}

@Test func usbRejectsRepeatedAndMidContainerZLPs() async throws {
    for middle in [false, true] {
        let header = try ContainerHeader(length: 512, type: .data, code: 0x1009, transaction: 1)
            .encoded()
        let payload = Data(repeating: 42, count: 500)
        let fragments =
            middle
            ? [bytes(header), bytes(Data()), bytes(payload)]
            : [bytes(header + payload), bytes(Data()), bytes(Data())]
        let io = RawIO(reads: [bytes(try response(0))] + fragments + [bytes(try response(1))])
        let session = ReadSession(transport: USBTransport(io: io))
        try await session.open()
        await #expect(throws: WireError.unexpectedContainer) {
            try await session.download(handle: 10) { _ in }
        }
        #expect(await io.closes == 1)
    }
}

@Test func usbWritesSendZLPOnlyAtPacketBoundaries() async throws {
    for size in [12, 16, 64, 512, 513, 65536] {
        let io = RawIO(packet: 64)
        let transport = USBTransport(io: io)
        try await transport.write(Data(repeating: 0, count: size))
        let sent = await io.sent
        #expect(sent.map(\.count) == (size % 64 == 0 ? [size, 0] : [size]))
        await transport.close()
        await transport.close()
        #expect(await io.closes == 1)
    }
}

@Test func usbReportsAndPreservesIndividualReadTransferBoundaries() async {
    let transport: any MTPBulkTransport = USBTransport(io: RawIO())
    #expect(transport.preservesReadTransferBoundaries)
    await transport.close()
}

@Test func usbSeparateDataHeaderEndsItsUSBTransferWithoutEndingContainer() async throws {
    do {
        let io = RawIO(packet: 64)
        let transport = USBTransport(io: io)
        try await transport.write(Data(repeating: 0x01, count: 12), boundary: .separateDataHeader)
        try await transport.write(Data(repeating: 0x02, count: 64), boundary: .continuesContainer)
        try await transport.write(Data(repeating: 0x03, count: 64), boundary: .endsContainer)
        #expect(await io.sent.map(\.count) == [12, 64, 64, 0])
        await transport.close()
    }
    do {
        // Synthetic packet size: proves an aligned header gets the ZLP needed
        // to terminate that USB transfer before the container payload begins.
        let io = RawIO(packet: 4)
        let transport = USBTransport(io: io)
        try await transport.write(Data(repeating: 0x04, count: 12), boundary: .separateDataHeader)
        #expect(await io.sent.map(\.count) == [12, 0])
        await transport.close()
    }
}

@Test func usbSeparateDataHeaderRequiresExactlyTwelveBytesAndLeavesDisposalToSession() async throws {
    for size in [0, 1, 11, 13, 64] {
        let io = RawIO(packet: 64)
        let transport = USBTransport(io: io)
        await #expect(throws: USBError.invalidTransfer) {
            try await transport.write(
                Data(repeating: 0x05, count: size), boundary: .separateDataHeader)
        }
        #expect(await io.sent.isEmpty)
        #expect(await io.closes == 0)
        await transport.close()
        #expect(await io.closes == 1)
    }
    for result in [
        USBTransfer(status: 0, transferred: 11, data: Data()),
        USBTransfer(status: -7, transferred: 12, data: Data()),
    ] {
        let io = RawIO(writes: [result], packet: 64)
        let transport = USBTransport(io: io)
        await #expect(throws: (any Error).self) {
            try await transport.write(
                Data(repeating: 0x06, count: 12), boundary: .separateDataHeader)
        }
        #expect(await io.sent.count == 1)
        #expect(await io.closes == 0)
        await transport.close()
        #expect(await io.closes == 1)
    }
}

@Test func usbContinuationWritesDoNotTerminateContainerBeforeFinalBoundary() async throws {
    for finalSize in [63, 64] {
        let io = RawIO(packet: 64)
        let log = DiagnosticLog()
        let transport = USBTransport(io: io, diagnostics: log)
        try await transport.write(
            Data(repeating: 0x11, count: 64), boundary: .continuesContainer)
        try await transport.write(
            Data(repeating: 0x22, count: 128), boundary: .continuesContainer)
        try await transport.write(
            Data(repeating: 0x33, count: finalSize), boundary: .endsContainer)

        let expected = finalSize == 64 ? [64, 128, 64, 0] : [64, 128, 63]
        #expect(await io.sent.map(\.count) == expected)
        let events = log.snapshot().events.filter { $0.kind == .usbWrite }
        #expect(events.count == 2)
        #expect(events.first?.sampleCount == 2)
        #expect(events.compactMap(\.bytes).reduce(0, +) == 64 + 128 + finalSize)
        #expect(events.allSatisfy { $0.failure == nil })
        await transport.close()
        #expect(await io.closes == 1)
    }
}

@Test func usbRejectsMisalignedContinuationWithoutSending() async throws {
    for size in [1, 63, 65, 65535] {
        let io = RawIO(packet: 64)
        let transport = USBTransport(io: io)
        await #expect(throws: USBError.invalidTransfer) {
            try await transport.write(
                Data(repeating: 0x44, count: size), boundary: .continuesContainer)
        }
        #expect(await io.sent.isEmpty)
        #expect(await io.closes == 0)
        await transport.close()
        #expect(await io.closes == 1)
    }
}

@Test func usbContinuationFailuresAreNotRetried() async throws {
    for result in [
        USBTransfer(status: 0, transferred: 63, data: Data()),
        USBTransfer(status: -7, transferred: 64, data: Data()),
    ] {
        let io = RawIO(writes: [result], packet: 64)
        let transport = USBTransport(io: io)
        await #expect(throws: (any Error).self) {
            try await transport.write(
                Data(repeating: 0x55, count: 64), boundary: .continuesContainer)
        }
        #expect(await io.sent.count == 1)
        #expect(await io.closes == 0)
        await transport.close()
        #expect(await io.closes == 1)
    }
}

@Test func usbTerminalZLPFailurePreservesPayloadCountAndIsNotRetried() async throws {
    let io = RawIO(
        writes: [
            USBTransfer(status: 0, transferred: 64, data: Data()),
            USBTransfer(status: -7, transferred: 0, data: Data()),
        ], packet: 64)
    let log = DiagnosticLog()
    let transport = USBTransport(io: io, diagnostics: log)
    await #expect(throws: USBError.status(-7, transferred: 0)) {
        try await transport.write(
            Data(repeating: 0x66, count: 64), boundary: .endsContainer)
    }
    #expect(await io.sent.map(\.count) == [64, 0])
    #expect(await io.closes == 0)
    let failure = try #require(
        log.snapshot().events.last(where: { $0.kind == .usbWrite && $0.failure != nil })
    )
    #expect(failure.kind == .usbWrite)
    #expect(failure.bytes == 64)
    #expect(failure.usbStatus == -7)
    #expect(failure.failure == .usbStatus)
    await transport.close()
    #expect(await io.closes == 1)
}

@Test func usbShortWriteAndPartialTimeoutAreNotRetried() async throws {
    for status: Int32 in [0, -7, -9, -4, -8] {
        let io = RawIO(writes: [USBTransfer(status: status, transferred: 3, data: Data())])
        let transport = USBTransport(io: io)
        await #expect(throws: (any Error).self) {
            try await transport.write(Data(repeating: 0, count: 16))
        }
        #expect(await io.sent.count == 1)
        #expect(await io.closes == 0)
        await transport.close()
        #expect(await io.closes == 1)
        await #expect(throws: USBError.closed) { try await transport.write(Data([0])) }
    }
}

@Test func usbReadErrorsPreservePartialCountAndLeaveDisposalToSession() async throws {
    for status: Int32 in [-7, -9, -4, -8, -3] {
        let io = RawIO(reads: [USBTransfer(status: status, transferred: 3, data: Data([1, 2, 3]))])
        let transport = USBTransport(io: io)
        await #expect(throws: USBError.status(status, transferred: 3)) {
            try await transport.readBulk(maxBytes: 65536)
        }
        #expect(await io.closes == 0)
        await transport.close()
        #expect(await io.closes == 1)
    }
}

@Test func usbValidatesAlignmentAndReturnedLengths() async throws {
    let invalid = RawIO()
    let transport = USBTransport(io: invalid)
    await #expect(throws: USBError.invalidTransfer) { try await transport.read(maxBytes: 12) }
    #expect(await invalid.requests.isEmpty)
    for result in [
        USBTransfer(status: 0, transferred: -1, data: Data()),
        USBTransfer(status: 0, transferred: 65537, data: Data()),
        USBTransfer(status: 0, transferred: 3, data: Data([1])),
    ] {
        let io = RawIO(reads: [result])
        let transport = USBTransport(io: io)
        await #expect(throws: USBError.invalidTransfer) { try await transport.read(maxBytes: 65536) }
        #expect(await io.closes == 0)
        await transport.close()
        #expect(await io.closes == 1)
    }
}

private actor PausedIO: USBBulkIO {
    nonisolated let inputPacketSize = 512
    nonisolated let outputPacketSize = 512
    private var pending: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    private(set) var closes = 0
    func send(_ data: Data) async -> USBTransfer { bytes(data) }
    func receive(length: Int) async -> USBTransfer {
        await withCheckedContinuation { continuation in
            pending = continuation
            observer?.resume()
            observer = nil
        }
        return bytes(Data([1, 2, 3]))
    }
    func waitUntilBlocked() async {
        if pending != nil { return }
        await withCheckedContinuation { observer = $0 }
    }
    func resume() {
        pending?.resume()
        pending = nil
    }
    func close() async { closes += 1 }
}

@Test func usbSubmittedReadRejectsConcurrentOperationsAndCompletesAtomically() async throws {
    let io = PausedIO()
    let transport = USBTransport(io: io)
    let reading = Task { try await transport.readBulk(maxBytes: 65536) }
    await io.waitUntilBlocked()
    await #expect(throws: USBError.busy) { try await transport.write(Data([1])) }
    reading.cancel()
    await io.resume()
    switch try await reading.value {
    case .bytes(let data): #expect(data == Data([1, 2, 3]))
    case .zeroLengthPacket: Issue.record("Expected the completed read payload")
    }
    #expect(await io.closes == 0)
    await transport.close()
    #expect(await io.closes == 1)
}

@Test func usbExplicitCloseDoesNotReturnSuccessfulDataFromPendingRead() async throws {
    let io = PausedIO()
    let transport = USBTransport(io: io)
    let reading = Task { try await transport.readBulk(maxBytes: 65536) }
    await io.waitUntilBlocked()
    await transport.close()
    await io.resume()
    await #expect(throws: USBError.closed) { try await reading.value }
    #expect(await io.closes == 1)
}

private final class CancellableIO: USBBulkIO, @unchecked Sendable {
    let inputPacketSize = 512
    let outputPacketSize = 512
    private let lock = NSLock()
    private var pending: CheckedContinuation<USBTransfer, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    private var cancellationCount = 0
    private var closeCount = 0

    func send(_ data: Data) async -> USBTransfer { bytes(data) }
    func receive(length: Int) async -> USBTransfer {
        await withCheckedContinuation { continuation in
            lock.lock()
            pending = continuation
            let waiting = observer
            observer = nil
            lock.unlock()
            waiting?.resume()
        }
    }
    func waitUntilBlocked() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if pending == nil {
                observer = continuation
                lock.unlock()
            } else {
                lock.unlock()
                continuation.resume()
            }
        }
    }
    func cancel() {
        lock.lock()
        cancellationCount += 1
        let blocked = pending
        pending = nil
        lock.unlock()
        blocked?.resume(returning: USBTransfer(status: -10, transferred: 0, data: Data()))
    }
    func completeRead() {
        lock.lock()
        let blocked = pending
        pending = nil
        lock.unlock()
        blocked?.resume(returning: bytes(Data([1, 2, 3])))
    }
    func close() async {
        recordClose()
    }
    private func recordClose() {
        lock.lock()
        closeCount += 1
        lock.unlock()
    }
    var snapshot: (cancellations: Int, closes: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (cancellationCount, closeCount)
    }
}

@Test func submittedUSBReadCompletesAtomicallyAfterTaskCancellation() async throws {
    let io = CancellableIO()
    let transport = USBTransport(io: io)
    let reading = Task { try await transport.readBulk(maxBytes: 65536) }
    await io.waitUntilBlocked()
    reading.cancel()
    #expect(io.snapshot.cancellations == 0)
    #expect(io.snapshot.closes == 0)
    io.completeRead()
    switch try await reading.value {
    case .bytes(let data): #expect(data == Data([1, 2, 3]))
    case .zeroLengthPacket: Issue.record("Expected the completed read payload")
    }
    #expect(io.snapshot.cancellations == 0)
    #expect(io.snapshot.closes == 0)
    await transport.close()
    #expect(io.snapshot.closes == 1)
}

private final class CancellableWriteIO: USBBulkIO, @unchecked Sendable {
    let inputPacketSize = 64
    let outputPacketSize = 64
    private let lock = NSLock()
    private var pending: CheckedContinuation<USBTransfer, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    private var sends = 0
    private var cancellations = 0
    private var closes = 0

    func send(_ data: Data) async -> USBTransfer {
        await withCheckedContinuation { continuation in
            lock.lock()
            sends += 1
            pending = continuation
            let waiting = observer
            observer = nil
            lock.unlock()
            waiting?.resume()
        }
    }

    func receive(length: Int) async -> USBTransfer {
        USBTransfer(status: -4, transferred: 0, data: Data())
    }

    func waitUntilBlocked() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if pending == nil {
                observer = continuation
                lock.unlock()
            } else {
                lock.unlock()
                continuation.resume()
            }
        }
    }

    func cancel() {
        lock.lock()
        cancellations += 1
        let blocked = pending
        pending = nil
        lock.unlock()
        blocked?.resume(returning: USBTransfer(status: -10, transferred: 0, data: Data()))
    }

    func completeWrite(byteCount: Int) {
        lock.lock()
        let blocked = pending
        pending = nil
        lock.unlock()
        blocked?.resume(
            returning: USBTransfer(status: 0, transferred: byteCount, data: Data()))
    }

    func close() async {
        recordClose()
    }

    private func recordClose() {
        lock.lock()
        closes += 1
        lock.unlock()
    }

    var snapshot: (sends: Int, cancellations: Int, closes: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (sends, cancellations, closes)
    }
}

@Test func submittedUSBWriteCompletesAtomicallyAfterTaskCancellation() async throws {
    let io = CancellableWriteIO()
    let transport = USBTransport(io: io)
    let writing = Task {
        try await transport.write(
            Data(repeating: 0x77, count: 64), boundary: .continuesContainer)
    }
    await io.waitUntilBlocked()
    writing.cancel()
    #expect(io.snapshot.cancellations == 0)
    #expect(io.snapshot.closes == 0)
    io.completeWrite(byteCount: 64)
    try await writing.value
    #expect(io.snapshot.sends == 1)
    #expect(io.snapshot.cancellations == 0)
    #expect(io.snapshot.closes == 0)
    await transport.close()
    #expect(io.snapshot.closes == 1)
}

@Test func cancelledPacketAlignedTerminalWriteStillSendsItsRequiredZLP() async throws {
    let io = CancellableWriteIO()
    let transport = USBTransport(io: io)
    let writing = Task {
        try await transport.write(
            Data(repeating: 0x78, count: 64), boundary: .endsContainer)
    }
    await io.waitUntilBlocked()
    writing.cancel()
    io.completeWrite(byteCount: 64)
    await io.waitUntilBlocked()
    #expect(io.snapshot.sends == 2)
    #expect(io.snapshot.cancellations == 0)
    io.completeWrite(byteCount: 0)
    try await writing.value
    #expect(io.snapshot.sends == 2)
    #expect(io.snapshot.cancellations == 0)
    await transport.close()
    #expect(io.snapshot.closes == 1)
}

private final class RawCancellationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func record() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

/// Pauses one selected raw USB submission while otherwise acting as a scripted
/// device. This lets the integration tests cancel the Swift task only after a
/// command or payload transfer is genuinely in flight.
private actor PausedTransferIO: USBBulkIO {
    nonisolated let inputPacketSize = 512
    nonisolated let outputPacketSize = 512
    nonisolated let rawCancellationRecorder = RawCancellationRecorder()
    private let pauseAtSend: Int?
    private let pauseAtReceive: Int?
    private var reads: [USBTransfer]
    private var sendCount = 0
    private(set) var receiveCount = 0
    private var pendingTransfer: CheckedContinuation<USBTransfer, Never>?
    private var pendingResult: USBTransfer?
    private var observer: CheckedContinuation<Void, Never>?
    private(set) var sent: [Data] = []
    private(set) var completedPausedTransfers = 0
    private(set) var closes = 0

    init(
        pauseAtSend: Int? = nil, pauseAtReceive: Int? = nil,
        reads: [USBTransfer]
    ) {
        self.pauseAtSend = pauseAtSend
        self.pauseAtReceive = pauseAtReceive
        self.reads = reads
    }

    func send(_ data: Data) async -> USBTransfer {
        sendCount += 1
        sent.append(data)
        let result = bytes(data)
        guard sendCount == pauseAtSend else { return result }
        return await pause(returning: result)
    }

    func receive(length: Int) async -> USBTransfer {
        receiveCount += 1
        let result = reads.isEmpty
            ? USBTransfer(status: -4, transferred: 0, data: Data()) : reads.removeFirst()
        guard receiveCount == pauseAtReceive else { return result }
        return await pause(returning: result)
    }

    private func pause(returning result: USBTransfer) async -> USBTransfer {
        await withCheckedContinuation { continuation in
            pendingResult = result
            pendingTransfer = continuation
            observer?.resume()
            observer = nil
        }
    }

    func waitUntilPaused() async {
        if pendingTransfer != nil { return }
        await withCheckedContinuation { observer = $0 }
    }

    func completePausedTransfer(with result: USBTransfer? = nil) {
        guard let pendingTransfer, let pendingResult else { return }
        self.pendingTransfer = nil
        self.pendingResult = nil
        completedPausedTransfers += 1
        pendingTransfer.resume(returning: result ?? pendingResult)
    }

    nonisolated func cancel() { rawCancellationRecorder.record() }


    func close() async { closes += 1 }
}

private func storageIDsTransfer(_ ids: [UInt32], transaction: UInt32) throws -> USBTransfer {
    var writer = DatasetWriter()
    writer.append(UInt32(ids.count))
    for id in ids { writer.append(id) }
    let data = try ContainerHeader.data(
        code: 0x1004, transaction: transaction, payloadLength: UInt64(writer.data.count))
        + writer.data
    return bytes(data)
}

@Test func cancellationDuringInboundCommandWriteDisposesSession() async throws {
    let io = try PausedTransferIO(
        pauseAtSend: 2,
        reads: [
            bytes(response(0)), storageIDsTransfer([7], transaction: 2),
            bytes(response(2)), bytes(response(3)),
        ])
    let session = ReadSession(transport: USBTransport(io: io))
    try await session.open()

    let command = Task { try await session.storageIDs() }
    await io.waitUntilPaused()
    command.cancel()
    await io.completePausedTransfer()
    await #expect(throws: CancellationError.self) { try await command.value }

    #expect(io.rawCancellationRecorder.value == 0)
    #expect(await !session.isUsable)
    await #expect(throws: WireError.disconnected) { try await session.storageIDs() }
    #expect(await io.closes == 1)
}

@Test func cancellationDuringSendObjectCommandWriteDisposesSession() async throws {
    let bytesToUpload = Data(repeating: 0x45, count: 65)
    let info = try ObjectInfo.uploadFile(
        storageID: 1, parent: 44, size: UInt64(bytesToUpload.count), filename: "cancel.bin")
    let io = try PausedTransferIO(
        pauseAtSend: 4,
        reads: [
            bytes(response(0)), bytes(response(1, parameters: [1, 44, 55])),
            storageIDsTransfer([9], transaction: 3), bytes(response(3)), bytes(response(4)),
        ])
    let session = ReadSession(transport: USBTransport(io: io))
    try await session.open()

    let upload = Task {
        try await session.uploadObject(
            info: info, read: { maximum in Data(bytesToUpload.prefix(maximum)) })
    }
    await io.waitUntilPaused()
    upload.cancel()
    await io.completePausedTransfer()
    await #expect(throws: CancellationError.self) { try await upload.value }

    #expect(io.rawCancellationRecorder.value == 0)
    #expect(await !session.isUsable)
    await #expect(throws: WireError.disconnected) { try await session.storageIDs() }
    #expect(await io.closes == 1)
}

@Test func cancellationDuringLargeSendObjectPayloadAlwaysDisposesSession() async throws {
    let firstPayloadSize = 64 * 1024 - 12
    let bytesToUpload = Data(repeating: 0x46, count: firstPayloadSize + 64 * 1024 + 1)
    let info = try ObjectInfo.uploadFile(
        storageID: 1, parent: 44, size: UInt64(bytesToUpload.count),
        filename: "cancel-large.bin")
    let source = UploadSource(bytesToUpload)
    let reads = try [
        bytes(response(0)), bytes(response(1, parameters: [1, 44, 56])),
    ]
    let io = PausedTransferIO(
        // OpenSession, SendObjectInfo command/data, SendObject command,
        // then the first 64 KiB DATA container transfer.
        pauseAtSend: 5, reads: reads)
    let session = ReadSession(transport: USBTransport(io: io))
    try await session.open()

    let upload = Task {
        try await session.uploadObject(
            info: info, read: { source.read(maximum: $0) })
    }
    await io.waitUntilPaused()
    upload.cancel()
    #expect(io.rawCancellationRecorder.value == 0)
    await io.completePausedTransfer()
    await #expect(throws: CancellationError.self) { try await upload.value }

    let sent = await io.sent
    let completedPayloadTransfer = try #require(sent.dropFirst(4).first)
    #expect(completedPayloadTransfer.count == 64 * 1024)
    let completedHeader = try ContainerHeader(
        data: Data(completedPayloadTransfer.prefix(12)))
    #expect(completedHeader.type == .data)
    #expect(completedHeader.code == 0x100D)
    #expect(completedHeader.transaction == 2)
    #expect(completedPayloadTransfer.dropFirst(12).allSatisfy { $0 == 0x46 })
    #expect(await io.completedPausedTransfers == 1)
    #expect(io.rawCancellationRecorder.value == 0)

    #expect(await !session.isUsable)
    await #expect(throws: WireError.disconnected) { try await session.storageIDs() }
    #expect(await io.closes == 1)
}

@Test func cancellationDuringLargeDownloadPayloadCompletesReadThenDisposesSession() async throws {
    let payloadSize = 64 * 1024 + 1
    let header = try ContainerHeader.data(
        code: 0x1009, transaction: 1, payloadLength: UInt64(payloadSize))
    let sink = Counter()
    let io = try PausedTransferIO(
        // OpenSession response, separate DATA header, then the first payload
        // transfer. The cancelled transaction's remaining byte/response are
        // discarded by the scripted successful CancelTransaction.
        pauseAtReceive: 3,
        reads: [
            bytes(response(0)), bytes(header), bytes(Data(repeating: 0x47, count: 64 * 1024)),
            storageIDsTransfer([11], transaction: 2), bytes(response(2)), bytes(response(3)),
        ])
    let session = ReadSession(transport: USBTransport(io: io))
    try await session.open()

    let download = Task {
        try await session.download(handle: 99, expectedSize: UInt64(payloadSize)) {
            sink.append($0)
        }
    }
    await io.waitUntilPaused()
    download.cancel()
    #expect(io.rawCancellationRecorder.value == 0)
    await io.completePausedTransfer()
    await #expect(throws: CancellationError.self) { try await download.value }

    #expect(await io.completedPausedTransfers == 1)
    #expect(io.rawCancellationRecorder.value == 0)
    // A completed raw payload read is delivered as one atomic chunk before
    // cancellation is observed at the next MTP chunk boundary.
    #expect(sink.value == 64 * 1024)
    #expect(await !session.isUsable)
    await #expect(throws: WireError.disconnected) { try await session.storageIDs() }
    #expect(await io.closes == 1)
}

@Test func cancelledInFlightDownloadTimeoutDisposesSession() async throws {
    let payloadSize = 64 * 1024 + 1
    let header = try ContainerHeader.data(
        code: 0x1009, transaction: 1, payloadLength: UInt64(payloadSize))
    let sink = Counter()
    let io = try PausedTransferIO(
        pauseAtReceive: 3,
        reads: [
            bytes(response(0)), bytes(header), bytes(Data(repeating: 0x4A, count: 64 * 1024)),
            storageIDsTransfer([14], transaction: 2), bytes(response(2)), bytes(response(3)),
        ])
    let session = ReadSession(transport: USBTransport(io: io))
    try await session.open()

    let download = Task {
        try await session.download(handle: 101, expectedSize: UInt64(payloadSize)) {
            sink.append($0)
        }
    }
    await io.waitUntilPaused()
    download.cancel()
    await io.completePausedTransfer(
        with: USBTransfer(
            status: -7, transferred: 17, data: Data(repeating: 0x4A, count: 17)))
    await #expect(throws: CancellationError.self) { try await download.value }

    #expect(io.rawCancellationRecorder.value == 0)
    #expect(sink.value == 0)
    #expect(await io.closes == 1)
    #expect(await !session.isUsable)
    await #expect(throws: WireError.disconnected) { try await session.storageIDs() }
}

@Test func cancelledInFlightUploadTimeoutDisposesSession() async throws {
    let firstPayloadSize = 64 * 1024 - 12
    let bytesToUpload = Data(repeating: 0x4B, count: firstPayloadSize + 64 * 1024 + 1)
    let info = try ObjectInfo.uploadFile(
        storageID: 1, parent: 44, size: UInt64(bytesToUpload.count),
        filename: "cancel-timeout.bin")
    let source = UploadSource(bytesToUpload)
    let io = try PausedTransferIO(
        pauseAtSend: 5,
        reads: [
            bytes(response(0)), bytes(response(1, parameters: [1, 44, 58])),
            storageIDsTransfer([15], transaction: 3), bytes(response(3)), bytes(response(4)),
        ])
    let session = ReadSession(transport: USBTransport(io: io))
    try await session.open()

    let upload = Task {
        try await session.uploadObject(
            info: info, read: { source.read(maximum: $0) })
    }
    await io.waitUntilPaused()
    upload.cancel()
    await io.completePausedTransfer(
        with: USBTransfer(status: -7, transferred: 1_024, data: Data()))
    await #expect(throws: CancellationError.self) { try await upload.value }

    #expect(io.rawCancellationRecorder.value == 0)
    #expect(await io.closes == 1)
    #expect(await !session.isUsable)
    await #expect(throws: WireError.disconnected) { try await session.storageIDs() }
}

@Test func cancellationDuringFinalDownloadPayloadDrainsResponseWithoutCancel() async throws {
    let payloadSize = 64 * 1024
    let header = try ContainerHeader.data(
        code: 0x1009, transaction: 1, payloadLength: UInt64(payloadSize))
    let sink = Counter()
    let io = try PausedTransferIO(
        // OpenSession response, separate DATA header, then the sole/final
        // payload transfer. Its response follows as another bounded read.
        pauseAtReceive: 3,
        reads: [
            bytes(response(0)), bytes(header), bytes(Data(repeating: 0x48, count: payloadSize)),
            bytes(response(1)), storageIDsTransfer([12], transaction: 2),
            bytes(response(2)), bytes(response(3)),
        ])
    let session = ReadSession(transport: USBTransport(io: io))
    try await session.open()

    let download = Task {
        try await session.download(handle: 100, expectedSize: UInt64(payloadSize)) {
            sink.append($0)
        }
    }
    await io.waitUntilPaused()
    download.cancel()
    #expect(io.rawCancellationRecorder.value == 0)
    await io.completePausedTransfer()
    await #expect(throws: CancellationError.self) { try await download.value }

    #expect(await io.completedPausedTransfers == 1)
    #expect(io.rawCancellationRecorder.value == 0)
    #expect(sink.value == payloadSize)
    #expect(await session.isUsable)
    #expect(try await session.storageIDs() == [12])
    try await session.close()
    #expect(await io.closes == 1)
}

@Test func cancellationDuringFinalUploadPayloadDrainsResponseWithoutCancel() async throws {
    let firstPayloadSize = 64 * 1024 - 12
    let bytesToUpload = Data(repeating: 0x49, count: firstPayloadSize + 1)
    let info = try ObjectInfo.uploadFile(
        storageID: 1, parent: 44, size: UInt64(bytesToUpload.count),
        filename: "cancel-final.bin")
    let source = UploadSource(bytesToUpload)
    let io = try PausedTransferIO(
        // OpenSession, SendObjectInfo command/data, SendObject command, first
        // DATA transfer, then the final one-byte DATA-OUT transfer.
        pauseAtSend: 6,
        reads: [
            bytes(response(0)), bytes(response(1, parameters: [1, 44, 57])),
            bytes(response(2)), storageIDsTransfer([13], transaction: 3),
            bytes(response(3)), bytes(response(4)),
        ])
    let session = ReadSession(transport: USBTransport(io: io))
    try await session.open()

    let upload = Task {
        try await session.uploadObject(
            info: info, read: { source.read(maximum: $0) })
    }
    await io.waitUntilPaused()
    upload.cancel()
    #expect(io.rawCancellationRecorder.value == 0)
    await io.completePausedTransfer()
    await #expect(throws: CancellationError.self) { try await upload.value }

    let sent = await io.sent
    let completedFinalPayload = try #require(sent.dropFirst(5).first)
    #expect(completedFinalPayload == Data([0x49]))
    #expect(await io.completedPausedTransfers == 1)
    #expect(io.rawCancellationRecorder.value == 0)
    #expect(await session.isUsable)
    #expect(try await session.storageIDs() == [13])
    try await session.close()
    #expect(await io.closes == 1)
}

@Test(arguments: [0, 65, 65524])
func cancellationDuringCombinedFinalDownloadDrainsResponse(payloadSize: Int) async throws {
    let header = try ContainerHeader.data(
        code: 0x1009, transaction: 1, payloadLength: UInt64(payloadSize))
    let io = try PausedTransferIO(pauseAtReceive: 2, reads: [
        bytes(response(0)), bytes(header + Data(repeating: 0x48, count: payloadSize)),
        bytes(response(1)), storageIDsTransfer([12], transaction: 2),
        bytes(response(2)), bytes(response(3)),
    ])
    let session = ReadSession(transport: USBTransport(io: io))
    try await session.open()
    let download = Task {
        try await session.download(handle: 100, expectedSize: UInt64(payloadSize)) { _ in }
    }
    await io.waitUntilPaused()
    download.cancel()
    await io.completePausedTransfer()
    await #expect(throws: CancellationError.self) { try await download.value }
    // The whole payload arrived with its header. Cancelling the responder now
    // would target its response phase, even for an empty file.
    #expect(await session.isUsable)
    #expect(await session.cancellationNeedsPhysicalReconnect == false)
    #expect(try await session.storageIDs() == [12])
    try await session.close()
    #expect(await io.closes == 1)
}

@Test func cancellationFromFinalDownloadSinkDrainsResponse() async throws {
    let header = try ContainerHeader.data(code: 0x1009, transaction: 1, payloadLength: 65)
    let io = try PausedTransferIO(reads: [
        bytes(response(0)), bytes(header), bytes(Data(repeating: 0x48, count: 65)),
        bytes(response(1)), storageIDsTransfer([12], transaction: 2),
        bytes(response(2)), bytes(response(3)),
    ])
    let session = ReadSession(transport: USBTransport(io: io))
    try await session.open()
    await #expect(throws: CancellationError.self) {
        try await session.download(handle: 100, expectedSize: 65) { _ in throw CancellationError() }
    }
    #expect(await session.isUsable)
    #expect(await session.cancellationNeedsPhysicalReconnect == false)
    #expect(try await session.storageIDs() == [12])
    try await session.close()
    #expect(await io.closes == 1)
}

@Test func cancellationDuringFinalResponseReadNeedsNoProtocolCancellation() async throws {
    let io = try PausedTransferIO(
        // OpenSession response, StorageIDs DATA, then its final 12-byte
        // response. Cancellation happens only after that response read is in
        // flight, so completing it finishes the transaction on the wire.
        pauseAtReceive: 3,
        reads: [
            bytes(response(0)), storageIDsTransfer([21], transaction: 1), bytes(response(1)),
            storageIDsTransfer([22], transaction: 2), bytes(response(2)), bytes(response(3)),
        ])
    let session = ReadSession(transport: USBTransport(io: io))
    try await session.open()

    let command = Task { try await session.storageIDs() }
    await io.waitUntilPaused()
    command.cancel()
    #expect(io.rawCancellationRecorder.value == 0)
    await io.completePausedTransfer()
    await #expect(throws: CancellationError.self) { try await command.value }

    #expect(await io.completedPausedTransfers == 1)
    #expect(io.rawCancellationRecorder.value == 0)
    #expect(await session.isUsable)
    #expect(try await session.storageIDs() == [22])
    try await session.close()
    #expect(await io.closes == 1)
}

@Test func cancellationDuringFragmentedResponseDrainsItsPayload() async throws {
    let fragmentedResponse = try response(1, parameters: [0x1234_5678])
    let io = try PausedTransferIO(
        // OpenSession response, then a CloseSession response whose 12-byte
        // header and four-byte parameter arrive in separate USB transfers.
        pauseAtReceive: 2,
        reads: [
            bytes(response(0)), bytes(Data(fragmentedResponse.prefix(12))),
            bytes(Data(fragmentedResponse.dropFirst(12))),
        ])
    let session = ReadSession(transport: USBTransport(io: io))
    try await session.open()

    let close = Task { try await session.close() }
    await io.waitUntilPaused()
    close.cancel()
    await io.completePausedTransfer()
    await #expect(throws: CancellationError.self) { try await close.value }

    #expect(await io.receiveCount == 3)
    #expect(io.rawCancellationRecorder.value == 0)
    #expect(await !session.isUsable)
    #expect(await io.closes == 1)
}

@Test(arguments: ["read", "write", "zlp"])
func removedUSBHandleIsRetiredWithoutRecoveryIO(direction: String) async throws {
    let removed = USBTransfer(status: -4, transferred: 0, data: Data())
    let io = RawIO(reads: [removed], writes: direction == "zlp"
                   ? [USBTransfer(status: 0, transferred: 512, data: Data()), removed] : [removed])
    let log = DiagnosticLog()
    let transport = USBTransport(io: io, diagnostics: log)
    await #expect(throws: USBError.status(-4, transferred: 0)) {
        if direction == "read" { _ = try await transport.read(maxBytes: 65536) }
        else { try await transport.write(Data(count: direction == "zlp" ? 512 : 24)) }
    }
    // Even before the session calls abort, no other request can reuse it.
    await #expect(throws: USBError.status(-4, transferred: 0)) {
        try await transport.write(Data([1]))
    }
    await transport.abort(transaction: 18)
    await transport.abort(transaction: 18)
    await transport.close()
    #expect(await io.closes == 1)
    #expect(log.snapshot().events.contains {
        $0.kind == .recoveryDecision && $0.recoveryAction == .closeOnly && $0.failure == .disconnected
    })
    #expect(!log.snapshot().events.contains { $0.kind == .usbCancel || $0.kind == .usbDeviceReset })
}

@Test func appleStyleTransportNeverAttemptsCancelOrResetOnAbort() async throws {
    let io = RawIO(reads: [USBTransfer(status: -7, transferred: 0, data: Data())])
    let log = DiagnosticLog()
    let transport = USBTransport(io: io, diagnostics: log)
    await #expect(throws: USBError.status(-7, transferred: 0)) { _ = try await transport.read(maxBytes: 65536) }
    await transport.abort(transaction: 1)
    #expect(await io.closes == 1)
    #expect(log.snapshot().events.contains { $0.recoveryAction == .closeOnly })
}

@Test func unplugDuringFolderListingClosesSessionWithoutReset() async throws {
    let io = RawIO(reads: [bytes(try response(0))], writes: [
        USBTransfer(status: 0, transferred: 16, data: Data()),
        USBTransfer(status: -4, transferred: 0, data: Data()),
    ])
    let session = ReadSession(transport: USBTransport(io: io))
    try await session.open()
    await #expect(throws: USBError.status(-4, transferred: 0)) {
        _ = try await session.objectHandles(storageID: 1)
    }
    #expect(await !session.isUsable)
    #expect(await io.closes == 1)
}

@Test func successfulContinuationWritesAreBatchedWithoutLosingTotals() async throws {
    let io = RawIO(packet: 512)
    let log = DiagnosticLog()
    let transport = USBTransport(io: io, diagnostics: log)
    let chunk = Data(repeating: 7, count: 512)
    for _ in 0..<130 {
        try await transport.write(chunk, boundary: .continuesContainer)
    }
    await transport.close()

    let batches = log.snapshot().events.filter { $0.kind == .usbWrite }
    #expect(batches.map(\.sampleCount) == [64, 64, 2])
    #expect(batches.compactMap(\.bytes).reduce(0, +) == 130 * chunk.count)
}

@Test func diagnosticBatchesExcludeDisabledIntervals() async throws {
    let io = RawIO(packet: 512)
    let log = DiagnosticLog(recordingEnabled: false)
    let transport = USBTransport(io: io, diagnostics: log.forDevice())
    let chunk = Data(repeating: 7, count: 512)
    for _ in 0..<5 { try await transport.write(chunk, boundary: .continuesContainer) }
    #expect(log.snapshot().events.isEmpty)
    log.setRecordingEnabled(true)
    for _ in 0..<2 { try await transport.write(chunk, boundary: .continuesContainer) }
    log.setRecordingEnabled(false)
    for _ in 0..<3 { try await transport.write(chunk, boundary: .continuesContainer) }
    log.setRecordingEnabled(true)
    try await transport.write(chunk, boundary: .continuesContainer)
    await transport.close()
    let batches = log.snapshot().events.filter { $0.kind == .usbWrite }
    #expect(batches.map(\.sampleCount) == [1])
    #expect(batches.map(\.bytes) == [512])
}

private actor OpeningGate {
    private var observer: CheckedContinuation<Void, Never>?
    private var pending: CheckedContinuation<Void, Never>?
    func pause() async {
        await withCheckedContinuation { continuation in
            pending = continuation
            observer?.resume()
            observer = nil
        }
    }
    func waitUntilPaused() async {
        if pending != nil { return }
        await withCheckedContinuation { observer = $0 }
    }
    func resume() {
        pending?.resume()
        pending = nil
    }
}

@Test func cancelledConnectionClosesNewlyAcquiredInterface() async throws {
    let io = RawIO()
    let gate = OpeningGate()
    let log = DiagnosticLog()
    let opening = Task {
        try await USBTransport.opening(diagnostics: log) { _ in
            await gate.pause()
            return io
        }
    }
    await gate.waitUntilPaused()
    opening.cancel()
    await gate.resume()
    await #expect(throws: CancellationError.self) { try await opening.value }
    #expect(await io.closes == 1)
    #expect(await io.sent.isEmpty)
    #expect(await io.requests.isEmpty)
    #expect(log.snapshot().events.map(\.kind) == [.usbReleased])
}

@Test func cancelledConnectionDoesNotStartDeviceAccess() async throws {
    let gate = OpeningGate()
    let io = RawIO()
    let opening = Task {
        await gate.pause()
        return try await USBTransport.opening { _ in
            Issue.record("Cancelled connection must not invoke the device factory")
            return io
        }
    }
    await gate.waitUntilPaused()
    opening.cancel()
    await gate.resume()
    await #expect(throws: CancellationError.self) { try await opening.value }
    #expect(await io.closes == 0)
}
