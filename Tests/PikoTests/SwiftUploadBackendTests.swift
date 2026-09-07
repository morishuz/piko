import Foundation
import MTPWire
import Testing

@testable import Piko

private enum SyntheticUploadDeviceError: Error {
    case invalidExchange
    case transportFailure
}

struct SyntheticUploadRecord: Sendable {
    let name: String
    let data: Data
    let payloadChunkSizes: [Int]
    let boundaries: [BulkWriteBoundary]
    let transportWriteSizes: [Int]
}

struct SyntheticUploadSnapshot: Sendable {
    let commands: [UInt16]
    let uploads: [SyntheticUploadRecord]
    let directoryNames: Set<String>
    let objectHandleQueries: Int
    let objectDataWriteAttempts: Int
    let failedPayloadBytes: Int
    let closed: Bool

    var writeOperationCommands: [UInt16] {
        commands.filter { $0 == WriteOperation.sendObjectInfo.rawValue || $0 == WriteOperation.sendObject.rawValue }
    }
}

/// A small in-memory MTP device that consumes actual command/data containers.
/// It deliberately models only the operations used by SwiftMTPBackend uploads.
actor SyntheticUploadDevice: MTPBulkTransport {
    private struct StoredObject: Sendable {
        var info: ObjectInfo
        var data: Data
    }

    private struct Reservation: Sendable {
        let handle: UInt32
        let info: ObjectInfo
    }

    private enum WritePhase: Sendable {
        case partialHeader(transaction: UInt32, handle: UInt32, offset: Int, count: Int)
        case partialBody(transaction: UInt32, handle: UInt32, offset: Int, count: Int, data: Data)
        case command
        case objectInfo(transaction: UInt32, storageID: UInt32, parent: UInt32)
        case objectHeader(transaction: UInt32)
        case objectBody(
            transaction: UInt32, expected: Int, received: Data,
            payloadChunkSizes: [Int], boundaries: [BulkWriteBoundary],
            transportWriteSizes: [Int])
    }

    private var editingHandle: UInt32?
    private(set) var partialRequests: [[UInt32]] = []
    private(set) var cancelCount = 0
    private(set) var interruptedIO = false
    private var pauseOperation: UInt16?
    private var pauseWrites = 0
    private var pauseCommands = false
    private var pauseContinuation: CheckedContinuation<Void, Never>?
    var isPaused: Bool { pauseContinuation != nil }
    var rejectOperation: UInt16?
    var rejectionCode: UInt16 = 0x200F
    var badPartialCount = false
    var changeIdentityOnEnd = false
    var failPartialPayload = false
    var ignoreDelete = false
    private var unavailableHandles: Set<UInt32> = []
    private var unavailableAfterMove = false
    func configureUnavailable(_ handles: Set<UInt32>, afterMove: Bool = false) {
        unavailableHandles = handles
        unavailableAfterMove = afterMove
    }

    func configureFault(reject: UInt16? = nil, badCount: Bool = false, changedIdentity: Bool = false, partialFailure: Bool = false, ignoredDelete: Bool = false, rejectionCode: UInt16 = 0x200F) {
        self.rejectionCode = rejectionCode
        failPartialPayload = partialFailure
        ignoreDelete = ignoredDelete
        rejectOperation = reject
        badPartialCount = badCount
        changeIdentityOnEnd = changedIdentity
    }
    func pause(operation: UInt16, afterWrites: Int = 1, includingCommand: Bool = false) {
        pauseOperation = operation; pauseWrites = afterWrites; pauseCommands = includingCommand
    }
    func resume() { pauseContinuation?.resume(); pauseContinuation = nil }
    func storedData(named name: String) -> Data? { objects.values.first { $0.info.filename == name }?.data }
    func cancel(transaction: UInt32) async -> Bool { cancelCount += 1; await close(); return false }

    private let reportedFileFormat: UInt16?
    private let failMoveAt: Int?
    private let corruptReadback: Bool
    private var moveCount = 0
    private var deleteCount = 0
    private let failDeleteAt: Int?
    private let writable: Bool
    private let reportedAccess: UInt16
    private let advertisedWrites: Set<UInt16>
    private let sampleProperties: [UInt16: Data]
    private(set) var objectReads: [UInt32] = []
    private let thumbnailData: Data?
    private let thumbnailSize: UInt32
    private let metadataMismatch: Bool
    private let failFinalObjectData: Bool
    private let failObjectHandleRead: Bool
    private var objects: [UInt32: StoredObject] = [:]
    private var nextHandle: UInt32 = 100
    private var reservation: Reservation?
    private var phase = WritePhase.command
    private var incoming = Data()
    private var opened = false
    private var isClosed = false
    private var commands: [UInt16] = []
    private var uploads: [SyntheticUploadRecord] = []
    private var objectHandleQueries = 0
    private var objectDataWriteAttempts = 0
    private var failedPayloadBytes = 0

    init(
        writable: Bool = true, accessCapability: UInt16? = nil,
        advertisedWrites: Set<UInt16> = Set(WriteOperation.allCases.map(\.rawValue)),
        existingNames: [String] = [], metadataMismatch: Bool = false,
        failFinalObjectData: Bool = false, failObjectHandleRead: Bool = false,
        failMoveAt: Int? = nil, corruptReadback: Bool = false, failDeleteAt: Int? = nil,
        reportedFileFormat: UInt16? = nil, thumbnailData: Data? = nil, thumbnailSize: UInt32? = nil,
        originalData: [String: Data] = [:], sampleProperties: [UInt16: Data] = [:]
    ) throws {
        self.sampleProperties = sampleProperties
        self.thumbnailData = thumbnailData
        self.thumbnailSize = thumbnailSize ?? UInt32(thumbnailData?.count ?? 0)
        self.reportedFileFormat = reportedFileFormat
        self.failDeleteAt = failDeleteAt
        self.failMoveAt = failMoveAt
        self.corruptReadback = corruptReadback
        self.writable = writable
        self.reportedAccess = accessCapability ?? (writable ? 0 : 1)
        self.advertisedWrites = advertisedWrites
        self.metadataMismatch = metadataMismatch
        self.failFinalObjectData = failFinalObjectData
        self.failObjectHandleRead = failObjectHandleRead
        for (offset, name) in existingNames.enumerated() {
            let handle = UInt32(10 + offset)
            let data = originalData[name] ?? Data()
            let info = try ObjectInfo.uploadFile(
                storageID: 1, parent: UInt32.max, size: UInt64(data.count), filename: name)
            objects[handle] = StoredObject(info: info, data: data)
        }
    }

    func prepareReconnect() {
        isClosed = false
        opened = false
        incoming = Data()
        phase = .command
    }

    /// Simulates a responder rebuilding its catalogue from unchanged storage.
    func restoreFixtureParent(handle: UInt32, parent: UInt32) throws {
        guard var object = objects[handle] else { throw SyntheticUploadDeviceError.invalidExchange }
        object.info = object.info.isDirectory
            ? try ObjectInfo.uploadDirectory(storageID: 1, parent: parent, filename: object.info.filename)
            : try ObjectInfo.uploadFile(storageID: 1, parent: parent,
                size: UInt64(object.data.count), filename: object.info.filename)
        objects[handle] = object
    }

    func rewriteRestoreRecord(_ transform: @Sendable (Data) throws -> Data) throws {
        guard let handle = objects.first(where: { $0.value.info.filename == "Restore.json" })?.key,
            var object = objects[handle] else { throw BinError.invalidEntry }
        object.data = try transform(object.data)
        object.info = try ObjectInfo.uploadFile(storageID: 1,
            parent: object.info.parent, size: UInt64(object.data.count), filename: "Restore.json")
        objects[handle] = object
    }

    func write(_ data: Data) async throws {
        try await write(data, boundary: .endsContainer)
    }

    func write(_ data: Data, boundary: BulkWriteBoundary) async throws {
        guard !isClosed else { throw WireError.disconnected }
        interruptedIO = interruptedIO || Task.isCancelled
        let wasCommand: Bool
        if case .command = phase { wasCommand = true } else { wasCommand = false }
        switch phase {
        case .partialHeader(let transaction, let handle, let offset, let count):
            let header = try ContainerHeader(data: data)
            guard data.count == 12, header.code == 0x95C2, header.type == .data,
                header.transaction == transaction, header.payloadLength == count,
                boundary == .separateDataHeader else { throw SyntheticUploadDeviceError.invalidExchange }
            phase = .partialBody(transaction: transaction, handle: handle, offset: offset, count: count, data: Data())
        case .partialBody(let transaction, let handle, let offset, let count, let received):
            if failPartialPayload { throw SyntheticUploadDeviceError.transportFailure }
            guard data.count <= 65_536, data.count + received.count <= count,
                var object = objects[handle], offset == object.data.count else {
                throw SyntheticUploadDeviceError.invalidExchange
            }
            var bytes = received
            bytes.append(data)
            let complete = bytes.count == count
            guard boundary == (complete ? .endsContainer : .continuesContainer) else {
                throw SyntheticUploadDeviceError.invalidExchange
            }
            if !complete {
                phase = .partialBody(transaction: transaction, handle: handle, offset: offset, count: count, data: bytes)
                break
            }
            object.data.append(bytes)
            objects[handle] = object
            phase = .command
            try enqueueResponse(transaction: transaction, parameters: [UInt32(badPartialCount ? count - 1 : count)])
        case .command:
            try receiveCommand(data, boundary: boundary)
        case .objectInfo(let transaction, let storageID, let parent):
            try receiveObjectInfo(
                data, boundary: boundary, transaction: transaction,
                storageID: storageID, parent: parent)
        case .objectHeader(let transaction):
            try receiveObjectHeader(data, boundary: boundary, transaction: transaction)
        case .objectBody(
            let transaction, let expected, let received, let payloadChunkSizes,
            let boundaries, let transportWriteSizes):
            try receiveObjectBody(
                data, boundary: boundary, transaction: transaction,
                expected: expected, received: received,
                payloadChunkSizes: payloadChunkSizes, boundaries: boundaries,
                transportWriteSizes: transportWriteSizes)
        }
        if pauseOperation == commands.last, !wasCommand || pauseCommands {
            pauseWrites -= 1
            if pauseWrites == 0 {
                pauseOperation = nil
                await withCheckedContinuation { pauseContinuation = $0 }
            }
        }
    }

    func read(maxBytes: Int) async throws -> Data {
        interruptedIO = interruptedIO || Task.isCancelled
        guard !isClosed, maxBytes > 0, !incoming.isEmpty else {
            throw SyntheticUploadDeviceError.invalidExchange
        }
        let count = min(maxBytes, 47, incoming.count)
        let result = Data(incoming.prefix(count))
        incoming.removeFirst(count)
        return result
    }

    func close() async {
        isClosed = true
        incoming = Data()
    }

    func snapshot() -> SyntheticUploadSnapshot {
        SyntheticUploadSnapshot(
            commands: commands, uploads: uploads,
            directoryNames: Set(objects.values.filter { $0.info.isDirectory }.map { $0.info.filename }),
            objectHandleQueries: objectHandleQueries,
            objectDataWriteAttempts: objectDataWriteAttempts,
            failedPayloadBytes: failedPayloadBytes, closed: isClosed)
    }

    private func receiveCommand(_ data: Data, boundary: BulkWriteBoundary) throws {
        guard boundary == .endsContainer, incoming.isEmpty, data.count >= 12 else {
            throw SyntheticUploadDeviceError.invalidExchange
        }
        let header = try ContainerHeader(data: Data(data.prefix(12)))
        guard header.type == .command, Int(header.length) == data.count else {
            throw SyntheticUploadDeviceError.invalidExchange
        }
        var reader = DatasetReader(Data(data.dropFirst(12)))
        var parameters: [UInt32] = []
        while reader.remaining > 0 { parameters.append(try reader.readUInt32()) }
        commands.append(header.code)
        if header.code == rejectOperation, header.code != WriteOperation.sendObjectInfo.rawValue {
            try enqueueResponse(transaction: header.transaction, code: rejectionCode)
            return
        }
        switch header.code {
        case ReadSession.getObjectPropertiesSupportedCode:
            guard opened, advertisedWrites.contains(header.code), parameters.count == 1 else {
                throw SyntheticUploadDeviceError.invalidExchange
            }
            var writer = DatasetWriter()
            writer.append(UInt32(sampleProperties.count))
            for property in sampleProperties.keys.sorted() { writer.append(property) }
            try enqueueData(writer.data, operation: header.code, transaction: header.transaction)
        case ReadSession.getObjectPropertyValueCode:
            guard opened, advertisedWrites.contains(header.code), parameters.count == 2,
                objects[parameters[0]] != nil else { throw SyntheticUploadDeviceError.invalidExchange }
            if let value = sampleProperties[UInt16(parameters[1])] {
                try enqueueData(value, operation: header.code, transaction: header.transaction)
            } else { try enqueueResponse(transaction: header.transaction, code: 0xA801) }
        case ReadSession.getThumbnailCode:
            guard opened, advertisedWrites.contains(header.code), parameters.count == 1,
                objects[parameters[0]] != nil else { throw SyntheticUploadDeviceError.invalidExchange }
            if let thumbnailData {
                try enqueueData(thumbnailData, operation: header.code, transaction: header.transaction)
            } else {
                try enqueueResponse(transaction: header.transaction, code: 0x2010)
            }
        case 0x95C4:
            guard parameters.count == 1, editingHandle == nil, objects[parameters[0]] != nil else {
                throw SyntheticUploadDeviceError.invalidExchange
            }
            editingHandle = parameters[0]
            try enqueueResponse(transaction: header.transaction)
        case 0x95C5:
            guard parameters.count == 1, editingHandle == parameters[0], var object = objects[parameters[0]] else {
                throw SyntheticUploadDeviceError.invalidExchange
            }
            object.info = try ObjectInfo.uploadFile(storageID: 1, parent: object.info.parent,
                size: UInt64(object.data.count), filename: changeIdentityOnEnd ? "changed.bin" : object.info.filename)
            objects[parameters[0]] = object
            editingHandle = nil
            try enqueueResponse(transaction: header.transaction)
        case 0x95C2:
            guard parameters.count == 4, editingHandle == parameters[0], parameters[2] == 0 else {
                throw SyntheticUploadDeviceError.invalidExchange
            }
            partialRequests.append(parameters)
            phase = .partialHeader(transaction: header.transaction, handle: parameters[0],
                offset: Int(parameters[1]), count: Int(parameters[3]))
        case ReadOperation.openSession.rawValue:
            guard !opened, parameters == [1] else {
                throw SyntheticUploadDeviceError.invalidExchange
            }
            opened = true
            try enqueueResponse(transaction: header.transaction)
        case ReadOperation.closeSession.rawValue:
            guard opened, parameters.isEmpty else {
                throw SyntheticUploadDeviceError.invalidExchange
            }
            opened = false
            try enqueueResponse(transaction: header.transaction)
        case ReadOperation.deviceInfo.rawValue:
            guard opened, parameters.isEmpty else {
                throw SyntheticUploadDeviceError.invalidExchange
            }
            var writer = DatasetWriter()
            writer.append(UInt16(100))
            writer.append(UInt32(6))
            writer.append(UInt16(100))
            try writer.append(string: "microsoft.com: 1.0;")
            writer.append(UInt16(0))
            let operations = ReadOperation.allCases.map(\.rawValue) + advertisedWrites.sorted()
            writer.append(UInt32(operations.count))
            for operation in operations { writer.append(operation) }
            for _ in 0..<4 { writer.append(UInt32(0)) }
            for value in ["Synthetic", "Upload fixture", "1", "fixture-serial"] {
                try writer.append(string: value)
            }
            try enqueueData(writer.data, operation: header.code, transaction: header.transaction)
        case ReadOperation.storageIDs.rawValue:
            guard opened, parameters.isEmpty else {
                throw SyntheticUploadDeviceError.invalidExchange
            }
            var writer = DatasetWriter()
            writer.append(UInt32(1))
            writer.append(UInt32(1))
            try enqueueData(writer.data, operation: header.code, transaction: header.transaction)
        case ReadOperation.storageInfo.rawValue:
            guard opened, parameters == [1] else {
                throw SyntheticUploadDeviceError.invalidExchange
            }
            var writer = DatasetWriter()
            writer.append(UInt16(3))
            writer.append(UInt16(2))
            writer.append(reportedAccess)
            writer.append(UInt64(1) << 30)
            writer.append(UInt64(1) << 29)
            writer.append(UInt32.max)
            try writer.append(string: "Upload storage")
            try writer.append(string: "")
            try enqueueData(writer.data, operation: header.code, transaction: header.transaction)
        case ReadOperation.objectHandles.rawValue:
            guard opened, parameters.count == 3, parameters[0] == 1, parameters[1] == 0 else {
                throw SyntheticUploadDeviceError.invalidExchange
            }
            objectHandleQueries += 1
            if failObjectHandleRead { throw SyntheticUploadDeviceError.transportFailure }
            let parent = parameters[2]
            let handles = objects.compactMap { handle, object -> UInt32? in
                let objectParent = object.info.parent == 0 ? UInt32.max : object.info.parent
                return objectParent == parent ? handle : nil
            }.sorted()
            var writer = DatasetWriter()
            writer.append(UInt32(handles.count))
            for handle in handles { writer.append(handle) }
            try enqueueData(writer.data, operation: header.code, transaction: header.transaction)
        case ReadOperation.objectInfo.rawValue:
            if let handle = parameters.first, unavailableHandles.contains(handle),
               !unavailableAfterMove || moveCount > 0 {
                try enqueueResponse(transaction: header.transaction, code: 0x2009)
                return
            }
            guard opened, parameters.count == 1, let object = objects[parameters[0]] else {
                throw SyntheticUploadDeviceError.invalidExchange
            }
            var info = object.info
            if metadataMismatch, parameters[0] >= 100, !info.isDirectory {
                info = try ObjectInfo.uploadFile(
                    storageID: info.storageID,
                    parent: info.parent == 0 ? UInt32.max : info.parent,
                    size: UInt64(object.data.count + 1), filename: info.filename,
                    modificationDate: info.modificationDate)
            }
            var encoded = try info.encoded()
            if !info.isDirectory, thumbnailSize > 0 {
                var thumbnail = DatasetWriter()
                thumbnail.append(UInt16(0x3801))
                thumbnail.append(thumbnailSize)
                encoded.replaceSubrange(12..<18, with: thumbnail.data)
            }
            if let reportedFileFormat, !info.isDirectory {
                encoded[4] = UInt8(truncatingIfNeeded: reportedFileFormat)
                encoded[5] = UInt8(reportedFileFormat >> 8)
            }
            try enqueueData(encoded, operation: header.code, transaction: header.transaction)
        case ReadOperation.getObject.rawValue, ReadSession.getPartialObjectCode:
            let partial = header.code == ReadSession.getPartialObjectCode
            guard opened, parameters.count == (partial ? 3 : 1), let object = objects[parameters[0]] else {
                throw SyntheticUploadDeviceError.invalidExchange
            }
            objectReads.append(parameters[0])
            var payload = object.data
            if corruptReadback, object.info.filename == "Restore.json", !payload.isEmpty {
                payload[0] ^= 1
            }
            if partial {
                let offset = Int(parameters[1]), count = Int(parameters[2])
                guard advertisedWrites.contains(header.code), offset + count <= payload.count else {
                    throw SyntheticUploadDeviceError.invalidExchange
                }
                payload = Data(payload.dropFirst(offset).prefix(count))
            }
            try enqueueData(payload, operation: header.code, transaction: header.transaction,
                responseParameters: partial ? [UInt32(payload.count)] : [])
        case 0x100B:
            guard opened, advertisedWrites.contains(header.code), parameters.count == 2,
                parameters[1] == 0, let object = objects[parameters[0]],
                !object.info.isDirectory || !objects.values.contains(where: { $0.info.parent == parameters[0] }) else {
                throw SyntheticUploadDeviceError.invalidExchange
            }
            if !ignoreDelete { objects.removeValue(forKey: parameters[0]) }
            deleteCount += 1
            if deleteCount == failDeleteAt { throw SyntheticUploadDeviceError.transportFailure }
            try enqueueResponse(transaction: header.transaction)
        case 0x1019:
            guard opened, advertisedWrites.contains(header.code), parameters.count == 3,
                parameters[1] == 1, var object = objects[parameters[0]],
                parameters[2] == 0 || objects[parameters[2]]?.info.isDirectory == true else {
                throw SyntheticUploadDeviceError.invalidExchange
            }
            let parent = parameters[2] == 0 ? UInt32.max : parameters[2]
            object.info = object.info.isDirectory
                ? try ObjectInfo.uploadDirectory(storageID: 1, parent: parent, filename: object.info.filename)
                : try ObjectInfo.uploadFile(storageID: 1, parent: parent,
                    size: UInt64(object.data.count), filename: object.info.filename)
            objects[parameters[0]] = object
            moveCount += 1
            if moveCount == failMoveAt { throw SyntheticUploadDeviceError.transportFailure }
            try enqueueResponse(transaction: header.transaction)
        case WriteOperation.sendObjectInfo.rawValue:
            guard opened, advertisedWrites.contains(header.code), parameters.count == 2,
                reservation == nil
            else { throw SyntheticUploadDeviceError.invalidExchange }
            phase = .objectInfo(
                transaction: header.transaction, storageID: parameters[0], parent: parameters[1])
        case WriteOperation.sendObject.rawValue:
            guard opened, advertisedWrites.contains(header.code), parameters.isEmpty,
                reservation != nil
            else { throw SyntheticUploadDeviceError.invalidExchange }
            phase = .objectHeader(transaction: header.transaction)
        default:
            throw SyntheticUploadDeviceError.invalidExchange
        }
    }

    private func receiveObjectInfo(
        _ data: Data, boundary: BulkWriteBoundary, transaction: UInt32,
        storageID: UInt32, parent: UInt32
    ) throws {
        guard boundary == .endsContainer, data.count >= 12 else {
            throw SyntheticUploadDeviceError.invalidExchange
        }
        let header = try ContainerHeader(data: Data(data.prefix(12)))
        guard header.type == .data, header.code == WriteOperation.sendObjectInfo.rawValue,
            header.transaction == transaction, Int(header.length) == data.count
        else { throw SyntheticUploadDeviceError.invalidExchange }
        let info = try ObjectInfo(data: Data(data.dropFirst(12)))
        let normalizedParent = info.parent == 0 ? UInt32.max : info.parent
        guard info.storageID == storageID, normalizedParent == parent else {
            throw SyntheticUploadDeviceError.invalidExchange
        }
        if rejectOperation == WriteOperation.sendObjectInfo.rawValue {
            phase = .command
            try enqueueResponse(transaction: transaction, code: rejectionCode)
            return
        }
        let handle = nextHandle
        nextHandle += 1
        if info.isDirectory {
            objects[handle] = StoredObject(info: info, data: Data())
        } else {
            reservation = Reservation(handle: handle, info: info)
        }
        phase = .command
        try enqueueResponse(
            transaction: transaction, parameters: [storageID, parent, handle])
    }

    private func receiveObjectHeader(
        _ data: Data, boundary: BulkWriteBoundary, transaction: UInt32
    ) throws {
        guard data.count >= 12, let reservation else {
            throw SyntheticUploadDeviceError.invalidExchange
        }
        let header = try ContainerHeader(data: Data(data.prefix(12)))
        guard header.type == .data, header.code == WriteOperation.sendObject.rawValue,
            header.transaction == transaction,
            header.payloadLength == Int(reservation.info.compressedSize)
        else { throw SyntheticUploadDeviceError.invalidExchange }
        let payload = Data(data.dropFirst(12))
        try acceptObjectData(
            payload, boundary: boundary, transaction: transaction,
            expected: header.payloadLength, received: Data(),
            payloadChunkSizes: [], boundaries: [], transportWriteSizes: [],
            transportWriteSize: data.count)
    }

    private func receiveObjectBody(
        _ data: Data, boundary: BulkWriteBoundary, transaction: UInt32,
        expected: Int, received: Data, payloadChunkSizes: [Int],
        boundaries: [BulkWriteBoundary], transportWriteSizes: [Int]
    ) throws {
        try acceptObjectData(
            data, boundary: boundary, transaction: transaction,
            expected: expected, received: received,
            payloadChunkSizes: payloadChunkSizes, boundaries: boundaries,
            transportWriteSizes: transportWriteSizes, transportWriteSize: data.count)
    }

    private func acceptObjectData(
        _ data: Data, boundary: BulkWriteBoundary, transaction: UInt32,
        expected: Int, received: Data, payloadChunkSizes: [Int],
        boundaries: [BulkWriteBoundary], transportWriteSizes: [Int],
        transportWriteSize: Int
    ) throws {
        objectDataWriteAttempts += 1
        var bytes = received
        bytes.append(data)
        var chunks = payloadChunkSizes
        chunks.append(data.count)
        var seenBoundaries = boundaries
        seenBoundaries.append(boundary)
        var writes = transportWriteSizes
        writes.append(transportWriteSize)
        guard bytes.count <= expected else { throw SyntheticUploadDeviceError.invalidExchange }
        let complete = bytes.count == expected
        guard boundary == (complete ? .endsContainer : .continuesContainer) else {
            throw SyntheticUploadDeviceError.invalidExchange
        }
        if complete, failFinalObjectData {
            failedPayloadBytes = bytes.count
            throw SyntheticUploadDeviceError.transportFailure
        }
        guard complete else {
            phase = .objectBody(
                transaction: transaction, expected: expected, received: bytes,
                payloadChunkSizes: chunks, boundaries: seenBoundaries,
                transportWriteSizes: writes)
            return
        }
        guard let reservation else { throw SyntheticUploadDeviceError.invalidExchange }
        objects[reservation.handle] = StoredObject(info: reservation.info, data: bytes)
        uploads.append(
            SyntheticUploadRecord(
                name: reservation.info.filename, data: bytes,
                payloadChunkSizes: chunks, boundaries: seenBoundaries,
                transportWriteSizes: writes))
        self.reservation = nil
        phase = .command
        try enqueueResponse(transaction: transaction)
    }

    private func enqueueData(_ data: Data, operation: UInt16, transaction: UInt32, responseParameters: [UInt32] = []) throws {
        guard incoming.isEmpty else { throw SyntheticUploadDeviceError.invalidExchange }
        let header = try ContainerHeader(
            length: UInt32(12 + data.count), type: .data,
            code: operation, transaction: transaction)
        incoming.append(header.encoded())
        incoming.append(data)
        try appendResponse(transaction: transaction, parameters: responseParameters)
    }

    private func enqueueResponse(
        transaction: UInt32, code: UInt16 = 0x2001, parameters: [UInt32] = []
    ) throws {
        guard incoming.isEmpty else { throw SyntheticUploadDeviceError.invalidExchange }
        try appendResponse(transaction: transaction, code: code, parameters: parameters)
    }

    private func appendResponse(
        transaction: UInt32, code: UInt16 = 0x2001, parameters: [UInt32] = []
    ) throws {
        let header = try ContainerHeader(
            length: UInt32(12 + parameters.count * 4), type: .response,
            code: code, transaction: transaction)
        var writer = DatasetWriter()
        for parameter in parameters { writer.append(parameter) }
        incoming.append(header.encoded())
        incoming.append(writer.data)
    }
}

final class SwiftUploadTestDirectory {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "swift-upload-backend-\(UUID().uuidString)", isDirectory: true)

    init() throws {
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func file(_ name: String, data: Data) throws -> URL {
        let result = url.appendingPathComponent(name)
        try data.write(to: result)
        return result
    }
}

func connectedUploadBackend(_ device: SyntheticUploadDevice) async throws -> SwiftMTPBackend {
    let backend = SwiftMTPBackend { device }
    let storages = try await backend.connect()
    #expect(storages.count == 1)
    #expect(storages.first?.id == 1)
    return backend
}

private actor BlockingUploadTransportFactory {
    private let device: SyntheticUploadDevice
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var startObserver: CheckedContinuation<Void, Never>?

    init(device: SyntheticUploadDevice) { self.device = device }

    func make() async -> SyntheticUploadDevice {
        await withCheckedContinuation {
            releaseContinuation = $0
            startObserver?.resume()
            startObserver = nil
        }
        return device
    }

    func waitUntilStarted() async {
        if releaseContinuation != nil { return }
        await withCheckedContinuation { startObserver = $0 }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private func isUploaded(_ disposition: UploadDisposition) -> Bool {
    switch disposition {
    case .uploaded, .uploadedVerified: true
    case .skippedExisting: false
    }
}

private func isSkipped(_ disposition: UploadDisposition) -> Bool {
    if case .skippedExisting = disposition { true } else { false }
}

@Suite("SwiftUploadBackendTests")
struct SwiftUploadBackendTests {
    @Test func cancellationAtSerializationGateIsAWriteFreePreflightFailure() async throws {
        let device = try SyntheticUploadDevice()
        let factory = BlockingUploadTransportFactory(device: device)
        let backend = SwiftMTPBackend { await factory.make() }
        let local = try SwiftUploadTestDirectory()
        let source = try local.file("cancelled-before-entry.bin", data: Data([1, 2, 3]))

        let connectTask = Task { try await backend.connect() }
        await factory.waitUntilStarted()
        let uploadTask = Task {
            try await backend.upload(
                storageID: 1, source: source, to: "/", progress: { _ in })
        }
        uploadTask.cancel()
        await factory.release()
        _ = try await connectTask.value

        do {
            _ = try await uploadTask.value
            Issue.record("A cancelled gate wait must not enter uploadImpl")
        } catch let failure as UploadPreflightFailure {
            #expect(failure.underlying is CancellationError)
        } catch {
            Issue.record("Expected UploadPreflightFailure, got \(error)")
        }
        #expect(await device.snapshot().writeOperationCommands.isEmpty)
        #expect(!backend.capabilities.canCancelActiveTransfer)
        #expect(backend.maximumUploadFileSize == Int64(UInt32.max) - 13)
        try await backend.disconnect()
    }

    @Test func runtimeCapabilityAndStreamedFilesReachDeviceExactly() async throws {
        let device = try SyntheticUploadDevice()
        let backend = try await connectedUploadBackend(device)
        #expect(await backend.supportsUpload(to: 1))

        let local = try SwiftUploadTestDirectory()
        let large = Data((0..<150_003).map { UInt8(truncatingIfNeeded: $0) })
        let fixtures: [(String, Data)] = [
            ("stream.bin", large),
            ("empty.bin", Data()),
            ("Grüße 日本語 📷.txt", Data("exact Unicode payload ✓".utf8)),
        ]
        for (name, bytes) in fixtures {
            let source = try local.file(name, data: bytes)
            let result = try await backend.upload(
                storageID: 1, source: source, to: "/", progress: { _ in })
            #expect(isUploaded(result))
        }

        let snapshot = await device.snapshot()
        #expect(snapshot.uploads.count == fixtures.count)
        for (name, bytes) in fixtures {
            let upload = try #require(snapshot.uploads.first { $0.name == name })
            #expect(upload.data == bytes)
        }
        let streamed = try #require(snapshot.uploads.first { $0.name == "stream.bin" })
        #expect(streamed.payloadChunkSizes.count > 1)
        #expect(streamed.transportWriteSizes.allSatisfy { $0 <= 65_536 })
        #expect(streamed.boundaries.dropLast().allSatisfy { $0 == .continuesContainer })
        #expect(streamed.boundaries.last == .endsContainer)
        let empty = try #require(snapshot.uploads.first { $0.name == "empty.bin" })
        #expect(empty.payloadChunkSizes == [0])
        #expect(empty.boundaries == [.endsContainer])
        #expect(snapshot.commands.filter { $0 == WriteOperation.sendObject.rawValue }.count == 3)
        try await backend.disconnect()
    }

    @Test func directoryCreationUsesOnlySendObjectInfoAndIsBrowsable() async throws {
        let device = try SyntheticUploadDevice()
        let backend = try await connectedUploadBackend(device)
        let result = try await backend.createUploadDirectory(
            storageID: 1, parent: "/", name: "旅行 📁")
        if case .created = result {} else { Issue.record("Expected directory creation") }

        let contents = try await backend.contents(storageID: 1, path: "/", showHiddenFiles: true)
        #expect(contents.first { $0.name == "旅行 📁" }?.isFolder == true)
        let snapshot = await device.snapshot()
        #expect(snapshot.directoryNames == ["旅行 📁"])
        #expect(snapshot.commands.filter { $0 == WriteOperation.sendObjectInfo.rawValue }.count == 1)
        #expect(!snapshot.commands.contains(WriteOperation.sendObject.rawValue))
        try await backend.disconnect()
    }

    @Test func freshCaseAndCanonicalConflictsSkipWithoutWriteOperations() async throws {
        let device = try SyntheticUploadDevice(existingNames: ["Photo.TXT", "café.txt"])
        let backend = try await connectedUploadBackend(device)
        let local = try SwiftUploadTestDirectory()
        let caseVariant = try local.file("photo.txt", data: Data([1]))
        let canonicalVariant = try local.file("cafe\u{301}.txt", data: Data([2]))

        #expect(isSkipped(try await backend.upload(
            storageID: 1, source: caseVariant, to: "/", progress: { _ in })))
        #expect(isSkipped(try await backend.upload(
            storageID: 1, source: canonicalVariant, to: "/", progress: { _ in })))

        let snapshot = await device.snapshot()
        #expect(snapshot.objectHandleQueries == 2)
        #expect(snapshot.writeOperationCommands.isEmpty)
        #expect(snapshot.uploads.isEmpty)
        try await backend.disconnect()
    }

    @MainActor @Test(arguments: [UInt16(0x200E), UInt16(0x200F)], [false, true])
    func onlyExplicitReadOnlyResponseDisablesWrites(code: UInt16, ranged: Bool) async throws {
        let device = try SyntheticUploadDevice(advertisedWrites: RangedUpload.requiredOperations.union([0x1019]))
        let backend = SwiftMTPBackend(canCancelActiveTransfer: ranged) { device }
        let model = DeviceBrowserModel(client: backend)
        await model.connectAndLoad()
        _ = try await backend.createUploadDirectory(storageID: 1, parent: "/", name: "Other")
        let local = try SwiftUploadTestDirectory()
        let source = try local.file("blocked.bin", data: Data([1, 2, 3]))
        await device.configureFault(reject: 0x100C, rejectionCode: code)
        await model.upload(sources: [source])
        #expect(model.state == .connected)
        #expect(!(await device.snapshot().closed))
        #expect(await device.storedData(named: "blocked.bin") == nil)
        #expect(model.transfers.results.contains {
            if case .failed(let message) = $0.outcome {
                message.contains(String(format: "0x%04x", code))
            } else { false }
        })
        #expect(model.canUpload == (code == 0x200F))
        #expect(model.canDropIntoBin == (code == 0x200F))
        #expect(await backend.supportsBinDeletion(storageID: 1) == (code == 0x200F))
        #expect(model.canOpenBin)
        let before = await device.snapshot().writeOperationCommands.count
        await device.configureFault()
        if code == 0x200E {
            await #expect(throws: UploadPreflightFailure.self) {
                try await backend.upload(storageID: 1, source: source, to: "/", progress: { _ in })
            }
            await #expect(throws: UploadPreflightFailure.self) {
                try await backend.createUploadDirectory(storageID: 1, parent: "/", name: "Retry")
            }
            #expect(await device.snapshot().writeOperationCommands.count == before)
        } else {
            // The same file and folder remain retryable after AccessDenied.
            await model.upload(sources: [source])
            #expect(await device.storedData(named: "blocked.bin") == Data([1, 2, 3]))
            _ = try await backend.createUploadDirectory(storageID: 1, parent: "/", name: "Retry")
            #expect(await device.snapshot().directoryNames.contains("Retry"))
        }
        await model.load(path: "/Other")
        #expect(model.canUpload == (code == 0x200F))
        if code == 0x200F {
            await model.upload(sources: [source])
            #expect(model.files.contains { $0.name == "blocked.bin" })
        }
        await model.load(path: "/")
        #expect(model.canUpload == (code == 0x200F))
        try await backend.disconnect()
        await device.prepareReconnect()
        _ = try await backend.connect()
        #expect(await backend.supportsUpload(to: 1))
        try await backend.disconnect()
    }

    @MainActor @Test(arguments: [UInt16(0), UInt16(1), UInt16(2)])
    func diagnosticsDistinguishAdvertisedWritesFromStoragePermissions(access: UInt16) async throws {
        let device = try SyntheticUploadDevice(accessCapability: access, advertisedWrites: [0x100C, 0x100D, 0x1019])
        let log = DiagnosticLog()
        let backend = SwiftMTPBackend(diagnostics: log) { device }
        let model = DeviceBrowserModel(client: backend, diagnostics: log)
        await model.connectAndLoad()
        let events = try #require(log.snapshot().capabilityEvents)
        let reported = try #require(events.first { $0.kind == .deviceCapabilities }?.capabilities)
        let browser = try #require(events.first { $0.kind == .browserCapabilities }?.capabilities)
        #expect(reported.storageAccess == access)
        #expect(reported.supportedOperations?.contains(0x100C) == true)
        #expect(reported.uploadEnabled == (access == 0))
        #expect(reported.binEnabled == (access == 0))
        #expect(browser.uploadEnabled == model.canUpload)
        #expect(browser.binEnabled == (access == 0))
        #expect(browser.binExists == (access == 0))
        #expect(browser.binDropEnabled == (access == 0))
        #expect(await device.snapshot().writeOperationCommands.isEmpty == (access != 0))
        try await backend.disconnect()
    }

    @Test func readOnlyStorageDisablesUploadAndDoesNotWrite() async throws {
        let device = try SyntheticUploadDevice(writable: false)
        let backend = try await connectedUploadBackend(device)
        #expect(!(await backend.supportsUpload(to: 1)))
        let local = try SwiftUploadTestDirectory()
        let source = try local.file("blocked.bin", data: Data([1, 2, 3]))
        await #expect(throws: UploadPreflightFailure.self) {
            try await backend.upload(storageID: 1, source: source, to: "/", progress: { _ in })
        }
        #expect(await device.snapshot().writeOperationCommands.isEmpty)
        try await backend.disconnect()
    }

    @Test func missingWriteCapabilityDisablesUploadAndDoesNotWrite() async throws {
        let advertised = Set([WriteOperation.sendObjectInfo.rawValue])
        let device = try SyntheticUploadDevice(advertisedWrites: advertised)
        let backend = try await connectedUploadBackend(device)
        #expect(!(await backend.supportsUpload(to: 1)))
        let local = try SwiftUploadTestDirectory()
        let source = try local.file("unsupported.bin", data: Data([4, 5, 6]))
        await #expect(throws: UploadPreflightFailure.self) {
            try await backend.upload(storageID: 1, source: source, to: "/", progress: { _ in })
        }
        #expect(await device.snapshot().writeOperationCommands.isEmpty)
        try await backend.disconnect()
    }

    @Test func postWriteMetadataMismatchInvalidatesWithoutRetry() async throws {
        let device = try SyntheticUploadDevice(metadataMismatch: true)
        let backend = try await connectedUploadBackend(device)
        let local = try SwiftUploadTestDirectory()
        let source = try local.file("mismatch.bin", data: Data(repeating: 0xA5, count: 257))

        await #expect(throws: BackendSessionError.reconnectRequired) {
            try await backend.upload(storageID: 1, source: source, to: "/", progress: { _ in })
        }
        let afterFailure = await device.snapshot()
        #expect(afterFailure.closed)
        #expect(afterFailure.uploads.count == 1)
        #expect(afterFailure.commands.filter { $0 == WriteOperation.sendObjectInfo.rawValue }.count == 1)
        #expect(afterFailure.commands.filter { $0 == WriteOperation.sendObject.rawValue }.count == 1)
        #expect(!(await backend.supportsUpload(to: 1)))
        await #expect(throws: UploadPreflightFailure.self) {
            try await backend.upload(storageID: 1, source: source, to: "/", progress: { _ in })
        }
        #expect(await device.snapshot().commands == afterFailure.commands)
    }

    @Test func postWriteTransportFailureInvalidatesWithoutRetry() async throws {
        let device = try SyntheticUploadDevice(failFinalObjectData: true)
        let backend = try await connectedUploadBackend(device)
        let local = try SwiftUploadTestDirectory()
        let bytes = Data(repeating: 0x5C, count: 513)
        let source = try local.file("transport.bin", data: bytes)

        await #expect(throws: BackendSessionError.reconnectRequired) {
            try await backend.upload(storageID: 1, source: source, to: "/", progress: { _ in })
        }
        let afterFailure = await device.snapshot()
        #expect(afterFailure.closed)
        #expect(afterFailure.uploads.isEmpty)
        #expect(afterFailure.failedPayloadBytes == bytes.count)
        #expect(afterFailure.objectDataWriteAttempts == 1)
        #expect(afterFailure.commands.filter { $0 == WriteOperation.sendObjectInfo.rawValue }.count == 1)
        #expect(afterFailure.commands.filter { $0 == WriteOperation.sendObject.rawValue }.count == 1)
        await #expect(throws: UploadPreflightFailure.self) {
            try await backend.upload(storageID: 1, source: source, to: "/", progress: { _ in })
        }
        #expect(await device.snapshot().commands == afterFailure.commands)
    }

    @MainActor @Test func coordinatorUsesVerifiedSwiftResultWithoutRedundantFolderScan() async throws {
        let device = try SyntheticUploadDevice()
        let backend = try await connectedUploadBackend(device)
        let local = try SwiftUploadTestDirectory()
        let source = try local.file("verified.bin", data: Data(repeating: 0x31, count: 73))
        let coordinator = TransferCoordinator()

        try await coordinator.upload(
            backend: backend, storageID: 1, sources: [source], directory: "/")

        #expect(coordinator.results.count == 1)
        #expect(coordinator.results.first?.outcome == .uploaded("/verified.bin"))
        // One fresh conflict listing belongs to the backend preflight. A second
        // one would be the redundant legacy verification scan.
        #expect(await device.snapshot().objectHandleQueries == 1)
        try await backend.disconnect()
    }

    @MainActor @Test func coordinatorReportsNoWritePreflightAsFailedAndContinues() async throws {
        let device = try SyntheticUploadDevice()
        let backend = try await connectedUploadBackend(device)
        let local = try SwiftUploadTestDirectory()
        let sources = try ["first.bin", "second.bin"].map {
            try local.file($0, data: Data([0x41]))
        }
        let coordinator = TransferCoordinator()

        try await coordinator.upload(
            backend: backend, storageID: 1, sources: sources, directory: "/Missing")

        #expect(coordinator.results.count == 2)
        #expect(coordinator.results.allSatisfy { if case .failed = $0.outcome { true } else { false } })
        #expect(coordinator.results.allSatisfy {
            if case .uploadUncertain = $0.outcome { false } else { true }
        })
        let snapshot = await device.snapshot()
        #expect(snapshot.objectHandleQueries == 2)
        #expect(snapshot.writeOperationCommands.isEmpty)
        #expect(!snapshot.closed)

        await #expect(throws: UploadPreflightFailure.self) {
            try await backend.createUploadDirectory(
                storageID: 1, parent: "/Missing", name: "New folder")
        }
        #expect(await device.snapshot().writeOperationCommands.isEmpty)
        try await backend.disconnect()
    }

    @MainActor @Test func coordinatorStopsForReconnectButDoesNotClaimPreflightRemoteUncertainty()
        async throws
    {
        let device = try SyntheticUploadDevice(failObjectHandleRead: true)
        let backend = try await connectedUploadBackend(device)
        let local = try SwiftUploadTestDirectory()
        let sources = try ["first.bin", "second.bin"].map {
            try local.file($0, data: Data([0x42]))
        }
        let coordinator = TransferCoordinator()

        await #expect(throws: BackendSessionError.reconnectRequired) {
            try await coordinator.upload(
                backend: backend, storageID: 1, sources: sources, directory: "/")
        }

        #expect(coordinator.results.count == 2)
        #expect({ if case .failed = coordinator.results[0].outcome { true } else { false } }())
        #expect(coordinator.results[1].outcome == .notAttempted)
        #expect(coordinator.results.allSatisfy {
            if case .uploadUncertain = $0.outcome { false } else { true }
        })
        let snapshot = await device.snapshot()
        #expect(snapshot.closed)
        #expect(snapshot.writeOperationCommands.isEmpty)
    }

    @MainActor @Test func coordinatorKeepsPostWriteTransportFailureUncertain() async throws {
        let device = try SyntheticUploadDevice(failFinalObjectData: true)
        let backend = try await connectedUploadBackend(device)
        let local = try SwiftUploadTestDirectory()
        let sources = try ["first.bin", "second.bin"].map {
            try local.file($0, data: Data([0x43]))
        }
        let coordinator = TransferCoordinator()

        await #expect(throws: BackendSessionError.reconnectRequired) {
            try await coordinator.upload(
                backend: backend, storageID: 1, sources: sources, directory: "/")
        }

        #expect(coordinator.results.count == 2)
        #expect({ if case .uploadUncertain = coordinator.results[0].outcome { true } else { false } }())
        #expect(coordinator.results[1].outcome == .notAttempted)
        let snapshot = await device.snapshot()
        #expect(snapshot.objectDataWriteAttempts == 1)
        #expect(snapshot.commands.filter { $0 == WriteOperation.sendObject.rawValue }.count == 1)
    }
}
