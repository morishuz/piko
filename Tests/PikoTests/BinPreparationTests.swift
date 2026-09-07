import Foundation
import MTPWire
import Testing
@testable import Piko

@MainActor
struct BinPreparationTests {
    private func device() throws -> SyntheticUploadDevice {
        try SyntheticUploadDevice(advertisedWrites: [0x100B, 0x100C, 0x100D, 0x1019], existingNames: ["photo.jpg"])
    }
    private func files(_ backend: any MTPBackend, _ path: String = "/") async throws -> [MTPFile] {
        try await backend.contents(storageID: 1, path: path, showHiddenFiles: true)
    }

    @Test(arguments: ["Piko Bin", "piko bin"])
    func occupiedNameIsNeverAdoptedOrHidden(name: String) async throws {
        let backend = DemoBackend(fileCount: 0, delay: .zero)
        _ = try await backend.connect()
        _ = try await backend.createUploadDirectory(storageID: 1, parent: "/", name: name)
        let model = DeviceBrowserModel(client: backend)
        await model.connectAndLoad()
        let root = try #require(model.binReadiness[1]?.roots.first)
        #expect(root.hasPrefix("/Piko Bin-"))
        #expect(BinLayout.isCandidateRoot(root))
        #expect(model.files.contains { $0.name == name })
        #expect(!model.files.contains { $0.path == root })
        #expect(try await files(backend, "/" + name).isEmpty)
        #expect(model.binCount == 0 && model.canOpenBin && model.canUpload)
        #expect(!model.isBinPath("/" + name))
        let unowned = try #require(model.files.first { $0.name == name })
        #expect(model.canDelete([unowned]))
        await model.load(path: "/" + name)
        #expect(!model.isViewingBin && model.canUpload)
        await model.disconnectAndReset()
        await model.connectAndLoad()
        #expect(model.binReadiness[1]?.roots == [root])
        #expect(try await files(backend).filter { BinLayout.isCandidateRoot($0.path) }.count == (name == "Piko Bin" ? 2 : 1))
    }

    @Test func markerFailureBlocksEveryWriteWithoutMovingUserFiles() async throws {
        let backend = DemoBackend(fileCount: 2, delay: .zero,
            uploadFailures: [BinLayout.markerName: .permissionDenied])
        let model = DeviceBrowserModel(client: backend)
        await model.connectAndLoad()
        #expect(model.isConnected && !model.canUpload && !model.canOpenBin)
        #expect(model.binCount == nil && model.writeRestriction != nil)
        #expect(model.storageWriteCapabilities[1]?.move == false)
        await model.load(path: "/Demo Files")
        model.selectAll()
        #expect(model.canDownload && !model.canDelete(model.files))
        #expect(!model.canDropIntoBin)
        #expect(try await files(backend).allSatisfy { $0.name != "Documents" })
        #expect(try await files(backend, BinLayout.root).isEmpty)
        await model.performBinAction(files: model.files, action: .trash)
        #expect(try await files(backend, "/Demo Files").contains { $0.name == "Sample-0002.txt" })
    }

    @Test(arguments: [UInt16(0x100C), UInt16(0x100D)])
    func recognisedFullBinRequiresNoNewWriteAndCanBeEmptied(rejectedOperation: UInt16) async throws {
        let wire = try device()
        let backend = SwiftMTPBackend { wire }
        let model = DeviceBrowserModel(client: backend)
        await model.connectAndLoad()
        await model.performBinAction(files: model.files, action: .trash)
        #expect(model.binCount == 1)
        await model.disconnectAndReset()
        await wire.prepareReconnect()
        await wire.configureFault(reject: rejectedOperation, rejectionCode: 0x200C)
        let before = await wire.snapshot().writeOperationCommands
        await model.connectAndLoad()
        #expect(model.canOpenBin && model.binCount == 1)
        #expect(await wire.snapshot().writeOperationCommands == before)
        await model.load(path: BinLayout.overview)
        #expect(model.canEmptyBin)
        await model.performBinAction(files: try #require(model.binListing).entries, action: .delete, emptying: true)
        #expect(model.operationError == nil && model.binCount == 0)
        #expect(try await files(backend, BinLayout.root).map(\.name) == [BinLayout.markerName])
        await model.load(path: "/")
        #expect(model.canOpenBin)
    }

    @Test func emptyBinPreservesUnrecognisedItemsAndTheOwnershipMarker() async throws {
        let backend = DemoBackend(fileCount: 1, delay: .zero)
        let model = DeviceBrowserModel(client: backend)
        await model.connectAndLoad()
        let folder = try #require(model.files.first { $0.name == "Demo Files" })
        await model.performBinAction(files: [folder], action: .trash)
        #expect(model.binCount == 1) // The folder counts once, including its children.
        let local = try SwiftUploadTestDirectory()
        _ = try await backend.upload(storageID: 1, source: local.file("Keep.txt", data: Data("unrecognised".utf8)),
            to: BinLayout.root, progress: { _ in })
        await model.load(path: BinLayout.overview)
        #expect(model.binCount == 2)
        #expect(model.binListing?.entries.count == 1)
        await model.performBinAction(files: try #require(model.binListing).entries, action: .delete, emptying: true)
        #expect(model.operationError == nil)
        #expect(model.files.map(\.name) == ["Keep.txt"] && model.binCount == 1)
        #expect(!model.canEmptyBin)
        #expect(model.canDelete(model.files) && !model.canRestore)
        await model.performBinAction(files: model.files, action: .delete)
        #expect(model.files.isEmpty && model.binCount == 0)
        #expect(try await files(backend, BinLayout.root).map(\.name) == [BinLayout.markerName])
    }

    @Test func missingMarkerMakesCountUnknownAndBlocksWritesUntilReconnect() async throws {
        let backend = DemoBackend(fileCount: 0, delay: .zero)
        let model = DeviceBrowserModel(client: backend)
        await model.connectAndLoad()
        let marker = try #require(try await files(backend, BinLayout.root).first)
        _ = try await backend.move(storageID: 1, file: marker, to: "/")
        await model.load(path: BinLayout.overview)
        #expect(!model.canOpenBin && !model.canUpload && model.binCount == nil)
        #expect(model.writeRestriction != nil)
        await model.disconnectAndReset()
        await model.connectAndLoad()
        #expect(model.binReadiness[1]?.roots.first?.hasPrefix("/Piko Bin-") == true)
        #expect(model.files.contains { $0.path == BinLayout.root })
    }

    @Test func preparationIsIndependentForEachStorage() async throws {
        let backend = RelayDevice(rejectDirectoryStorage: 2)
        let model = DeviceBrowserModel(client: backend)
        await model.connectAndLoad()
        #expect(model.isConnected && model.canUpload)
        #expect(model.storageWriteCapabilities[1]?.upload == true)
        #expect(model.storageWriteCapabilities[1]?.move == true)
        #expect(model.storageWriteCapabilities[2]?.upload == false)
        #expect(model.storageWriteCapabilities[2]?.move == false)
        #expect(model.binReadiness[2]?.count == nil)
    }

    @Test func blockedDeviceCanStillCopyOutButCannotReceiveOrMove() async throws {
        let source = DemoBackend(fileCount: 2, delay: .zero, uploadFailures: ["Piko Bin": .permissionDenied])
        let destination = DemoBackend(fileCount: 0, delay: .zero)
        let found = [DiscoveredDevice(id: "a", name: "Source"), DiscoveredDevice(id: "b", name: "Destination")]
        let manager = DeviceManager(discover: { found },
            makeBackend: { device, _ in device.id == "a" ? source : destination })
        await manager.scan()
        for device in manager.devices { await device.browser.connectAndLoad() }
        let a = manager.devices[0], b = manager.devices[1]
        await a.browser.load(path: "/Demo Files")
        let file = try #require(a.browser.files.first { !$0.isFolder })
        manager.beginRemoteDrag(device: a, files: [file], browserID: a.browser.browserDragID)
        let tokens = try #require(manager.dragSelection).tokens
        #expect(manager.remoteRequest(tokens, to: a, storageID: 1, directory: "/") == nil)
        #expect(manager.remoteRequest(tokens, to: b, storageID: 1, directory: "/")?.operation == .copy)
        #expect(!a.browser.canOpenBin && b.browser.canOpenBin)
    }
}
