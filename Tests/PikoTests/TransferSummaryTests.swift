import Foundation
import Testing
@testable import Piko

@Test func transferSummaryDistinguishesFilesFoldersAndUncertainWrites() {
    let summary = TransferSummary([
        TransferResult(source: "/one", outcome: .uploaded("/Device/one")),
        TransferResult(source: "/folder", outcome: .uploadedDirectory("/Device/folder")),
        TransferResult(source: "/.DS_Store", outcome: .uploadExcluded("Finder metadata")),
        TransferResult(source: "/bad", outcome: .failed("Denied")),
        TransferResult(source: "/unknown", outcome: .uploadUncertain("Disconnected")),
        TransferResult(source: "/cancelled", outcome: .uploadCancelled("Stopped")),
        TransferResult(source: "/exists", outcome: .uploadConflict("Exists")),
        TransferResult(source: "/later", outcome: .notAttempted),
    ])
    let text = summary.uploadMessage(directory: "/Device")
    #expect(text.contains("1 files uploaded (size checked), 1 folders created, 1 name conflicts, 1 metadata items excluded, 1 failed, 1 uncertain, 1 cancelled, 1 not attempted."))
    #expect(text.contains("Disconnect and reconnect before another upload."))
    #expect(summary.uploadFailure == .other)
    #expect(summary.cancelledUploadMessage.contains("1 uncertain device write outcomes"))
    #expect(!summary.cancelledUploadMessage.contains("before any confirmed device writes"))
}

@Test func transferSummaryKeepsIssuePriorityAndLimitsDetails() {
    // Original order intentionally puts a conflict first. Failures must remain
    // visible ahead of conflicts when the report truncates its detail list.
    let results = [TransferResult(source: "/source/existing", outcome: .uploadConflict("Exists"))]
        + (0..<9).map { TransferResult(source: "/source/failure-\($0)", outcome: .failed("Denied")) }
    let summary = TransferSummary(results)
    let upload = summary.uploadMessage(directory: "/Device")
    #expect(upload.contains("9 failed"))
    #expect(upload.contains("failure-7: Denied"))
    #expect(!upload.contains("failure-8: Denied"))
    #expect(!upload.contains("existing: Exists"))
    #expect(!upload.contains("/source/failure-0: Denied"))
    let download = summary.downloadMessage(destination: URL(fileURLWithPath: "/output"))
    #expect(download.contains("/source/failure-0: Denied"))
}

@Test func cancelledFinalUploadIsNotLoggedAsSuccessful() {
    let summary = TransferSummary([
        TransferResult(source: "/cancelled", outcome: .uploadCancelled("Cancelled cleanly")),
    ])
    #expect(summary.pending == 0)
    #expect(summary.uploadFailure == .cancelled)
}

@Test func stoppedTransferSummariesPreserveCompletedItems() {
    let target = URL(fileURLWithPath: "/output/one")
    let download = TransferSummary([
        TransferResult(source: "/one", outcome: .downloaded(target)),
        TransferResult(source: "/folder", outcome: .createdDirectory(target)),
        TransferResult(source: "/later", outcome: .notAttempted),
    ])
    #expect(download.downloadFailure == .cancelled)
    #expect(download.interruptedDownloadMessage.contains("was not retried"))
    let upload = TransferSummary([TransferResult(source: "/folder", outcome: .uploadedDirectory("/folder"))])
    #expect(upload.cancelledUploadMessage.contains("1 confirmed device writes"))
    #expect(upload.uploadFailure == nil)
    #expect(TransferSummary([]).cancelledUploadMessage == "Upload stopped before any confirmed device writes.")
}

@Test func cancellationSuppressesOnlyCleanOutcomes() {
    let pending = TransferResult(source: "/later", outcome: .notAttempted)
    let clean = TransferSummary([
        TransferResult(source: "/first", outcome: .uploaded("/first")),
        TransferResult(source: "/second", outcome: .uploadCancelled("Removed")), pending,
    ])
    #expect(!clean.requiresAttention(wasCancelled: true))
    #expect(clean.requiresAttention(wasCancelled: false))
    for outcome in [TransferResult.Outcome.failed("Read failed"), .uploadUncertain("Disconnected"),
        .uploadConflict("Exists"), .skipped, .uploadCancelled("Inspect destination", requiresInspection: true)] {
        let partial = TransferSummary([TransferResult(source: "/first", outcome: outcome), pending])
        #expect(partial.requiresAttention(wasCancelled: true))
    }
}
