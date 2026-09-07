import Foundation
import Testing

@testable import MTPWire

@Test func commandEncodingMatchesWireBytes() throws {
    let bytes = try ContainerHeader.command(code: 0x1002, transaction: 0, parameters: [1])
    #expect(bytes == Data([16, 0, 0, 0, 1, 0, 2, 16, 0, 0, 0, 0, 1, 0, 0, 0]))
    #expect(throws: WireError.invalidLength) {
        try ContainerHeader.command(
            code: 0x1002, transaction: 0, parameters: Array(repeating: 0, count: 6))
    }
}

@Test func stringsRoundTripIncludingSurrogatePairs() throws {
    for value in ["", "Camera", "日本語", "photo 📷", String(repeating: "a", count: 254)] {
        var writer = DatasetWriter()
        try writer.append(string: value)
        var reader = DatasetReader(writer.data)
        #expect(try reader.readString() == value)
        try reader.requireEnd()
    }
    var writer = DatasetWriter()
    #expect(throws: WireError.invalidString) {
        try writer.append(string: String(repeating: "a", count: 255))
    }
    for bytes: [UInt8] in [
        [2, 65, 0], [2, 65, 0, 1, 0], [2, 0, 216, 0, 0],
        [2, 0, 220, 0, 0], [3, 0, 216, 65, 0, 0, 0],
    ] {
        var reader = DatasetReader(Data(bytes))
        #expect(throws: (any Error).self) { try reader.readString() }
    }
}

@Test func numericBoundariesAndUntrustedArrayCounts() throws {
    var writer = DatasetWriter()
    writer.append(UInt64.max)
    var reader = DatasetReader(writer.data)
    #expect(try reader.readUInt64() == UInt64.max)
    reader = DatasetReader(Data([255, 255, 255, 255]))
    #expect(throws: WireError.truncated) { try reader.readUInt32Array() }
    reader = DatasetReader(Data([1, 0, 0, 0, 1]))
    #expect(throws: WireError.truncated) { try reader.readUInt16Array() }
}

@Test func generatedHeadersRoundTripAndRejectTruncation() throws {
    for index: UInt32 in 0..<512 {
        let header = try ContainerHeader(
            length: index + 12, type: .data, code: UInt16(index), transaction: UInt32.max - index)
        #expect(try ContainerHeader(data: header.encoded()) == header)
        for length in 0..<12 {
            #expect(throws: WireError.invalidLength) {
                try ContainerHeader(data: Data(header.encoded().prefix(length)))
            }
        }
    }
    #expect(throws: WireError.invalidLength) {
        try ContainerHeader(length: 11, type: .data, code: 0, transaction: 0)
    }
    #expect(throws: WireError.invalidLength) {
        try ContainerHeader(length: 33, type: .response, code: 0, transaction: 0)
    }
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
private func dataContainer(_ payload: Data, code: UInt16, transaction: UInt32) throws -> Data {
    try ContainerHeader(
        length: UInt32(12 + payload.count), type: .data, code: code, transaction: transaction
    )
    .encoded() + payload
}

struct ThumbnailWireTests {
    @Test func malformedRepresentativePropertyListPoisonsSession() async throws {
        var payload = DatasetWriter()
        payload.append(UInt32.max)
        let transport = try ScriptedTransport([
            .init(command: ContainerHeader.command(code: 0x1002, transaction: 0, parameters: [1]), reply: response(0)),
            .init(command: ContainerHeader.command(code: 0x9801, transaction: 1, parameters: [0xB982]),
                reply: dataContainer(payload.data, code: 0x9801, transaction: 1) + response(1)),
        ])
        let session = ReadSession(transport: transport)
        try await session.open()
        await #expect(throws: WireError.truncated) { try await session.objectPropertiesSupported(format: 0xB982) }
        #expect(await session.isUsable == false)
        #expect(await transport.closeCount == 1)
    }

    @Test(arguments: [2, 4, ReadSession.maximumThumbnailBytes + 1])
    func companionReadEnforcesActualSizeAndNeverAcceptsOversizedPayload(size: Int) async throws {
        let payload = Data(repeating: 0, count: size)
        let transport = try ScriptedTransport([
            .init(command: ContainerHeader.command(code: 0x1002, transaction: 0, parameters: [1]), reply: response(0)),
            .init(command: ContainerHeader.command(code: 0x1009, transaction: 1, parameters: [7]),
                reply: dataContainer(payload, code: 0x1009, transaction: 1) + response(1)),
        ])
        let session = ReadSession(transport: transport)
        try await session.open()
        for count in [UInt64(0), UInt64(ReadSession.maximumThumbnailBytes + 1)] {
            await #expect(throws: WireError.sizeLimit) { try await session.thumbnailFile(handle: 7, expectedSize: count) }
        }
        await #expect(throws: (any Error).self) { try await session.thumbnailFile(handle: 7, expectedSize: 3) }
        #expect(await session.isUsable == false)
        #expect(await transport.closeCount == 1)
    }

    @Test func fragmentedThumbnailAndInvalidHandles() async throws {
        let payload = Data([1, 2, 3, 4, 5])
        let transport = try ScriptedTransport([
            .init(command: ContainerHeader.command(code: 0x1002, transaction: 0, parameters: [1]), reply: response(0)),
            .init(command: ContainerHeader.command(code: 0x100A, transaction: 1, parameters: [7]),
                reply: dataContainer(payload, code: 0x100A, transaction: 1) + response(1)),
            .init(command: ContainerHeader.command(code: 0x1003, transaction: 2), reply: response(2)),
        ], fragmentSize: 1)
        let session = ReadSession(transport: transport)
        try await session.open()
        for handle: UInt32 in [0, UInt32.max] {
            await #expect(throws: WireError.invalidLength) { try await session.thumbnail(handle: handle) }
        }
        #expect(try await session.thumbnail(handle: 7) == payload)
        try await session.close()
        #expect(await transport.closeCount == 1)
    }

    @Test(arguments: [false, true]) func oversizedOrTruncatedThumbnailPoisonsSession(oversized: Bool) async throws {
        let size = oversized ? ReadSession.maximumThumbnailBytes + 1 : 10
        let header = try ContainerHeader(length: UInt32(12 + size), type: .data, code: 0x100A, transaction: 1)
        let transport = try ScriptedTransport([
            .init(command: ContainerHeader.command(code: 0x1002, transaction: 0, parameters: [1]), reply: response(0)),
            .init(command: ContainerHeader.command(code: 0x100A, transaction: 1, parameters: [7]), reply: header.encoded()),
        ])
        let session = ReadSession(transport: transport)
        try await session.open()
        await #expect(throws: (any Error).self) { try await session.thumbnail(handle: 7) }
        #expect(await session.isUsable == false)
        #expect(await transport.closeCount == 1)
        await #expect(throws: (any Error).self) { try await session.thumbnail(handle: 7) }
        #expect(await transport.closeCount == 1)
    }
}

private actor ScriptedTransport: MTPBulkTransport {
    struct Step: Sendable {
        let command: Data
        let reply: Data
    }
    private var steps: [Step]
    private var reply = Data()
    private let fragmentSize: Int
    private(set) var closed = false
    private(set) var closeCount = 0
    init(_ steps: [Step], fragmentSize: Int = 7) {
        self.steps = steps
        self.fragmentSize = fragmentSize
    }
    func write(_ data: Data) async throws {
        guard !closed, !steps.isEmpty, reply.isEmpty else { throw WireError.disconnected }
        let step = steps.removeFirst()
        guard data == step.command else { throw WireError.unexpectedContainer }
        reply = step.reply
    }
    func read(maxBytes: Int) async throws -> Data {
        let result = Data(reply.prefix(min(maxBytes, fragmentSize)))
        reply.removeFirst(result.count)
        return result
    }
    func close() async {
        closed = true
        closeCount += 1
    }

    func discardReplyForCancellation() { reply = Data() }
}

@Test func fragmentedSessionAndStorageExchange() async throws {
    var writer = DatasetWriter()
    writer.append(UInt32(2))
    writer.append(UInt32(1))
    writer.append(UInt32(65537))
    let transport = try ScriptedTransport([
        .init(
            command: ContainerHeader.command(code: 0x1002, transaction: 0, parameters: [1]),
            reply: response(0)),
        .init(
            command: ContainerHeader.command(code: 0x1004, transaction: 1),
            reply: dataContainer(writer.data, code: 0x1004, transaction: 1) + response(1)),
        .init(command: ContainerHeader.command(code: 0x1003, transaction: 2), reply: response(2)),
    ])
    let session = ReadSession(transport: transport)
    await #expect(throws: WireError.sessionRequired) { try await session.storageIDs() }
    try await session.open()
    #expect(try await session.storageIDs() == [1, 65537])
    try await session.close()
    #expect(await transport.closed)
}

@Test func openRecoversOneStaleAndroidSessionWithTransactionZero() async throws {
    let transport = try ScriptedTransport([
        .init(
            command: ContainerHeader.command(code: 0x1002, transaction: 0, parameters: [1]),
            // Android may report the retained session ID as a response parameter.
            reply: response(0, code: 0x201E, parameters: [77])),
        .init(
            command: ContainerHeader.command(code: 0x1003, transaction: 0),
            reply: response(0)),
        .init(
            command: ContainerHeader.command(code: 0x1002, transaction: 0, parameters: [1]),
            reply: response(0)),
        .init(
            command: ContainerHeader.command(code: 0x1003, transaction: 1),
            reply: response(1)),
    ])
    let session = ReadSession(transport: transport)
    try await session.open()
    #expect(await session.isUsable)
    try await session.close()
    #expect(await transport.closeCount == 1)
}

@Test func truncatedStaleSessionClosePoisonsAndReleasesExactlyOnce() async throws {
    let transport = try ScriptedTransport([
        .init(
            command: ContainerHeader.command(code: 0x1002, transaction: 0, parameters: [1]),
            reply: response(0, code: 0x201E)),
        .init(
            command: ContainerHeader.command(code: 0x1003, transaction: 0),
            reply: Data([1, 2, 3])),
    ])
    let session = ReadSession(transport: transport)
    await #expect(throws: (any Error).self) { try await session.open() }
    #expect(await !session.isUsable)
    #expect(await transport.closeCount == 1)
}

@Test func secondSessionAlreadyOpenResponseStopsWithoutLooping() async throws {
    let transport = try ScriptedTransport([
        .init(
            command: ContainerHeader.command(code: 0x1002, transaction: 0, parameters: [1]),
            reply: response(0, code: 0x201E)),
        .init(
            command: ContainerHeader.command(code: 0x1003, transaction: 0),
            reply: response(0)),
        .init(
            command: ContainerHeader.command(code: 0x1002, transaction: 0, parameters: [1]),
            reply: response(0, code: 0x201E)),
    ])
    let session = ReadSession(transport: transport)
    await #expect(throws: WireError.response(0x201E)) { try await session.open() }
    #expect(await !session.isUsable)
    #expect(await transport.closeCount == 1)
}

@Test func responseErrorsDoNotDesynchronizeSession() async throws {
    let transport = try ScriptedTransport(
        [
            .init(
                command: ContainerHeader.command(code: 0x1002, transaction: 0, parameters: [1]),
                reply: response(0)),
            .init(
                command: ContainerHeader.command(code: 0x1004, transaction: 1),
                reply: response(1, code: 0x2019)),
            .init(command: ContainerHeader.command(code: 0x1003, transaction: 2), reply: response(2)),
        ], fragmentSize: 64 * 1024)
    let session = ReadSession(transport: transport)
    try await session.open()
    await #expect(throws: WireError.response(0x2019)) { try await session.storageIDs() }
    try await session.close()
    #expect(await transport.closed)
}

@Test func standardAndVendorResponseRangesRemainRecoverable() async throws {
    for code: UInt16 in [0x2000, 0x2019, 0x2FFF, 0xA000, 0xA801, 0xAFFF] {
        let transport = try ScriptedTransport(
            [
                .init(
                    command: ContainerHeader.command(code: 0x1002, transaction: 0, parameters: [1]),
                    reply: response(0)),
                .init(
                    command: ContainerHeader.command(code: 0x1004, transaction: 1),
                    reply: response(1, code: code)),
                .init(command: ContainerHeader.command(code: 0x1003, transaction: 2), reply: response(2)),
            ], fragmentSize: 64 * 1024)
        let session = ReadSession(transport: transport)
        try await session.open()
        await #expect(throws: WireError.response(code)) { try await session.storageIDs() }
        #expect(await session.isUsable)
        try await session.close()
        #expect(await transport.closeCount == 1)
    }
}

@Test func nonResponseCodesPoisonSessionDespiteValidFraming() async throws {
    for code: UInt16 in [0x0000, 0x1004, 0x3000, 0x9000, 0xB000, 0xFFFF] {
        let transport = try ScriptedTransport([
            .init(
                command: ContainerHeader.command(code: 0x1002, transaction: 0, parameters: [1]),
                reply: response(0)),
            .init(
                command: ContainerHeader.command(code: 0x1004, transaction: 1),
                reply: response(1, code: code)),
        ])
        let session = ReadSession(transport: transport)
        try await session.open()
        await #expect(throws: WireError.unexpectedContainer) { try await session.storageIDs() }
        #expect(await !session.isUsable)
        #expect(await transport.closeCount == 1)
    }
}

@Test func transactionIDsWrapAndSkipReservedValues() async throws {
    var writer = DatasetWriter()
    writer.append(UInt32(0))
    let transport = try ScriptedTransport(
        [
            .init(
                command: ContainerHeader.command(code: 0x1002, transaction: 0, parameters: [1]),
                reply: response(0)),
            .init(
                command: ContainerHeader.command(code: 0x1004, transaction: UInt32.max - 1),
                reply: dataContainer(writer.data, code: 0x1004, transaction: UInt32.max - 1)
                    + response(UInt32.max - 1)),
            .init(
                command: ContainerHeader.command(code: 0x1004, transaction: 1),
                reply: dataContainer(writer.data, code: 0x1004, transaction: 1) + response(1)),
            .init(command: ContainerHeader.command(code: 0x1003, transaction: 2), reply: response(2)),
        ], fragmentSize: 64 * 1024)
    let session = ReadSession(transport: transport, startingTransaction: UInt32.max - 1)
    try await session.open()
    #expect(try await session.storageIDs().isEmpty)
    #expect(try await session.storageIDs().isEmpty)
    try await session.close()
    #expect(await transport.closeCount == 1)
}

@Test func wrongTransactionAndTruncatedRepliesPoisonSession() async throws {
    for reply in [try response(9), Data([1, 2, 3])] {
        let transport = try ScriptedTransport([
            .init(
                command: ContainerHeader.command(code: 0x1002, transaction: 0, parameters: [1]),
                reply: reply)
        ])
        let session = ReadSession(transport: transport)
        await #expect(throws: (any Error).self) { try await session.open() }
        #expect(await transport.closed)
        await #expect(throws: WireError.disconnected) { try await session.storageIDs() }
    }
}

@Test func malformedHeaderDiagnosticsKeepOnlySafeParsedFields() async throws {
    var malformed = DatasetWriter()
    malformed.append(UInt32(12))
    malformed.append(UInt16(99))
    malformed.append(UInt16(0x2001))
    malformed.append(UInt32(0x1234_5678))
    let transport = try ScriptedTransport([
        .init(
            command: ContainerHeader.command(code: 0x1002, transaction: 0, parameters: [1]),
            reply: malformed.data)
    ])
    let log = DiagnosticLog()
    let session = ReadSession(transport: transport, diagnostics: log)

    await #expect(throws: WireError.invalidType) { try await session.open() }

    let event = try #require(log.snapshot().events.first { $0.kind == .malformedHeader })
    #expect(event.failure == .invalidType)
    #expect(event.transaction == 0)
    #expect(event.containerLength == 12)
    #expect(event.containerType == 99)
    #expect(event.containerCode == 0x2001)
    #expect(event.containerTransaction == 0x1234_5678)
    #expect(event.sessionID != nil)
}

private final class ByteCounter: @unchecked Sendable {
    // The synchronous sink is invoked serially; NSLock also protects test access.
    private let lock = NSLock()
    private var value = 0
    private var peak = 0
    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        value += data.count
        peak = max(peak, data.count)
    }
    var snapshot: (Int, Int) {
        lock.lock()
        defer { lock.unlock() }
        return (value, peak)
    }
}

@Test func downloadStreamsBoundedChunksAndConsumesResponse() async throws {
    let payload = Data(repeating: 42, count: 2 * 1024 * 1024 + 13)
    let transport = try ScriptedTransport(
        [
            .init(
                command: ContainerHeader.command(code: 0x1002, transaction: 0, parameters: [1]),
                reply: response(0)),
            .init(
                command: ContainerHeader.command(code: 0x1009, transaction: 1, parameters: [10]),
                reply: dataContainer(payload, code: 0x1009, transaction: 1) + response(1)),
            .init(command: ContainerHeader.command(code: 0x1003, transaction: 2), reply: response(2)),
        ], fragmentSize: 65536)
    let session = ReadSession(transport: transport)
    try await session.open()
    let counter = ByteCounter()
    try await session.download(handle: 10) { counter.append($0) }
    #expect(counter.snapshot.0 == payload.count)
    #expect(counter.snapshot.1 <= 65536)
    try await session.close()
}

@Test func metadataAllocationLimitRejectsHugeClaimBeforeReadingPayload() async throws {
    let transport = try ScriptedTransport([
        .init(
            command: ContainerHeader.command(code: 0x1001, transaction: 0),
            reply: ContainerHeader(
                length: UInt32(ReadSession.metadataLimit + 13), type: .data, code: 0x1001, transaction: 0
            ).encoded())
    ])
    let session = ReadSession(transport: transport)
    await #expect(throws: WireError.sizeLimit) { try await session.deviceInfo() }
    #expect(await transport.closed)
}

@Test func closeReleasesTransportEvenWhenDeviceRejectsClose() async throws {
    let transport = try ScriptedTransport([
        .init(
            command: ContainerHeader.command(code: 0x1002, transaction: 0, parameters: [1]),
            reply: response(0)),
        .init(
            command: ContainerHeader.command(code: 0x1003, transaction: 1),
            reply: response(1, code: 0x2019)),
    ])
    let session = ReadSession(transport: transport)
    try await session.open()
    await #expect(throws: WireError.response(0x2019)) { try await session.close() }
    #expect(await transport.closed)
    await #expect(throws: WireError.disconnected) { try await session.storageIDs() }
}

@Test func sinkFailurePoisonsSessionAndClosesTransport() async throws {
    enum SinkFailure: Error { case diskFull }
    let transport = try ScriptedTransport([
        .init(
            command: ContainerHeader.command(code: 0x1002, transaction: 0, parameters: [1]),
            reply: response(0)),
        .init(
            command: ContainerHeader.command(code: 0x1009, transaction: 1, parameters: [10]),
            reply: dataContainer(Data([1, 2, 3]), code: 0x1009, transaction: 1) + response(1)),
    ])
    let session = ReadSession(transport: transport)
    try await session.open()
    await #expect(throws: SinkFailure.diskFull) {
        try await session.download(handle: 10) { _ in throw SinkFailure.diskFull }
    }
    #expect(await transport.closed)
    await #expect(throws: WireError.disconnected) { try await session.storageIDs() }
}

@Test func sinkCannotMasqueradeAsAFramedDeviceError() async throws {
    let transport = try ScriptedTransport([
        .init(
            command: ContainerHeader.command(code: 0x1002, transaction: 0, parameters: [1]),
            reply: response(0)),
        .init(
            command: ContainerHeader.command(code: 0x1009, transaction: 1, parameters: [10]),
            reply: dataContainer(Data([1]), code: 0x1009, transaction: 1) + response(1)),
    ])
    let session = ReadSession(transport: transport)
    try await session.open()
    await #expect(throws: WireError.response(0x2019)) {
        try await session.download(handle: 10) { _ in throw WireError.response(0x2019) }
    }
    #expect(await transport.closed)
    #expect(await !session.isUsable)
}

@Test func mismatchedDownloadSizeRejectedBeforeCallingSink() async throws {
    let transport = try ScriptedTransport([
        .init(
            command: ContainerHeader.command(code: 0x1002, transaction: 0, parameters: [1]),
            reply: response(0)),
        .init(
            command: ContainerHeader.command(code: 0x1009, transaction: 1, parameters: [10]),
            reply: dataContainer(Data([1, 2]), code: 0x1009, transaction: 1) + response(1)),
    ])
    let session = ReadSession(transport: transport)
    try await session.open()
    let counter = ByteCounter()
    await #expect(throws: WireError.objectSizeMismatch) {
        try await session.download(handle: 10, expectedSize: 1) { counter.append($0) }
    }
    #expect(counter.snapshot.0 == 0)
    #expect(await transport.closed)
}

@Test func malformedDatasetPoisonsSessionAfterValidFraming() async throws {
    let transport = try ScriptedTransport([
        .init(
            command: ContainerHeader.command(code: 0x1002, transaction: 0, parameters: [1]),
            reply: response(0)),
        .init(
            command: ContainerHeader.command(code: 0x1005, transaction: 1, parameters: [1]),
            reply: dataContainer(Data([1]), code: 0x1005, transaction: 1) + response(1)),
    ])
    let session = ReadSession(transport: transport)
    try await session.open()
    await #expect(throws: WireError.truncated) { try await session.storageInfo(storageID: 1) }
    #expect(await transport.closed)
    await #expect(throws: WireError.disconnected) { try await session.storageIDs() }
    try await session.close()
    try await session.close()
    #expect(await transport.closeCount == 1)
}

@Test func unsolicitedBulkBytesAfterResponseInvalidateSession() async throws {
    let transport = try ScriptedTransport(
        [
            .init(
                command: ContainerHeader.command(code: 0x1002, transaction: 0, parameters: [1]),
                reply: response(0) + Data([0xAB]))
        ], fragmentSize: 65536)
    let session = ReadSession(transport: transport)
    await #expect(throws: WireError.unexpectedContainer) { try await session.open() }
    #expect(await transport.closed)
}

private actor PausedTransport: MTPBulkTransport {
    let base: ScriptedTransport
    private let discardsInterruptedReply: Bool
    private var shouldPauseBeforeRead = false
    private var shouldPauseAfterRead = false
    private var blocked: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    private(set) var cancelledTransactions: [UInt32] = []
    init(base: ScriptedTransport, discardsInterruptedReply: Bool = false) {
        self.base = base
        self.discardsInterruptedReply = discardsInterruptedReply
    }
    func pauseNextRead() { shouldPauseBeforeRead = true }
    func pauseAfterNextRead() { shouldPauseAfterRead = true }
    func waitUntilBlocked() async {
        if blocked != nil { return }
        await withCheckedContinuation { observer = $0 }
    }
    func resume() {
        blocked?.resume()
        blocked = nil
    }
    func write(_ data: Data) async throws { try await base.write(data) }
    func read(maxBytes: Int) async throws -> Data {
        if shouldPauseBeforeRead {
            shouldPauseBeforeRead = false
            await pauseRead()
        }
        let result = try await base.read(maxBytes: maxBytes)
        if shouldPauseAfterRead {
            shouldPauseAfterRead = false
            await pauseRead()
        }
        return result
    }
    func abort(transaction: UInt32?) async {
        if let transaction { cancelledTransactions.append(transaction) }
        if discardsInterruptedReply { await base.discardReplyForCancellation() }
        await base.close()
    }
    func close() async { await base.close() }

    private func pauseRead() async {
        await withCheckedContinuation { continuation in
            blocked = continuation
            observer?.resume()
            observer = nil
        }
    }
}

private actor CancellationStartGate {
    private var blocked: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            blocked = continuation
            observer?.resume()
            observer = nil
        }
    }

    func waitUntilBlocked() async {
        if blocked != nil { return }
        await withCheckedContinuation { observer = $0 }
    }

    func release() {
        blocked?.resume()
        blocked = nil
    }
}

private actor CancellingAfterWriteTransport: MTPBulkTransport {
    let base: ScriptedTransport
    private var writesUntilCancellation: Int
    private(set) var cancelledTransactions: [UInt32] = []

    init(base: ScriptedTransport, cancellationWrite: Int) {
        self.base = base
        writesUntilCancellation = cancellationWrite
    }

    func write(_ data: Data) async throws {
        try await base.write(data)
        writesUntilCancellation -= 1
        if writesUntilCancellation == 0 {
            withUnsafeCurrentTask { $0?.cancel() }
        }
    }

    func read(maxBytes: Int) async throws -> Data {
        try await base.read(maxBytes: maxBytes)
    }

    func abort(transaction: UInt32?) async {
        if let transaction { cancelledTransactions.append(transaction) }
        await base.close()
    }

    func close() async { await base.close() }
}

@Test func cancellationBeforeReadCommandIsSentKeepsSessionUsable() async throws {
    var ids = DatasetWriter()
    ids.append(UInt32(1))
    ids.append(UInt32(7))
    let base = try ScriptedTransport([
        .init(
            command: ContainerHeader.command(code: 0x1002, transaction: 0, parameters: [1]),
            reply: response(0)),
        // The cancelled call reserves transaction 1 but never writes it.
        .init(
            command: ContainerHeader.command(code: 0x1004, transaction: 2),
            reply: dataContainer(ids.data, code: 0x1004, transaction: 2) + response(2)),
        .init(command: ContainerHeader.command(code: 0x1003, transaction: 3), reply: response(3)),
    ])
    let transport = PausedTransport(base: base)
    let session = ReadSession(transport: transport)
    try await session.open()

    let gate = CancellationStartGate()
    let command = Task {
        await gate.wait()
        return try await session.storageIDs()
    }
    await gate.waitUntilBlocked()
    command.cancel()
    await gate.release()
    await #expect(throws: CancellationError.self) { try await command.value }

    #expect(await transport.cancelledTransactions.isEmpty)
    #expect(await session.isUsable)
    #expect(try await session.storageIDs() == [7])
    try await session.close()
    #expect(await base.closeCount == 1)
}

@Test func cancellationAfterNoDataCommandWriteDoesNotCancelResponsePhase() async throws {
    let base = try ScriptedTransport(
        [
            .init(
                command: ContainerHeader.command(code: 0x1002, transaction: 0, parameters: [1]),
                reply: response(0)),
            .init(
                command: ContainerHeader.command(code: 0x1003, transaction: 1),
                reply: response(1, parameters: [42])),
        ], fragmentSize: 3)
    let transport = CancellingAfterWriteTransport(base: base, cancellationWrite: 2)
    let session = ReadSession(transport: transport)
    try await session.open()

    let closing = Task { try await session.close() }
    await #expect(throws: CancellationError.self) { try await closing.value }

    #expect(await transport.cancelledTransactions.isEmpty)
    #expect(await !session.isUsable)
    #expect(await base.closeCount == 1)
}

@Test func cancellationBeforeOutboundCommandIsSentKeepsSessionUsable() async throws {
    var ids = DatasetWriter()
    ids.append(UInt32(1))
    ids.append(UInt32(9))
    let info = try ObjectInfo.uploadDirectory(
        storageID: 1, parent: UInt32.max, filename: "Cancelled")
    let base = try ScriptedTransport([
        .init(
            command: ContainerHeader.command(code: 0x1002, transaction: 0, parameters: [1]),
            reply: response(0)),
        // The cancelled SendObjectInfo reserves transaction 1 but sends no bytes.
        .init(
            command: ContainerHeader.command(code: 0x1004, transaction: 2),
            reply: dataContainer(ids.data, code: 0x1004, transaction: 2) + response(2)),
        .init(command: ContainerHeader.command(code: 0x1003, transaction: 3), reply: response(3)),
    ])
    let transport = PausedTransport(base: base)
    let session = ReadSession(transport: transport)
    try await session.open()

    let gate = CancellationStartGate()
    let command = Task {
        await gate.wait()
        return try await session.createDirectory(info: info)
    }
    await gate.waitUntilBlocked()
    command.cancel()
    await gate.release()
    await #expect(throws: CancellationError.self) { try await command.value }

    #expect(await transport.cancelledTransactions.isEmpty)
    #expect(await session.isUsable)
    #expect(try await session.storageIDs() == [9])
    try await session.close()
    #expect(await base.closeCount == 1)
}

@Test func cancellationAfterCompleteResponseKeepsSessionUsable() async throws {
    var ids = DatasetWriter()
    ids.append(UInt32(1))
    ids.append(UInt32(11))
    let base = try ScriptedTransport(
        [
            .init(
                command: ContainerHeader.command(code: 0x1002, transaction: 0, parameters: [1]),
                reply: response(0)),
            .init(
                command: ContainerHeader.command(code: 0x1009, transaction: 1, parameters: [10]),
                reply: dataContainer(Data([1]), code: 0x1009, transaction: 1) + response(1)),
            .init(
                command: ContainerHeader.command(code: 0x1004, transaction: 2),
                reply: dataContainer(ids.data, code: 0x1004, transaction: 2) + response(2)),
            .init(command: ContainerHeader.command(code: 0x1003, transaction: 3), reply: response(3)),
        ], fragmentSize: 64 * 1024)
    let transport = PausedTransport(base: base)
    let session = ReadSession(transport: transport)
    try await session.open()

    let download = Task {
        try await session.download(handle: 10) { _ in
            // The response is already buffered behind this one-byte payload.
            // Cancelling here is observed only after that response is parsed.
            withUnsafeCurrentTask { $0?.cancel() }
        }
    }
    await #expect(throws: CancellationError.self) { try await download.value }

    #expect(await transport.cancelledTransactions.isEmpty)
    #expect(await session.isUsable)
    #expect(try await session.storageIDs() == [11])
    try await session.close()
    #expect(await base.closeCount == 1)
}

@Test func sessionStateRejectionsRequireFreshConnection() async throws {
    for code: UInt16 in [0x2003, 0x2004, 0x201E] {
        let transport = try ScriptedTransport([
            .init(
                command: ContainerHeader.command(code: 0x1002, transaction: 0, parameters: [1]),
                reply: response(0)),
            .init(
                command: ContainerHeader.command(code: 0x1004, transaction: 1),
                reply: response(1, code: code)
            ),
        ])
        let session = ReadSession(transport: transport)
        try await session.open()
        await #expect(throws: WireError.response(code)) { try await session.storageIDs() }
        #expect(await !session.isUsable)
        #expect(await transport.closeCount == 1)
    }
}

@Test func cancelledTransactionReleasesTransportAndRejectsConcurrentCommands() async throws {
    let base = try ScriptedTransport([
        .init(
            command: ContainerHeader.command(code: 0x1002, transaction: 0, parameters: [1]),
            reply: response(0)),
        .init(
            command: ContainerHeader.command(code: 0x1009, transaction: 1, parameters: [10]),
            reply: dataContainer(Data([1, 2, 3]), code: 0x1009, transaction: 1) + response(1)),
    ])
    let transport = PausedTransport(base: base)
    let session = ReadSession(transport: transport)
    try await session.open()
    await transport.pauseNextRead()
    let counter = ByteCounter()
    let task = Task { try await session.download(handle: 10) { counter.append($0) } }
    await transport.waitUntilBlocked()
    await #expect(throws: WireError.busy) { try await session.storageIDs() }
    await #expect(throws: WireError.busy) { try await session.close() }
    task.cancel()
    await transport.resume()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(counter.snapshot.0 == 0)
    #expect(await !session.isUsable)
    #expect(await base.closeCount == 1)
    try await session.close()
    #expect(await base.closeCount == 1)
}

@Test func interruptedDownloadCancellationDisposesSession() async throws {
    var ids = DatasetWriter()
    ids.append(UInt32(1))
    ids.append(UInt32(7))
    let base = try ScriptedTransport([
        .init(
            command: ContainerHeader.command(code: 0x1002, transaction: 0, parameters: [1]),
            reply: response(0)),
        .init(
            command: ContainerHeader.command(code: 0x1009, transaction: 1, parameters: [10]),
            reply: dataContainer(Data([1, 2, 3]), code: 0x1009, transaction: 1) + response(1)),
        .init(
            command: ContainerHeader.command(code: 0x1004, transaction: 2),
            reply: dataContainer(ids.data, code: 0x1004, transaction: 2) + response(2)),
        .init(command: ContainerHeader.command(code: 0x1003, transaction: 3), reply: response(3)),
    ])
    let transport = PausedTransport(base: base, discardsInterruptedReply: true)
    let session = ReadSession(transport: transport)
    try await session.open()
    await transport.pauseNextRead()
    let task = Task { try await session.download(handle: 10) { _ in } }
    await transport.waitUntilBlocked()
    task.cancel()
    await transport.resume()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(await transport.cancelledTransactions == [1])
    #expect(await !session.isUsable)
    await #expect(throws: WireError.disconnected) { try await session.storageIDs() }
    #expect(await base.closeCount == 1)
}

@Test func cancellationDuringFragmentedDirectResponseDrainsWithoutCancelRequest() async throws {
    var ids = DatasetWriter()
    ids.append(UInt32(1))
    ids.append(UInt32(17))
    let base = try ScriptedTransport(
        [
            .init(
                command: ContainerHeader.command(code: 0x1002, transaction: 0, parameters: [1]),
                reply: response(0)),
            .init(
                command: ContainerHeader.command(code: 0x1004, transaction: 1),
                reply: response(1, code: 0x2019, parameters: [42])),
            .init(
                command: ContainerHeader.command(code: 0x1004, transaction: 2),
                reply: dataContainer(ids.data, code: 0x1004, transaction: 2) + response(2)),
            .init(command: ContainerHeader.command(code: 0x1003, transaction: 3), reply: response(3)),
        ], fragmentSize: 3)
    let transport = PausedTransport(base: base, discardsInterruptedReply: true)
    let session = ReadSession(transport: transport)
    try await session.open()

    await transport.pauseAfterNextRead()
    let command = Task { try await session.storageIDs() }
    await transport.waitUntilBlocked()
    command.cancel()
    await transport.resume()
    await #expect(throws: WireError.response(0x2019)) { try await command.value }

    #expect(await transport.cancelledTransactions.isEmpty)
    #expect(await session.isUsable)
    #expect(try await session.storageIDs() == [17])
    try await session.close()
    #expect(await base.closeCount == 1)
}

@Test func cancellationDuringFragmentedDataHeaderDisposesSession() async throws {
    var ids = DatasetWriter()
    ids.append(UInt32(1))
    ids.append(UInt32(23))
    let base = try ScriptedTransport(
        [
            .init(
                command: ContainerHeader.command(code: 0x1002, transaction: 0, parameters: [1]),
                reply: response(0)),
            .init(
                command: ContainerHeader.command(code: 0x1009, transaction: 1, parameters: [10]),
                reply: dataContainer(Data([1, 2, 3]), code: 0x1009, transaction: 1) + response(1)),
            .init(
                command: ContainerHeader.command(code: 0x1004, transaction: 2),
                reply: dataContainer(ids.data, code: 0x1004, transaction: 2) + response(2)),
            .init(command: ContainerHeader.command(code: 0x1003, transaction: 3), reply: response(3)),
        ], fragmentSize: 3)
    let transport = PausedTransport(base: base, discardsInterruptedReply: true)
    let session = ReadSession(transport: transport)
    try await session.open()

    await transport.pauseAfterNextRead()
    let counter = ByteCounter()
    let download = Task { try await session.download(handle: 10) { counter.append($0) } }
    await transport.waitUntilBlocked()
    download.cancel()
    await transport.resume()
    await #expect(throws: CancellationError.self) { try await download.value }

    #expect(counter.snapshot.0 == 0)
    #expect(await transport.cancelledTransactions == [1])
    #expect(await !session.isUsable)
    await #expect(throws: WireError.disconnected) { try await session.storageIDs() }
    #expect(await base.closeCount == 1)
}

@Test func robustnessEveryDownloadTruncationPoisonsAndReleasesExactlyOnce() async throws {
    let complete =
        try dataContainer(Data(repeating: 0x5A, count: 33), code: 0x1009, transaction: 1)
        + response(1)
    for cut in 0..<complete.count {
        for fragment in [1, 7, 65536] {
            let log = DiagnosticLog()
            let transport = try ScriptedTransport(
                [
                    .init(
                        command: ContainerHeader.command(code: 0x1002, transaction: 0, parameters: [1]),
                        reply: response(0)),
                    .init(
                        command: ContainerHeader.command(code: 0x1009, transaction: 1, parameters: [10]),
                        reply: Data(complete.prefix(cut))),
                ], fragmentSize: fragment)
            let session = ReadSession(transport: transport, diagnostics: log)
            try await session.open()
            await #expect(throws: WireError.truncated) { try await session.download(handle: 10) { _ in } }
            #expect(await !session.isUsable)
            await #expect(throws: WireError.disconnected) {
                try await session.download(handle: 10) { _ in }
            }
            try await session.close()
            try await session.close()
            #expect(await transport.closeCount == 1)
            let failures = log.snapshot().events.filter { $0.kind == .transaction && $0.failure != nil }
            #expect(failures.count == 1)
            #expect(failures.first?.operation == 0x1009)
            #expect(failures.first?.failure == .truncated)
        }
    }
}

@Test func robustnessCommandFailureIsNotReplayed() async throws {
    // No scripted write available: fail before any reply exists.
    let transport = ScriptedTransport([])
    let log = DiagnosticLog()
    let session = ReadSession(transport: transport, diagnostics: log)
    await #expect(throws: WireError.disconnected) { try await session.open() }
    await #expect(throws: WireError.disconnected) { try await session.open() }
    try await session.close()
    #expect(await transport.closeCount == 1)
    #expect(log.snapshot().events.filter { $0.kind == .transaction }.count == 1)
}

@Test func robustnessRepeatedConnectionsTransfersAndRecoverableErrors() async throws {
    let log = DiagnosticLog(capacity: 32)
    for cycle in 0..<64 {
        var steps: [ScriptedTransport.Step] = [
            try .init(
                command: ContainerHeader.command(code: 0x1002, transaction: 0, parameters: [1]),
                reply: response(0))
        ]
        for transaction: UInt32 in 1...8 {
            let reply =
                transaction == 4
                ? try response(transaction, code: 0x2019)
                : try dataContainer(Data([UInt8(cycle)]), code: 0x1009, transaction: transaction)
                    + response(transaction)
            steps.append(
                try .init(
                    command: ContainerHeader.command(
                        code: 0x1009, transaction: transaction, parameters: [10]),
                    reply: reply))
        }
        steps.append(
            try .init(command: ContainerHeader.command(code: 0x1003, transaction: 9), reply: response(9)))
        let transport = ScriptedTransport(steps, fragmentSize: (cycle % 13) + 1)
        let session = ReadSession(transport: transport, diagnostics: log)
        try await session.open()
        for transaction in 1...8 {
            if transaction == 4 {
                await #expect(throws: WireError.response(0x2019)) {
                    try await session.download(handle: 10) { _ in }
                }
            } else {
                try await session.download(handle: 10) { data in #expect(data == Data([UInt8(cycle)])) }
            }
            #expect(await session.isUsable)
        }
        try await session.close()
        #expect(await transport.closeCount == 1)
    }
    #expect(log.snapshot().events.count == 32)
    #expect(log.snapshot().discardedEvents > 0)
}

@Test func robustnessCancelledFinalResponseCannotReportSuccess() async throws {
    let base = try ScriptedTransport(
        [
            .init(
                command: ContainerHeader.command(code: 0x1002, transaction: 0, parameters: [1]),
                reply: response(0))
        ], fragmentSize: 65536)
    let transport = PausedTransport(base: base)
    let log = DiagnosticLog()
    let session = ReadSession(transport: transport, diagnostics: log)
    await transport.pauseNextRead()
    let task = Task { try await session.open() }
    await transport.waitUntilBlocked()
    task.cancel()
    await transport.resume()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(await !session.isUsable)
    #expect(await base.closeCount == 1)
    #expect(log.snapshot().events.first?.failure == .cancelled)
}

@Test func robustnessSlowResponseCanCompleteWithoutReplay() async throws {
    let base = try ScriptedTransport([
        .init(
            command: ContainerHeader.command(code: 0x1002, transaction: 0, parameters: [1]),
            reply: response(0)),
        .init(command: ContainerHeader.command(code: 0x1003, transaction: 1), reply: response(1)),
    ])
    let transport = PausedTransport(base: base)
    let session = ReadSession(transport: transport)
    await transport.pauseNextRead()
    let task = Task { try await session.open() }
    await transport.waitUntilBlocked()
    await #expect(throws: WireError.busy) { try await session.open() }
    await transport.resume()
    try await task.value
    #expect(await session.isUsable)
    try await session.close()
    #expect(await base.closeCount == 1)
}

@Test func commandCannotEnterWhileSessionIsOpening() async throws {
    let base = try ScriptedTransport([
        .init(
            command: ContainerHeader.command(code: 0x1002, transaction: 0, parameters: [1]),
            reply: response(0)),
        .init(command: ContainerHeader.command(code: 0x1003, transaction: 1), reply: response(1)),
    ])
    let transport = PausedTransport(base: base)
    let session = ReadSession(transport: transport)
    await transport.pauseNextRead()
    let opening = Task { try await session.open() }
    await transport.waitUntilBlocked()
    await #expect(throws: WireError.busy) { try await session.deviceInfo() }
    await transport.resume()
    try await opening.value
    #expect(await session.isUsable)
    try await session.close()
    #expect(await base.closeCount == 1)
}

@Test(arguments: [UInt32(0), 1, 65536, ReadSession.maximumPartialObjectBytes])
func partialObjectChecksBoundariesAndConsumesCountedResponse(count: UInt32) async throws {
    let offset = count == 0 ? 0 : UInt32.max - count + 1
    let payload = Data(repeating: 0x42, count: Int(count))
    let transport = try ScriptedTransport([
        .init(command: ContainerHeader.command(code: 0x1002, transaction: 0, parameters: [1]), reply: response(0)),
        .init(command: ContainerHeader.command(code: 0x101B, transaction: 1, parameters: [10, offset, count]),
            reply: dataContainer(payload, code: 0x101B, transaction: 1) + response(1, parameters: [count])),
        .init(command: ContainerHeader.command(code: 0x1003, transaction: 2), reply: response(2)),
    ], fragmentSize: 65536)
    let session = ReadSession(transport: transport)
    try await session.open()
    await #expect(throws: WireError.invalidLength) { try await session.partialObject(handle: 0, offset: 0, count: 1) }
    await #expect(throws: WireError.invalidLength) { try await session.partialObject(handle: UInt32.max, offset: 0, count: 1) }
    await #expect(throws: WireError.invalidLength) { try await session.partialObject(handle: 10, offset: UInt32.max, count: 2) }
    await #expect(throws: WireError.invalidLength) { try await session.partialObject(handle: 10, offset: 0, count: ReadSession.maximumPartialObjectBytes + 1) }
    #expect(try await session.partialObject(handle: 10, offset: offset, count: count) == payload)
    #expect(await session.isUsable)
    try await session.close()
}

@Test(arguments: [[UInt32](), [2], [1, 99]])
func partialObjectRejectsMissingOrWrongResponseCount(parameters: [UInt32]) async throws {
    let transport = try ScriptedTransport([
        .init(command: ContainerHeader.command(code: 0x1002, transaction: 0, parameters: [1]), reply: response(0)),
        .init(command: ContainerHeader.command(code: 0x101B, transaction: 1, parameters: [10, 0, 1]),
            reply: dataContainer(Data([42]), code: 0x101B, transaction: 1) + response(1, parameters: parameters)),
    ])
    let session = ReadSession(transport: transport)
    try await session.open()
    await #expect(throws: WireError.objectSizeMismatch) { try await session.partialObject(handle: 10, offset: 0, count: 1) }
    #expect(await !session.isUsable)
    #expect(await transport.closeCount == 1)
}

@Test(arguments: [0, 3, 5])
func partialObjectRejectsUnexpectedDataLength(length: Int) async throws {
    let transport = try ScriptedTransport([
        .init(command: ContainerHeader.command(code: 0x1002, transaction: 0, parameters: [1]), reply: response(0)),
        .init(command: ContainerHeader.command(code: 0x101B, transaction: 1, parameters: [10, 0, 4]),
            reply: dataContainer(Data(repeating: 42, count: length), code: 0x101B, transaction: 1) + response(1, parameters: [4])),
    ])
    let session = ReadSession(transport: transport)
    try await session.open()
    await #expect(throws: (any Error).self) { try await session.partialObject(handle: 10, offset: 0, count: 4) }
    #expect(await !session.isUsable)
    #expect(await transport.closeCount == 1)
}
