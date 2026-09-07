import Foundation
import MTPWire
import Testing
@testable import Piko

@MainActor struct ThumbnailGenerationTests {
    @Test func selectedOriginalsUseVerifiedDownloadsAndOnlyMissingPhotosAreRead() async throws {
        let data = try thumbnailPNG(width: 1024, height: 768)
        let device = try SyntheticUploadDevice(advertisedWrites: [], existingNames: ["a.jpg", "b.png", "notes.txt"],
            originalData: ["a.jpg": data, "b.png": data, "notes.txt": data])
        let model = DeviceBrowserModel(client: SwiftMTPBackend { device })
        await model.connectAndLoad()
        let files = model.files
        #expect(model.missingThumbnailFiles(files).count == 2)
        await model.generateThumbnails(files)
        #expect(model.isConnected)
        #expect(!model.isBusy)
        #expect(!model.isGeneratingThumbnails)
        #expect(model.operationError == nil)
        #expect(model.transferConfirmation == nil)
        #expect(model.thumbnails.count == 2)
        #expect(model.missingThumbnailFiles(files).isEmpty)
        for file in files where file.isPhotoThumbnailCandidate {
            let key = try #require(model.thumbnailKey(for: file))
            #expect(model.thumbnails.entry(for: key)?.image?.width == 256)
        }
        for result in model.transfers.results {
            if case .downloaded(let url) = result.outcome {
                #expect(!FileManager.default.fileExists(atPath: url.path))
                #expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
            }
        }
        let commands = await device.snapshot().commands
        #expect(commands.filter { $0 == 0x1009 }.count == 2)
        #expect(!commands.contains(0x100A))
        await model.generateThumbnails(files)
        #expect(await device.snapshot().commands == commands)
        await model.disconnectAndReset()
    }

    @Test func corruptedOriginalFailsLocallyAndBatchContinues() async throws {
        let device = try SyntheticUploadDevice(advertisedWrites: [], existingNames: ["a.jpg", "b.jpg"],
            originalData: ["a.jpg": Data("bad image".utf8), "b.jpg": thumbnailPNG()])
        let model = DeviceBrowserModel(client: SwiftMTPBackend { device })
        await model.connectAndLoad()
        await model.generateThumbnails(model.files)
        #expect(model.isConnected)
        #expect(model.thumbnails.count == 1)
        #expect(model.transfers.summary.failed.count == 1)
        #expect(model.operationError?.contains("1 photo") == true)
        #expect(await device.snapshot().closed == false)
        await model.disconnectAndReset()
    }

    @Test func stoppingGenerationFinishesCurrentOriginalSkipsQueueAndKeepsSession() async throws {
        let data = try thumbnailPNG()
        let device = try SyntheticUploadDevice(advertisedWrites: [], existingNames: ["a.jpg", "b.jpg"],
            originalData: ["a.jpg": data, "b.jpg": data])
        let model = DeviceBrowserModel(client: SwiftMTPBackend { device })
        await model.connectAndLoad()
        await device.pause(operation: 0x1009, includingCommand: true)
        let job = Task { await model.generateThumbnails(model.files) }
        try await thumbnailWait { await device.isPaused }
        #expect(model.isGeneratingThumbnails)
        #expect(!model.canDownload)
        model.transfers.cancelTransfer()
        await device.resume()
        await job.value
        #expect(model.isConnected)
        #expect(model.thumbnails.count == 1)
        #expect(model.transfers.summary.pending == 1)
        #expect(await device.snapshot().commands.filter { $0 == 0x1009 }.count == 1)
        #expect(await device.cancelCount == 0)
        #expect(await device.interruptedIO == false)
        await model.disconnectAndReset()
    }
}
