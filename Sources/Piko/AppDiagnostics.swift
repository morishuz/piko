import AppKit
import Combine
import MTPWire
import UniformTypeIdentifiers

@MainActor
final class AppDiagnostics: ObservableObject {
    static let recordingKey = "recordDiagnosticsWithConsent"
    static let detailedRecordingKey = "recordDetailedDiagnostics"
    @Published private(set) var isRecording: Bool
    @Published private(set) var recordsFileDetails: Bool
    private let defaults: UserDefaults
    let log: DiagnosticLog
    let buildIdentity: AppBuildIdentity
    private let journal: DiagnosticJournal
    private var recordedThisLaunch: Bool

    enum Consent {
        case basic, detailed

        var title: String {
            self == .basic ? "Enable local diagnostics?" : "Include filenames and folder paths?"
        }

        var message: String {
            let contents = self == .basic
                ? "Records app actions, errors, timings, byte counts, device capabilities, USB/MTP codes and app/macOS versions. Basic logs exclude filenames, paths, serial-number fields and file contents."
                : "Also records device filenames, folder paths, object IDs, model, firmware and USB registry identifiers. These details may reveal private information. File contents and serial-number fields are never recorded."
            return contents + "\n\nLogs are saved only on this Mac and retained across restarts and crashes, with up to 4,096 events per session. This choice stays enabled until you turn it off. Turning it off stops new recording; Delete Diagnostics removes retained logs. Exported copies must be deleted separately.\n\nThe app makes no internet connections. Reports are shared only if you export and send them yourself."
        }
    }

    private static func confirm(_ consent: Consent) -> Bool {
        let alert = NSAlert()
        alert.messageText = consent.title
        alert.informativeText = consent.message
        alert.addButton(withTitle: "Enable")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.last?.keyEquivalent = "\u{1b}"
        return alert.runModal() == .alertFirstButtonReturn
    }

    func requestRecording(_ enabled: Bool, confirm: ((Consent) -> Bool)? = nil) {
        guard enabled != isRecording else { return }
        if enabled {
            guard consentGranted(.basic, using: confirm) else { return }
        }
        setRecordingEnabled(enabled)
    }

    func requestFileDetails(_ enabled: Bool, confirm: ((Consent) -> Bool)? = nil) {
        guard isRecording, enabled != recordsFileDetails else { return }
        if enabled {
            guard consentGranted(.detailed, using: confirm) else { return }
        }
        setRecordsFileDetails(enabled)
    }

    private func consentGranted(_ consent: Consent, using confirmation: ((Consent) -> Bool)?) -> Bool {
        if let confirmation { return confirmation(consent) }
        return Self.confirm(consent)
    }

    init(
        bundleInfo: [String: Any] = Bundle.main.infoDictionary ?? [:],
        journalDirectory: URL = AppDiagnostics.defaultJournalDirectory(),
        defaults: UserDefaults = .standard
    ) {
        self.defaults = defaults
        let enabled = defaults.bool(forKey: Self.recordingKey)
        isRecording = enabled
        recordedThisLaunch = enabled
        // Detailed recording requires consent to basic recording too.
        recordsFileDetails = enabled && defaults.bool(forKey: Self.detailedRecordingKey)
        if !enabled { defaults.removeObject(forKey: Self.detailedRecordingKey) }
        let identity = AppBuildIdentity(bundleInfo: bundleInfo)
        buildIdentity = identity
        let journal = DiagnosticJournal(
            directory: journalDirectory,
            metadata: DiagnosticSessionMetadata(
                buildIdentity: identity,
                macOS: AppDiagnosticReport.macOSVersion()), startImmediately: enabled)
        self.journal = journal
        log = DiagnosticLog(capacity: 4096, recordingEnabled: enabled) { [weak journal] event in
            journal?.record(event)
        }
        log.setRecordsDetails(recordsFileDetails)
    }

    private func setRecordingEnabled(_ enabled: Bool) {
        if enabled {
            journal.startRecording()
            recordedThisLaunch = true
            log.setRecordingEnabled(true)
        } else {
            // The shared gate covers all device logs, including detached USB workers.
            log.setRecordingEnabled(false)
            journal.stopWithoutCleanMarker()
            setRecordsFileDetails(false)
        }
        isRecording = enabled
        defaults.set(enabled, forKey: Self.recordingKey)
    }

    static func defaultJournalDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("Piko", isDirectory: true)
            .appendingPathComponent("Diagnostics", isDirectory: true)
    }

    private func setRecordsFileDetails(_ enabled: Bool) {
        recordsFileDetails = enabled
        defaults.set(enabled, forKey: Self.detailedRecordingKey)
        log.setRecordsDetails(enabled)
    }

    func clearDiagnostics() {
        log.setRecordingEnabled(false)
        log.clear()
        journal.clear()
        log.setRecordingEnabled(isRecording)
    }

    func finishShutdown(clean: Bool) {
        log.setRecordingEnabled(false)
        if clean { journal.markCleanShutdown() }
        else { journal.stopWithoutCleanMarker() }
    }

    func report(includeFileDetails: Bool? = nil) -> AppDiagnosticReport {
        let includeFileDetails = includeFileDetails ?? recordsFileDetails
        journal.flush()
        return AppDiagnosticReport(
            log: log,
            version: buildIdentity.version, build: buildIdentity.build,
            sourceRevision: buildIdentity.sourceRevision,
            sourceDirty: buildIdentity.sourceDirty,
            previousSession: journal.previousSession(),
            savedSession: recordedThisLaunch ? nil : journal.currentSession(),
            includeFileDetails: includeFileDetails)
    }

    func exportReport() {
        let includeFileDetails = recordsFileDetails
        let panel = NSSavePanel()
        panel.title = includeFileDetails ? "Export Detailed Diagnostic Report" : "Export Diagnostic Report"
        panel.nameFieldStringValue = includeFileDetails ? "Piko-Diagnostics-Detailed.json" : "Piko-Diagnostics.json"
        panel.allowedContentTypes = [.json]
        panel.message = includeFileDetails
            ? "Includes recorded device filenames, folder paths, object IDs, model and firmware from retained diagnostic sessions. Enable detailed recording before reproducing the issue. Review before sharing. This only saves a file; the app makes no internet connections."
            : "Contains retained diagnostic sessions: backend/build, operation codes, storage permissions, capability/button states, byte counts, timings and error categories. No filenames, paths, serial-number fields or file contents. This only saves a file; the app makes no internet connections."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try report(includeFileDetails: includeFileDetails).encoded().write(to: url, options: .atomic)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not save diagnostic report"
            alert.informativeText = "Choose a writable location and try again."
            alert.runModal()
        }
    }
}
