import Foundation
import MTPWire
import Testing

@testable import Piko

@MainActor @Suite struct RangedUploadTests {
    private let operations = RangedUpload.requiredOperations

    private func backend(_ device: SyntheticUploadDevice, log: DiagnosticLog? = nil) async throws -> SwiftMTPBackend {
        let backend = SwiftMTPBackend(canCancelActiveTransfer: true, diagnostics: log) { device }
        _ = try await backend.connect()
        return backend
    }

    private func waitForPause(_ device: SyntheticUploadDevice) async throws {
        for _ in 0..<2000 {
            if await device.isPaused { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(await device.isPaused)
    }

    @Test(arguments: [UInt16(0x200C), UInt16(0x2015)])
    func creationRejectionReportsFailureAndAllowsRetry(code: UInt16) async throws {
        let device = try SyntheticUploadDevice(advertisedWrites: operations, existingNames: ["keep.txt"])
        let backend = SwiftMTPBackend(canCancelActiveTransfer: true) { device }
        let model = DeviceBrowserModel(client: PreparedBinFixture(backend))
        await model.connectAndLoad()
        let local = try SwiftUploadTestDirectory()
        let bytes = Data([1, 2, 3])
        let source = try local.file("retry.bin", data: bytes)
        await device.configureFault(reject: 0x100C, rejectionCode: code)
        await model.upload(sources: [source])
        let snapshot = await device.snapshot()
        #expect(model.state == .connected)
        #expect(model.canUpload)
        #expect(model.files.contains { $0.name == "keep.txt" })
        #expect(model.transfers.results.count == 1)
        #expect(model.transfers.results.contains {
            if case .failed(let message) = $0.outcome {
                message.contains(String(format: "0x%04x", code))
            } else { false }
        })
        #expect(!snapshot.closed)
        #expect(snapshot.writeOperationCommands == [0x100C])
        #expect(!snapshot.commands.contains(0x100B))
        #expect(snapshot.uploads.isEmpty)
        await device.configureFault()
        await model.upload(sources: [source])
        #expect(await device.storedData(named: "retry.bin") == bytes)
        #expect(await device.storedData(named: "keep.txt") == Data())
        #expect(model.state == .connected)
        #expect(!(await device.snapshot().closed))
        try await backend.disconnect()
    }

    @Test(arguments: [2, 19]) func repeatedCancelThenUploadBrowseDownloadOnSameSession(pauseWrite: Int) async throws {
        let device = try SyntheticUploadDevice(advertisedWrites: operations, existingNames: ["keep.txt"])
        let log = DiagnosticLog()
        let backend = try await backend(device, log: log)
        let local = try SwiftUploadTestDirectory()
        let bytes = await Task.detached {
            Data((0..<(3 * 1024 * 1024 + 123)).map { UInt8(truncatingIfNeeded: $0 / 251 + $0) })
        }.value
        let source = try local.file("large.bin", data: bytes)
        let completed = try local.file("completed.txt", data: Data())
        let skipped = try local.file("never.txt", data: Data([99]))
        for _ in 0..<2 {
            let coordinator = TransferCoordinator(diagnostics: log)
            await device.pause(operation: 0x95C2, afterWrites: pauseWrite)
            let transfer = Task {
                try await coordinator.upload(backend: backend, storageID: 1,
                    sources: [completed, source, skipped], directory: "/")
            }
            try await waitForPause(device)
            #expect(coordinator.canCancelActiveTransfer)
            let previous = await device.partialRequests.count
            coordinator.cancelTransfer()
            await device.resume()
            try await transfer.value
            #expect(await device.partialRequests.count == previous)
            #expect(await device.storedData(named: "large.bin") == nil)
            #expect(await device.storedData(named: "completed.txt") == Data())
            #expect(await device.storedData(named: "keep.txt") == Data())
            #expect(await device.storedData(named: "never.txt") == nil)
            #expect(coordinator.results.contains { if case .uploadCancelled = $0.outcome { true } else { false } })
            #expect(coordinator.results.last?.outcome == .notAttempted)
            #expect(!(await device.snapshot().closed))
            #expect(await device.cancelCount == 0)
            #expect(!(await device.interruptedIO))
            _ = try await backend.contents(storageID: 1, path: "/", showHiddenFiles: true)
        }
        _ = try await backend.upload(storageID: 1, source: source, to: "/", progress: { _ in })
        #expect(await device.storedData(named: "large.bin") == bytes)
        let listed = try await backend.contents(storageID: 1, path: "/", showHiddenFiles: true)
        let file = try #require(listed.first { $0.name == "large.bin" })
        let output = local.url.appendingPathComponent("download")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        try await backend.download(storageID: 1, files: [file], to: output, progress: { _ in })
        #expect(try Data(contentsOf: output.appendingPathComponent(file.name)) == bytes)
        #expect(await device.snapshot().commands.filter { $0 == 0x1002 }.count == 1)
        #expect(log.snapshot().events.contains { $0.kind == .uploadStrategy && $0.operation == 0x95C2 })
        #expect(log.snapshot().events.filter { $0.kind == .uploadCleanup && $0.failure == nil }.count == 2)
        try await backend.disconnect()
    }

    @Test func androidFilenameDerivedFormatSupportsUploadAndCancellation() async throws {
        let device = try SyntheticUploadDevice(advertisedWrites: operations, reportedFileFormat: 0x3801)
        let backend = try await backend(device)
        let local = try SwiftUploadTestDirectory()
        let data = Data(repeating: 0xAC, count: 1_100_003)
        let source = try local.file("photo.jpg", data: data)
        _ = try await backend.upload(storageID: 1, source: source, to: "/", progress: { _ in })
        #expect(await device.storedData(named: "photo.jpg") == data)
        let cancelled = try local.file("cancelled.jpg", data: data)
        await device.pause(operation: 0x95C2)
        let task = Task { try await backend.upload(storageID: 1, source: cancelled, to: "/", progress: { _ in }) }
        try await waitForPause(device)
        task.cancel()
        await device.resume()
        await #expect(throws: UploadError.cancelledAndRemoved) { try await task.value }
        #expect(await device.storedData(named: "cancelled.jpg") == nil)
        #expect(await device.storedData(named: "photo.jpg") == data)
        #expect(!(await device.snapshot().closed))
        #expect(await device.cancelCount == 0)
    }

    @Test(arguments: [UInt16(0x100D), 0x95C4, 0x95C5])
    func cancellationDuringCreationOrEditBoundaryRemovesOnlyNewFile(operation: UInt16) async throws {
        let device = try SyntheticUploadDevice(advertisedWrites: operations, existingNames: ["keep.txt"])
        let backend = try await backend(device)
        let local = try SwiftUploadTestDirectory()
        let source = try local.file("boundary.bin", data: Data(repeating: 0x35, count: 123))
        await device.pause(operation: operation, includingCommand: true)
        let task = Task { try await backend.upload(storageID: 1, source: source, to: "/", progress: { _ in }) }
        try await waitForPause(device)
        task.cancel()
        await device.resume()
        await #expect(throws: UploadError.cancelledAndRemoved) { try await task.value }
        #expect(await device.storedData(named: "boundary.bin") == nil)
        #expect(await device.storedData(named: "keep.txt") == Data())
        #expect(await device.cancelCount == 0)
        #expect(!(await device.snapshot().closed))
        #expect(!(await device.interruptedIO))
        if operation == 0x95C5 { #expect(await device.snapshot().commands.filter { $0 == 0x95C5 }.count == 1) }
    }

    @Test(arguments: [UInt16(0x95C2), 0x95C4, 0x95C5, 0x100B])
    func ordinaryUploadFinishesCurrentFileAndSkipsQueue(missing: UInt16) async throws {
        let device = try SyntheticUploadDevice(advertisedWrites:
            operations.union([ReadSession.getPartialObjectCode]).subtracting([missing]))
        let log = DiagnosticLog()
        let backend = SwiftMTPBackend(canCancelActiveTransfer: true, diagnostics: log) { device }
        _ = try await backend.connect()
        #expect(!(await backend.supportsUploadCancellation(to: 1)))
        #expect(await backend.supportsDownloadCancellation())
        #expect(await backend.supportsUpload(to: 1))
        let local = try SwiftUploadTestDirectory()
        let bytes = Data(repeating: 0x23, count: 200_013)
        let source = try local.file("whole.bin", data: bytes)
        let next = try local.file("next.bin", data: bytes)
        let coordinator = TransferCoordinator()
        await device.pause(operation: 0x100D)
        let task = Task { try await coordinator.upload(backend: backend, storageID: 1, sources: [source, next], directory: "/") }
        try await waitForPause(device)
        #expect(!coordinator.canCancelActiveTransfer)
        coordinator.cancelTransfer()
        await device.resume()
        try await task.value
        #expect(await device.storedData(named: "whole.bin") == bytes)
        #expect(await device.storedData(named: "next.bin") == nil)
        #expect(coordinator.results.last?.outcome == .notAttempted)
        #expect(await device.partialRequests.isEmpty)
        #expect(await device.cancelCount == 0)
        #expect(!(await device.interruptedIO))
        #expect(!(await device.snapshot().closed))
        let snapshot = await device.snapshot()
        // The fixture validates SendObject's length against SendObjectInfo,
        // proving the full size was declared before the body was sent.
        #expect(snapshot.uploads.count == 1)
        #expect(snapshot.uploads.first?.data == bytes)
        #expect(!snapshot.commands.contains(0x95C4))
        #expect(!snapshot.commands.contains(0x95C5))
        #expect(log.snapshot().events.contains {
            $0.kind == .uploadStrategy && $0.operation == 0x100D && $0.requestedBytes == nil
        })
        try await backend.disconnect()
    }

    @Test(arguments: ["deleteRejected", "identityChanged", "endRejected", "deleteTransportFailure", "deleteIgnored"])
    func unsuccessfulCleanupNeverClaimsRemovalOrRetries(fault: String) async throws {
        let device = try SyntheticUploadDevice(advertisedWrites: operations, existingNames: ["keep.txt"],
            failDeleteAt: fault == "deleteTransportFailure" ? 1 : nil)
        let backend = try await backend(device)
        let local = try SwiftUploadTestDirectory()
        let source = try local.file("incomplete.bin", data: Data(repeating: 0x55, count: 2_000_000))
        let coordinator = TransferCoordinator()
        await device.pause(operation: 0x95C2)
        let task = Task { try await coordinator.upload(backend: backend, storageID: 1, sources: [source], directory: "/") }
        try await waitForPause(device)
        await device.configureFault(reject: fault == "deleteRejected" ? 0x100B : (fault == "endRejected" ? 0x95C5 : nil),
            changedIdentity: fault == "identityChanged", ignoredDelete: fault == "deleteIgnored")
        coordinator.cancelTransfer()
        await device.resume()
        await #expect(throws: BackendSessionError.reconnectRequired) { try await task.value }
        #expect(coordinator.results.contains { if case .uploadUncertain = $0.outcome { true } else { false } })
        #expect(await device.storedData(named: "keep.txt") == Data())
        let commands = await device.snapshot().commands
        #expect(commands.filter { $0 == 0x95C5 }.count == 1)
        #expect(commands.filter { $0 == 0x100B }.count == (fault.hasPrefix("delete") ? 1 : 0))
        #expect(await device.cancelCount == 0)
    }

    @Test(arguments: ["badCount", "objectRejected", "beginRejected", "endRejected", "partialFailure"])
    func failedRangeDoesNotFallbackReplayOrDelete(fault: String) async throws {
        let device = try SyntheticUploadDevice(advertisedWrites: operations)
        let rejectedOperation: UInt16? = switch fault {
        case "objectRejected": 0x100D
        case "beginRejected": 0x95C4
        case "endRejected": 0x95C5
        default: nil
        }
        await device.configureFault(reject: rejectedOperation, badCount: fault == "badCount", partialFailure: fault == "partialFailure")
        let backend = try await backend(device)
        let local = try SwiftUploadTestDirectory()
        let source = try local.file("failure.bin", data: Data(repeating: 1, count: 2_000_000))
        await #expect(throws: BackendSessionError.reconnectRequired) {
            try await backend.upload(storageID: 1, source: source, to: "/", progress: { _ in })
        }
        let snapshot = await device.snapshot()
        #expect(snapshot.commands.filter { $0 == 0x100D }.count == 1) // Empty creation only.
        #expect(snapshot.closed)
        if fault != "objectRejected" { #expect(snapshot.uploads.first?.data == Data()) }
        #expect(!snapshot.commands.contains(0x100B))
        let expectedRanges = switch fault {
        case "objectRejected", "beginRejected": 0
        case "endRejected": 2
        default: 1
        }
        #expect(await device.partialRequests.count == expectedRanges)
        #expect(await device.cancelCount == 0)
    }

    @Test(arguments: [true, false]) func gracefulQuitWaitsForCleanupOrCurrentFile(ranged: Bool) async throws {
        let device = try SyntheticUploadDevice(advertisedWrites: ranged ? operations : [0x100C, 0x100D])
        let backend = SwiftMTPBackend(canCancelActiveTransfer: true) { device }
        let model = DeviceBrowserModel(client: PreparedBinFixture(backend))
        await model.connectAndLoad()
        let local = try SwiftUploadTestDirectory()
        let source = try local.file("quit.bin", data: Data(repeating: 8, count: 2_000_000))
        await device.pause(operation: ranged ? 0x95C2 : 0x100D)
        let upload = Task { await model.upload(sources: [source]) }
        try await waitForPause(device)
        let quit = Task { await model.prepareToQuit() }
        for _ in 0..<2000 {
            if model.transfers.stopRequested { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(model.transfers.stopRequested)
        #expect(!(await device.snapshot().closed))
        await device.resume()
        await upload.value
        await quit.value
        #expect(await device.snapshot().closed)
        #expect(await device.snapshot().commands.last == 0x1003)
        #expect(await device.cancelCount == 0)
        #expect((await device.storedData(named: "quit.bin") == nil) == ranged)
    }
}
