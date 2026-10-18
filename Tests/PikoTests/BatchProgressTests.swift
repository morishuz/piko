import Foundation
import Testing
@testable import Piko

struct BatchProgressTests {
    @Test func weightsByBytesAndDoesNotDoubleCountResolvedFile() {
        var progress = BatchProgress(files: [("small", 100), ("large", 900)])
        #expect(progress.fraction(activePath: "small", activeBytes: 50) == 0.05)
        progress.resolve("small")
        #expect(progress.fraction(activePath: "small", activeBytes: 100) == 0.1)
        #expect(progress.fraction(activePath: "large", activeBytes: 450) == 0.55)
        progress.resolve("small")
        #expect(progress.processedFileCount == 1)
        progress.resolve("large")
        #expect(progress.fraction(activePath: nil) == 1)
    }

    @Test func zeroUnknownAndLargeSizesAreSafe() {
        var empty = BatchProgress(files: [("empty", 0)])
        #expect(empty.fraction(activePath: "empty") == 0)
        empty.resolve("empty")
        #expect(empty.fraction(activePath: nil) == 1)
        #expect(BatchProgress(files: [("unknown", -1)]).fraction(activePath: nil) == nil)
        let large = BatchProgress(files: [("a", .max), ("b", .max)])
        #expect(large.fraction(activePath: "a", activeBytes: Double(Int64.max)) == 0.5)
    }
}

@MainActor
private final class PausedProgressBackend: MTPBackend {
    let capabilities = BackendCapabilities(reportsProgress: true, canCancelActiveTransfer: false)
    let folder = RelayDevice.file(1, "/Album", folder: true)
    let files = [RelayDevice.file(2, "/Album/small", size: 100), RelayDevice.file(3, "/Album/large", size: 900)]
    var pending: CheckedContinuation<Void, Never>?
    func connect() async throws -> [MTPStorage] { [DemoBackend.storage] }
    func disconnect() async throws -> Bool { true }
    func contents(storageID: UInt32, path: String, showHiddenFiles: Bool) async throws -> [MTPFile] {
        path == "/" ? [folder] : files
    }
    func download(storageID: UInt32, files: [MTPFile], to destination: URL, progress: @escaping ProgressHandler) async throws {
        for file in files {
            progress(TransferProgress(fileName: file.name, bytesTransferred: file.size / 2, totalBytes: file.size))
            await withCheckedContinuation { pending = $0 }
            try Data(repeating: 1, count: Int(file.size)).write(to: destination.appendingPathComponent(file.name))
            progress(TransferProgress(fileName: file.name, bytesTransferred: file.size, totalBytes: file.size))
        }
    }
    func resume() { let continuation = pending; pending = nil; continuation?.resume() }
}

@MainActor
struct BatchProgressIntegrationTests {
    @Test func folderDownloadCountsFilesAndPreservesOverallProgressBetweenFiles() async throws {
        let backend = PausedProgressBackend()
        let coordinator = TransferCoordinator()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let task = Task { try await coordinator.run(backend: backend, storageID: 1, files: [backend.folder], destination: directory) }
        for _ in 0..<1000 {
            if coordinator.overallFraction == 0.05 && backend.pending != nil { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(coordinator.overallFraction == 0.05)
        #expect(coordinator.batchProgress.fileCount == 2)
        #expect(coordinator.batchProgress.processedFileCount == 0)
        backend.resume()
        for _ in 0..<1000 {
            if coordinator.overallFraction == 0.55 && backend.pending != nil { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(coordinator.overallFraction == 0.55)
        #expect(coordinator.batchProgress.processedFileCount == 1)
        backend.resume()
        try await task.value
        #expect(coordinator.overallFraction == 1)
        #expect(coordinator.batchProgress.processedFileCount == 2)
        #expect(coordinator.summary.downloaded == 2)
    }
}
