import Foundation
import MTPWire

/// An awaited child preserves diagnostic context without inheriting Cancel.
/// Use for metadata, final cleanup or a bounded range, never an entire file.
func finishTransaction<Value: Sendable>(
    _ operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    let task = Task { try await operation() }
    return try await task.value
}

enum RangedUpload {
    static let requiredOperations: Set<UInt16> = [
        WriteOperation.sendObjectInfo.rawValue, WriteOperation.sendObject.rawValue,
        ReadSession.beginEditObjectCode, ReadSession.sendPartialObjectCode,
        ReadSession.endEditObjectCode, 0x100B,
    ]

    static func send(
        session: ReadSession, created: ObjectCreationResult, info: ObjectInfo, reader: UploadFileReader,
        existingHandles: Set<UInt32>, diagnostics: DiagnosticLog?,
        progress: @escaping ProgressHandler
    ) async throws {
        guard let size = info.byteCount else { throw WireError.sizeLimit }
        // The caller has completed creation. Validate before handling Cancel so
        // cancellation can clean up only this newly created empty object.
        // Never open or delete a pre-existing object, including a reused handle.
        guard created.storageID == info.storageID,
            sameParent(created.parent, info.parent), !existingHandles.contains(created.handle)
        else { throw SwiftBackendError.invalidMetadata }
        let initial = try await finishTransaction {
            try await validate(session: session, handle: created.handle, info: info, size: 0)
        }

        var editing = false
        var offset: UInt64 = 0
        do {
            try Task.checkCancellation()
            if size > 0 {
                try await finishTransaction { try await session.beginEditObject(handle: created.handle) }
                editing = true
            }
            while offset < size {
                try Task.checkCancellation()
                let count = min(Int(ReadSession.maximumPartialObjectBytes), Int(size - offset))
                let data = try reader.read(maxBytes: count)
                guard data.count == count else { throw UploadError.sourceChanged }
                try Task.checkCancellation()
                let start = offset
                try await finishTransaction {
                    try await session.sendPartialObject(handle: created.handle, offset: start, data: data)
                }
                offset += UInt64(count)
                progress(TransferProgress(fileName: info.filename,
                    bytesTransferred: Int64(offset), totalBytes: Int64(size)))
            }
            try reader.finish()
            if editing {
                // Once attempted, never replay EndEditObject after an error.
                editing = false
                try await finishTransaction { try await session.endEditObject(handle: created.handle) }
            }
            try Task.checkCancellation()
        } catch {
            guard await session.isUsable else { throw error }
            if editing {
                try await finishTransaction { try await session.endEditObject(handle: created.handle) }
            }
            guard error is CancellationError else { throw error }
            let received = offset
            let started = DiagnosticLog.start()
            do {
                try await finishTransaction {
                    // Revalidate identity/location/size after closing the edit.
                    // If the device changed it, retain it for manual inspection.
                    _ = try await validate(session: session, handle: created.handle, info: info,
                        size: received, expectedFormat: initial.format)
                    try await session.deleteObject(handle: created.handle)
                    let remaining = try await session.objectHandles(
                        storageID: info.storageID, parent: info.parent == 0 ? UInt32.max : info.parent)
                    guard !remaining.contains(created.handle) else { throw SwiftBackendError.invalidMetadata }
                }
                diagnostics?.record(.uploadCleanup, since: started, bytes: Int(received))
            } catch {
                diagnostics?.record(.uploadCleanup, since: started, failure: .classify(error))
                throw error
            }
            throw UploadError.cancelledAndRemoved
        }
    }

    private static func sameParent(_ left: UInt32, _ right: UInt32) -> Bool {
        left == right || ([0, UInt32.max].contains(left) && [0, UInt32.max].contains(right))
    }

    private static func validate(
        session: ReadSession, handle: UInt32, info: ObjectInfo, size: UInt64,
        expectedFormat: UInt16? = nil
    ) async throws -> ObjectInfo {
        let actual = try await session.objectInfo(handle: handle)
        guard actual.storageID == info.storageID, sameParent(actual.parent, info.parent),
            Data(actual.filename.utf8) == Data(info.filename.utf8),
            expectedFormat == nil || actual.format == expectedFormat,
            !actual.isDirectory, actual.byteCount == size else { throw SwiftBackendError.invalidMetadata }
        // Android derives this from the filename, so it may differ from the
        // generic format requested during creation. Retain it for cleanup checks.
        return actual
    }
}
