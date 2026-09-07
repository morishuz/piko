import Foundation
import Testing

@testable import MTPWire

private func uploadResponse(
    _ transaction: UInt32, code: UInt16 = 0x2001, parameters: [UInt32] = []
) throws -> Data {
    let header = try ContainerHeader(
        length: UInt32(12 + parameters.count * 4), type: .response,
        code: code, transaction: transaction)
    var writer = DatasetWriter()
    for parameter in parameters { writer.append(parameter) }
    return header.encoded() + writer.data
}

private func uploadDataContainer(
    _ payload: Data, code: UInt16, transaction: UInt32
) throws -> Data {
    try ContainerHeader.data(
        code: code, transaction: transaction, payloadLength: UInt64(payload.count)) + payload
}

private actor UploadScriptTransport: MTPBulkTransport {
    struct ExpectedWrite: Sendable {
        let data: Data
        let boundary: BulkWriteBoundary
        let reply: Data

        init(
            _ data: Data, boundary: BulkWriteBoundary = .endsContainer,
            reply: Data = Data()
        ) {
            self.data = data
            self.boundary = boundary
            self.reply = reply
        }
    }

    private var expected: [ExpectedWrite]
    private var reply = Data()
    private let fragmentSize: Int
    private(set) var closed = false
    private(set) var closeCount = 0
    private(set) var writeCount = 0

    init(_ expected: [ExpectedWrite], fragmentSize: Int = 11) {
        self.expected = expected
        self.fragmentSize = fragmentSize
    }

    func write(_ data: Data) async throws {
        try accept(data, boundary: .endsContainer)
    }

    func write(_ data: Data, boundary: BulkWriteBoundary) async throws {
        try accept(data, boundary: boundary)
    }

    private func accept(_ data: Data, boundary: BulkWriteBoundary) throws {
        writeCount += 1
        guard !closed, reply.isEmpty, !expected.isEmpty else { throw WireError.disconnected }
        let next = expected.removeFirst()
        guard data == next.data, boundary == next.boundary else {
            throw WireError.unexpectedContainer
        }
        reply = next.reply
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

    func discardNextWriteForCancellation() {
        if !expected.isEmpty { expected.removeFirst() }
        reply = Data()
    }

    var consumedAllWrites: Bool { expected.isEmpty }
}

/// Models a USB-aware transport where each supplied reply element is one
/// underlying bulk transfer. Unlike `UploadScriptTransport`, read fragmentation
/// therefore has protocol significance.
private actor TransferBoundaryTransport: MTPBulkTransport {
    nonisolated var preservesReadTransferBoundaries: Bool { true }

    struct ExpectedWrite: Sendable {
        let data: Data
        let boundary: BulkWriteBoundary
        let replyTransfers: [Data]

        init(
            _ data: Data, boundary: BulkWriteBoundary = .endsContainer,
            replyTransfers: [Data] = []
        ) {
            self.data = data
            self.boundary = boundary
            self.replyTransfers = replyTransfers
        }
    }

    private var expected: [ExpectedWrite]
    private var replyTransfers: [Data] = []
    private(set) var closeCount = 0

    init(_ expected: [ExpectedWrite]) { self.expected = expected }

    func write(_ data: Data) async throws { try accept(data, boundary: .endsContainer) }

    func write(_ data: Data, boundary: BulkWriteBoundary) async throws {
        try accept(data, boundary: boundary)
    }

    private func accept(_ data: Data, boundary: BulkWriteBoundary) throws {
        guard replyTransfers.isEmpty, !expected.isEmpty else { throw WireError.disconnected }
        let next = expected.removeFirst()
        guard data == next.data, boundary == next.boundary else {
            throw WireError.unexpectedContainer
        }
        replyTransfers = next.replyTransfers
    }

    func read(maxBytes: Int) async throws -> Data { try nextTransfer(maxBytes: maxBytes) }

    func readBulk(maxBytes: Int) async throws -> BulkRead {
        .bytes(try nextTransfer(maxBytes: maxBytes))
    }

    private func nextTransfer(maxBytes: Int) throws -> Data {
        guard !replyTransfers.isEmpty else { return Data() }
        let result = replyTransfers.removeFirst()
        guard result.count <= maxBytes else { throw WireError.sizeLimit }
        return result
    }

    func close() async { closeCount += 1 }
    var consumedAllWrites: Bool { expected.isEmpty }
}

private func storageIDsPayload(_ ids: [UInt32]) -> Data {
    var writer = DatasetWriter()
    writer.append(UInt32(ids.count))
    for id in ids { writer.append(id) }
    return writer.data
}

private final class UploadReader: @unchecked Sendable {
    private let lock = NSLock()
    private let bytes: Data
    private let maximumFragment: Int
    private var position = 0
    private(set) var requests: [Int] = []

    init(_ bytes: Data, maximumFragment: Int = .max) {
        self.bytes = bytes
        self.maximumFragment = maximumFragment
    }

    func read(maximum: Int) -> Data {
        lock.lock()
        defer { lock.unlock() }
        requests.append(maximum)
        guard position < bytes.count else { return Data() }
        let count = min(maximum, maximumFragment, bytes.count - position)
        let result = Data(bytes[position..<(position + count)])
        position += count
        return result
    }
}

private final class UploadProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UInt64] = []
    func record(_ value: UInt64) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }
    var snapshot: [UInt64] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

@Test func uploadObjectInfoFactoriesEncodeStandardFileAndFolderDatasets() throws {
    let file = try ObjectInfo.uploadFile(
        storageID: 0x0001_0001, parent: UInt32.max, size: 123,
        filename: "photo 📷.jpg", modificationDate: "20260902T230400")
    #expect(file.storageID == 0x0001_0001)
    #expect(file.format == 0x3000)
    #expect(file.compressedSize == 123)
    #expect(file.parent == 0)
    #expect(file.associationType == 0)
    #expect(try ObjectInfo(data: file.encoded()) == file)

    let directory = try ObjectInfo.uploadDirectory(
        storageID: 0x0001_0001, parent: 77, filename: "Documents")
    #expect(directory.format == 0x3001)
    #expect(directory.compressedSize == 0)
    #expect(directory.parent == 77)
    #expect(directory.associationType == 1)
    #expect(try ObjectInfo(data: directory.encoded()) == directory)

    // Fifteen numeric fields precede the four PTP strings.
    #expect(try file.encoded().count >= 52 + 4)
}

@Test func uploadObjectInfoRejectsUnsafeNamesStringsStorageAndExtendedSizes() throws {
    for name in ["", ".", "..", "a/b", "a\0b", String(repeating: "a", count: 255)] {
        #expect(throws: (any Error).self) {
            try ObjectInfo.uploadFile(storageID: 1, parent: UInt32.max, size: 1, filename: name)
        }
    }
    // The limit is UTF-16 code units, not Character count.
    _ = try ObjectInfo.uploadFile(
        storageID: 1, parent: UInt32.max, size: 1,
        filename: String(repeating: "📷", count: 127))
    #expect(throws: WireError.invalidString) {
        try ObjectInfo.uploadFile(
            storageID: 1, parent: UInt32.max, size: 1,
            filename: String(repeating: "📷", count: 128))
    }
    for storageID in [UInt32(0), UInt32.max] {
        #expect(throws: WireError.invalidLength) {
            try ObjectInfo.uploadDirectory(
                storageID: storageID, parent: UInt32.max, filename: "Folder")
        }
    }
    #expect(throws: WireError.sizeLimit) {
        try ObjectInfo.uploadFile(
            storageID: 1, parent: UInt32.max,
            size: ObjectInfo.maximumOrdinaryObjectSize + 1, filename: "large.bin")
    }
}

@Test func responseParserRetainsParametersAndObjectCreationRequiresExactlyThree() throws {
    let encoded = try uploadResponse(9, parameters: [1, 0, 42])
    let header = try ContainerHeader(data: Data(encoded.prefix(12)))
    let response = try MTPResponse(header: header, payload: Data(encoded.dropFirst(12)))
    #expect(response.code == 0x2001)
    #expect(response.transaction == 9)
    #expect(response.parameters == [1, 0, 42])
    #expect(try ObjectCreationResult(response: response).handle == 42)

    for parameters in [[UInt32](), [1, 0], [1, 0, 42, 99]] {
        let bytes = try uploadResponse(9, parameters: parameters)
        let parsed = try MTPResponse(
            header: ContainerHeader(data: Data(bytes.prefix(12))),
            payload: Data(bytes.dropFirst(12)))
        #expect(throws: WireError.invalidLength) {
            try ObjectCreationResult(response: parsed)
        }
    }
}

@Test func createDirectoryUsesRootCommandSentinelAndNoSendObject() async throws {
    let info = try ObjectInfo.uploadDirectory(
        storageID: 1, parent: UInt32.max, filename: "Empty")
    let transport = try UploadScriptTransport([
        .init(
            ContainerHeader.command(code: 0x1002, transaction: 0, parameters: [1]),
            reply: uploadResponse(0)),
        .init(ContainerHeader.command(code: 0x100C, transaction: 1, parameters: [1, UInt32.max])),
        .init(
            uploadDataContainer(info.encoded(), code: 0x100C, transaction: 1),
            reply: uploadResponse(1, parameters: [1, 0, 50])),
        .init(ContainerHeader.command(code: 0x1003, transaction: 2), reply: uploadResponse(2)),
    ])
    let session = ReadSession(transport: transport)
    try await session.open()
    #expect(try await session.createDirectory(info: info).handle == 50)
    try await session.close()
    #expect(await transport.consumedAllWrites)
    #expect(await transport.closeCount == 1)
}

@Test func uploadSmallAndZeroByteObjectsUseAdjacentTransactions() async throws {
    for bytes in [Data("abc".utf8), Data()] {
        let info = try ObjectInfo.uploadFile(
            storageID: 1, parent: 44, size: UInt64(bytes.count), filename: "small.bin")
        let transport = try UploadScriptTransport([
            .init(
                ContainerHeader.command(code: 0x1002, transaction: 0, parameters: [1]),
                reply: uploadResponse(0)),
            .init(ContainerHeader.command(code: 0x100C, transaction: 1, parameters: [1, 44])),
            .init(
                uploadDataContainer(info.encoded(), code: 0x100C, transaction: 1),
                reply: uploadResponse(1, parameters: [1, 44, 51])),
            .init(ContainerHeader.command(code: 0x100D, transaction: 2)),
            .init(
                uploadDataContainer(bytes, code: 0x100D, transaction: 2),
                reply: uploadResponse(2)),
            .init(ContainerHeader.command(code: 0x1003, transaction: 3), reply: uploadResponse(3)),
        ])
        let session = ReadSession(transport: transport)
        let reader = UploadReader(bytes)
        let progress = UploadProgressRecorder()
        try await session.open()
        let created = try await session.uploadObject(
            info: info, read: { reader.read(maximum: $0) },
            progress: { progress.record($0) })
        #expect(created.storageID == 1)
        #expect(created.parent == 44)
        #expect(created.handle == 51)
        #expect(progress.snapshot == [UInt64(bytes.count)])
        try await session.close()
        #expect(await transport.consumedAllWrites)
    }
}

@Test func uploadStreamsFullIntermediateChunksAndOnlyFinalBoundaryEndsContainer() async throws {
    let firstPayload = 64 * 1024 - 12
    let bytes = Data((0..<(firstPayload + 64 * 1024 + 7)).map { UInt8(truncatingIfNeeded: $0) })
    let info = try ObjectInfo.uploadFile(
        storageID: 1, parent: 44, size: UInt64(bytes.count), filename: "stream.bin")
    let first = try ContainerHeader.data(
        code: 0x100D, transaction: 2, payloadLength: UInt64(bytes.count))
        + Data(bytes.prefix(firstPayload))
    let middleStart = firstPayload
    let middleEnd = middleStart + 64 * 1024
    let middle = Data(bytes[middleStart..<middleEnd])
    let last = Data(bytes[middleEnd...])
    let transport = try UploadScriptTransport([
        .init(
            ContainerHeader.command(code: 0x1002, transaction: 0, parameters: [1]),
            reply: uploadResponse(0)),
        .init(ContainerHeader.command(code: 0x100C, transaction: 1, parameters: [1, 44])),
        .init(
            uploadDataContainer(info.encoded(), code: 0x100C, transaction: 1),
            reply: uploadResponse(1, parameters: [1, 44, 52])),
        .init(ContainerHeader.command(code: 0x100D, transaction: 2)),
        .init(first, boundary: .continuesContainer),
        .init(middle, boundary: .continuesContainer),
        .init(last, boundary: .endsContainer, reply: uploadResponse(2)),
        .init(ContainerHeader.command(code: 0x1003, transaction: 3), reply: uploadResponse(3)),
    ])
    let session = ReadSession(transport: transport)
    let reader = UploadReader(bytes, maximumFragment: 7_003)
    let progress = UploadProgressRecorder()
    try await session.open()
    _ = try await session.uploadObject(
        info: info, read: { reader.read(maximum: $0) },
        progress: { progress.record($0) })
    #expect(progress.snapshot == [UInt64(firstPayload), UInt64(middleEnd), UInt64(bytes.count)])
    try await session.close()
    #expect(await transport.consumedAllWrites)
}

@Test func boundaryAwareCombinedHeaderModeIsMirroredForUpload() async throws {
    let storage = storageIDsPayload([1])
    let bytes = Data([1, 2, 3])
    let info = try ObjectInfo.uploadFile(
        storageID: 1, parent: 44, size: UInt64(bytes.count), filename: "combined.bin")
    let transport = try TransferBoundaryTransport([
        .init(
            ContainerHeader.command(code: 0x1002, transaction: 0, parameters: [1]),
            replyTransfers: [uploadResponse(0)]),
        .init(
            ContainerHeader.command(code: 0x1004, transaction: 1),
            replyTransfers: [
                uploadDataContainer(storage, code: 0x1004, transaction: 1), uploadResponse(1),
            ]),
        .init(ContainerHeader.command(code: 0x100C, transaction: 2, parameters: [1, 44])),
        .init(
            uploadDataContainer(info.encoded(), code: 0x100C, transaction: 2),
            replyTransfers: [uploadResponse(2, parameters: [1, 44, 60])]),
        .init(ContainerHeader.command(code: 0x100D, transaction: 3)),
        .init(
            uploadDataContainer(bytes, code: 0x100D, transaction: 3),
            replyTransfers: [uploadResponse(3)]),
        .init(
            ContainerHeader.command(code: 0x1003, transaction: 4),
            replyTransfers: [uploadResponse(4)]),
    ])
    let session = ReadSession(transport: transport)
    let reader = UploadReader(bytes)
    try await session.open()
    #expect(try await session.storageIDs() == [1])
    _ = try await session.uploadObject(info: info, read: { reader.read(maximum: $0) })
    try await session.close()
    #expect(await transport.consumedAllWrites)
}

@Test func boundaryAwareSeparateHeaderModeIsMirroredForChunkedUpload() async throws {
    let storage = storageIDsPayload([1])
    let storageHeader = try ContainerHeader.data(
        code: 0x1004, transaction: 1, payloadLength: UInt64(storage.count))
    let bytes = Data((0..<(64 * 1024 + 7)).map { UInt8(truncatingIfNeeded: $0) })
    let info = try ObjectInfo.uploadFile(
        storageID: 1, parent: 44, size: UInt64(bytes.count), filename: "separate.bin")
    let objectHeader = try ContainerHeader.data(
        code: 0x100D, transaction: 3, payloadLength: UInt64(bytes.count))
    let transport = try TransferBoundaryTransport([
        .init(
            ContainerHeader.command(code: 0x1002, transaction: 0, parameters: [1]),
            replyTransfers: [uploadResponse(0)]),
        .init(
            ContainerHeader.command(code: 0x1004, transaction: 1),
            replyTransfers: [storageHeader, storage, uploadResponse(1)]),
        .init(ContainerHeader.command(code: 0x100C, transaction: 2, parameters: [1, 44])),
        .init(
            ContainerHeader.data(
                code: 0x100C, transaction: 2,
                payloadLength: UInt64(info.encoded().count)),
            boundary: .separateDataHeader),
        .init(
            info.encoded(), replyTransfers: [uploadResponse(2, parameters: [1, 44, 61])]),
        .init(ContainerHeader.command(code: 0x100D, transaction: 3)),
        .init(objectHeader, boundary: .separateDataHeader),
        .init(Data(bytes.prefix(64 * 1024)), boundary: .continuesContainer),
        .init(Data(bytes.suffix(7)), replyTransfers: [uploadResponse(3)]),
        .init(
            ContainerHeader.command(code: 0x1003, transaction: 4),
            replyTransfers: [uploadResponse(4)]),
    ])
    let session = ReadSession(transport: transport)
    let reader = UploadReader(bytes, maximumFragment: 5_003)
    let progress = UploadProgressRecorder()
    try await session.open()
    #expect(try await session.storageIDs() == [1])
    _ = try await session.uploadObject(
        info: info, read: { reader.read(maximum: $0) },
        progress: { progress.record($0) })
    #expect(progress.snapshot == [UInt64(64 * 1024), UInt64(bytes.count)])
    try await session.close()
    #expect(await transport.consumedAllWrites)
}

@Test func zeroLengthInboundDataDoesNotImplySeparateHeaderMode() async throws {
    let bytes = Data()
    let info = try ObjectInfo.uploadFile(
        storageID: 1, parent: 44, size: 0, filename: "empty.bin")
    let transport = try TransferBoundaryTransport([
        .init(
            ContainerHeader.command(code: 0x1002, transaction: 0, parameters: [1]),
            replyTransfers: [uploadResponse(0)]),
        .init(
            ContainerHeader.command(code: 0x1009, transaction: 1, parameters: [7]),
            replyTransfers: [
                ContainerHeader.data(code: 0x1009, transaction: 1, payloadLength: 0),
                uploadResponse(1),
            ]),
        .init(ContainerHeader.command(code: 0x100C, transaction: 2, parameters: [1, 44])),
        .init(
            uploadDataContainer(info.encoded(), code: 0x100C, transaction: 2),
            replyTransfers: [uploadResponse(2, parameters: [1, 44, 62])]),
        .init(ContainerHeader.command(code: 0x100D, transaction: 3)),
        .init(
            ContainerHeader.data(code: 0x100D, transaction: 3, payloadLength: 0),
            replyTransfers: [uploadResponse(3)]),
        .init(
            ContainerHeader.command(code: 0x1003, transaction: 4),
            replyTransfers: [uploadResponse(4)]),
    ])
    let session = ReadSession(transport: transport)
    let reader = UploadReader(bytes)
    try await session.open()
    try await session.download(handle: 7, expectedSize: 0) { _ in }
    _ = try await session.uploadObject(info: info, read: { reader.read(maximum: $0) })
    try await session.close()
    #expect(await transport.consumedAllWrites)
}

@Test func zeroByteUploadInSeparateModeUsesOneTerminalDataHeader() async throws {
    let storage = storageIDsPayload([1])
    let storageHeader = try ContainerHeader.data(
        code: 0x1004, transaction: 1, payloadLength: UInt64(storage.count))
    let info = try ObjectInfo.uploadFile(
        storageID: 1, parent: 44, size: 0, filename: "empty-separate.bin")
    let transport = try TransferBoundaryTransport([
        .init(
            ContainerHeader.command(code: 0x1002, transaction: 0, parameters: [1]),
            replyTransfers: [uploadResponse(0)]),
        .init(
            ContainerHeader.command(code: 0x1004, transaction: 1),
            replyTransfers: [storageHeader, storage, uploadResponse(1)]),
        .init(ContainerHeader.command(code: 0x100C, transaction: 2, parameters: [1, 44])),
        .init(
            ContainerHeader.data(
                code: 0x100C, transaction: 2,
                payloadLength: UInt64(info.encoded().count)),
            boundary: .separateDataHeader),
        .init(
            info.encoded(), replyTransfers: [uploadResponse(2, parameters: [1, 44, 63])]),
        .init(ContainerHeader.command(code: 0x100D, transaction: 3)),
        // With no payload, the header itself completes the DATA container.
        .init(
            ContainerHeader.data(code: 0x100D, transaction: 3, payloadLength: 0),
            boundary: .endsContainer, replyTransfers: [uploadResponse(3)]),
        .init(
            ContainerHeader.command(code: 0x1003, transaction: 4),
            replyTransfers: [uploadResponse(4)]),
    ])
    let session = ReadSession(transport: transport)
    let reader = UploadReader(Data())
    try await session.open()
    #expect(try await session.storageIDs() == [1])
    _ = try await session.uploadObject(info: info, read: { reader.read(maximum: $0) })
    try await session.close()
    #expect(await transport.consumedAllWrites)
}

@Test func explicitSendObjectInfoRejectionLeavesFramedSessionReusable() async throws {
    let info = try ObjectInfo.uploadDirectory(
        storageID: 1, parent: UInt32.max, filename: "Denied")
    let transport = try UploadScriptTransport([
        .init(
            ContainerHeader.command(code: 0x1002, transaction: 0, parameters: [1]),
            reply: uploadResponse(0)),
        .init(ContainerHeader.command(code: 0x100C, transaction: 1, parameters: [1, UInt32.max])),
        .init(
            uploadDataContainer(info.encoded(), code: 0x100C, transaction: 1),
            reply: uploadResponse(1, code: 0x200F)),
        .init(ContainerHeader.command(code: 0x1003, transaction: 2), reply: uploadResponse(2)),
    ])
    let session = ReadSession(transport: transport)
    try await session.open()
    await #expect(throws: WireError.response(0x200F)) {
        try await session.createDirectory(info: info)
    }
    #expect(await session.isUsable)
    try await session.close()
    #expect(await transport.consumedAllWrites)
}

@Test func malformedCreationResponseAndSendObjectFailureInvalidateSession() async throws {
    let folder = try ObjectInfo.uploadDirectory(
        storageID: 1, parent: UInt32.max, filename: "Malformed")
    let malformed = try UploadScriptTransport([
        .init(
            ContainerHeader.command(code: 0x1002, transaction: 0, parameters: [1]),
            reply: uploadResponse(0)),
        .init(ContainerHeader.command(code: 0x100C, transaction: 1, parameters: [1, UInt32.max])),
        .init(
            uploadDataContainer(folder.encoded(), code: 0x100C, transaction: 1),
            reply: uploadResponse(1, parameters: [1, 0])),
    ])
    let malformedSession = ReadSession(transport: malformed)
    try await malformedSession.open()
    await #expect(throws: WireError.invalidLength) {
        try await malformedSession.createDirectory(info: folder)
    }
    #expect(await !malformedSession.isUsable)
    #expect(await malformed.closeCount == 1)

    let bytes = Data([1, 2, 3])
    let file = try ObjectInfo.uploadFile(
        storageID: 1, parent: 44, size: UInt64(bytes.count), filename: "failed.bin")
    let failedObject = try UploadScriptTransport([
        .init(
            ContainerHeader.command(code: 0x1002, transaction: 0, parameters: [1]),
            reply: uploadResponse(0)),
        .init(ContainerHeader.command(code: 0x100C, transaction: 1, parameters: [1, 44])),
        .init(
            uploadDataContainer(file.encoded(), code: 0x100C, transaction: 1),
            reply: uploadResponse(1, parameters: [1, 44, 53])),
        .init(ContainerHeader.command(code: 0x100D, transaction: 2)),
        .init(
            uploadDataContainer(bytes, code: 0x100D, transaction: 2),
            reply: uploadResponse(2, code: 0x2007)),
    ])
    let failedSession = ReadSession(transport: failedObject)
    let reader = UploadReader(bytes)
    try await failedSession.open()
    await #expect(throws: WireError.response(0x2007)) {
        try await failedSession.uploadObject(info: file, read: { reader.read(maximum: $0) })
    }
    #expect(await !failedSession.isUsable)
    #expect(await failedObject.closeCount == 1)
}

@Test(arguments: [UInt32(44), UInt32.max])
func uploadRejectsContradictoryCreationDestinationBeforeSendingObject(parent: UInt32) async throws {
    let info = try ObjectInfo.uploadFile(
        storageID: 1, parent: parent, size: 1, filename: "destination.bin")
    for parameters: [UInt32] in [[2, parent, 55], [1, 45, 55]] {
        let transport = try UploadScriptTransport([
            .init(
                ContainerHeader.command(code: 0x1002, transaction: 0, parameters: [1]),
                reply: uploadResponse(0)),
            .init(ContainerHeader.command(code: 0x100C, transaction: 1, parameters: [1, parent])),
            .init(
                uploadDataContainer(info.encoded(), code: 0x100C, transaction: 1),
                reply: uploadResponse(1, parameters: parameters)),
        ])
        let session = ReadSession(transport: transport)
        try await session.open()
        await #expect(throws: WireError.invalidLength) {
            try await session.uploadObject(info: info, read: { _ in
                Issue.record("Contradictory destination must be rejected before reading object data")
                return Data()
            })
        }
        // Protocol hardening: stop after SendObjectInfo when the responder
        // contradicts the requested destination, before any SendObject bytes.
        #expect(await transport.writeCount == 3)
        #expect(await !session.isUsable)
        #expect(await transport.closeCount == 1)
    }
}

@Test(arguments: [UInt32(0), UInt32.max])
func uploadAcceptsBothRootParentResponseForms(responseParent: UInt32) async throws {
    let info = try ObjectInfo.uploadFile(
        storageID: 1, parent: UInt32.max, size: 1, filename: "root.bin")
    let bytes = Data([7])
    let transport = try UploadScriptTransport([
        .init(
            ContainerHeader.command(code: 0x1002, transaction: 0, parameters: [1]),
            reply: uploadResponse(0)),
        .init(ContainerHeader.command(code: 0x100C, transaction: 1, parameters: [1, UInt32.max])),
        .init(
            uploadDataContainer(info.encoded(), code: 0x100C, transaction: 1),
            reply: uploadResponse(1, parameters: [1, responseParent, 55])),
        .init(ContainerHeader.command(code: 0x100D, transaction: 2)),
        .init(
            uploadDataContainer(bytes, code: 0x100D, transaction: 2),
            reply: uploadResponse(2)),
        .init(ContainerHeader.command(code: 0x1003, transaction: 3), reply: uploadResponse(3)),
    ])
    let session = ReadSession(transport: transport)
    let reader = UploadReader(bytes)
    try await session.open()
    let result = try await session.uploadObject(info: info, read: { reader.read(maximum: $0) })
    #expect(result.parent == responseParent)
    try await session.close()
    #expect(await transport.consumedAllWrites)
}

@Test func shortOrLongLocalSourceInvalidatesAfterObjectInfoAcceptance() async throws {
    for bytes in [Data([1, 2]), Data([1, 2, 3, 4])] {
        let declared = UInt64(3)
        let info = try ObjectInfo.uploadFile(
            storageID: 1, parent: 44, size: declared, filename: "changed.bin")
        let transport = try UploadScriptTransport([
            .init(
                ContainerHeader.command(code: 0x1002, transaction: 0, parameters: [1]),
                reply: uploadResponse(0)),
            .init(ContainerHeader.command(code: 0x100C, transaction: 1, parameters: [1, 44])),
            .init(
                uploadDataContainer(info.encoded(), code: 0x100C, transaction: 1),
                reply: uploadResponse(1, parameters: [1, 44, 54])),
            .init(ContainerHeader.command(code: 0x100D, transaction: 2)),
        ])
        let session = ReadSession(transport: transport)
        let reader = UploadReader(bytes)
        try await session.open()
        await #expect(throws: WireError.objectSizeMismatch) {
            try await session.uploadObject(info: info, read: { reader.read(maximum: $0) })
        }
        #expect(await !session.isUsable)
        #expect(await transport.closeCount == 1)
    }
}

private actor PausingUploadTransport: MTPBulkTransport {
    private let base: UploadScriptTransport
    private let pauseAtWrite: Int
    private let discardsInterruptedReply: Bool
    private var writeCount = 0
    private var paused = false
    private var blocker: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    private(set) var cancelledTransactions: [UInt32] = []

    init(
        base: UploadScriptTransport, pauseAtWrite: Int,
        discardsInterruptedReply: Bool = false
    ) {
        self.base = base
        self.pauseAtWrite = pauseAtWrite
        self.discardsInterruptedReply = discardsInterruptedReply
    }

    func write(_ data: Data) async throws {
        try await pauseIfNeeded()
        try await base.write(data)
    }

    func write(_ data: Data, boundary: BulkWriteBoundary) async throws {
        try await pauseIfNeeded()
        try await base.write(data, boundary: boundary)
    }

    private func pauseIfNeeded() async throws {
        writeCount += 1
        guard writeCount == pauseAtWrite else { return }
        paused = true
        observer?.resume()
        observer = nil
        await withCheckedContinuation { blocker = $0 }
    }

    func waitUntilPaused() async {
        if paused { return }
        await withCheckedContinuation { observer = $0 }
    }

    func resume() {
        blocker?.resume()
        blocker = nil
        paused = false
    }

    func read(maxBytes: Int) async throws -> Data {
        try await base.read(maxBytes: maxBytes)
    }

    func abort(transaction: UInt32?) async {
        if let transaction { cancelledTransactions.append(transaction) }
        if discardsInterruptedReply { await base.discardNextWriteForCancellation() }
        await base.close()
    }

    func close() async { await base.close() }
}

@Test func interruptedSendObjectCancellationDisposesSession() async throws {
    let bytes = Data(repeating: 0x45, count: 65)
    let info = try ObjectInfo.uploadFile(
        storageID: 1, parent: 44, size: UInt64(bytes.count), filename: "cancel.bin")
    let base = try UploadScriptTransport([
        .init(
            ContainerHeader.command(code: 0x1002, transaction: 0, parameters: [1]),
            reply: uploadResponse(0)),
        .init(ContainerHeader.command(code: 0x100C, transaction: 1, parameters: [1, 44])),
        .init(
            uploadDataContainer(info.encoded(), code: 0x100C, transaction: 1),
            reply: uploadResponse(1, parameters: [1, 44, 55])),
        .init(ContainerHeader.command(code: 0x100D, transaction: 2)),
        .init(
            uploadDataContainer(bytes, code: 0x100D, transaction: 2),
            boundary: .endsContainer, reply: uploadResponse(2)),
        .init(
            ContainerHeader.command(code: 0x1004, transaction: 3),
            reply: uploadDataContainer(storageIDsPayload([1]), code: 0x1004, transaction: 3)
                + uploadResponse(3)),
        .init(ContainerHeader.command(code: 0x1003, transaction: 4), reply: uploadResponse(4)),
    ])
    let transport = PausingUploadTransport(
        base: base, pauseAtWrite: 4, discardsInterruptedReply: true)
    let session = ReadSession(transport: transport)
    let reader = UploadReader(bytes)
    try await session.open()
    let upload = Task {
        try await session.uploadObject(info: info, read: { reader.read(maximum: $0) })
    }
    await transport.waitUntilPaused()
    upload.cancel()
    await transport.resume()
    await #expect(throws: CancellationError.self) { try await upload.value }
    #expect(await transport.cancelledTransactions == [2])
    #expect(await !session.isUsable)
    await #expect(throws: WireError.disconnected) { try await session.storageIDs() }
    #expect(await base.closeCount == 1)
}

@Test func cancellationAfterAcceptedObjectInfoRetiresReservedUploadSession() async throws {
    let info = try ObjectInfo.uploadFile(
        storageID: 1, parent: 44, size: 1, filename: "cancel-reservation.bin")
    let base = try UploadScriptTransport([
        .init(
            ContainerHeader.command(code: 0x1002, transaction: 0, parameters: [1]),
            reply: uploadResponse(0)),
        .init(ContainerHeader.command(code: 0x100C, transaction: 1, parameters: [1, 44])),
        .init(
            uploadDataContainer(info.encoded(), code: 0x100C, transaction: 1),
            reply: uploadResponse(1, parameters: [1, 44, 55])),
    ])
    let transport = PausingUploadTransport(base: base, pauseAtWrite: 3)
    let session = ReadSession(transport: transport)
    try await session.open()
    let upload = Task {
        try await session.uploadObject(info: info, read: { _ in
            Issue.record("Cancelled upload must not start reading SendObject data")
            return Data()
        })
    }
    // Cancel while the final SendObjectInfo transfer is in flight. Its
    // successful response must be drained, but it reserves a file that still
    // needs SendObject; finishing this transaction does not finish the upload.
    await transport.waitUntilPaused()
    upload.cancel()
    await transport.resume()
    await #expect(throws: CancellationError.self) { try await upload.value }
    #expect(await !session.isUsable)
    #expect(await base.closeCount == 1)
    #expect(await base.consumedAllWrites)
    // The reservation transaction has already completed. Retire the handle
    // without sending CancelTransaction for that completed transaction.
    #expect(await transport.cancelledTransactions.isEmpty)
    await #expect(throws: WireError.disconnected) { try await session.storageIDs() }
}

@Test func noCommandCanInterleaveBetweenSendObjectInfoAndSendObject() async throws {
    let bytes = Data([7])
    let info = try ObjectInfo.uploadFile(
        storageID: 1, parent: 44, size: 1, filename: "atomic.bin")
    let base = try UploadScriptTransport([
        .init(
            ContainerHeader.command(code: 0x1002, transaction: 0, parameters: [1]),
            reply: uploadResponse(0)),
        .init(ContainerHeader.command(code: 0x100C, transaction: 1, parameters: [1, 44])),
        .init(
            uploadDataContainer(info.encoded(), code: 0x100C, transaction: 1),
            reply: uploadResponse(1, parameters: [1, 44, 55])),
        .init(ContainerHeader.command(code: 0x100D, transaction: 2)),
        .init(
            uploadDataContainer(bytes, code: 0x100D, transaction: 2),
            reply: uploadResponse(2)),
        .init(ContainerHeader.command(code: 0x1003, transaction: 3), reply: uploadResponse(3)),
    ])
    let transport = PausingUploadTransport(base: base, pauseAtWrite: 4)
    let session = ReadSession(transport: transport)
    let reader = UploadReader(bytes)
    try await session.open()
    let upload = Task {
        try await session.uploadObject(info: info, read: { reader.read(maximum: $0) })
    }
    await transport.waitUntilPaused()
    await #expect(throws: WireError.busy) { try await session.storageIDs() }
    await #expect(throws: WireError.busy) { try await session.close() }
    await transport.resume()
    _ = try await upload.value
    try await session.close()
    #expect(await base.consumedAllWrites)
}

private actor LegacyWriteTransport: MTPBulkTransport {
    private(set) var writes: [Data] = []
    func write(_ data: Data) async throws { writes.append(data) }
    func read(maxBytes: Int) async throws -> Data { Data() }
    func close() async {}
}

@Test func legacyTransportDefaultOnlyAcceptsCompleteContainers() async throws {
    let transport = LegacyWriteTransport()
    try await transport.write(Data([1]), boundary: .endsContainer)
    await #expect(throws: WireError.streamingWriteUnsupported) {
        try await transport.write(Data([2]), boundary: .continuesContainer)
    }
    await #expect(throws: WireError.streamingWriteUnsupported) {
        try await transport.write(Data(repeating: 3, count: 12), boundary: .separateDataHeader)
    }
    #expect(await transport.writes == [Data([1])])
}

struct MoveWireTests {
    @Test func moveUsesExactParametersAndNormalizesRoot() async throws {
        let transport = UploadScriptTransport([
            .init(try ContainerHeader.command(code: 0x1002, transaction: 0, parameters: [1]), reply: try uploadResponse(0)),
            .init(try ContainerHeader.command(code: 0x1019, transaction: 1, parameters: [10, 1, 22]), reply: try uploadResponse(1)),
            .init(try ContainerHeader.command(code: 0x1019, transaction: 2, parameters: [10, 1, 0]), reply: try uploadResponse(2)),
        ])
        let session = ReadSession(transport: transport)
        try await session.open()
        try await session.moveObject(handle: 10, storageID: 1, parent: 22)
        try await session.moveObject(handle: 10, storageID: 1, parent: UInt32.max)
        #expect(await transport.consumedAllWrites)
        #expect(await session.isUsable)
    }

    @Test func moveRejectsWildcardHandlesBeforeWriting() async throws {
        let transport = UploadScriptTransport([])
        let session = ReadSession(transport: transport)
        for handle: UInt32 in [0, UInt32.max] {
            await #expect(throws: WireError.invalidLength) {
                try await session.moveObject(handle: handle, storageID: 1, parent: 2)
            }
        }
        #expect(await transport.consumedAllWrites)
        #expect(await transport.closeCount == 0)
    }

    @Test func moveMalformedSuccessInvalidatesSession() async throws {
        let transport = UploadScriptTransport([
            .init(try ContainerHeader.command(code: 0x1002, transaction: 0, parameters: [1]), reply: try uploadResponse(0)),
            .init(try ContainerHeader.command(code: 0x1019, transaction: 1, parameters: [10, 1, 22]), reply: try uploadResponse(1, parameters: [99])),
        ])
        let session = ReadSession(transport: transport)
        try await session.open()
        await #expect(throws: WireError.invalidLength) {
            try await session.moveObject(handle: 10, storageID: 1, parent: 22)
        }
        #expect(await session.isUsable == false)
        #expect(await transport.closeCount == 1)
    }

    @Test func moveRejectionIsNotRetried() async throws {
        let transport = UploadScriptTransport([
            .init(try ContainerHeader.command(code: 0x1002, transaction: 0, parameters: [1]), reply: try uploadResponse(0)),
            .init(try ContainerHeader.command(code: 0x1019, transaction: 1, parameters: [10, 1, 22]), reply: try uploadResponse(1, code: 0x2005)),
        ])
        let session = ReadSession(transport: transport)
        try await session.open()
        await #expect(throws: WireError.response(0x2005)) {
            try await session.moveObject(handle: 10, storageID: 1, parent: 22)
        }
        #expect(await transport.consumedAllWrites)
    }
}

struct DeleteWireTests {
    @Test func deleteUsesSingleHandleAndZeroFormatOnly() async throws {
        let transport = UploadScriptTransport([
            .init(try ContainerHeader.command(code: 0x1002, transaction: 0, parameters: [1]), reply: try uploadResponse(0)),
            .init(try ContainerHeader.command(code: 0x100B, transaction: 1, parameters: [10, 0]), reply: try uploadResponse(1)),
        ])
        let session = ReadSession(transport: transport)
        try await session.open()
        try await session.deleteObject(handle: 10)
        #expect(await transport.consumedAllWrites)
        for handle: UInt32 in [0, UInt32.max] {
            await #expect(throws: WireError.invalidLength) { try await session.deleteObject(handle: handle) }
        }
        #expect(await session.isUsable)
    }
}

@Suite struct PartialUploadWireTests {
    @Test(arguments: [1, 65_536, 1_048_576])
    func sendsIndependentRangesWithSeparateHeaderAnd64BitOffset(count: Int) async throws {
        let payload = Data(repeating: 0x63, count: count)
        let offset: UInt64 = 0x1_0000_0123
        var writes: [UploadScriptTransport.ExpectedWrite] = [
            .init(try ContainerHeader.command(code: 0x1002, transaction: 0, parameters: [1]), reply: try uploadResponse(0)),
            .init(try ContainerHeader.command(code: 0x95C4, transaction: 1, parameters: [42]), reply: try uploadResponse(1)),
            .init(try ContainerHeader.command(code: 0x95C2, transaction: 2, parameters: [42, 0x123, 1, UInt32(count)])),
            .init(try ContainerHeader.data(code: 0x95C2, transaction: 2, payloadLength: UInt64(count)), boundary: .separateDataHeader),
        ]
        for offset in stride(from: 0, to: count, by: 65_536) {
            let end = min(offset + 65_536, count)
            writes.append(.init(Data(payload[offset..<end]),
                boundary: end == count ? .endsContainer : .continuesContainer,
                reply: end == count ? try uploadResponse(2, parameters: [UInt32(count)]) : Data()))
        }
        writes.append(.init(try ContainerHeader.command(code: 0x95C5, transaction: 3, parameters: [42]), reply: try uploadResponse(3)))
        writes.append(.init(try ContainerHeader.command(code: 0x1003, transaction: 4), reply: try uploadResponse(4)))
        let transport = UploadScriptTransport(writes)
        let session = ReadSession(transport: transport)
        try await session.open()
        try await session.beginEditObject(handle: 42)
        try await session.sendPartialObject(handle: 42, offset: offset, data: payload)
        try await session.endEditObject(handle: 42)
        try await session.close()
        #expect(await transport.consumedAllWrites)
    }

    @Test(arguments: [[UInt32](), [0], [2], [1, 0]])
    func wrongOrMissingByteCountInvalidatesSession(parameters: [UInt32]) async throws {
        let transport = UploadScriptTransport([
            .init(try ContainerHeader.command(code: 0x1002, transaction: 0, parameters: [1]), reply: try uploadResponse(0)),
            .init(try ContainerHeader.command(code: 0x95C2, transaction: 1, parameters: [42, 0, 0, 1])),
            .init(try ContainerHeader.data(code: 0x95C2, transaction: 1, payloadLength: 1), boundary: .separateDataHeader),
            .init(Data([23]), reply: try uploadResponse(1, parameters: parameters)),
        ])
        let session = ReadSession(transport: transport)
        try await session.open()
        await #expect(throws: WireError.objectSizeMismatch) {
            try await session.sendPartialObject(handle: 42, offset: 0, data: Data([23]))
        }
        #expect(!(await session.isUsable))
        #expect(await transport.closed)
    }

    @Test func guardsRejectWildcardsOversizeEmptyAndOverflowBeforeIO() async throws {
        let transport = UploadScriptTransport([])
        let session = ReadSession(transport: transport)
        for handle in [UInt32(0), UInt32.max] {
            await #expect(throws: WireError.invalidLength) { try await session.beginEditObject(handle: handle) }
            await #expect(throws: WireError.invalidLength) { try await session.endEditObject(handle: handle) }
            await #expect(throws: WireError.invalidLength) {
                try await session.sendPartialObject(handle: handle, offset: 0, data: Data([1]))
            }
        }
        for data in [Data(), Data(repeating: 1, count: 1_048_577)] {
            await #expect(throws: WireError.invalidLength) {
                try await session.sendPartialObject(handle: 42, offset: 0, data: data)
            }
        }
        await #expect(throws: WireError.invalidLength) {
            try await session.sendPartialObject(handle: 42, offset: UInt64.max, data: Data([1]))
        }
        #expect(await transport.consumedAllWrites)
        #expect(!(await transport.closed))
    }
}
