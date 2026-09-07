import Darwin
import Foundation
import Testing

@testable import Piko

private final class LocalUploadFixture {
    let root: URL
    let snapshots: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "upload-local-safety-\(UUID().uuidString)", isDirectory: true)
        snapshots = root.appendingPathComponent("snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
    }

    func file(_ path: String, size: Int = 32) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x5a, count: size).write(to: url)
        return url
    }

    deinit { try? FileManager.default.removeItem(at: root) }
}

private final class CancellationAfterChecks: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let limit: Int

    init(_ limit: Int) { self.limit = limit }

    func check() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count >= limit
    }

    var checks: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private final class ReplaceSourceAfterChecks: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let source: URL

    init(source: URL) { self.source = source }

    func check() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        if count == 4 {
            try? Data(repeating: 0x33, count: 1_048_577).write(to: source, options: .atomic)
        }
        return false
    }
}

@Test func snapshotCopyIsCancellableBetweenChunksAndCleansPartialOutput() throws {
    let fixture = try LocalUploadFixture()
    let source = try fixture.file("large.bin", size: 1_048_576)
    let cancellation = CancellationAfterChecks(4)

    #expect(throws: CancellationError.self) {
        try UploadSnapshot(
            source: source, cancelled: cancellation.check,
            temporaryDirectory: fixture.snapshots)
    }
    #expect(cancellation.checks >= 4)
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.snapshots.path).isEmpty)
}

@Test func snapshotRejectsConcurrentReplacementAndPreservesModificationDate() throws {
    let fixture = try LocalUploadFixture()
    let source = try fixture.file("stable.bin", size: 1_048_576)
    let sourceDate = Date(timeIntervalSince1970: 1_700_000_000.125)
    try FileManager.default.setAttributes([.modificationDate: sourceDate], ofItemAtPath: source.path)

    let snapshot = try UploadSnapshot(source: source, temporaryDirectory: fixture.snapshots)
    defer { snapshot.remove() }
    let copiedDate = try #require(
        FileManager.default.attributesOfItem(atPath: snapshot.file.path)[.modificationDate] as? Date)
    #expect(abs(copiedDate.timeIntervalSince(sourceDate)) < 0.001)
    #expect(snapshot.size == 1_048_576)

    snapshot.remove()
    let replacement = ReplaceSourceAfterChecks(source: source)
    #expect(throws: UploadError.sourceChanged) {
        try UploadSnapshot(
            source: source, cancelled: replacement.check,
            temporaryDirectory: fixture.snapshots)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.snapshots.path).isEmpty)
}

@Test func planRejectsSameMetadataFileAndDirectoryReplacements() throws {
    let fixture = try LocalUploadFixture()
    let source = try fixture.file("selected.bin", size: 64)
    let sourceDate = Date(timeIntervalSince1970: 1_700_000_100)
    try FileManager.default.setAttributes([.modificationDate: sourceDate], ofItemAtPath: source.path)
    let expectedIdentity = try UploadSourceIdentity.capture(at: source)
    let selected = try #require(UploadPlan.build(sources: [source]).first)
    #expect(selected.plannedFileSize == 64)

    let oldSource = fixture.root.appendingPathComponent("old-selected.bin")
    try FileManager.default.moveItem(at: source, to: oldSource)
    try Data(repeating: 0x5a, count: 64).write(to: source)
    try FileManager.default.setAttributes([.modificationDate: sourceDate], ofItemAtPath: source.path)
    #expect(throws: UploadError.sourceChanged) { try selected.validateForSnapshot() }
    #expect(throws: UploadError.sourceChanged) {
        try UploadSnapshot(
            source: source, expectedIdentity: expectedIdentity,
            temporaryDirectory: fixture.snapshots)
    }
    #expect(throws: UploadError.sourceChanged) {
        try selected.makeSnapshot(temporaryDirectory: fixture.snapshots)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.snapshots.path).isEmpty)

    let child = try fixture.file("Tree/Sub/child.bin")
    let plannedChild = try #require(UploadPlan.build(sources: [fixture.root.appendingPathComponent("Tree")]).last)
    #expect(
        plannedChild.source.resolvingSymlinksInPath()
            == child.resolvingSymlinksInPath())
    let subdirectory = child.deletingLastPathComponent()
    try FileManager.default.moveItem(
        at: subdirectory, to: fixture.root.appendingPathComponent("old-subdirectory"))
    try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: false)
    #expect(throws: UploadError.sourceChanged) { try plannedChild.validateAncestors() }
}

@Test func planDetectsInPlaceRewriteWhenModificationDateIsRestored() throws {
    let fixture = try LocalUploadFixture()
    let source = try fixture.file("rewritten.bin", size: 64)
    let sourceDate = Date(timeIntervalSince1970: 1_700_000_200)
    try FileManager.default.setAttributes([.modificationDate: sourceDate], ofItemAtPath: source.path)
    let before = try UploadSourceIdentity.capture(at: source)
    let item = try #require(UploadPlan.build(sources: [source]).first)

    usleep(10_000)
    let handle = try FileHandle(forWritingTo: source)
    try handle.write(contentsOf: Data([0x31]))
    try handle.close()
    try FileManager.default.setAttributes([.modificationDate: sourceDate], ofItemAtPath: source.path)
    let after = try UploadSourceIdentity.capture(at: source)

    #expect(after.device == before.device)
    #expect(after.inode == before.inode)
    #expect(after.size == before.size)
    #expect(after.modificationSeconds == before.modificationSeconds)
    #expect(after.modificationNanoseconds == before.modificationNanoseconds)
    #expect(
        after.changeSeconds != before.changeSeconds
            || after.changeNanoseconds != before.changeNanoseconds)
    #expect(throws: UploadError.sourceChanged) { try item.validateForSnapshot() }
    #expect(throws: UploadError.sourceChanged) {
        try item.makeSnapshot(temporaryDirectory: fixture.snapshots)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.snapshots.path).isEmpty)
}

@Test func snapshotRejectsSpecialFilesAndAlreadyCancelledTasks() async throws {
    let fixture = try LocalUploadFixture()
    let fifo = fixture.root.appendingPathComponent("named-pipe")
    #expect(mkfifo(fifo.path, mode_t(0o600)) == 0)
    #expect(throws: UploadError.unsupportedSource) {
        try UploadSnapshot(source: fifo, temporaryDirectory: fixture.snapshots)
    }

    let source = try fixture.file("cancelled.bin", size: 1_048_576)
    let task = Task { try UploadSnapshot(source: source, temporaryDirectory: fixture.snapshots) }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.snapshots.path).isEmpty)
}
