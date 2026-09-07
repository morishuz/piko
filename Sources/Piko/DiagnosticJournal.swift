import Foundation
import MTPWire

struct DiagnosticSessionMetadata: Codable, Equatable, Sendable {
    let appVersion: String
    let build: String
    let macOS: String
    let backend: String
    let scope: String
    let sourceRevision: String
    let sourceDirty: Bool?

    init(buildIdentity: AppBuildIdentity, macOS: String, backend: String = "swift-apple-usb") {
        appVersion = buildIdentity.version
        build = buildIdentity.build
        self.macOS = Self.numericVersion(macOS)
        // Old reports can describe simulated sessions; this is a decoding allowlist,
        // not a choice of runtime implementation.
        self.backend = ["swift-apple-usb", "demo"].contains(backend) ? backend : "invalid-configuration"
        scope = self.backend == "swift-apple-usb" ? "app-actions-and-swift-wire-usb" : "app-actions-only"
        sourceRevision = buildIdentity.sourceRevision
        sourceDirty = buildIdentity.sourceDirty
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let identity = AppBuildIdentity(
            version: try values.decodeIfPresent(String.self, forKey: .appVersion),
            build: try values.decodeIfPresent(String.self, forKey: .build),
            sourceRevision: try values.decodeIfPresent(String.self, forKey: .sourceRevision),
            sourceDirty: try values.decodeIfPresent(Bool.self, forKey: .sourceDirty))
        let rawBackend = try values.decodeIfPresent(String.self, forKey: .backend)
        self.init(
            buildIdentity: identity,
            macOS: try values.decodeIfPresent(String.self, forKey: .macOS) ?? "unknown",
            backend: rawBackend ?? "invalid-configuration")
    }

    private static func numericVersion(_ value: String) -> String {
        guard !value.isEmpty, value.count <= 32,
            value.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 })
        else { return "unknown" }
        return value
    }
}

struct PersistedDiagnosticSession: Codable, Sendable {
    let metadata: DiagnosticSessionMetadata
    let cleanExit: Bool
    let journalTruncated: Bool
    let log: DiagnosticSnapshot

    func filtered(includeFileDetails: Bool) -> Self {
        Self(metadata: metadata, cleanExit: cleanExit, journalTruncated: journalTruncated,
             log: includeFileDetails ? log : log.excludingDetails())
    }
}

/// An append-only journal for diagnostic events. Remote metadata appears only
/// when the user enables detailed recording; standard exports filter it out.
/// Writes never block USB/MTP actors. Important lifecycle records
/// cause the serial writer to flush and synchronize everything queued before
/// them; routine records are flushed in a short batch.
final class DiagnosticJournal: @unchecked Sendable {
    private static let maximumJournalBytes = 32 * 1_024 * 1_024
    private enum RecordKind: String, Codable { case header, event, cleanExit }

    private struct Record: Codable {
        let kind: RecordKind
        let metadata: DiagnosticSessionMetadata?
        let capacity: Int?
        let discardedEvents: UInt64?
        let event: DiagnosticEvent?

        static func header(
            metadata: DiagnosticSessionMetadata, capacity: Int, discardedEvents: UInt64
        ) -> Self {
            Self(
                kind: .header, metadata: metadata, capacity: capacity,
                discardedEvents: discardedEvents, event: nil)
        }

        static func value(_ event: DiagnosticEvent) -> Self {
            Self(
                kind: .event, metadata: nil, capacity: nil,
                discardedEvents: nil, event: event)
        }

        static let clean = Self(
            kind: .cleanExit, metadata: nil, capacity: nil,
            discardedEvents: nil, event: nil)
    }

    private static let criticalKinds: Set<DiagnosticEventKind> = [
        .connect, .disconnect, .download, .upload,
        .cancelRequested, .recoveryDecision, .recoveryWait, .recoveryAttempt,
        .usbOpen, .usbCancel, .usbReset, .usbDeviceReset, .usbReleased,
        .sessionReleased,
        .responderReset, .moveRecovery,
    ]

    private let queue = DispatchQueue(label: "com.piko.mac.diagnostic-journal")
    private let directory: URL
    private let currentURL: URL
    private let previousURL: URL
    private let metadata: DiagnosticSessionMetadata
    private let capacity: Int
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var handle: FileHandle?
    private var buffer = Data()
    private var retainedEvents: [DiagnosticEvent] = []
    private var totalEvents: UInt64 = 0
    private var persistedEventLines = 0
    private var scheduledFlush: DispatchWorkItem?
    private var stopped = true
    private var sessionStarted = false

    init(directory: URL, metadata: DiagnosticSessionMetadata, capacity: Int = 4096,
         startImmediately: Bool = true) {
        self.directory = directory
        currentURL = directory.appendingPathComponent("current.jsonl", isDirectory: false)
        previousURL = directory.appendingPathComponent("previous.jsonl", isDirectory: false)
        self.metadata = metadata
        self.capacity = min(4096, max(1, capacity))
        if startImmediately { startRecording() }
    }

    /// Opening Settings or launching with recording off must not create or rotate files.
    func startRecording() {
        queue.sync {
            guard stopped else { return }
            stopped = false
            if sessionStarted {
                do {
                    handle = try FileHandle(forWritingTo: currentURL)
                    try handle?.seekToEnd()
                } catch { stopped = true; closeHandleLocked() }
            } else {
                prepareLocked()
                sessionStarted = !stopped
            }
        }
    }

    func record(_ event: DiagnosticEvent) {
        // Persist discovery breadcrumbs before opening the selected USB interface. Unlike normal
        // transfer telemetry these are low-frequency, crash-boundary evidence.
        if event.kind == .usbDiscovery || event.kind == .usbOpenAttempt || event.kind == .usbDiscoveryRelease
            || event.kind == .appleUSBDiscovery || event.kind == .appleUSBError {
            queue.sync { appendLocked(event, synchronize: true) }
            return
        }
        let synchronize = Self.criticalKinds.contains(event.kind) || event.failure != nil
            || event.kind == .detailedRecordingStarted || event.kind == .detailedRecordingStopped
        queue.async { [weak self] in
            self?.appendLocked(event, synchronize: synchronize)
        }
    }

    func previousSession() -> PersistedDiagnosticSession? {
        queue.sync { readSessionLocked(at: previousURL) }
    }

    func currentSession() -> PersistedDiagnosticSession? {
        queue.sync { readSessionLocked(at: currentURL) }
    }

    func flush() {
        queue.sync { flushLocked(synchronize: true) }
    }

    func clear() {
        queue.sync {
            let resume = !stopped
            scheduledFlush?.cancel()
            scheduledFlush = nil
            buffer.removeAll(keepingCapacity: true)
            retainedEvents.removeAll(keepingCapacity: true)
            totalEvents = 0
            persistedEventLines = 0
            closeHandleLocked()
            try? FileManager.default.removeItem(at: previousURL)
            try? FileManager.default.removeItem(at: currentURL)
            sessionStarted = false
            if resume {
                prepareLocked()
                sessionStarted = !stopped
            }
        }
    }

    func markCleanShutdown() {
        queue.sync {
            guard !stopped else { return }
            scheduledFlush?.cancel()
            scheduledFlush = nil
            appendRecordLocked(.clean)
            flushLocked(synchronize: true)
            closeHandleLocked()
            stopped = true
        }
    }

    /// Flush an immediate quit (or simulated process death) without claiming a clean exit.
    func stopWithoutCleanMarker() {
        queue.sync {
            scheduledFlush?.cancel()
            scheduledFlush = nil
            flushLocked(synchronize: true)
            closeHandleLocked()
            stopped = true
        }
    }

    private func prepareLocked() {
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            var directoryValues = URLResourceValues()
            directoryValues.isExcludedFromBackup = true
            var mutableDirectory = directory
            try? mutableDirectory.setResourceValues(directoryValues)
            if FileManager.default.fileExists(atPath: currentURL.path) {
                try? FileManager.default.removeItem(at: previousURL)
                try FileManager.default.moveItem(at: currentURL, to: previousURL)
            }
            createCurrentLocked()
        } catch {
            stopped = true
            handle = nil
        }
    }

    private func createCurrentLocked() {
        do {
            let header = Record.header(metadata: metadata, capacity: capacity, discardedEvents: 0)
            try encodedLine(header).write(to: currentURL, options: .atomic)
            handle = try FileHandle(forWritingTo: currentURL)
            try handle?.seekToEnd()
            try handle?.synchronize()
        } catch {
            stopped = true
            closeHandleLocked()
        }
    }

    private func appendLocked(_ event: DiagnosticEvent, synchronize: Bool) {
        guard !stopped, handle != nil else { return }
        retainedEvents.append(event)
        if retainedEvents.count > capacity {
            retainedEvents.removeFirst(retainedEvents.count - capacity)
        }
        totalEvents += 1
        persistedEventLines += 1
        appendRecordLocked(.value(event))

        if persistedEventLines >= capacity * 2 {
            flushLocked(synchronize: synchronize)
            compactLocked()
        } else if synchronize {
            flushLocked(synchronize: true)
        } else {
            scheduleFlushLocked()
        }
    }

    private func appendRecordLocked(_ record: Record) {
        guard let line = try? encodedLine(record) else { return }
        buffer.append(line)
    }

    private func scheduleFlushLocked() {
        guard scheduledFlush == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.scheduledFlush = nil
            self.flushLocked(synchronize: false)
        }
        scheduledFlush = work
        queue.asyncAfter(deadline: .now() + .milliseconds(250), execute: work)
    }

    private func flushLocked(synchronize: Bool) {
        guard let handle, !buffer.isEmpty else {
            if synchronize { try? handle?.synchronize() }
            return
        }
        do {
            try handle.write(contentsOf: buffer)
            buffer.removeAll(keepingCapacity: true)
            if synchronize { try handle.synchronize() }
        } catch {
            buffer.removeAll(keepingCapacity: true)
            closeHandleLocked()
            stopped = true
        }
    }

    private func compactLocked() {
        closeHandleLocked()
        do {
            let discarded = totalEvents - UInt64(retainedEvents.count)
            var data = try encodedLine(
                .header(metadata: metadata, capacity: capacity, discardedEvents: discarded))
            for event in retainedEvents { data.append(try encodedLine(.value(event))) }
            try data.write(to: currentURL, options: .atomic)
            handle = try FileHandle(forWritingTo: currentURL)
            try handle?.seekToEnd()
            persistedEventLines = retainedEvents.count
        } catch {
            stopped = true
            closeHandleLocked()
        }
    }

    private func closeHandleLocked() {
        try? handle?.close()
        handle = nil
    }

    private func encodedLine(_ record: Record) throws -> Data {
        var data = try encoder.encode(record)
        data.append(0x0A)
        return data
    }

    private func readSessionLocked(at url: URL) -> PersistedDiagnosticSession? {
        let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard let size, size <= Self.maximumJournalBytes else { return nil }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        var header: Record?
        var events: [DiagnosticEvent] = []
        var cleanExit = false
        var truncated = false

        for line in lines {
            guard let record = try? decoder.decode(Record.self, from: Data(line)) else {
                truncated = true
                break
            }
            switch record.kind {
            case .header:
                guard header == nil, record.metadata != nil, record.capacity != nil else {
                    truncated = true
                    break
                }
                header = record
            case .event:
                guard header != nil, !cleanExit, let event = record.event else {
                    truncated = true
                    break
                }
                events.append(event)
            case .cleanExit:
                guard header != nil, !cleanExit else {
                    truncated = true
                    break
                }
                cleanExit = true
            }
            if truncated { break }
        }

        guard let header, let metadata = header.metadata else { return nil }
        let storedCapacity = min(4096, max(1, header.capacity ?? capacity))
        let overflow = max(0, events.count - storedCapacity)
        let retained = Array(events.suffix(storedCapacity))
        let discarded = (header.discardedEvents ?? 0) + UInt64(overflow)
        return PersistedDiagnosticSession(
            metadata: metadata, cleanExit: cleanExit, journalTruncated: truncated,
            log: DiagnosticSnapshot(
                capacity: storedCapacity, discardedEvents: discarded, events: retained))
    }
}
