import Foundation
import MTPWire

struct BackendCapabilities: Sendable, Equatable {
    let reportsProgress: Bool
    let canCancelActiveTransfer: Bool
}

struct TransferProgress: Sendable, Equatable {
    let fileName: String
    let bytesTransferred: Int64
    let totalBytes: Int64?
}

typealias ProgressHandler = @Sendable (TransferProgress) -> Void

/// Backend-independent contract. Object identifiers are valid only in their session.
/// Destructive/optional operations will be added with capability-specific contracts.
protocol MTPBackend: Sendable {
    var capabilities: BackendCapabilities { get }
    /// Download cancellation can depend on device-advertised read operations.
    func supportsDownloadCancellation() async -> Bool
    func deviceDetails() async -> MTPDeviceDetails?
    func connect() async throws -> [MTPStorage]
    func browseContents(storageID: UInt32, path: String, showHiddenFiles: Bool) async throws -> MTPDirectoryListing
    func contents(storageID: UInt32, path: String, showHiddenFiles: Bool) async throws -> [MTPFile]
    func download(
        storageID: UInt32, files: [MTPFile], to destination: URL,
        progress: @escaping ProgressHandler) async throws
    @discardableResult func disconnect() async throws -> Bool
}

/// A partial view is for display only. Transfers, conflict checks and Bin
/// operations must continue to use strict contents(), never this snapshot.
struct MTPDirectoryListing: Sendable {
    let files: [MTPFile]
    var unavailableCount = 0
    var warning: String? {
        unavailableCount == 0 ? nil :
            "The device listed \(unavailableCount) unavailable item(s) in this folder or its parent folders. Available items are shown. Refresh to try again."
    }
}

enum MoveError: LocalizedError, Equatable {
    case unverified, notApplied, recoveryUnavailable, recoveryFailed
    var errorDescription: String? {
        switch self {
        case .unverified:
            "The device accepted the move, but its file listing could not confirm the result. Inspect the source and destination before retrying. No move was repeated; Bin recovery information, if present, remains on the device."
        case .notApplied:
            "The device reported success, but the file is still listed in its original folder. Browsing was restored automatically. The move was not repeated and the remaining items were stopped."
        case .recoveryUnavailable:
            "The device reported success but its file listing is inconsistent, and it rejected automatic recovery. The connection remains open so you can browse available files. Unplug and reconnect this device's USB cable to retry a full listing, then inspect the source and destination. The move was not repeated."
        case .recoveryFailed:
            "The device reported success but left its file listing inconsistent. Automatic recovery could not restore a verified listing. Unplug and reconnect this device's USB cable, then inspect the source and destination. The move was not repeated."
        }
    }
}

extension MTPBackend {
    func browseContents(storageID: UInt32, path: String, showHiddenFiles: Bool) async throws -> MTPDirectoryListing {
        MTPDirectoryListing(files: try await contents(storageID: storageID, path: path, showHiddenFiles: showHiddenFiles))
    }
    func deviceDetails() async -> MTPDeviceDetails? { nil }
    func supportsDownloadCancellation() async -> Bool { capabilities.canCancelActiveTransfer }
}

/// Device-side moves are independent of upload and Bin creation capabilities.
protocol MTPMoveBackend: MTPBackend {
    func supportsMove(storageID: UInt32) async -> Bool
    func move(storageID: UInt32, file: MTPFile, to directory: String) async throws -> MTPFile
}

struct StorageWriteCapabilities: Sendable {
    let upload: Bool
    let move: Bool
}

/// Optional capability for backends that can replace a poisoned transport and
/// MTP session without replaying the operation that invalidated them.
protocol MTPFreshSessionBackend: MTPBackend {
    func replaceSession() async throws -> [MTPStorage]
}

/// Optional capability: single-file uploads only. The backend must serialize the
/// fresh (including hidden files) conflict check and write as one local operation.
/// MTP does not offer atomic create-if-absent against changes on the device itself.
protocol MTPUploadBackend: MTPBackend {
    /// Largest regular file this backend can encode in one upload container.
    /// `nil` means that the backend does not expose a useful preflight limit.
    var maximumUploadFileSize: Int64? { get }

    /// Runtime capability check. A backend may support uploads in general while
    /// the connected device or selected storage does not.
    func supportsUploadCancellation(to storageID: UInt32) async -> Bool
    func supportsUpload(to storageID: UInt32) async -> Bool
    func upload(
        storageID: UInt32, source: URL, to directory: String,
        progress: @escaping ProgressHandler
    ) async throws -> UploadDisposition
}

extension MTPUploadBackend {
    var maximumUploadFileSize: Int64? { nil }
    func supportsUploadCancellation(to storageID: UInt32) async -> Bool { capabilities.canCancelActiveTransfer }
    func supportsUpload(to storageID: UInt32) async -> Bool { true }
}

enum UploadDisposition: Sendable {
    /// Default result. The coordinator verifies it with a fresh listing.
    case uploaded
    /// The backend already verified this exact remote object after writing it.
    case uploadedVerified(MTPFile)
    case skippedExisting
}

/// Directory creation is a separate optional capability. Existing names, even
/// directories, are skipped: the preview does not merge into existing trees.
protocol MTPFolderUploadBackend: MTPUploadBackend {
    func createUploadDirectory(storageID: UInt32, parent: String, name: String) async throws
        -> UploadDirectoryDisposition
}

enum UploadDirectoryDisposition: Sendable { case created, skippedExisting }

enum UploadError: LocalizedError, Equatable {
    case unsupportedSource, sourceChanged, readOnlyStorage, unsupportedBackend
    case cancelledSessionRecovered, cancelledAndRemoved
    case rejected(String)
    case verificationFailed
    var errorDescription: String? {
        switch self {
        case .unsupportedSource:
            "This item is not a supported regular file. Packages, symbolic links and special files are not supported."
        case .sourceChanged: "The source changed while preparing its upload. Try again after saving the file."
        case .readOnlyStorage: "This device storage reports that it is read-only."
        case .unsupportedBackend: "This backend does not support uploads."
        case .cancelledAndRemoved:
            "Upload cancelled. The incomplete file was removed and the device remains connected."
        case .cancelledSessionRecovered:
            "Upload cancelled. The device completed MTP cancellation and is ready for another command."
        case .rejected(let message): message
        case .verificationFailed:
            "The device did not report exactly one uploaded file with the expected size."
        }
    }
}

/// The backend failed before invoking its first remote write operation. The
/// coordinator may report the item as failed rather than remotely uncertain,
/// while still terminating the batch when the read-side preflight lost the
/// session. The underlying error remains the user-facing and diagnostic cause.
struct UploadPreflightFailure: LocalizedError, DiagnosticError {
    let underlying: any Error
    init(_ underlying: any Error) { self.underlying = underlying }

    var errorDescription: String? { underlying.localizedDescription }
    var diagnosticFailure: DiagnosticFailure { .classify(underlying) }
}


enum BackendError: LocalizedError, Equatable, DiagnosticError {
    case disconnected
    case noStorage
    case invalidPath(String)
    case busy

    var errorDescription: String? {
        switch self {
        case .disconnected: "The device is disconnected."
        case .noStorage:
            "No MTP storage became available. Keep the device unlocked, reselect File Transfer, and reconnect."
        case .invalidPath(let path): "Unsafe or invalid file path: \(path)"
        case .busy: "An operation is already running."
        }
    }

    var diagnosticFailure: DiagnosticFailure {
        switch self {
        case .disconnected: .disconnected
        case .noStorage: .noStorage
        case .busy: .busy
        case .invalidPath: .other
        }
    }
}

/// A backend has positively determined that the current MTP session can no
/// longer be used. Callers must discard every storage/object handle and make a
/// new connection; this is deliberately distinct from an ordinary per-file
/// rejection that may be safely followed by the next transfer.
enum BackendSessionError: LocalizedError, Equatable {
    case reconnectRequired
    case physicalReconnectRequired
    case listingRecoveryFailed
    case usbTransportFailure(String)

    static func from(_ error: any Error) -> BackendSessionError? {
        if error as? MoveError == .recoveryFailed { return .listingRecoveryFailed }
        if let preflight = error as? UploadPreflightFailure { return from(preflight.underlying) }
        if let sessionError = error as? BackendSessionError { return sessionError }
        return error as? BackendError == .disconnected ? .reconnectRequired : nil
    }

    var errorDescription: String? {
        switch self {
        case .physicalReconnectRequired:
            "The device did not confirm transfer cancellation. Unplug its USB cable, reconnect it and select File Transfer before trying again. A partial upload may remain; no operation was replayed."
        case .listingRecoveryFailed:
            MoveError.recoveryFailed.localizedDescription
        case .reconnectRequired:
            "The device session was lost or changed. Reconnect before continuing."
        case .usbTransportFailure(let message):
            "The USB/MTP connection failed and can no longer be used: \(message)"
        }
    }
}

/// An actor can reenter at an await; this gate keeps whole operations exclusive.
/// Cancelled waiters acquire and release their turn without entering the backend.
actor OperationGate {
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private func acquire() async {
        if !held {
            held = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty { held = false } else { waiters.removeFirst().resume() }
    }

    func run<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }

    /// Optional work never joins the queue ahead of a user's next operation.
    func runIfIdle<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        guard !held else { throw BackendError.busy }
        try Task.checkCancellation()
        held = true
        defer { release() }
        return try await operation()
    }
}
