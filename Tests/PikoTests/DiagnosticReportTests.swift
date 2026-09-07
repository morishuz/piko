import Foundation
import MTPWire
import Testing

@testable import Piko

@Test func diagnosticReportIdentifiesActualBackendAndRejectsArbitraryBuildText() throws {
    let log = DiagnosticLog()
    log.record(.connect, failure: .other)
    let report = AppDiagnosticReport(
        log: log, version: "0.5.1", build: "11",
        sourceRevision: "ABCDEF0123456789ABCDEF0123456789ABCDEF01", sourceDirty: true)
    let json = try #require(JSONSerialization.jsonObject(with: report.encoded()) as? [String: Any])
    #expect(json["schemaVersion"] as? Int == 7)
    #expect(json["backend"] as? String == "swift-apple-usb")
    #expect(json["appVersion"] as? String == "0.5.1")
    #expect(json["scope"] as? String == "app-actions-and-swift-wire-usb")
    #expect(json["sourceRevision"] as? String == "abcdef0123456789abcdef0123456789abcdef01")
    #expect(json["sourceDirty"] as? Bool == true)
    let other = AppDiagnosticReport(
        log: log, version: "/Users/private", build: "serial")
    let text = String(decoding: try other.encoded(), as: UTF8.self)
    #expect(!text.contains("/Users/private"))
    #expect(!text.contains("serial"))
    #expect(other.scope == "app-actions-and-swift-wire-usb")
    #expect(other.sourceRevision == "unknown")
}

@Test func buildIdentitySanitizesBundleMetadataAndFormatsCompactly() {
    let identity = AppBuildIdentity(bundleInfo: [
        "CFBundleShortVersionString": "0.5.5",
        "CFBundleVersion": "15",
        "PikoSourceRevision": "ABCDEF0123456789ABCDEF0123456789ABCDEF01",
        "PikoSourceDirty": "YES",
    ])
    #expect(identity.sourceRevision == "abcdef0123456789abcdef0123456789abcdef01")
    #expect(identity.sourceDirty == true)

    for unsafe in ["", "xyz", String(repeating: "a", count: 41), "/Users/private"] {
        let value = AppBuildIdentity(
            version: "0.5.5", build: "15", sourceRevision: unsafe, sourceDirty: nil)
        #expect(value.sourceRevision == "unknown")
    }
}

@Test @MainActor func appDiagnosticsRetainFullHardwareTestWindow() throws {
    let directory = try temporaryDiagnosticDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let diagnostics = AppDiagnostics(
        bundleInfo: [:], journalDirectory: directory)
    #expect(diagnostics.log.snapshot().capacity == 4096)
}

@Test func diagnosticJournalRecoversUncleanPreviousSession() throws {
    let directory = try temporaryDiagnosticDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let metadata = diagnosticMetadata()
    let first = DiagnosticJournal(directory: directory, metadata: metadata, capacity: 3)
    let log = DiagnosticLog(capacity: 3) { [weak first] event in first?.record(event) }
    log.record(.usbOpen)
    log.record(.cancelRequested, transferDirection: .upload)
    log.record(.recoveryDecision, recoveryAction: .closeOnly)
    first.flush()
    first.stopWithoutCleanMarker()

    let second = DiagnosticJournal(directory: directory, metadata: metadata, capacity: 3)
    let recovered = try #require(second.previousSession())
    #expect(recovered.metadata == metadata)
    #expect(!recovered.cleanExit)
    #expect(!recovered.journalTruncated)
    #expect(recovered.log.capacity == 3)
    #expect(recovered.log.discardedEvents == 0)
    #expect(recovered.log.events.map(\.kind) == [
        .usbOpen, .cancelRequested, .recoveryDecision,
    ])
    let report = AppDiagnosticReport(
        log: DiagnosticLog(), version: "0.6.7", build: "25",
        previousSession: recovered)
    let json = try #require(JSONSerialization.jsonObject(with: report.encoded()) as? [String: Any])
    let previous = try #require(json["previousSession"] as? [String: Any])
    #expect(previous["cleanExit"] as? Bool == false)
    #expect((previous["log"] as? [String: Any])?["events"] != nil)
    second.markCleanShutdown()
}

@Test func discoveryBreadcrumbIsOnDiskBeforeRecorderReturns() throws {
    let directory = try temporaryDiagnosticDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let journal = DiagnosticJournal(directory: directory, metadata: diagnosticMetadata())
    let log = DiagnosticLog { [weak journal] event in journal?.record(event) }
    log.record(.usbDiscovery, phase: .command, transportID: 1, discoveryStage: .initialize)
    // No flush or stop call: this is the crash boundary immediately before init.
    let data = try Data(contentsOf: directory.appendingPathComponent("current.jsonl"))
    let text = String(decoding: data, as: UTF8.self)
    #expect(text.contains("usbDiscovery"))
    #expect(text.contains("discoveryStage"))
    journal.stopWithoutCleanMarker()
    let reopened = DiagnosticJournal(directory: directory, metadata: diagnosticMetadata())
    let event = try #require(reopened.previousSession()?.log.events.last)
    #expect(event.discoveryStage == .initialize)
    #expect(event.phase == .command)
    reopened.markCleanShutdown()
}

@Test func diagnosticJournalMarksCleanExitAndClearRemovesPreviousSession() throws {
    let directory = try temporaryDiagnosticDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let metadata = diagnosticMetadata()
    let first = DiagnosticJournal(directory: directory, metadata: metadata)
    let log = DiagnosticLog { [weak first] event in first?.record(event) }
    log.record(.connect)
    first.markCleanShutdown()

    let second = DiagnosticJournal(directory: directory, metadata: metadata)
    let recovered = try #require(second.previousSession())
    #expect(recovered.cleanExit)
    #expect(!recovered.journalTruncated)
    #expect(recovered.log.events.map(\.kind) == [.connect])
    second.clear()
    #expect(second.previousSession() == nil)
    second.markCleanShutdown()
}

@Test func diagnosticJournalKeepsCompletePrefixOfCrashTruncatedLine() throws {
    let directory = try temporaryDiagnosticDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let metadata = diagnosticMetadata()
    let first = DiagnosticJournal(directory: directory, metadata: metadata)
    let log = DiagnosticLog { [weak first] event in first?.record(event) }
    log.record(.usbOpen)
    first.flush()
    first.stopWithoutCleanMarker()
    let current = directory.appendingPathComponent("current.jsonl")
    let handle = try FileHandle(forWritingTo: current)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("{partial".utf8))
    try handle.close()

    let second = DiagnosticJournal(directory: directory, metadata: metadata)
    let recovered = try #require(second.previousSession())
    #expect(!recovered.cleanExit)
    #expect(recovered.journalTruncated)
    #expect(recovered.log.events.map(\.kind) == [.usbOpen])
    second.markCleanShutdown()
}

@Test func diagnosticJournalCompactsToItsConfiguredEventLimit() throws {
    let directory = try temporaryDiagnosticDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let metadata = diagnosticMetadata()
    let first = DiagnosticJournal(directory: directory, metadata: metadata, capacity: 3)
    let log = DiagnosticLog(capacity: 3) { [weak first] event in first?.record(event) }
    for _ in 0..<8 { log.record(.listing) }
    first.flush()
    first.stopWithoutCleanMarker()

    let second = DiagnosticJournal(directory: directory, metadata: metadata, capacity: 3)
    let recovered = try #require(second.previousSession())
    #expect(recovered.log.discardedEvents == 5)
    #expect(recovered.log.events.map(\.sequence) == [5, 6, 7])
    second.markCleanShutdown()
}

@Test func persistedDiagnosticMetadataIsSanitizedWhenReadFromDisk() throws {
    let unsafe = Data(
        #"{"appVersion":"/Users/private","build":"serial","macOS":"private-host","backend":"private-device","scope":"private-scope","sourceRevision":"private-revision"}"#.utf8)
    let metadata = try JSONDecoder().decode(DiagnosticSessionMetadata.self, from: unsafe)
    #expect(metadata.appVersion == "development")
    #expect(metadata.build == "development")
    #expect(metadata.macOS == "unknown")
    #expect(metadata.backend == "invalid-configuration")
    #expect(metadata.scope == "app-actions-only")
    #expect(metadata.sourceRevision == "unknown")
    #expect(!String(decoding: try JSONEncoder().encode(metadata), as: UTF8.self).contains("private"))
}

@Test @MainActor func demoAppDiagnosticsRecordActionsWithoutFileOrStorageNames() async throws {
    let log = DiagnosticLog()
    let model = DeviceBrowserModel(client: DemoBackend(), diagnostics: log)
    await model.connectAndLoad()
    #expect(model.isConnected)
    await model.disconnectAndReset()
    #expect(log.snapshot().events.map(\.kind) == [.connect, .listing, .browserCapabilities, .disconnect])
    let json = String(
        decoding: try AppDiagnosticReport(log: log, version: nil, build: nil).encoded(),
        as: UTF8.self)
    #expect(!json.contains("DCIM"))
    #expect(!json.contains("fileName"))
}

private func temporaryDiagnosticDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("Piko-DiagnosticTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func diagnosticMetadata() -> DiagnosticSessionMetadata {
    DiagnosticSessionMetadata(
        buildIdentity: AppBuildIdentity(
            version: "0.6.7", build: "25",
            sourceRevision: "abcdef0123456789abcdef0123456789abcdef01", sourceDirty: false),
        macOS: "26.5.1")
}

@Test @MainActor func appShutdownMarkerDistinguishesImmediateAndOrderlyQuit() throws {
    for clean in [false, true] {
        let directory = try temporaryDiagnosticDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = UserDefaults(suiteName: "Piko.ShutdownTests.\(UUID())")!
        let app = AppDiagnostics(bundleInfo: [:], journalDirectory: directory, defaults: defaults)
        app.requestRecording(true, confirm: { _ in true })
        app.log.record(.usbOpen)
        app.finishShutdown(clean: clean)
        let reopened = DiagnosticJournal(directory: directory, metadata: diagnosticMetadata())
        let previous = try #require(reopened.previousSession())
        #expect(previous.cleanExit == clean)
        #expect(previous.log.events.contains { $0.kind == .usbOpen })
        reopened.markCleanShutdown()
    }
}

@Test func capabilitySnapshotsSurviveRingRolloverAndDecodeOlderReports() throws {
    let log = DiagnosticLog(capacity: 2)
    log.record(.deviceCapabilities, capabilities: DiagnosticCapabilities(
        storageIndex: 0, storageAccess: 2, supportedOperations: [0x100C, 0x100D],
        uploadEnabled: false, binEnabled: false))
    log.record(.browserCapabilities, capabilities: DiagnosticCapabilities(
        storageIndex: 0, storageAccess: 2, uploadEnabled: false, binEnabled: false,
        binExists: false, binDropEnabled: false))
    for _ in 0..<5 { log.record(.usbRead, bytes: 65536) }
    let snapshot = log.snapshot()
    #expect(snapshot.events.allSatisfy { $0.kind == .usbRead })
    #expect(snapshot.capabilityEvents?.count == 2)
    #expect(snapshot.capabilityEvents?.first?.capabilities?.storageAccess == 2)
    let data = try JSONEncoder().encode(snapshot)
    #expect(try JSONDecoder().decode(DiagnosticSnapshot.self, from: data).capabilityEvents?.count == 2)
    var legacy = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    legacy.removeValue(forKey: "capabilityEvents")
    #expect(try JSONDecoder().decode(DiagnosticSnapshot.self, from: JSONSerialization.data(withJSONObject: legacy)).capabilityEvents == nil)
    log.resetCapabilities()
    #expect(log.snapshot().capabilityEvents?.isEmpty == true)
    #expect(log.snapshot().events.count == 2)
}
