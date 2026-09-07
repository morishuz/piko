import Foundation
import MTPWire
import Testing
@testable import Piko

@MainActor
struct DiagnosticConsentTests {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "DiagnosticConsentTests.\(UUID())")!
    }

    @Test func freshLaunchAndDeclinedConsentRecordNothing() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = defaults()
        // An old detailed setting must not silently grant either level of consent.
        settings.set(true, forKey: AppDiagnostics.detailedRecordingKey)
        let app = AppDiagnostics(journalDirectory: directory, defaults: settings)
        let model = DeviceBrowserModel(client: DemoBackend(), diagnostics: app.log.forDevice())
        await model.connectAndLoad()
        await model.disconnectAndReset()
        app.requestRecording(true, confirm: { _ in false })
        app.requestFileDetails(true, confirm: { _ in Issue.record("Details offered while off"); return true })
        app.log.record(.appleUSBDiscovery)
        app.log.record(.browserCapabilities, capabilities: DiagnosticCapabilities(
            storageIndex: 0, uploadEnabled: true, binEnabled: true))
        #expect(!app.isRecording && !app.recordsFileDetails && !app.log.recordsDetails)
        #expect(app.log.snapshot().events.isEmpty)
        #expect(app.log.snapshot().capabilityEvents?.isEmpty == true)
        #expect(!settings.bool(forKey: AppDiagnostics.recordingKey))
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        app.clearDiagnostics()
        app.finishShutdown(clean: true)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func optInPersistsAndOffLaunchPreservesSavedLogsWithoutWriting() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = defaults()
        let first = AppDiagnostics(journalDirectory: directory, defaults: settings)
        first.requestRecording(true, confirm: { consent in
            #expect(consent == .basic); return true
        })
        first.requestFileDetails(true, confirm: { _ in false })
        #expect(!first.recordsFileDetails)
        first.requestFileDetails(true, confirm: { consent in
            #expect(consent == .detailed); return true
        })
        let child = first.log.forDevice()
        child.record(.moveDetails, details: .move(sourcePath: "/private-photo.jpg",
            destinationPath: "/private-folder", storageID: 1, objectHandle: 2))
        child.record(.usbOpen)
        first.finishShutdown(clean: false)

        let second = AppDiagnostics(journalDirectory: directory, defaults: settings)
        #expect(second.isRecording && second.recordsFileDetails)
        let previous = try #require(second.report(includeFileDetails: true).previousSession)
        #expect(!previous.cleanExit)
        #expect(previous.log.events.contains { $0.details != nil })
        second.log.record(.connect)
        second.requestRecording(false)
        #expect(!second.isRecording && !second.recordsFileDetails && !second.log.recordsDetails)
        let files = ["current.jsonl", "previous.jsonl"].map { directory.appendingPathComponent($0) }
        let before = try files.map { try Data(contentsOf: $0) }
        let events = second.log.snapshot().events.count
        second.log.forDevice().record(.usbRead, bytes: 123)
        second.log.record(.appleUSBError, failure: .other)
        #expect(second.log.snapshot().events.count == events)
        second.finishShutdown(clean: true)

        let third = AppDiagnostics(journalDirectory: directory, defaults: settings)
        #expect(!third.isRecording && !third.recordsFileDetails)
        third.log.record(.listing)
        #expect(third.log.snapshot().events.isEmpty)
        let report = third.report(includeFileDetails: true)
        #expect(report.savedSession?.log.events.contains { $0.kind == .connect } == true)
        #expect(report.previousSession?.log.events.contains { $0.details != nil } == true)
        let standard = String(decoding: try third.report().encoded(), as: UTF8.self)
        #expect(!standard.contains("private-photo") && !standard.contains("private-folder"))
        third.finishShutdown(clean: true)
        #expect(try files.map { try Data(contentsOf: $0) } == before)
        third.clearDiagnostics()
        #expect(files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect(third.report().savedSession == nil && third.report().previousSession == nil)
    }

    @Test func stopResumeAndClearDoNotLeakEventsFromDisabledInterval() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = AppDiagnostics(journalDirectory: directory, defaults: defaults())
        let child = app.log.forDevice()
        app.requestRecording(true, confirm: { _ in true })
        child.record(.connect)
        app.requestRecording(false)
        child.record(.listing)
        app.requestRecording(true, confirm: { _ in true })
        child.record(.disconnect)
        #expect(app.report().log.events.map(\.kind) == [.connect, .disconnect])
        app.clearDiagnostics()
        child.record(.usbOpen)
        app.finishShutdown(clean: true)
        let journal = DiagnosticJournal(directory: directory,
            metadata: DiagnosticSessionMetadata(buildIdentity: app.buildIdentity,                 macOS: "14.0"), startImmediately: false)
        #expect(journal.currentSession()?.log.events.map(\.kind) == [.usbOpen])
    }

    @Test func exportFollowsFilenameCheckboxAndFiltersPreviouslyRecordedDetails() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = AppDiagnostics(journalDirectory: directory, defaults: defaults())
        app.requestRecording(true, confirm: { _ in true })
        app.requestFileDetails(true, confirm: { _ in true })
        app.log.record(.moveDetails, details: .move(sourcePath: "/private-photo.jpg",
            destinationPath: "/private-folder", storageID: 1, objectHandle: 2))
        #expect(app.report().includesFileDetails)
        #expect(String(decoding: try app.report().encoded(), as: UTF8.self).contains("private-photo.jpg"))
        app.requestFileDetails(false)
        #expect(!app.report().includesFileDetails)
        #expect(!String(decoding: try app.report().encoded(), as: UTF8.self).contains("private-photo.jpg"))
        // Changing export mode does not erase the retained recording.
        #expect(app.log.snapshot().events.contains { $0.details != nil })
        app.requestFileDetails(true, confirm: { _ in true })
        app.requestRecording(false)
        #expect(!app.report().includesFileDetails)
        #expect(!String(decoding: try app.report().encoded(), as: UTF8.self).contains("private-photo.jpg"))
        app.clearDiagnostics()
    }
}
