import Foundation
import MTPWire

enum ConflictPolicy: String, CaseIterable, Sendable { case keepBoth, skip, replace }

/// Shared write-failure classification for local uploads and device copies.
/// A preflight failure cannot leave a remote object, even when the underlying
/// error is unfamiliar. Session recovery remains the caller's responsibility.
struct UploadFailure {
    let underlying: any Error
    let beforeWrite: Bool

    init(_ error: any Error, writeAttempted: Bool) {
        let preflight = error as? UploadPreflightFailure
        underlying = preflight?.underlying ?? error
        beforeWrite = !writeAttempted || preflight != nil
    }

    var isUncertain: Bool {
        guard !beforeWrite else { return false }
        switch underlying {
        case UploadError.rejected, UploadError.readOnlyStorage, UploadError.unsupportedSource,
            UploadError.sourceChanged, UploadError.unsupportedBackend:
            return false
        default: return true
        }
    }
}

struct TransferResult: Identifiable, Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        case downloaded(URL)
        case uploaded(String)
        case uploadedDirectory(String)
        case uploadExcluded(String)
        case uploadUncertain(String)
        case uploadCancelled(String, requiresInspection: Bool = false)
        case uploadConflict(String)
        case createdDirectory(URL)
        case skipped
        case failed(String)
        case notAttempted
    }
    let id = UUID()
    let source: String
    let outcome: Outcome
}

enum TransferError: LocalizedError, Equatable {
    case invalidDestination, invalidDownloadedFile
    case sizeMismatch(expected: Int64, actual: Int64)
    case treeLimit, ambiguousLocalFolderNames
    case filePromiseDestinationExists
    case filePromiseFailed(String)
    var errorDescription: String? {
        switch self {
        case .invalidDestination: "The destination is not a regular folder, or contains a symbolic link."
        case .invalidDownloadedFile: "The backend did not produce the expected regular file."
        case .sizeMismatch(let expected, let actual):
            "Incomplete download: expected \(expected) bytes, received \(actual)."
        case .treeLimit: "The device returned a cyclic or excessively large folder tree."
        case .ambiguousLocalFolderNames:
            "The selected tree contains folder names this Mac cannot safely keep separate."
        case .filePromiseDestinationExists:
            "The drag destination already contains an item with that name."
        case .filePromiseFailed(let message): message
        }
    }
}

/// A single classification pass for UI summaries and diagnostic outcomes.
/// Keeps presentation independent of browser state and transfer execution.
struct TransferSummary {
    private(set) var downloaded = 0
    private(set) var uploaded = 0
    private(set) var folders = 0
    private(set) var excluded = 0
    private(set) var skipped = 0
    private(set) var pending = 0
    private(set) var failed: [TransferResult] = []
    private(set) var uncertain: [TransferResult] = []
    private(set) var cancelled: [TransferResult] = []
    private(set) var conflicts: [TransferResult] = []

    init(_ results: [TransferResult]) {
        for result in results {
            switch result.outcome {
            case .downloaded: downloaded += 1
            case .uploaded: uploaded += 1
            case .uploadedDirectory: folders += 1
            case .uploadExcluded: excluded += 1
            case .skipped: skipped += 1
            case .notAttempted: pending += 1
            case .failed: failed.append(result)
            case .uploadUncertain: uncertain.append(result)
            case .uploadCancelled: cancelled.append(result)
            case .uploadConflict: conflicts.append(result)
            case .createdDirectory: break
            }
        }
    }

    var downloadFailure: DiagnosticFailure? {
        !failed.isEmpty ? .other : pending > 0 ? .cancelled : nil
    }

    var uploadFailure: DiagnosticFailure? {
        (!failed.isEmpty || !uncertain.isEmpty) ? .other
            : !conflicts.isEmpty ? .conflict : !cancelled.isEmpty || pending > 0 ? .cancelled : nil
    }

    var cancellationNeedsInspection: Bool {
        cancelled.contains {
            if case .uploadCancelled(_, requiresInspection: true) = $0.outcome { true } else { false }
        }
    }

    func requiresAttention(wasCancelled: Bool) -> Bool {
        !failed.isEmpty || !uncertain.isEmpty || !conflicts.isEmpty || skipped > 0
            || cancellationNeedsInspection || (pending > 0 && !wasCancelled)
    }

    func downloadMessage(destination: URL) -> String {
        let message = "\(downloaded) files downloaded, \(skipped) skipped, \(failed.count) failed, \(pending) not attempted.\n\(destination.path)"
        return message + issueDetails(failed, basenameOnly: false)
    }

    var interruptedDownloadMessage: String {
        "The transfer stopped after \(downloaded) files were downloaded; \(pending) were not attempted. The interrupted operation was not retried."
    }

    func uploadMessage(directory: String) -> String {
        var message = "\(uploaded) files uploaded (size checked), \(folders) folders created, \(conflicts.count) name conflicts, \(excluded) metadata items excluded, \(failed.count) failed, \(uncertain.count) uncertain, \(cancelled.count) cancelled, \(pending) not attempted.\nDevice folder: \(directory)"
        message += issueDetails(failed + uncertain + cancelled + conflicts, basenameOnly: true)
        if !uncertain.isEmpty {
            message += "\n\nDisconnect and reconnect before another upload. Inspect the destination before retrying."
        }
        return message
    }

    var cancelledUploadMessage: String {
        if !uncertain.isEmpty {
            return "Upload cancelled with \(uncertain.count) uncertain device write outcomes. Inspect the destination and reconnect before retrying; no automatic cleanup was attempted."
        }
        let completedWrites = uploaded + folders
        return completedWrites == 0
            ? "Upload stopped before any confirmed device writes."
            : "Upload cancelled after \(completedWrites) confirmed device writes. Completed items remain on the device; no automatic cleanup was attempted."
    }

    var interruptedUploadMessage: String {
        "Upload stopped after the device session was lost: \(uncertain.count) uncertain, \(pending) not attempted. Inspect the destination and reconnect before retrying."
    }

    private func issueDetails(_ issues: [TransferResult], basenameOnly: Bool) -> String {
        guard !issues.isEmpty else { return "" }
        let lines = issues.prefix(8).map { result in
            let source = basenameOnly ? URL(fileURLWithPath: result.source).lastPathComponent : result.source
            switch result.outcome {
            case .failed(let message), .uploadUncertain(let message),
                 .uploadCancelled(let message, _), .uploadConflict(let message):
                return "\(source): \(message)"
            default: return source
            }
        }
        return "\n\n" + lines.joined(separator: "\n")
    }
}
