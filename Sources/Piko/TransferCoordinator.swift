import Combine
import Foundation
import MTPWire

/// Transfers are serialized. Downloads are staged on the destination filesystem;
/// uploads use private local snapshots and report ambiguous remote outcomes.
@MainActor
final class TransferCoordinator: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var isPlanning = false
    @Published private(set) var stopRequested = false
    private(set) var cancellationRequested = false
    @Published private(set) var progress: TransferProgress?
    @Published private(set) var results: [TransferResult] = []
    @Published private(set) var plannedCount = 0
    var summary: TransferSummary { TransferSummary(results) }

    @Published private(set) var isUploading = false
    @Published private(set) var canCancelActiveTransfer = false
    private var progressToken: UUID?
    private var planningCancellation: PlanningCancellation?
    private var activeOperationToken: UUID?
    private var activeOperationCancellation: (@Sendable () -> Void)?
    private var diagnosticTransferID: UInt64?
    private let diagnostics: DiagnosticLog?
    private let uploadPlanner:
        @Sendable ([URL], PlanningCancellation) throws -> [UploadPlanItem]
    private let uploadSnapshotter: @Sendable (UploadPlanItem) throws -> UploadSnapshot

    init(
        diagnostics: DiagnosticLog? = nil,
        uploadPlanner: @escaping @Sendable ([URL], PlanningCancellation) throws
            -> [UploadPlanItem] = { sources, cancellation in
                try UploadPlan.build(
                    sources: sources, cancelled: { cancellation.isCancelled })
        },
        uploadSnapshotter: @escaping @Sendable (UploadPlanItem) throws -> UploadSnapshot = { item in
            try item.makeSnapshot(cancelled: { Task.isCancelled })
        }
    ) {
        self.diagnostics = diagnostics
        self.uploadPlanner = uploadPlanner
        self.uploadSnapshotter = uploadSnapshotter
    }

    func stopAfterCurrentFile() {
        guard isRunning else { return }
        diagnostics?.record(
            .stopAfterCurrentFile, bytes: progress.map { Int($0.bytesTransferred) },
            transferID: diagnosticTransferID,
            transferDirection: isUploading ? .upload : .download)
        stopRequested = true
        planningCancellation?.cancel()
        if isPlanning { activeOperationCancellation?() }
    }

    /// Cancels planning, snapshotting, or the active backend operation. Only
    /// backends that can stop the active file safely opt in.
    func cancelTransfer() {
        guard isRunning else { return }
        guard isPlanning || canCancelActiveTransfer else {
            stopAfterCurrentFile()
            return
        }
        cancellationRequested = true
        diagnostics?.record(
            .cancelRequested, bytes: progress.map { Int($0.bytesTransferred) },
            transferID: diagnosticTransferID,
            transferDirection: isUploading ? .upload : .download)
        stopRequested = true
        planningCancellation?.cancel()
        activeOperationCancellation?()
    }

    func run(
        backend: any MTPBackend, storageID: UInt32, files: [MTPFile], destination: URL,
        conflicts: ConflictPolicy = .keepBoth, diagnosticTransferID: UInt64? = nil,
        consumeDownload: (@MainActor (URL, MTPFile) async throws -> Void)? = nil
    ) async throws {
        try beginBatch(
            uploading: false, canCancelActiveTransfer: false,
            diagnosticTransferID: diagnosticTransferID)
        defer { endBatch() }
        canCancelActiveTransfer = await backend.supportsDownloadCancellation()
        if stopRequested { throw CancellationError() }

        let output = try DownloadDestination(destination)
        let cancellation = PlanningCancellation()
        planningCancellation = cancellation
        let items = try await performCancellable(
            interruptible: canCancelActiveTransfer, cancelAlso: { cancellation.cancel() }
        ) {
            try await DownloadPlan.build(
                files: files, backend: backend, storageID: storageID,
                cancelled: { cancellation.isCancelled })
        }
        planningCancellation = nil
        if stopRequested { throw CancellationError() }
        plannedCount = items.count
        isPlanning = false
        var terminalSessionError: BackendSessionError?

        for (index, item) in items.enumerated() {
            if terminalSessionError != nil {
                appendNotAttempted(items[index...].map(\.file.path))
                break
            }
            if Task.isCancelled {
                appendNotAttempted(items[index...].map(\.file.path))
                throw CancellationError()
            }
            if stopRequested {
                results.append(TransferResult(source: item.file.path, outcome: .notAttempted))
                continue
            }
            defer { endProgress() }
            do {
                guard let target = try output.prepare(item, conflicts: conflicts) else {
                    results.append(TransferResult(source: item.file.path, outcome: .skipped))
                    continue
                }
                if item.file.isFolder {
                    results.append(TransferResult(source: item.file.path, outcome: .createdDirectory(target)))
                    continue
                }
                let staging = try output.makeStagingDirectory()
                defer { try? FileManager.default.removeItem(at: staging) }
                let handler = beginProgress(
                    fileName: item.file.name,
                    totalBytes: item.file.size >= 0 ? item.file.size : nil)
                try await performCancellable(interruptible: canCancelActiveTransfer) {
                    try await backend.download(
                        storageID: storageID, files: [item.file], to: staging, progress: handler)
                }
                try Task.checkCancellation()
                let staged = staging.appendingPathComponent(item.file.name)
                let published = try output.publish(staged, item: item, target: target, conflicts: conflicts)
                if let published, let consumeDownload {
                    try await consumeDownload(published, item.file)
                }
                results.append(
                    TransferResult(
                        source: item.file.path,
                        outcome: published.map { .downloaded($0) } ?? .skipped))

            } catch is CancellationError {
                appendNotAttempted(items[index...].map(\.file.path))
                throw CancellationError()
            } catch {
                results.append(
                    TransferResult(source: item.file.path, outcome: .failed(error.localizedDescription)))
                if let sessionError = BackendSessionError.from(error) {
                    terminalSessionError = sessionError
                    stopRequested = true
                }
            }
        }
        if let terminalSessionError { throw terminalSessionError }
        try Task.checkCancellation()
    }

    /// Uploads files/trees; existing directory names conflict with the entire subtree.
    /// Never retries or deletes a remote object after an ambiguous write failure.
    func upload(
        backend: any MTPUploadBackend, storageID: UInt32, sources: [URL],
        directory: String, diagnosticTransferID: UInt64? = nil
    ) async throws {
        guard !isRunning else { throw BackendError.busy }
        try RemotePath.validate(directory)
        try beginBatch(
            uploading: true, canCancelActiveTransfer: false,
            diagnosticTransferID: diagnosticTransferID)
        defer { endBatch() }
        canCancelActiveTransfer = await backend.supportsUploadCancellation(to: storageID)
        if stopRequested { throw CancellationError() }
        let cancellation = PlanningCancellation()
        let planner = uploadPlanner
        let snapshotter = uploadSnapshotter
        planningCancellation = cancellation
        let items = try await performCancellable(cancelAlso: { cancellation.cancel() }) {
            try planner(sources, cancellation)
        }
        if stopRequested { throw CancellationError() }
        try Task.checkCancellation()
        if items.contains(where: { if case .directory = $0.kind { true } else { false } }),
            !(backend is any MTPFolderUploadBackend)
        {
            throw UploadError.unsupportedBackend
        }
        plannedCount = items.count
        isPlanning = false
        planningCancellation = nil
        var blockedSubtrees: [[String]: TransferResult.Outcome] = [:]
        var terminalSessionError: BackendSessionError?
        for (index, item) in items.enumerated() {
            let source = item.source
            if terminalSessionError != nil {
                appendNotAttempted(items[index...].map(\.source.path))
                break
            }
            if Task.isCancelled {
                appendNotAttempted(items[index...].map(\.source.path))
                throw CancellationError()
            }
            if stopRequested {
                results.append(TransferResult(source: source.path, outcome: .notAttempted))
                continue
            }
            if let blocked = blockedSubtrees.first(where: {
                item.components.count > $0.key.count && item.components.starts(with: $0.key)
            }) {
                results.append(TransferResult(source: source.path, outcome: blocked.value))
                continue
            }
            if case .excluded(let reason) = item.kind {
                results.append(TransferResult(source: source.path, outcome: .uploadExcluded(reason)))
                continue
            }
            let destination = item.remoteParent(in: directory)
            var writeAttempted = false
            defer { endProgress() }
            do {
                if case .directory = item.kind {
                    try item.validateForSnapshot()
                    guard let folderBackend = backend as? any MTPFolderUploadBackend else {
                        throw UploadError.unsupportedBackend
                    }
                    writeAttempted = true
                    let result = try await performCancellable(interruptible: false) {
                        try await folderBackend.createUploadDirectory(
                            storageID: storageID,
                            parent: destination, name: source.lastPathComponent)
                    }
                    if result == .skippedExisting {
                        let conflict = TransferResult.Outcome.uploadConflict(
                            "An item named \"\(source.lastPathComponent)\" already exists on the device. The folder tree was not merged.")
                        results.append(TransferResult(source: source.path, outcome: conflict))
                        blockedSubtrees[item.components] = conflict
                    } else {
                        let path =
                            RemotePath.appending(source.lastPathComponent, to: destination)
                        results.append(TransferResult(source: source.path, outcome: .uploadedDirectory(path)))
                    }
                    continue
                }
                if let plannedSize = item.plannedFileSize,
                    let maximumSize = backend.maximumUploadFileSize,
                    plannedSize > maximumSize
                {
                    throw UploadError.rejected(
                        "This file is too large for an ordinary MTP upload. Extended-length uploads are not supported yet."
                    )
                }
                isPlanning = true
                // Snapshot outside the main actor. The backend gets an immutable private
                // copy, not a path an editor may change halfway through transfer.
                let snapshot = try await performCancellable {
                    try snapshotter(item)
                }
                defer { snapshot.remove() }
                isPlanning = false
                if Task.isCancelled {
                    throw CancellationError()
                }
                if stopRequested {
                    results.append(TransferResult(source: source.path, outcome: .notAttempted))
                    continue
                }
                let handler = beginProgress(fileName: source.lastPathComponent, totalBytes: snapshot.size)
                writeAttempted = true
                let disposition = try await performCancellable(interruptible: canCancelActiveTransfer) {
                    try await backend.upload(
                        storageID: storageID, source: snapshot.file, to: destination, progress: handler)
                }
                if case .skippedExisting = disposition {
                    results.append(
                        TransferResult(
                            source: source.path,
                            outcome: .uploadConflict(
                                "An item named \"\(source.lastPathComponent)\" already exists on the device. Nothing was uploaded.")))
                    continue
                }
                if case .uploadedVerified(let uploaded) = disposition {
                    guard RemotePath.collisionKey(uploaded.name) == RemotePath.collisionKey(source.lastPathComponent),
                        !uploaded.isFolder, uploaded.size == snapshot.size
                    else { throw UploadError.verificationFailed }
                    results.append(
                        TransferResult(source: source.path, outcome: .uploaded(uploaded.path)))
                    continue
                }
                let contents = try await performCancellable(interruptible: canCancelActiveTransfer) {
                    try await backend.contents(
                        storageID: storageID, path: destination, showHiddenFiles: true)
                }
                let matches = contents.filter {
                    RemotePath.collisionKey($0.name) == RemotePath.collisionKey(source.lastPathComponent)
                }
                guard matches.count == 1, let uploaded = matches.first,
                    !uploaded.isFolder, uploaded.size == snapshot.size
                else { throw UploadError.verificationFailed }
                results.append(TransferResult(source: source.path, outcome: .uploaded(uploaded.path)))
            } catch {
                isPlanning = false
                if case .directory = item.kind { blockedSubtrees[item.components] = .notAttempted }
                let failure = UploadFailure(error, writeAttempted: writeAttempted)
                let reportedError = failure.underlying
                if reportedError is CancellationError && failure.beforeWrite {
                    appendNotAttempted(items[index...].map(\.source.path))
                    throw CancellationError()
                }
                if reportedError as? UploadError == .cancelledSessionRecovered
                    || reportedError as? UploadError == .cancelledAndRemoved {
                    results.append(
                        TransferResult(
                            source: source.path,
                            outcome: .uploadCancelled(reportedError as? UploadError == .cancelledAndRemoved
                                ? reportedError.localizedDescription
                                : "Cancelled cleanly at the MTP/USB layer. A partial or complete item may remain on the device; inspect it before retrying the same name.",
                                requiresInspection: reportedError as? UploadError == .cancelledSessionRecovered
                            )))
                    stopRequested = true
                    continue
                }
                if failure.isUncertain {
                    results.append(
                        TransferResult(
                            source: source.path,
                            outcome: .uploadUncertain(
                                "\(reportedError.localizedDescription) A partial or complete file may be on the device. Inspect it before retrying; no transfer was replayed."
                            )))
                    stopRequested = true
                } else {
                    results.append(
                        TransferResult(
                            source: source.path, outcome: .failed(reportedError.localizedDescription)))
                }
                if let sessionError = BackendSessionError.from(error) {
                    terminalSessionError = sessionError
                    stopRequested = true
                }
            }
        }
        if let terminalSessionError { throw terminalSessionError }
        try Task.checkCancellation()
    }

    private func beginBatch(
        uploading: Bool, canCancelActiveTransfer: Bool, diagnosticTransferID: UInt64?
    ) throws {
        guard !isRunning else { throw BackendError.busy }
        isRunning = true
        isUploading = uploading
        self.canCancelActiveTransfer = canCancelActiveTransfer
        self.diagnosticTransferID = diagnosticTransferID
        isPlanning = true
        stopRequested = false
        cancellationRequested = false
        results = []
        plannedCount = 0
        endProgress()
    }

    private func endBatch() {
        isRunning = false
        isPlanning = false
        canCancelActiveTransfer = false
        planningCancellation = nil
        activeOperationToken = nil
        activeOperationCancellation = nil
        diagnosticTransferID = nil
        endProgress()
    }

    /// Local preparation is interruptible. A backend without safe active
    /// cancellation completes its remote operation even if the parent stops.
    private func performCancellable<Value: Sendable>(
        interruptible: Bool = true,
        cancelAlso: (@Sendable () -> Void)? = nil,
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let token = UUID()
        let correlationID = diagnosticTransferID
        let task = Task.detached {
            try await DiagnosticContext.$transferID.withValue(correlationID) {
                try await operation()
            }
        }
        let cancel: @Sendable () -> Void = {
            cancelAlso?()
            if interruptible { task.cancel() }
        }
        activeOperationToken = token
        activeOperationCancellation = cancel
        defer {
            if activeOperationToken == token {
                activeOperationToken = nil
                activeOperationCancellation = nil
            }
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            cancel()
        }
    }

    private func beginProgress(fileName: String, totalBytes: Int64?) -> ProgressHandler {
        let token = UUID()
        progressToken = token
        progress = TransferProgress(fileName: fileName, bytesTransferred: 0, totalBytes: totalBytes)
        return { [weak self] update in
            Task { @MainActor [weak self] in
                guard let self, self.progressToken == token else { return }
                self.progress = TransferProgress(
                    fileName: fileName,
                    bytesTransferred: max(self.progress?.bytesTransferred ?? 0, update.bytesTransferred),
                    totalBytes: totalBytes ?? update.totalBytes)
            }
        }
    }

    private func endProgress() {
        progressToken = nil
        progress = nil
    }

    private func appendNotAttempted(_ sources: [String]) {
        results.append(
            contentsOf: sources.map { TransferResult(source: $0, outcome: .notAttempted) })
    }

}
