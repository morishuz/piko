import Foundation
import Testing

@testable import MTPWire

@Test func diagnosticRingIsBoundedOrderedAndClearable() throws {
    let log = DiagnosticLog(capacity: 3)
    for index in 0..<8 { log.record(.usbRead, bytes: index) }
    let snapshot = log.snapshot()
    #expect(snapshot.events.map(\.sequence) == [5, 6, 7])
    #expect(snapshot.events.map(\.bytes) == [5, 6, 7])
    #expect(snapshot.discardedEvents == 5)
    let encoded = try JSONEncoder().encode(snapshot)
    let decoded = try JSONDecoder().decode(DiagnosticSnapshot.self, from: encoded)
    #expect(decoded.events.count == 3)
    log.clear()
    #expect(log.snapshot().events.isEmpty)
    #expect(log.snapshot().discardedEvents == 0)
    log.record(.connect)
    #expect(log.snapshot().events.first?.sequence == 0)
    #expect(DiagnosticLog(capacity: Int.max).snapshot().capacity == 4096)
    #expect(DiagnosticLog(capacity: -1).snapshot().capacity == 1)
}

@Test func diagnosticConcurrentWritersAndSnapshotsAreConsistent() async {
    let log = DiagnosticLog(capacity: 127)
    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<8 {
            group.addTask {
                for _ in 0..<1000 {
                    log.record(.usbRead, bytes: 512)
                    let snapshot = log.snapshot()
                    #expect(snapshot.events.count <= 127)
                    #expect(snapshot.events.map(\.sequence) == snapshot.events.map(\.sequence).sorted())
                }
            }
        }
    }
    #expect(log.snapshot().discardedEvents == 8000 - 127)
}

@Test func diagnosticUnknownErrorsNeverSerializeDescriptions() throws {
    let privateText = "/Users/private/secret-photo.jpg SERIAL-PRIVATE-123"
    let error = NSError(
        domain: privateText, code: 7,
        userInfo: [NSLocalizedDescriptionKey: privateText])
    let log = DiagnosticLog()
    log.record(.download, failure: .classify(error))
    let json = String(decoding: try JSONEncoder().encode(log.snapshot()), as: UTF8.self)
    #expect(!json.contains(privateText))
    #expect(log.snapshot().events.first?.failure == .other)
    #expect(DiagnosticFailure.classify(CancellationError()) == .cancelled)
}

@Test func diagnosticCorrelationIsLocalMonotonicAndTaskScoped() {
    let log = DiagnosticLog()
    let first = log.nextCorrelationID()
    let second = log.nextCorrelationID()
    #expect(second == first + 1)
    DiagnosticContext.$transferID.withValue(first) {
        DiagnosticContext.$recoveryID.withValue(second) {
            log.record(.recoveryAttempt, recoveryAttempt: 2)
        }
    }
    let event = log.snapshot().events.first
    #expect(event?.transferID == first)
    #expect(event?.recoveryID == second)
    #expect(event?.recoveryAttempt == 2)
    log.clear()
    #expect(log.nextCorrelationID() == second + 1)
}

@Test func disablingSharedRecorderStopsConcurrentObserversAndStaleBatches() async throws {
    let observed = DiagnosticLog(capacity: 4096)
    let log = DiagnosticLog(capacity: 4096) { observed.record($0.kind) }
    let child = log.forDevice()
    let generation = try #require(log.recordingGeneration)
    child.record(.connect)
    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<4 {
            group.addTask {
                for _ in 0..<500 { child.record(.usbRead, bytes: 512) }
            }
        }
        log.setRecordingEnabled(false)
        let stopped = log.snapshot().events.count
        let delivered = observed.snapshot().events.count
        await group.waitForAll()
        #expect(log.snapshot().events.count == stopped)
        #expect(observed.snapshot().events.count == delivered)
        #expect(stopped == delivered)
    }
    log.setRecordingEnabled(true)
    let count = log.snapshot().events.count
    child.record(.usbWrite, recordingGeneration: generation)
    #expect(log.snapshot().events.count == count)
    child.record(.disconnect)
    #expect(log.snapshot().events.last?.kind == .disconnect)
}
