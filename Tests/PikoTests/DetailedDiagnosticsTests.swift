import Foundation
import MTPWire
import Testing
@testable import Piko

struct DetailedDiagnosticsTests {
    private func report(_ log: DiagnosticLog, previous: PersistedDiagnosticSession? = nil, detailed: Bool) throws -> String {
        String(decoding: try AppDiagnosticReport(log: log, version: "0.10.6", build: "51",
            previousSession: previous, includeFileDetails: detailed).encoded(), as: UTF8.self)
    }

    @Test func defaultRecordingAndStandardExportExcludeDetailsForEveryDevice() throws {
        let log = DiagnosticLog(), first = log.forDevice(), second = log.forDevice()
        let detail = DiagnosticDetails.move(sourcePath: "/private-name.mov", destinationPath: "/private-folder",
            storageID: 1, objectHandle: 10)
        first.record(.moveDetails, details: detail)
        #expect(log.snapshot().events.isEmpty)
        log.setRecordsDetails(true)
        first.record(.moveDetails, details: detail)
        second.record(.moveDetails, details: detail)
        #expect(Set(log.snapshot().events.filter { $0.details != nil }.map(\.deviceID)).count == 2)
        #expect(try report(log, detailed: true).contains("private-name.mov"))
        #expect(!(try report(log, detailed: false).contains("private-name.mov")))
        log.setRecordsDetails(false)
        let count = log.snapshot().events.count
        second.record(.moveDetails, details: detail)
        #expect(log.snapshot().events.count == count)
    }

    @Test func filenameAndFailedHandleContextSurviveRestartWithExplicitExportOnly() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let metadata = DiagnosticSessionMetadata(buildIdentity: AppBuildIdentity(version: "0.10.6", build: "51",
            sourceRevision: nil, sourceDirty: nil), macOS: "26.6.2")
        let journal = DiagnosticJournal(directory: directory, metadata: metadata)
        let log = DiagnosticLog(capacity: 4096) { journal.record($0) }
        log.setRecordsDetails(true)
        let deviceLog = log.forDevice()
        let device = try SyntheticUploadDevice(existingNames: ["known-camera-file.jpg", "unavailable-file.jpg"])
        let backend = SwiftMTPBackend(diagnostics: deviceLog) { device }
        _ = try await backend.connect()
        // Observe both names once; then have the camera reject one advertised handle.
        _ = try await backend.browseContents(storageID: 1, path: "/", showHiddenFiles: true)
        await device.configureUnavailable([11])
        let listing = try await backend.browseContents(storageID: 1, path: "/", showHiddenFiles: true)
        #expect(listing.unavailableCount == 1)
        #expect(listing.files.map(\.name) == ["known-camera-file.jpg"])
        let failed = try #require(log.snapshot().events.last { $0.kind == .objectDetails && $0.response == 0x2009 })
        guard case let .object(path, storage, parent, handle, info) = failed.details else {
            Issue.record("Missing object context"); return
        }
        #expect(path == "/" && storage == 1 && parent == UInt32.max && handle == 11 && info == nil)
        #expect(failed.sessionID != nil && failed.deviceID != nil)
        #expect(log.snapshot().events.contains { $0.kind == .transaction && $0.response == 0x2009 && $0.sessionID == failed.sessionID })
        #expect(!(await device.snapshot().closed))
        try await backend.disconnect()
        journal.stopWithoutCleanMarker()

        let reopened = DiagnosticJournal(directory: directory, metadata: metadata)
        let previous = try #require(reopened.previousSession())
        #expect(!previous.journalTruncated && !previous.cleanExit)
        let detailed = try report(DiagnosticLog(), previous: previous, detailed: true)
        #expect(detailed.contains("known-camera-file.jpg") && detailed.contains("unavailable-file.jpg"))
        #expect(detailed.contains("objectHandle") && detailed.contains("firmware"))
        #expect(!detailed.contains("fixture-serial"))
        let standard = try report(DiagnosticLog(), previous: previous, detailed: false)
        #expect(!standard.contains("camera-file.jpg") && !standard.contains("unavailable-file.jpg"))
        #expect(!standard.contains("objectHandle") && !standard.contains("firmware"))
        reopened.clear()
        #expect(reopened.previousSession() == nil)
        reopened.markCleanShutdown()
    }

    @Test func metadataWithoutPriorSuccessfulReadDoesNotInventFilename() async throws {
        let log = DiagnosticLog(); log.setRecordsDetails(true)
        let device = try SyntheticUploadDevice(existingNames: ["not-disclosed.jpg"])
        await device.configureUnavailable([10])
        let backend = SwiftMTPBackend(diagnostics: log) { device }
        _ = try await backend.connect()
        _ = try await backend.browseContents(storageID: 1, path: "/", showHiddenFiles: true)
        let text = try report(log, detailed: true)
        #expect(!text.contains("not-disclosed.jpg"))
        #expect(text.contains("objectHandle") && text.contains("8201"))
        await device.configureFault(reject: 0x1007)
        await #expect(throws: WireError.response(0x200F)) {
            try await backend.browseContents(storageID: 1, path: "/", showHiddenFiles: true)
        }
        let failedDirectory = try #require(log.snapshot().events.last { $0.kind == .directoryDetails })
        guard case let .directory(_, _, _, _, total) = failedDirectory.details else {
            Issue.record("Missing failed folder context"); return
        }
        #expect(total == nil) // A failed enumeration is not an empty folder.
        try await backend.disconnect()
    }

    @Test func longMetadataAndHandleListsStayBounded() throws {
        let log = DiagnosticLog(); log.setRecordsDetails(true)
        log.record(.directoryDetails, details: .directory(path: String(repeating: "文", count: 10000),
            storageID: 1, parentHandle: 0, handles: Array(1...10000), totalHandles: 10000))
        let last = try #require(log.snapshot().events.last)
        guard case let .directory(path, _, _, handles, total) = last.details else {
            Issue.record("Missing directory context"); return
        }
        #expect(path.utf8.count <= 512 && path.hasSuffix("…"))
        #expect(handles.count == 64 && total == 10000)
        #expect(try JSONEncoder().encode(last).count < 4096)
    }

    @Test @MainActor func recordingChoicePersistsAndFailedConnectRetainsDeviceContext() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults = UserDefaults(suiteName: "Piko.DetailedTests.\(UUID())")!
        defer { try? FileManager.default.removeItem(at: directory) }
        let diagnostics = AppDiagnostics(journalDirectory: directory, defaults: defaults)
        #expect(!diagnostics.recordsFileDetails)
        diagnostics.requestRecording(true, confirm: { _ in true })
        diagnostics.requestFileDetails(true, confirm: { _ in true })
        let deviceLog = diagnostics.log.forDevice()
        let model = DeviceBrowserModel(client: FailingConnectionBackend(), diagnostics: deviceLog,
            discoveredDevice: DiscoveredDevice(id: "10", target: 10, vendor: 1, product: 2,
                name: "Test camera", serialNumber: "never-record-this-serial"))
        await model.connectAndLoad()
        let text = try report(diagnostics.log, detailed: true)
        #expect(text.contains("Test camera") && text.contains("usbRegistryID"))
        #expect(!text.contains("never-record-this-serial"))
        diagnostics.finishShutdown(clean: true)
        let reopened = AppDiagnostics(journalDirectory: directory, defaults: defaults)
        #expect(reopened.recordsFileDetails && reopened.log.recordsDetails)
        reopened.requestFileDetails(false)
        #expect(!defaults.bool(forKey: AppDiagnostics.detailedRecordingKey))
        reopened.clearDiagnostics()
        #expect(reopened.log.snapshot().events.isEmpty)
        reopened.finishShutdown(clean: true)
    }
}


private struct FailingConnectionBackend: MTPBackend {
    let capabilities = BackendCapabilities(reportsProgress: false, canCancelActiveTransfer: false)
    func connect() async throws -> [MTPStorage] { throw SimulatedDeviceError.failure("Connection failed") }
    func contents(storageID: UInt32, path: String, showHiddenFiles: Bool) async throws -> [MTPFile] { [] }
    func download(storageID: UInt32, files: [MTPFile], to destination: URL,
                  progress: @escaping ProgressHandler) async throws {}
    func disconnect() async throws -> Bool { true }
}
