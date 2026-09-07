import Foundation
import MTPWire

/// Snapshots survive spring-loaded browsing, but never a session replacement.
@MainActor
struct RemoteDragSelection {
    let browserID: UUID
    let source: ManagedDevice
    let connectionToken: Int
    let storageID: UInt32
    let files: [MTPFile]
    var tokens: [RemoteDragItem] { files.map { RemoteDragItem(browserID: browserID, handle: $0.id) } }
}

enum RemoteDropOperation: String { case move = "Move", copy = "Copy" }

@MainActor
struct RemoteTransferRequest {
    let source: RemoteDragSelection
    let destination: ManagedDevice
    let destinationConnection: Int
    let storageID: UInt32
    let directory: String
    let operation: RemoteDropOperation

    var participants: [DeviceBrowserModel] {
        source.source === destination ? [destination.browser] : [source.source.browser, destination.browser]
    }
    var isCurrent: Bool {
        source.source.browser.connectionToken == source.connectionToken
            && destination.browser.connectionToken == destinationConnection
            && source.source.browser.isConnected && destination.browser.isConnected
            && (operation == .move ? destination.browser.storageWriteCapabilities[storageID]?.move == true
                : destination.browser.storageWriteCapabilities[storageID]?.upload == true)
            && !destination.browser.isBinPath(directory, storageID: storageID)
    }
}

struct RemoteTransferResult: Equatable {
    enum Outcome: Equatable { case moved, copied, folderCreated, skipped, excluded, failed(String), uncertain(String), cancelled, notAttempted }
    let path: String
    let outcome: Outcome
}

/// Coordinates existing, independently cancellable download/upload batches.
/// Only the current file is staged locally; completed copies never delete a source.
@MainActor
final class RemoteTransferCoordinator: ObservableObject {
    enum Phase { case preparing, moving, downloading, uploading, creatingFolder, finished }
    let request: RemoteTransferRequest
    let download: TransferCoordinator
    let upload: TransferCoordinator
    @Published private(set) var phase: Phase = .preparing
    @Published private(set) var stopRequested = false
    @Published private(set) var fileName = ""
    @Published private(set) var plannedCount = 0
    @Published private(set) var results: [RemoteTransferResult] = []
    private(set) var sourceSessionError: BackendSessionError?
    private(set) var destinationSessionError: BackendSessionError?
    private var planningCancellation = PlanningCancellation()
    private var started = false
    private var temporaryDirectory: URL?
    private var readingSource = true

    init(request: RemoteTransferRequest) {
        self.request = request
        download = TransferCoordinator(diagnostics: request.source.source.browser.diagnosticLog)
        upload = TransferCoordinator(diagnostics: request.destination.browser.diagnosticLog)
    }

    var active: TransferCoordinator? {
        switch phase { case .downloading: download; case .uploading: upload; default: nil }
    }
    var title: String {
        "\(request.operation.rawValue): \(request.source.source.displayName) → \(request.destination.displayName)"
    }
    var status: String {
        switch phase {
        case .preparing: "Preparing transfer…"
        case .moving: "Moving \(fileName)"
        case .downloading: "Downloading \(fileName) to temporary storage"
        case .uploading: "Uploading \(fileName) to destination"
        case .creatingFolder: "Creating \(fileName)"
        case .finished: "Transfer finished"
        }
    }
    func cancel() {
        guard phase != .finished else { return }
        stopRequested = true
        planningCancellation.cancel()
        active?.cancelTransfer()
    }

    func run() async {
        guard !started else { return }
        started = true
        defer {
            if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
            phase = .finished
        }
        do {
            guard request.isCurrent else { throw BackendSessionError.reconnectRequired }
            try await validateSources()
            try checkpoint()
            if request.operation == .move { try await move(); return }
            try await copy()
        } catch is CancellationError {
            if results.isEmpty { results.append(RemoteTransferResult(path: "Selection", outcome: .cancelled)) }
        } catch {
            markSessionFailure(error)
            results.append(RemoteTransferResult(path: fileName.isEmpty ? "Selection" : fileName, outcome: .failed(error.localizedDescription)))
        }
    }

    private func checkpoint() throws {
        if stopRequested || Task.isCancelled { throw CancellationError() }
        guard request.isCurrent else { throw BackendSessionError.reconnectRequired }
    }

    private func markSessionFailure(_ error: any Error) {
        guard let session = BackendSessionError.from(error) else { return }
        if !request.source.source.browser.isConnected { sourceSessionError = session }
        if !request.destination.browser.isConnected { destinationSessionError = session }
        if sourceSessionError == nil && destinationSessionError == nil {
            if readingSource { sourceSessionError = session } else { destinationSessionError = session }
        }
    }

    private func validateSources() async throws {
        readingSource = true
        let backend = request.source.source.browser.client
        for parent in Set(request.source.files.map(\.parentPath)) {
            try checkpoint()
            let current = try await backend.contents(storageID: request.source.storageID, path: parent, showHiddenFiles: true)
            guard request.source.files.filter({ $0.parentPath == parent }).allSatisfy(current.contains) else {
                throw SwiftBackendError.staleSelection
            }
        }
    }

    private func move() async throws {
        guard let backend = request.source.source.browser.client as? any MTPMoveBackend,
              await backend.supportsMove(storageID: request.storageID) else { throw BinError.unsupported }
        plannedCount = request.source.files.count
        phase = .moving
        for (index, file) in request.source.files.enumerated() {
            if stopRequested { appendPending(request.source.files[index...].map(\.path)); break }
            fileName = file.name
            do {
                try checkpoint()
                let moved = try await backend.move(storageID: request.storageID, file: file, to: request.directory)
                results.append(RemoteTransferResult(path: file.path, outcome: .moved))
                if moved.sessionID != file.sessionID {
                    appendPending(request.source.files.dropFirst(index + 1).map(\.path))
                    break
                }
            } catch is CancellationError {
                stopRequested = true
                results.append(RemoteTransferResult(path: file.path, outcome: .cancelled))
                appendPending(request.source.files.dropFirst(index + 1).map(\.path)); break
            } catch BinError.conflict {
                results.append(RemoteTransferResult(path: file.path, outcome: .skipped))
            } catch let error as MoveError where error == .unverified || error == .recoveryUnavailable {
                results.append(RemoteTransferResult(path: file.path, outcome: .uncertain(error.localizedDescription)))
                appendPending(request.source.files.dropFirst(index + 1).map(\.path))
                break
            } catch MoveError.notApplied {
                results.append(RemoteTransferResult(path: file.path, outcome: .failed(MoveError.notApplied.localizedDescription)))
                appendPending(request.source.files.dropFirst(index + 1).map(\.path))
                break
            } catch MoveError.recoveryFailed {
                sourceSessionError = .listingRecoveryFailed
                results.append(RemoteTransferResult(path: file.path, outcome: .uncertain(MoveError.recoveryFailed.localizedDescription)))
                appendPending(request.source.files.dropFirst(index + 1).map(\.path))
                break
            } catch BinError.uncertain {
                sourceSessionError = .reconnectRequired
                results.append(RemoteTransferResult(path: file.path, outcome: .uncertain("Inspect the source and destination before retrying the move.")))
                appendPending(request.source.files.dropFirst(index + 1).map(\.path))
                break
            } catch {
                markSessionFailure(error)
                results.append(RemoteTransferResult(path: file.path, outcome: .failed(error.localizedDescription)))
                if sourceSessionError != nil {
                    appendPending(request.source.files.dropFirst(index + 1).map(\.path)); break
                }
            }
        }
    }

    private func copy() async throws {
        let source = request.source.source.browser.client
        guard let destination = request.destination.browser.client as? any MTPUploadBackend,
              await destination.supportsUpload(to: request.storageID) else { throw UploadError.unsupportedBackend }
        let cancellation = planningCancellation
        let plan = try await DownloadPlan.build(files: request.source.files, backend: source,
            storageID: request.source.storageID, cancelled: { cancellation.isCancelled })
        try checkpoint()
        plannedCount = plan.count
        if plan.contains(where: { $0.file.isFolder }), !(destination is any MTPFolderUploadBackend) {
            throw UploadError.unsupportedBackend
        }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("piko-device-copy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        temporaryDirectory = temporary
        var blocked: [([String], RemoteTransferResult.Outcome)] = []
        for (index, item) in plan.enumerated() {
            if stopRequested { appendPending(plan[index...].map(\.file.path)); break }
            let file = item.file
            fileName = file.name
            if let blocked = blocked.first(where: { item.components.starts(with: $0.0) }) {
                results.append(RemoteTransferResult(path: file.path, outcome: blocked.1)); continue
            }
            let parent = item.components.dropLast().reduce(request.directory) { RemotePath.appending($1, to: $0) }
            var creatingDirectory = false
            var uploadingFile = false
            do {
                try checkpoint()
                readingSource = false
                // Check conflicts before downloading bytes. The backend repeats
                // this check immediately before creation to catch later races.
                let current = try await destination.contents(storageID: request.storageID, path: parent, showHiddenFiles: true)
                if current.contains(where: { RemotePath.collisionKey($0.name) == RemotePath.collisionKey(file.name) }) {
                    if file.isFolder { blocked.append((item.components, .skipped)) }
                    results.append(RemoteTransferResult(path: file.path, outcome: .skipped)); continue
                }
                try checkpoint()
                if file.isFolder {
                    phase = .creatingFolder
                    guard let folderBackend = destination as? any MTPFolderUploadBackend else { throw UploadError.unsupportedBackend }
                    creatingDirectory = true
                    let disposition = try await folderBackend.createUploadDirectory(storageID: request.storageID, parent: parent, name: file.name)
                    if disposition == .skippedExisting { blocked.append((item.components, .skipped)) }
                    results.append(RemoteTransferResult(path: file.path, outcome: disposition == .created ? .folderCreated : .skipped))
                } else {
                    if let limit = destination.maximumUploadFileSize, file.size > limit { throw SwiftBackendError.unsupportedSize }
                    // Preserve the existing upload metadata exclusion policy.
                    if file.name == ".DS_Store" {
                        results.append(RemoteTransferResult(path: file.path, outcome: .excluded)); continue
                    }
                    let staging = temporary.appendingPathComponent(UUID().uuidString)
                    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                    defer { try? FileManager.default.removeItem(at: staging) }
                    readingSource = true
                    phase = .downloading
                    try await download.run(backend: source, storageID: request.source.storageID, files: [file], destination: staging)
                    if let failure = download.summary.failed.first, case .failed(let message) = failure.outcome { throw UploadError.rejected(message) }
                    try checkpoint()
                    guard download.summary.downloaded == 1 else { throw TransferError.invalidDownloadedFile }
                    readingSource = false
                    uploadingFile = true
                    phase = .uploading
                    try await upload.upload(backend: destination, storageID: request.storageID,
                        sources: [staging.appendingPathComponent(file.name)], directory: parent)
                    if let uncertain = upload.summary.uncertain.first, case .uploadUncertain(let message) = uncertain.outcome {
                        destinationSessionError = .reconnectRequired
                        results.append(RemoteTransferResult(path: file.path, outcome: .uncertain(message)))
                        appendPending(plan.dropFirst(index + 1).map(\.file.path)); break
                    }
                    if !upload.summary.cancelled.isEmpty {
                        stopRequested = true
                        results.append(RemoteTransferResult(path: file.path, outcome: .cancelled))
                    } else if let failure = upload.summary.failed.first, case .failed(let message) = failure.outcome {
                        results.append(RemoteTransferResult(path: file.path, outcome: .failed(message)))
                    } else {
                        results.append(RemoteTransferResult(path: file.path, outcome: upload.summary.uploaded == 1 ? .copied : .skipped))
                    }
                }
            } catch is CancellationError {
                stopRequested = true
                results.append(RemoteTransferResult(path: file.path, outcome: .cancelled))
                appendPending(plan.dropFirst(index + 1).map(\.file.path)); break
            } catch {
                markSessionFailure(error)
                let failure = UploadFailure(error, writeAttempted: creatingDirectory)
                let uncertainWrite = !readingSource && (uploadingFile && !upload.summary.uncertain.isEmpty || failure.isUncertain)
                if uncertainWrite { destinationSessionError = destinationSessionError ?? .reconnectRequired }
                results.append(RemoteTransferResult(path: file.path,
                    outcome: uncertainWrite ? .uncertain(failure.underlying.localizedDescription) : .failed(failure.underlying.localizedDescription)))
                if file.isFolder { blocked.append((item.components, .notAttempted)) }
                if sourceSessionError != nil || destinationSessionError != nil {
                    appendPending(plan.dropFirst(index + 1).map(\.file.path)); break
                }
            }
        }
    }

    private func appendPending(_ paths: [String]) {
        results += paths.map { RemoteTransferResult(path: $0, outcome: .notAttempted) }
    }

    var attentionMessage: String? {
        let hasIssue = sourceSessionError != nil || destinationSessionError != nil
            || upload.summary.cancellationNeedsInspection || results.contains {
                switch $0.outcome {
                case .failed, .uncertain, .skipped: true
                case .notAttempted: !stopRequested
                default: false
                }
            }
        guard hasIssue else { return nil }
        return resultMessage + (upload.summary.cancellationNeedsInspection
            ? "\n\n" + upload.summary.uploadMessage(directory: request.directory) : "")
    }

    var resultMessage: String {
        func count(_ outcome: RemoteTransferResult.Outcome) -> Int { results.filter { $0.outcome == outcome }.count }
        let failures = results.filter { if case .failed = $0.outcome { true } else { false } }
        let uncertain = results.filter { if case .uncertain = $0.outcome { true } else { false } }
        let details = (failures + uncertain).prefix(8).map { item in
            let message: String
            switch item.outcome { case .failed(let value), .uncertain(let value): message = value; default: message = "" }
            return "\((item.path as NSString).lastPathComponent): \(message)"
        }.joined(separator: "\n")
        return "\(title)\nDestination: \(request.directory)\n\n"
            + "\(count(.moved)) moved, \(count(.copied)) copied (size checked), \(count(.folderCreated)) folders created, "
            + "\(count(.skipped)) conflicts skipped, \(count(.excluded)) metadata items excluded, \(failures.count) failed, "
            + "\(uncertain.count) uncertain, \(count(.cancelled)) cancelled, \(count(.notAttempted)) not attempted."
            + (stopRequested ? "\nTransfer stopped. Completed items were kept." : "")
            + (request.operation == .copy ? "\nOriginal files remain on the source device." : "")
            + (details.isEmpty ? "" : "\n\n\(details)")
    }
}
