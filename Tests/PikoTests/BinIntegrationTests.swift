import Foundation
import AppKit
import SwiftUI
import MTPWire
import Testing

@testable import Piko

struct BinIntegrationTests {
    private func device(failMoveAt: Int? = nil, corruptReadback: Bool = false, partialReads: Bool = false) throws -> SyntheticUploadDevice {
        try SyntheticUploadDevice(advertisedWrites: partialReads ? [0x100C, 0x100D, 0x1019, 0x101B] : [0x100C, 0x100D, 0x1019],
            existingNames: ["photo.jpg"], failMoveAt: failMoveAt, corruptReadback: corruptReadback)
    }

    private func listing(_ backend: SwiftMTPBackend, _ path: String) async throws -> [MTPFile] {
        try await backend.contents(storageID: 1, path: path, showHiddenFiles: true)
    }

    private func preparedBin(_ backend: SwiftMTPBackend) async throws -> DeviceBin {
        let bin = DeviceBin(backend: backend)
        _ = try await bin.prepare(storageID: 1)
        return bin
    }

    @MainActor @Test func verifiedTrashSucceedsWhenLaterWritesAreRejected() async throws {
        let device = try device()
        let backend = SwiftMTPBackend {
            PostMoveWriteRejectionTransport(device: device, movedHandle: 10)
        }
        let model = DeviceBrowserModel(client: backend)
        await model.connectAndLoad()
        let original = try #require(model.files.first { $0.name == "photo.jpg" })
        await model.performBinAction(files: [original], action: .trash)
        #expect(model.isConnected)
        #expect(model.operationError == nil)
        #expect(model.transferConfirmation == nil)
        #expect(model.binCount == 1)
        #expect(!(await device.snapshot().closed))
        await device.configureFault()
        let bin = DeviceBin(backend: backend)
        let entry = try #require(try await bin.contents(storageID: 1).entries.first)
        try await bin.restore(storageID: 1, entry: entry)
        #expect(try await listing(backend, "/").contains { $0.name == original.name })
        await model.disconnectAndReset()
    }

    @Test func acceptedMoveWithMissingMetadataKeepsSessionAndDoesNotReplay() async throws {
        let device = try device()
        let backend = try await connectedUploadBackend(device)
        let file = try #require(try await listing(backend, "/").first)
        _ = try await backend.createUploadDirectory(storageID: 1, parent: "/", name: "Target")
        await device.configureUnavailable([file.id], afterMove: true)
        await #expect(throws: MoveError.unverified) {
            try await backend.move(storageID: 1, file: file, to: "/Target")
        }
        #expect(!(await device.snapshot().closed))
        #expect(await device.snapshot().commands.filter { $0 == 0x1019 }.count == 1)
        let partial = try await backend.browseContents(storageID: 1, path: "/Target", showHiddenFiles: true)
        #expect(partial.files.isEmpty && partial.unavailableCount == 1)
        await device.configureUnavailable([])
        #expect(try await listing(backend, "/Target").map(\.name) == [file.name])
        try await backend.disconnect()
    }

    @Test func rejectedMoveKeepsSessionAndSource() async throws {
        let device = try device()
        let backend = try await connectedUploadBackend(device)
        let file = try #require(try await listing(backend, "/").first)
        _ = try await backend.createUploadDirectory(storageID: 1, parent: "/", name: "Target")
        await device.configureFault(reject: 0x1019)
        await #expect(throws: WireError.response(0x200F)) {
            try await backend.move(storageID: 1, file: file, to: "/Target")
        }
        #expect(!(await device.snapshot().closed))
        #expect(try await listing(backend, "/").contains(file))
        #expect(try await listing(backend, "/Target").isEmpty)
        try await backend.disconnect()
    }

    @Test @MainActor func staleListedHandleAllowsBrowsingButNotIncompleteWriteChecks() async throws {
        let device = try SyntheticUploadDevice(advertisedWrites: [0x100C, 0x100D, 0x1019],
            existingNames: ["missing.jpg", "visible.jpg"])
        let backend = SwiftMTPBackend { device }
        await device.configureUnavailable([10])
        let browser = DeviceBrowserModel(client: backend)
        await browser.connectAndLoad()
        #expect(browser.isConnected)
        #expect(browser.files.map(\.name) == ["visible.jpg"])
        #expect(browser.browsingIssue != nil)
        #expect(browser.operationError == nil)
        await #expect(throws: WireError.response(0x2009)) {
            try await backend.contents(storageID: 1, path: "/", showHiddenFiles: true)
        }
        await #expect(throws: (any Error).self) {
            try await backend.createUploadDirectory(storageID: 1, parent: "/", name: "Target")
        }
        #expect(await device.snapshot().writeOperationCommands.isEmpty)
        #expect(!(await device.snapshot().closed))
        await device.configureUnavailable([])
        await browser.load(path: "/")
        #expect(browser.browsingIssue == nil && browser.files.count == 2)
        // Other response errors still fail instead of silently hiding every item.
        await device.configureFault(reject: 0x1008)
        await browser.load(path: "/")
        #expect(browser.browsingIssue != nil && browser.operationError != nil)
        await browser.disconnectAndReset()
    }

    @Test func moveSupportDoesNotRequireUploadOrBinCreation() async throws {
        let device = try SyntheticUploadDevice(advertisedWrites: [0x1019])
        let backend = try await connectedUploadBackend(device)
        #expect(await backend.supportsMove(storageID: 1))
        #expect(!(await backend.supportsUpload(to: 1)))
        #expect(!(await backend.supportsBin(storageID: 1)))
        try await backend.disconnect()
    }

    @Test @MainActor func binRejectsFilesDraggedFromAnotherConnectedDevice() async throws {
        let deviceA = try device(), deviceB = try device()
        let first = DeviceBrowserModel(client: SwiftMTPBackend { deviceA })
        let second = DeviceBrowserModel(client: SwiftMTPBackend { deviceB })
        await first.connectAndLoad()
        await second.connectAndLoad()
        let fileA = try #require(first.files.first)
        let fileB = try #require(second.files.first)
        #expect(fileA.id == fileB.id)
        let drag = RemoteDragItem(browserID: first.browserDragID, handle: fileA.id)
        #expect(first.canAcceptBinDrop([drag]))
        #expect(!second.canAcceptBinDrop([drag]))
        let before = await deviceB.snapshot().commands
        second.acceptBinDrop([drag])
        #expect(await deviceB.snapshot().commands == before)
        await first.disconnectAndReset()
        #expect(second.isConnected)
        await second.disconnectAndReset()
    }

    @Test func binPersistsRestorePathAndRestoresUsingFreshSession() async throws {
        let device = try device()
        let backend = try await connectedUploadBackend(device)
        let file = try #require(try await listing(backend, "/").first)
        try await (try await preparedBin(backend)).trash(storageID: 1, file: file)
        #expect(try await listing(backend, "/").allSatisfy { $0.name != "photo.jpg" })
        let oldEntry = try #require(try await listing(backend, BinLayout.root).first { $0.isFolder })
        #expect(oldEntry.name.contains("photo.jpg"))
        let payload = oldEntry.path + "/Files"
        #expect(try await listing(backend, payload).map(\.name) == ["photo.jpg"])
        try await backend.disconnect()
        await device.prepareReconnect()
        let freshBackend = try await connectedUploadBackend(device)
        let entry = try #require(try await listing(freshBackend, BinLayout.root).first { $0.isFolder })
        #expect(entry.sessionID != oldEntry.sessionID)
        try await DeviceBin(backend: freshBackend).restore(storageID: 1, entry: entry)
        #expect(try await listing(freshBackend, "/").contains { $0.name == "photo.jpg" })
        #expect(try await listing(freshBackend, payload).isEmpty)
        #expect(await device.snapshot().commands.allSatisfy { $0 != 0x100B })
    }

    @Test func binRoundTripsFolderAndChildren() async throws {
        let device = try device()
        let backend = try await connectedUploadBackend(device)
        _ = try await backend.createUploadDirectory(storageID: 1, parent: "/", name: "Album")
        let file = try #require(try await listing(backend, "/").first { !$0.isFolder })
        _ = try await backend.move(storageID: 1, file: file, to: "/Album")
        let folder = try #require(try await listing(backend, "/").first { $0.name == "Album" })
        let bin = try await preparedBin(backend)
        try await bin.trash(storageID: 1, file: folder)
        let entry = try #require(try await listing(backend, BinLayout.root).first { $0.isFolder })
        #expect(try await listing(backend, entry.path + "/Files/Album").map(\.name) == ["photo.jpg"])
        try await bin.restore(storageID: 1, entry: entry)
        #expect(try await listing(backend, "/Album").map(\.name) == ["photo.jpg"])
    }

    @Test(arguments: [1, 2, 3]) func binInterruptedMovesNeverRetryAndRemainRecoverable(failAt: Int) async throws {
        let device = try device(failMoveAt: failAt)
        let backend = try await connectedUploadBackend(device)
        let file = try #require(try await listing(backend, "/").first)
        await #expect(throws: BinError.uncertain) {
            try await (try await preparedBin(backend)).trash(storageID: 1, file: file)
        }
        #expect(await device.snapshot().commands.filter { $0 == 0x1019 }.count == failAt)
        #expect(await device.snapshot().closed)
        await device.prepareReconnect()
        let fresh = try await connectedUploadBackend(device)
        if failAt < 3 {
            #expect(try await listing(fresh, "/").contains { $0.name == "photo.jpg" })
        } else {
            let entry = try #require(try await listing(fresh, BinLayout.root).first { $0.isFolder })
            try await DeviceBin(backend: fresh).restore(storageID: 1, entry: entry)
            #expect(try await listing(fresh, "/").contains { $0.name == "photo.jpg" })
        }
    }

    @Test func binReadbackFailureLeavesOriginalUntouched() async throws {
        let device = try device(corruptReadback: true)
        let backend = try await connectedUploadBackend(device)
        let file = try #require(try await listing(backend, "/").first)
        await #expect(throws: BinError.invalidEntry) {
            try await (try await preparedBin(backend)).trash(storageID: 1, file: file)
        }
        #expect(await device.snapshot().commands.allSatisfy { $0 != 0x1019 && $0 != 0x100B })
        #expect(try await listing(backend, "/").contains(file))
    }

    @Test func binRestoreNeverOverwritesCaseVariant() async throws {
        let device = try device()
        let backend = try await connectedUploadBackend(device)
        let file = try #require(try await listing(backend, "/").first)
        let bin = try await preparedBin(backend)
        try await bin.trash(storageID: 1, file: file)
        let entry = try #require(try await listing(backend, BinLayout.root).first { $0.isFolder })
        let local = try SwiftUploadTestDirectory()
        let conflicting = try local.file("PHOTO.JPG", data: Data([1, 2, 3]))
        _ = try await backend.upload(storageID: 1, source: conflicting, to: "/", progress: { _ in })
        await #expect(throws: BinError.conflict("/")) { try await bin.restore(storageID: 1, entry: entry) }
        #expect(try await listing(backend, entry.path + "/Files").map(\.name) == ["photo.jpg"])
        #expect(try await listing(backend, "/").first { $0.name == "PHOTO.JPG" }?.size == 3)
    }

    @Test func binRecreatesMissingOriginalParents() async throws {
        let device = try device()
        let backend = try await connectedUploadBackend(device)
        _ = try await backend.createUploadDirectory(storageID: 1, parent: "/", name: "Album")
        _ = try await backend.createUploadDirectory(storageID: 1, parent: "/", name: "Elsewhere")
        let file = try #require(try await listing(backend, "/").first { !$0.isFolder })
        let nested = try await backend.move(storageID: 1, file: file, to: "/Album")
        let bin = try await preparedBin(backend)
        try await bin.trash(storageID: 1, file: nested)
        let oldParent = try #require(try await listing(backend, "/").first { $0.name == "Album" })
        _ = try await backend.move(storageID: 1, file: oldParent, to: "/Elsewhere")
        let entry = try #require(try await listing(backend, BinLayout.root).first { $0.isFolder })
        try await bin.restore(storageID: 1, entry: entry)
        #expect(try await listing(backend, "/Album").map(\.name) == ["photo.jpg"])
    }

    @Test(arguments: ["../escape", BinLayout.root, "//DCIM"])
    func binRejectsTamperedRestorePath(path: String) async throws {
        let device = try device()
        let backend = try await connectedUploadBackend(device)
        let file = try #require(try await listing(backend, "/").first)
        let bin = try await preparedBin(backend)
        try await bin.trash(storageID: 1, file: file)
        try await device.rewriteRestoreRecord { data in
            var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            json["originalParent"] = path
            return try JSONSerialization.data(withJSONObject: json)
        }
        let before = await device.snapshot().commands.filter { $0 == 0x1019 }.count
        let entry = try #require(try await listing(backend, BinLayout.root).first { $0.isFolder })
        await #expect(throws: (any Error).self) { try await bin.restore(storageID: 1, entry: entry) }
        #expect(await device.snapshot().commands.filter { $0 == 0x1019 }.count == before)
    }

    @Test func binProtectsItsOwnAncestorsAndRejectsStaleSelections() async throws {
        let device = try device()
        let backend = try await connectedUploadBackend(device)
        let old = try #require(try await listing(backend, "/").first)
        let bin = try await preparedBin(backend)
        try await bin.trash(storageID: 1, file: old)
        let documents = try #require(try await listing(backend, "/").first { $0.path == BinLayout.root })
        await #expect(throws: BinError.invalidEntry) { try await bin.trash(storageID: 1, file: documents) }
        let before = await device.snapshot().commands.count
        await #expect(throws: BinError.changed) { try await bin.trash(storageID: 1, file: old) }
        let newCommands = await device.snapshot().commands.dropFirst(before)
        #expect(newCommands.allSatisfy { $0 != 0x1019 && $0 != 0x100C && $0 != 0x100D })
    }

    @MainActor @Test(arguments: [0, 1, 2])
    func unavailableBinCannotOpenAndUploadUsesCapabilities(mode: Int) async throws {
        let operations: Set<UInt16> = mode == 1 ? [] : [0x100C, 0x100D]
        let device = try SyntheticUploadDevice(writable: mode != 0, advertisedWrites: operations, existingNames: ["photo.jpg"])
        let model = DeviceBrowserModel(client: SwiftMTPBackend { device })
        await model.connectAndLoad()
        #expect(!model.canOpenBin)
        #expect(!model.canUpload)
        let before = await device.snapshot().commands.count
        model.openBin()
        try await Task.sleep(for: .milliseconds(10))
        #expect(model.currentPath == "/")
        #expect(model.operationError == nil)
        #expect(await device.snapshot().commands.count == before)
    }

    @MainActor @Test func connectionPreparesEmptyBinBeforeEnablingDrops() async throws {
        let device = try device()
        let model = DeviceBrowserModel(client: SwiftMTPBackend { device })
        await model.connectAndLoad()
        let file = try #require(model.files.first)
        model.replaceSelection([file.id])
        #expect(model.binExists == true)
        #expect(model.canOpenBin)
        #expect(model.binCount == 0)
        let drag = RemoteDragItem(browserID: model.browserDragID, handle: file.id)
        #expect(model.canDropIntoBin)
        #expect(model.canAcceptBinDrop([drag]))
        #expect(await device.snapshot().commands.allSatisfy { $0 != 0x1019 && $0 != 0x100B })
        await model.performBinAction(files: [file], action: .trash)
        #expect(model.binExists == true)
        #expect(model.canOpenBin)
        model.openBin()
        for _ in 0..<1000 {
            if model.isViewingBin && !model.isLoadingDirectory { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(model.isViewingBin)
        #expect(!model.canOpenBin)
        #expect(!model.canDropIntoBin)
        #expect(model.files.map(\.name) == [file.name])
        #expect(model.binCount == 1)
        model.navigateUp()
        for _ in 0..<1000 {
            if model.currentPath == "/" && !model.isLoadingDirectory { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(model.currentPath == "/")
        #expect(model.operationError == nil)
        #expect(model.canOpenBin)
    }

    @Test func binDisabledWithoutMoveSupport() async throws {
        let device = try SyntheticUploadDevice(advertisedWrites: [0x100C, 0x100D], existingNames: ["photo.jpg"])
        let backend = try await connectedUploadBackend(device)
        #expect(await backend.supportsBin(storageID: 1) == false)
        let file = try #require(try await listing(backend, "/").first)
        await #expect(throws: BinError.unsupported) { try await (try await preparedBin(backend)).trash(storageID: 1, file: file) }
        #expect(await device.snapshot().writeOperationCommands.isEmpty)
    }

    @MainActor @Test(arguments: [false, true], [false, true])
    func browserBinActionsRefreshAndRestore(partialReads: Bool, partialWrites: Bool) async throws {
        var operations: Set<UInt16> = [0x100C, 0x100D, 0x1019]
        if partialReads { operations.insert(0x101B) }
        if partialWrites { operations.formUnion(RangedUpload.requiredOperations) }
        let device = try SyntheticUploadDevice(advertisedWrites: operations, existingNames: ["photo.jpg"])
        let model = DeviceBrowserModel(client: SwiftMTPBackend(canCancelActiveTransfer: true) { device })
        await model.connectAndLoad()
        let file = try #require(model.files.first)
        model.replaceSelection([file.id])
        #expect(model.canTrash)
        await model.performBinAction(files: [file], restoring: false)
        #expect(model.operationError == nil)
        #expect(model.files.allSatisfy { $0.name != "photo.jpg" })
        #expect(!model.isTransferring)
        await model.load(path: BinLayout.overview)
        let entry = try #require(model.files.first)
        #expect(entry.name == file.name)
        #expect(entry.isFolder == file.isFolder)
        #expect(entry.size == file.size)
        #expect(model.originalLocation(for: entry) == file.path)
        model.replaceSelection([entry.id])
        #expect(model.canRestore)
        await model.performBinAction(files: [entry], restoring: true)
        #expect(model.operationError == nil)
        #expect(model.files.isEmpty)
        #expect(model.binListing?.retainedEntryCount == 1)
        await model.load(path: "/")
        #expect(model.files.contains { $0.name == "photo.jpg" })
        #expect(await device.snapshot().commands.contains(0x101B) == partialReads)
        #expect(await device.snapshot().commands.contains(0x95C2) == partialWrites)
    }

    @MainActor @Test func browserBinFailureStopsBatchAndRequiresReconnect() async throws {
        let device = try SyntheticUploadDevice(advertisedWrites: [0x100C, 0x100D, 0x1019],
            existingNames: ["first.jpg", "second.jpg"], failMoveAt: 3)
        let model = DeviceBrowserModel(client: SwiftMTPBackend { device })
        await model.connectAndLoad()
        await model.performBinAction(files: model.files, restoring: false)
        #expect(!model.isConnected)
        #expect(!model.isTransferring)
        #expect(model.files.isEmpty)
        #expect(model.operationError?.contains("0 of 2") == true)
        #expect(await device.snapshot().commands.filter { $0 == 0x1019 }.count == 3)
    }
    @Test func binPreservesNonemptyFileNamedLikeMetadata() async throws {
        let device = try device()
        let backend = try await connectedUploadBackend(device)
        let local = try SwiftUploadTestDirectory()
        let data = Data((0..<8192).map { UInt8($0 % 251) })
        let source = try local.file("Restore.json", data: data)
        _ = try await backend.upload(storageID: 1, source: source, to: "/", progress: { _ in })
        let file = try #require(try await listing(backend, "/").first { $0.name == "Restore.json" })
        let bin = try await preparedBin(backend)
        try await bin.trash(storageID: 1, file: file)
        let entry = try #require(try await listing(backend, BinLayout.root).first { $0.isFolder })
        try await bin.restore(storageID: 1, entry: entry)
        let restored = try #require(try await listing(backend, "/").first { $0.name == "Restore.json" })
        let output = try SwiftUploadTestDirectory()
        try await backend.download(storageID: 1, files: [restored], to: output.url, progress: { _ in })
        #expect(try Data(contentsOf: output.url.appendingPathComponent("Restore.json")) == data)
        await #expect(throws: BinError.emptyEntry) { try await bin.restore(storageID: 1, entry: entry) }
    }

    @Test func binRejectsStorageIdentityMismatchBeforeMoving() async throws {
        let device = try device()
        let backend = try await connectedUploadBackend(device)
        let file = try #require(try await listing(backend, "/").first)
        let bin = try await preparedBin(backend)
        try await bin.trash(storageID: 1, file: file)
        try await device.rewriteRestoreRecord { data in
            var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            var storage = try #require(json["storage"] as? [String: Any])
            storage["serialNumber"] = "different-device"
            json["storage"] = storage
            return try JSONSerialization.data(withJSONObject: json)
        }
        let entry = try #require(try await listing(backend, BinLayout.root).first { $0.isFolder })
        await #expect(throws: BinError.invalidEntry) { try await bin.restore(storageID: 1, entry: entry) }
        #expect(await device.snapshot().commands.filter { $0 == 0x1019 }.count == 3)
    }

    @Test func permanentDeleteRemovesOnlySelectedBinTree() async throws {
        let device = try SyntheticUploadDevice(advertisedWrites: [0x100B, 0x100C, 0x100D, 0x1019],
            existingNames: ["photo.jpg", "keep.jpg"])
        let backend = try await connectedUploadBackend(device)
        let bin = try await preparedBin(backend)
        let photo = try #require(try await listing(backend, "/").first { $0.name == "photo.jpg" })
        try await bin.trash(storageID: 1, file: photo)
        let entry = try #require(try await listing(backend, BinLayout.root).first { $0.isFolder })
        try await bin.permanentlyDelete(storageID: 1, file: entry)
        #expect(try await listing(backend, BinLayout.root).map(\.name) == [BinLayout.markerName])
        #expect(try await listing(backend, "/").contains { $0.name == "keep.jpg" })
        #expect(await device.snapshot().commands.filter { $0 == 0x100B }.count == 6)
        let documents = try #require(try await listing(backend, "/").first { $0.path == BinLayout.root })
        await #expect(throws: BinError.invalidEntry) { try await bin.permanentlyDelete(storageID: 1, file: documents) }
        let root = try #require(try await listing(backend, "/").first { $0.path == BinLayout.root })
        await #expect(throws: BinError.invalidEntry) { try await backend.deleteBinItem(storageID: 1, file: root, within: BinLayout.root) }
    }

    @Test func uncertainPermanentDeleteStopsWithoutReplayAndKeepsNotes() async throws {
        let device = try SyntheticUploadDevice(advertisedWrites: [0x100B, 0x100C, 0x100D, 0x1019],
            existingNames: ["photo.jpg"], failDeleteAt: 1)
        let backend = try await connectedUploadBackend(device)
        let bin = try await preparedBin(backend)
        let photo = try #require(try await listing(backend, "/").first { $0.name == "photo.jpg" })
        try await bin.trash(storageID: 1, file: photo)
        let entry = try #require(try await listing(backend, BinLayout.root).first { $0.isFolder })
        await #expect(throws: BinError.deletionUncertain) { try await bin.permanentlyDelete(storageID: 1, file: entry) }
        #expect(await device.snapshot().commands.filter { $0 == 0x100B }.count == 1)
        #expect(await device.snapshot().closed)
        await device.prepareReconnect()
        let fresh = try await connectedUploadBackend(device)
        #expect(try await listing(fresh, entry.path).contains { $0.name == "Restore.json" })
    }

    @Test(arguments: [UInt16(0x200F), 0x2019, 0x200E, 0x2012])
    func rejectedPermanentDeletePreservesItemAndSession(code: UInt16) async throws {
        let device = try SyntheticUploadDevice(advertisedWrites: [0x100B, 0x100C, 0x100D, 0x1019],
            existingNames: ["photo.jpg"])
        let backend = try await connectedUploadBackend(device)
        let bin = try await preparedBin(backend)
        let photo = try #require(try await listing(backend, "/").first { $0.name == "photo.jpg" })
        try await bin.trash(storageID: 1, file: photo)
        let item = try #require(try await bin.contents(storageID: 1).items.first)
        await device.configureFault(reject: 0x100B, rejectionCode: code)
        if code == 0x2012 {
            await #expect(throws: BinError.deletionUncertain) {
                try await bin.permanentlyDelete(storageID: 1, file: item.entry, expectedItem: item)
            }
            #expect(await device.snapshot().commands.filter { $0 == 0x100B }.count == 1)
            #expect(await device.snapshot().closed)
            return
        }
        await #expect(throws: WireError.response(code)) {
            try await bin.permanentlyDelete(storageID: 1, file: item.entry, expectedItem: item)
        }
        #expect(await device.snapshot().commands.filter { $0 == 0x100B }.count == 1)
        #expect(!(await device.snapshot().closed))
        #expect(try await bin.contents(storageID: 1).files.contains(item.file))
        #expect(await backend.supportsBinDeletion(storageID: 1) == (code != 0x200E))
        #expect(await backend.supportsUpload(to: 1) == (code != 0x200E))
        #expect(await backend.supportsMove(storageID: 1) == (code != 0x200E))
        try await backend.disconnect()
    }

    @MainActor @Test func binDropRejectsForeignAndStaleBrowserTokens() async throws {
        let device = try device()
        let model = DeviceBrowserModel(client: SwiftMTPBackend { device })
        await model.connectAndLoad()
        let file = try #require(model.files.first)
        let item = RemoteDragItem(browserID: model.browserDragID, handle: file.id)
        #expect(model.canAcceptBinDrop([item]))
        #expect(!model.canAcceptBinDrop([RemoteDragItem(browserID: UUID(), handle: file.id)]))
        #expect(!model.canAcceptBinDrop([RemoteDragItem(browserID: model.browserDragID, handle: 999)]))
        await model.load(path: "/")
        #expect(!model.canAcceptBinDrop([item]))
    }

    @Test(arguments: ["/Documents/BIN2", "/documents/bin", "/DCIM"])
    func permanentDeleteRejectsOtherFolders(parent: String) async throws {
        let device = try SyntheticUploadDevice(advertisedWrites: [0x100B, 0x100C, 0x100D, 0x1019], existingNames: ["keep.jpg"])
        let backend = try await connectedUploadBackend(device)
        let original = try #require(try await listing(backend, "/").first)
        let file = MTPFile(sessionID: original.sessionID, size: original.size, isFolder: false,
            dateAdded: original.dateAdded, name: original.name, path: parent + "/keep.jpg",
            parentPath: parent, fileExtension: "jpg", parentID: original.parentID, id: original.id)
        await #expect(throws: BinError.invalidEntry) { try await backend.deleteBinItem(storageID: 1, file: file, within: BinLayout.root) }
        #expect(await device.snapshot().commands.allSatisfy { $0 != 0x100B })
    }

    @MainActor @Test func binRowsRestoreAndDeleteCorrectDuplicateNamesAndEmptyRetainedNotes() async throws {
        let device = try SyntheticUploadDevice(advertisedWrites: [0x100B, 0x100C, 0x100D, 0x1019],
            existingNames: ["photo.jpg", "keep.jpg"])
        let backend = SwiftMTPBackend { device }
        let model = DeviceBrowserModel(client: backend)
        await model.connectAndLoad()
        let bin = try await preparedBin(backend)
        let original = try #require(model.files.first { $0.name == "photo.jpg" })
        _ = try await backend.createUploadDirectory(storageID: 1, parent: "/", name: "Album")
        let local = try SwiftUploadTestDirectory()
        let data = Data("second photo".utf8)
        let source = try local.file("photo.jpg", data: data)
        _ = try await backend.upload(storageID: 1, source: source, to: "/Album", progress: { _ in })
        let nested = try #require(try await listing(backend, "/Album").first)
        try await bin.trash(storageID: 1, file: original)
        try await bin.trash(storageID: 1, file: nested)
        await model.load(path: BinLayout.overview)
        #expect(model.files.map(\.name) == ["photo.jpg", "photo.jpg"])
        #expect(Set(model.files.map(\.id)).count == 2)
        #expect(Set(model.files.compactMap { model.originalLocation(for: $0) }) == ["/photo.jpg", "/Album/photo.jpg"])
        let first = try #require(model.files.first { model.originalLocation(for: $0) == "/photo.jpg" })
        let second = try #require(model.files.first { model.originalLocation(for: $0) == "/Album/photo.jpg" })
        let output = try SwiftUploadTestDirectory()
        let promised = output.url.appendingPathComponent(second.name)
        try await model.writeFilePromise(second, to: promised)
        #expect(try Data(contentsOf: promised) == data)
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.url.path) == ["photo.jpg"])
        await model.performBinAction(files: [first], action: .restore)
        #expect(model.transferConfirmation == nil)
        #expect(model.operationError == nil)
        #expect(model.files.count == 1)
        #expect(!model.canRestoreSelection([first]))
        #expect(try await listing(backend, "/").contains { $0.name == "photo.jpg" })
        await model.performBinAction(files: model.files, action: .delete)
        #expect(model.transferConfirmation == nil)
        #expect(model.operationError == nil)
        #expect(model.files.isEmpty)
        #expect(model.canEmptyBin)
        #expect(model.binListing?.retainedEntryCount == 1)
        let notes = try #require(model.binListing).entries
        await model.performBinAction(files: notes, action: .delete, emptying: true)
        #expect(model.transferConfirmation == nil)
        #expect(model.operationError == nil)
        #expect(!model.canEmptyBin)
        #expect(try await listing(backend, BinLayout.root).map(\.name) == [BinLayout.markerName])
        #expect(try await listing(backend, "/").contains { $0.name == "keep.jpg" })
    }

    @MainActor @Test(arguments: ["invalid-json", "unsafe-path", "extra-file"])
    func unrecognizedBinEntriesStayVisibleWithoutRestore(problem: String) async throws {
        let device = try SyntheticUploadDevice(advertisedWrites: [0x100B, 0x100C, 0x100D, 0x1019], existingNames: ["photo.jpg"])
        let backend = SwiftMTPBackend { device }
        let model = DeviceBrowserModel(client: backend)
        await model.connectAndLoad()
        await model.performBinAction(files: model.files, action: .trash)
        let entry = try #require(try await listing(backend, BinLayout.root).first { $0.isFolder })
        if problem == "extra-file" {
            let local = try SwiftUploadTestDirectory()
            let source = try local.file("keep-me.txt", data: Data("unexpected user data".utf8))
            _ = try await backend.upload(storageID: 1, source: source, to: entry.path, progress: { _ in })
        } else {
            try await device.rewriteRestoreRecord { data in
                if problem == "invalid-json" { return Data("broken".utf8) }
                var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
                json["originalParent"] = "../escape"
                return try JSONSerialization.data(withJSONObject: json)
            }
        }
        await model.load(path: BinLayout.overview)
        #expect(model.operationError == nil)
        #expect(model.files.map(\.path) == [entry.path])
        #expect(!model.canRestoreSelection(model.files))
        #expect(model.canDelete(model.files))
        #expect(model.binListing?.retainedEntryCount == 0)
    }

    @Test func binActionsRejectRestoreRecordChangedSinceListing() async throws {
        let device = try SyntheticUploadDevice(advertisedWrites: [0x100B, 0x100C, 0x100D, 0x1019], existingNames: ["photo.jpg"])
        let backend = try await connectedUploadBackend(device)
        let file = try #require(try await listing(backend, "/").first)
        let bin = try await preparedBin(backend)
        try await bin.trash(storageID: 1, file: file)
        let item = try #require(try await bin.contents(storageID: 1).items.first)
        try await device.rewriteRestoreRecord { data in
            var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            json["originalParent"] = "/Changed"
            return try JSONSerialization.data(withJSONObject: json)
        }
        let before = await device.snapshot().writeOperationCommands
        await #expect(throws: BinError.changed) { try await bin.restore(storageID: 1, entry: item.entry, expectedItem: item) }
        await #expect(throws: BinError.changed) { try await bin.permanentlyDelete(storageID: 1, file: item.entry, expectedItem: item) }
        #expect(await device.snapshot().writeOperationCommands == before)
    }

    @MainActor @Test func rejectedBinPreparationLeavesBrowsingAndReconnectAvailable() async throws {
        let device = try device()
        await device.configureFault(reject: 0x100C)
        let backend = SwiftMTPBackend { device }
        let model = DeviceBrowserModel(client: backend)
        await model.connectAndLoad()
        #expect(model.isConnected)
        #expect(model.files.map(\.name) == ["photo.jpg"])
        #expect(model.binExists == false && model.binCount == nil)
        #expect(!model.canOpenBin && !model.canDropIntoBin && !model.canUpload)
        #expect(!model.canDelete(model.files))
        #expect(model.storageWriteCapabilities[1]?.move == false)
        #expect(model.writeRestriction != nil)
        model.selectAll()
        #expect(model.canDownload)
        let writes = await device.snapshot().writeOperationCommands
        await device.configureFault()
        await model.load(path: "/")
        #expect(await device.snapshot().writeOperationCommands == writes)
        await model.disconnectAndReset()
        await device.prepareReconnect()
        await model.connectAndLoad()
        #expect(model.isConnected && model.canUpload && model.canOpenBin)
        #expect(model.binCount == 0 && model.writeRestriction == nil)
    }

    @MainActor private func waitForPath(_ path: String, in model: DeviceBrowserModel) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while model.currentPath != path || model.isLoadingDirectory {
            try #require(ContinuousClock.now < deadline, "Navigation did not reach the requested path")
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor @Test func binBreadcrumbsAndStorageClicksExitNestedDeletedFolders() async throws {
        let device = try device()
        let backend = SwiftMTPBackend { device }
        let model = DeviceBrowserModel(client: backend)
        await model.connectAndLoad()
        _ = try await backend.createUploadDirectory(storageID: 1, parent: "/", name: "Album")
        _ = try await backend.createUploadDirectory(storageID: 1, parent: "/Album", name: "Subfolder")
        _ = try await backend.createUploadDirectory(storageID: 1, parent: "/", name: "Normal")
        await model.load(path: "/")
        let album = try #require(model.files.first { $0.name == "Album" })
        await model.performBinAction(files: [album], action: .trash)
        // Avoid a completed-action alert obscuring the optional synthetic render.
        model.transferConfirmation = nil
        await model.load(path: BinLayout.overview)
        #expect(model.breadcrumbs == [.init(path: "/", name: "/"), .init(path: BinLayout.overview, name: "Bin")])
        model.selectStorage(1)
        try await waitForPath("/", in: model)
        #expect(!model.isBrowsingBin)
        await model.load(path: BinLayout.overview)
        let folder = try #require(model.files.first { $0.name == "Album" })
        model.open(folder)
        try await waitForPath(folder.path, in: model)
        let subfolder = try #require(model.files.first { $0.name == "Subfolder" })
        model.open(subfolder)
        try await waitForPath(subfolder.path, in: model)
        let crumbs = model.breadcrumbs
        #expect(crumbs.map(\.name) == ["/", "Bin", "Album", "Subfolder"])
        #expect(crumbs.map(\.path) == ["/", BinLayout.overview, folder.path, subfolder.path])
        // Breadcrumb destinations reuse normal navigation; the hidden recovery
        // directories never become displayed ancestors.
        await model.load(path: crumbs[2].path)
        #expect(model.currentPath == folder.path)
        await model.load(path: subfolder.path)
        await model.load(path: crumbs[1].path)
        #expect(model.isViewingBin)
        await renderBinBrowser(model)
        await model.load(path: crumbs[0].path)
        #expect(model.currentPath == "/" && !model.isBrowsingBin)
        await model.load(path: BinLayout.overview)
        model.open(try #require(model.files.first { $0.name == "Album" }))
        try await waitForPath(folder.path, in: model)
        model.open(try #require(model.files.first { $0.name == "Subfolder" }))
        try await waitForPath(subfolder.path, in: model)
        model.selectStorage(1)
        try await waitForPath("/", in: model)
        await model.load(path: "/Normal")
        model.selectStorage(1)
        await Task.yield()
        #expect(model.currentPath == "/Normal" && !model.isLoadingDirectory)
        await model.disconnectAndReset()
    }

    @MainActor private func renderBinBrowser(_ model: DeviceBrowserModel) async {
        guard let directory = ProcessInfo.processInfo.environment["PIKO_UI_RENDER_DIRECTORY"] else { return }
        let view = NSHostingView(rootView: DeviceContentView(model: model, deviceName: "Synthetic device", modelName: "Bin navigation"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        view.layoutSubtreeIfNeeded()
        do {
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("bin-navigation.png"))
        } catch { Issue.record(error) }
    }

    @MainActor @Test func binnedFolderOpensItsFilesAndUpReturnsToBin() async throws {
        let device = try device()
        let backend = SwiftMTPBackend { device }
        let model = DeviceBrowserModel(client: backend)
        await model.connectAndLoad()
        let photo = try #require(model.files.first)
        _ = try await backend.createUploadDirectory(storageID: 1, parent: "/", name: "Album")
        _ = try await backend.move(storageID: 1, file: photo, to: "/Album")
        await model.load(path: "/")
        let original = try #require(model.files.first { $0.name == "Album" })
        await model.performBinAction(files: [original], action: .trash)
        await model.load(path: BinLayout.overview)
        let folder = try #require(model.files.first)
        #expect(folder.name == "Album" && folder.isFolder)
        #expect(model.canRestoreSelection([folder]))
        model.open(folder)
        for _ in 0..<1000 {
            if model.currentPath == folder.path && !model.isLoadingDirectory { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(model.files.map(\.name) == ["photo.jpg"])
        #expect(model.breadcrumbs.map(\.name) == ["/", "Bin", "Album"])
        #expect(model.breadcrumbs.map(\.path) == ["/", BinLayout.overview, folder.path])
        #expect(model.canOpenBin)
        model.navigateUp()
        for _ in 0..<1000 {
            if model.isViewingBin && !model.isLoadingDirectory { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(model.isViewingBin)
        #expect(model.files.map(\.name) == ["Album"])
    }

}

/// Simulates storage refusing further writes immediately after the user item
/// moves, while allowing the backend to verify its destination and source.
private struct PostMoveWriteRejectionTransport: MTPBulkTransport {
    let device: SyntheticUploadDevice
    let movedHandle: UInt32

    func write(_ data: Data) async throws { try await write(data, boundary: .endsContainer) }
    func write(_ data: Data, boundary: BulkWriteBoundary) async throws {
        try await device.write(data, boundary: boundary)
        guard let header = try? ContainerHeader(data: Data(data.prefix(12))),
            header.type == .command, header.code == 0x1019 else { return }
        var parameters = DatasetReader(Data(data.dropFirst(12)))
        if try parameters.readUInt32() == movedHandle {
            await device.configureFault(reject: 0x100C, rejectionCode: 0x200C)
        }
    }
    func read(maxBytes: Int) async throws -> Data { try await device.read(maxBytes: maxBytes) }
    func close() async { await device.close() }
}
