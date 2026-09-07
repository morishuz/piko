import AppKit
import Foundation
import MTPWire
import Testing

@testable import Piko

private final class TestDirectory {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "piko-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}

private actor EmptyStorageBackend: MTPBackend {
    nonisolated let capabilities = BackendCapabilities(
        reportsProgress: false, canCancelActiveTransfer: false)
    private(set) var disconnected = false

    func connect() async throws -> [MTPStorage] { [] }
    func contents(storageID: UInt32, path: String, showHiddenFiles: Bool) async throws -> [MTPFile] {
        throw BackendError.disconnected
    }
    func download(
        storageID: UInt32, files: [MTPFile], to destination: URL,
        progress: @escaping ProgressHandler
    ) async throws {
        throw BackendError.disconnected
    }
    func disconnect() async throws -> Bool {
        disconnected = true
        return true
    }
}

@MainActor @Test func browserRejectsBackendWithoutStorageAndReleasesIt() async {
    let backend = EmptyStorageBackend()
    let model = DeviceBrowserModel(client: backend)
    await model.connectAndLoad()
    #expect(model.state == .failed(BackendError.noStorage.localizedDescription))
    #expect(!model.isConnected)
    #expect(model.storages.isEmpty)
    #expect(model.selectedStorageID == nil)
    #expect(await backend.disconnected)
    #expect(DiagnosticFailure.classify(BackendError.noStorage) == .noStorage)
}

@Test func publishingRechecksLateConflictsAndKeepsStagingPrivate() throws {
    for policy in [ConflictPolicy.skip, .keepBoth, .replace] {
        let directory = try TestDirectory()
        let output = try DownloadDestination(directory.url)
        let file = DemoBackend.entry(id: 1, name: "sample.txt", parent: "/", folder: false)
        let item = DownloadPlanItem(file: file, components: [file.name])
        let target = try #require(try output.prepare(item, conflicts: policy))
        let staging = try output.makeStagingDirectory()
        let permissions =
            try FileManager.default.attributesOfItem(atPath: staging.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o700)
        let staged = staging.appendingPathComponent(file.name)
        let payload = Data(repeating: 42, count: 8192)
        try payload.write(to: staged)
        try Data("existing".utf8).write(to: target)
        let published = try output.publish(staged, item: item, target: target, conflicts: policy)
        if policy == .skip {
            #expect(published == nil)
        } else {
            #expect(try Data(contentsOf: #require(published)) == payload)
        }
        if policy != .replace { #expect(try Data(contentsOf: target) == Data("existing".utf8)) }
    }
}

@Test func publishingRejectsParentReplacedBySymlink() throws {
    let directory = try TestDirectory()
    let outside = try TestDirectory()
    let output = try DownloadDestination(directory.url)
    let file = DemoBackend.entry(id: 1, name: "sample.txt", parent: "/Album", folder: false)
    let item = DownloadPlanItem(file: file, components: ["Album", file.name])
    let target = try #require(try output.prepare(item, conflicts: .replace))
    let staging = try output.makeStagingDirectory()
    let staged = staging.appendingPathComponent(file.name)
    try Data(repeating: 42, count: 8192).write(to: staged)
    let parent = target.deletingLastPathComponent()
    try FileManager.default.removeItem(at: parent)
    try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: outside.url)
    #expect(throws: TransferError.invalidDestination) {
        try output.publish(staged, item: item, target: target, conflicts: .replace)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: outside.url.path).isEmpty)
}

@MainActor @Test func invalidDownloadRootMetadataIsRejectedWithoutWriting() async throws {
    let invalid = MTPFile(
        size: 0, isFolder: true, dateAdded: "", name: "Album", path: "/",
        parentPath: "/", fileExtension: "", parentID: 0, id: 1)
    await #expect(throws: BackendError.invalidPath("/")) {
        try await DownloadPlan.build(
            files: [invalid], backend: DemoBackend(), storageID: 1, cancelled: { false })
    }
}

@MainActor @Test func overlappingDownloadSelectionPreservesTreeRegardlessOfOrder() async throws {
    let backend = DemoBackend(fileCount: 2, delay: .zero)
    _ = try await backend.connect()
    let parent = try #require(try await backend.contents(storageID: 1, path: "/").first)
    let child = try #require(try await backend.contents(storageID: 1, path: "/Demo Files/Nested").first)
    for selection in [[child, parent], [parent, child], [parent, parent]] {
        let output = try TestDirectory()
        let coordinator = TransferCoordinator()
        try await coordinator.run(backend: backend, storageID: 1, files: selection, destination: output.url)
        #expect(
            FileManager.default.fileExists(
                atPath: output.url.appendingPathComponent("Demo Files/Nested/\(child.name)").path))
        #expect(!FileManager.default.fileExists(atPath: output.url.appendingPathComponent(child.name).path))
        #expect(
            coordinator.results.filter { if case .downloaded = $0.outcome { true } else { false } }.count == 2
        )
    }
}

@MainActor @Test func demoNavigationAndSelection() async throws {
    let model = DeviceBrowserModel(client: DemoBackend(fileCount: 5, delay: .zero))
    await model.connectAndLoad()
    #expect(model.isConnected)
    #expect(model.files.map(\.name) == ["Demo Files"])
    await model.load(path: "/Demo Files")
    #expect(model.files.count == 5)
    model.select(model.files[1], modifiers: [])
    model.select(model.files[3], modifiers: .shift)
    #expect(model.selectedFileIDs == Set(model.files[1...3].map(\.id)))
    model.select(model.files[2], modifiers: .command)
    #expect(model.selectedFileIDs.count == 2)
    model.selectAll()
    #expect(model.selectedFileIDs.count == 5)
    model.clearSelection()
    #expect(model.selectedFileIDs.isEmpty)
    // Simulate a native List keyboard/accessibility update. The subsequent
    // shift-click must range from that selection, not an obsolete pointer anchor.
    model.replaceSelection([model.files[4].id])
    model.select(model.files[2], modifiers: .shift)
    #expect(model.selectedFileIDs == Set(model.files[2...4].map(\.id)))
    model.replaceSelection([model.files[0].id])
    model.replaceSelection(Set(model.files[0...1].map(\.id)))
    model.replaceSelection(Set(model.files[0...2].map(\.id)))
    model.select(model.files[4], modifiers: .shift)
    #expect(model.selectedFileIDs == Set(model.files[0...4].map(\.id)))
    model.replaceSelection([999_999])
    #expect(model.selectedFileIDs.isEmpty)
    model.select(model.files[1], modifiers: .shift)
    #expect(model.selectedFileIDs == [model.files[1].id])
    await model.load(path: "/Demo Files/Nested")
    #expect(model.files.count == 1)
    #expect(model.canNavigateUp)
    await model.disconnectAndReset()
    #expect(!model.isConnected)
    #expect(model.files.isEmpty)
}

@MainActor @Test func recursiveDownloadsAreVerifiedAndConflictsKeepBoth() async throws {
    let directory = try TestDirectory()
    let backend = DemoBackend(fileCount: 3, delay: .zero)
    _ = try await backend.connect()
    let files = try await backend.contents(storageID: 1, path: "/")
    let coordinator = TransferCoordinator()
    try await coordinator.run(backend: backend, storageID: 1, files: files, destination: directory.url)
    #expect(coordinator.results.count == 5)  // two folders and three files
    #expect(
        coordinator.results.filter { if case .downloaded = $0.outcome { true } else { false } }.count == 3)
    let original = directory.url.appendingPathComponent("Demo Files/Sample-0002.txt")
    let bytes = try Data(contentsOf: original)
    #expect(bytes == Data(repeating: 76, count: 8192))
    try await coordinator.run(backend: backend, storageID: 1, files: files, destination: directory.url)
    #expect(try Data(contentsOf: original) == bytes)
    #expect(
        FileManager.default.fileExists(
            atPath: directory.url.appendingPathComponent("Demo Files/Sample-0002 (2).txt").path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.url.path) == ["Demo Files"])
}

@MainActor @Test func finderFilePromisesPublishCompleteFilesAndFoldersAtExactURLs() async throws {
    let model = DeviceBrowserModel(client: DemoBackend(fileCount: 3, delay: .zero))
    await model.connectAndLoad()
    let rootFolder = try #require(model.files.first)
    let folderOutput = try TestDirectory()
    let promisedFolder = folderOutput.url.appendingPathComponent("Dragged Demo Files")
    try await model.writeFilePromise(rootFolder, to: promisedFolder)
    #expect(
        FileManager.default.fileExists(
            atPath: promisedFolder.appendingPathComponent("Nested/Sample-0001.txt").path))
    #expect(model.transferConfirmation == nil)

    await model.load(path: "/Demo Files")
    let file = try #require(model.files.first(where: { !$0.isFolder }))
    let fileOutput = try TestDirectory()
    let promisedFile = fileOutput.url.appendingPathComponent(file.name)
    try await model.writeFilePromise(file, to: promisedFile)
    #expect(try Data(contentsOf: promisedFile) == Data(repeating: 76, count: 8192))
    #expect(!model.isTransferring)
}

@MainActor @Test func finderFilePromiseNeverReplacesAnExistingDestination() async throws {
    let model = DeviceBrowserModel(client: DemoBackend(fileCount: 2, delay: .zero))
    await model.connectAndLoad()
    await model.load(path: "/Demo Files")
    let file = try #require(model.files.first(where: { !$0.isFolder }))
    let output = try TestDirectory()
    let promised = output.url.appendingPathComponent(file.name)
    let original = Data("keep me".utf8)
    try original.write(to: promised)
    await #expect(throws: TransferError.filePromiseDestinationExists) {
        try await model.writeFilePromise(file, to: promised)
    }
    #expect(try Data(contentsOf: promised) == original)
    #expect(
        try FileManager.default.contentsOfDirectory(atPath: output.url.path)
            == [file.name])
}

@MainActor @Test func remoteTableVendsLazyNativeFilePromisesAndDownloadMenu() async throws {
    let model = DeviceBrowserModel(client: DemoBackend(fileCount: 2, delay: .zero))
    await model.connectAndLoad()
    await model.load(path: "/Demo Files")
    let file = try #require(model.files.first(where: { !$0.isFolder }))
    let tableModel = RemoteFileTable(
        files: [file], selection: .constant([file.id]), isEnabled: true,
        onOpen: { _ in }, onDownload: {}, canUpload: true,
        onUploadDrop: { _ in true }, writePromise: model.writeFilePromise)
    let coordinator = RemoteFileTable.Coordinator(parent: tableModel)
    let table = NSTableView()
    table.dataSource = coordinator
    table.delegate = coordinator
    coordinator.update(parent: tableModel, tableView: table)
    table.selectRowIndexes([0], byExtendingSelection: false)

    let menu = NSMenu()
    coordinator.menuNeedsUpdate(menu)
    #expect(menu.items.map(\.title) == ["Download…", "", "Delete (Move to Bin)…"])

    let provider = try #require(
        coordinator.tableView(table, pasteboardWriterForRow: 0) as? NSFilePromiseProvider)
    #expect(
        coordinator.filePromiseProvider(provider, fileNameForType: provider.fileType)
            == file.name)
    let remoteData = try #require(provider.pasteboardPropertyList(forType: RemoteDragItem.pasteboardType) as? Data)
    let remoteItem = try JSONDecoder().decode(RemoteDragItem.self, from: remoteData)
    #expect(remoteItem.handle == file.id)
    #expect(remoteItem.browserID == tableModel.browserDragID)
    #expect(provider.writingOptions(forType: RemoteDragItem.pasteboardType, pasteboard: .general).isEmpty)
    let output = try TestDirectory()
    let promised = output.url.appendingPathComponent(file.name)
    let failure: String? = await withCheckedContinuation { continuation in
        coordinator.filePromiseProvider(provider, writePromiseTo: promised) { error in
            continuation.resume(returning: error?.localizedDescription)
        }
    }
    #expect(failure == nil)
    #expect(FileManager.default.fileExists(atPath: promised.path))
}

@MainActor @Test(arguments: [true, false])
func finderPromiseCompletionDistinguishesCancellationFromFailure(cancelled: Bool) async throws {
    let file = DemoBackend.entry(id: 1, name: "remote.txt", parent: "/", folder: false)
    let tableModel = RemoteFileTable(
        files: [file], selection: .constant([file.id]), isEnabled: true,
        onOpen: { _ in }, onDownload: {}, canUpload: false,
        onUploadDrop: { _ in false }, writePromise: { _, _ in
            if cancelled { throw CancellationError() }
            throw CocoaError(.fileWriteNoPermission)
        })
    let coordinator = RemoteFileTable.Coordinator(parent: tableModel)
    let table = NSTableView()
    coordinator.update(parent: tableModel, tableView: table)
    let provider = try #require(
        coordinator.tableView(table, pasteboardWriterForRow: 0) as? NSFilePromiseProvider)
    let output = try TestDirectory()
    let failure: (String, Int)? = await withCheckedContinuation { continuation in
        coordinator.filePromiseProvider(provider, writePromiseTo: output.url.appendingPathComponent(file.name)) { @Sendable error in
            if let error = error as NSError? {
                continuation.resume(returning: (error.domain, error.code))
            } else {
                continuation.resume(returning: nil)
            }
        }
    }
    #expect(failure?.0 == NSCocoaErrorDomain)
    #expect(failure?.1 == (cancelled ? CocoaError.Code.userCancelled.rawValue : CocoaError.Code.fileWriteNoPermission.rawValue))
}

@MainActor @Test func remoteTableDefersUploadUntilAfterAppKitDropCallback() async throws {
    let file = DemoBackend.entry(id: 1, name: "remote.txt", parent: "/", folder: false)
    let source = URL(fileURLWithPath: "/tmp/local.txt")
    var received: [URL] = []
    let tableModel = RemoteFileTable(
        files: [file], selection: .constant([]), isEnabled: true,
        onOpen: { _ in }, onDownload: {}, canUpload: true,
        onUploadDrop: { urls in received = urls; return true },
        writePromise: { _, _ in })
    let coordinator = RemoteFileTable.Coordinator(parent: tableModel)

    coordinator.deferUploadDrop([source])
    #expect(received.isEmpty)
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }
    #expect(received == [source])
}

@MainActor @Test func binContextMenuRestoresItsSnapshotAndShowsOriginalLocation() throws {
    let files = [1, 2].map { DemoBackend.entry(id: UInt32($0), name: "photo.jpg", parent: "/Bin\($0)", folder: false) }
    var restored: [MTPFile] = []
    var deleted: [MTPFile] = []
    var tableModel = RemoteFileTable(files: files, selection: .constant(Set(files.map(\.id))),
        isEnabled: true, onOpen: { _ in }, onDownload: {},
        canDelete: { !$0.isEmpty }, onDelete: { deleted = $0 }, deleteIsPermanent: true,
        showsRestore: true, canRestore: { !$0.isEmpty }, onRestore: { restored = $0 },
        originalLocation: { "/DCIM/\($0.name)" }, canUpload: false,
        onUploadDrop: { _ in false }, writePromise: { _, _ in })
    let coordinator = RemoteFileTable.Coordinator(parent: tableModel)
    let table = NSTableView()
    table.allowsMultipleSelection = true
    table.dataSource = coordinator
    table.delegate = coordinator
    coordinator.update(parent: tableModel, tableView: table)
    table.selectRowIndexes(IndexSet(integersIn: 0..<2), byExtendingSelection: false)
    let menu = NSMenu()
    coordinator.menuNeedsUpdate(menu)
    #expect(menu.items.map(\.title) == ["Download 2 Items…", "Generate Thumbnail", "", "Restore to Original Location…", "Delete Permanently…"])
    #expect(menu.items.first { $0.title == "Generate Thumbnail" }?.isEnabled == false)
    let column = try #require(table.tableColumns.first { $0.title == "Original Location" })
    let cell = coordinator.tableView(table, viewFor: column, row: 0) as? NSTableCellView
    #expect(cell?.textField?.stringValue == "/DCIM/photo.jpg")
    table.selectRowIndexes([1], byExtendingSelection: false)
    for item in menu.items.suffix(2) {
        #expect(item.isEnabled)
        #expect(NSApplication.shared.sendAction(try #require(item.action), to: item.target, from: item))
    }
    #expect(restored == files)
    #expect(deleted == files)
    tableModel.canRestore = { _ in false }
    coordinator.update(parent: tableModel, tableView: table)
    coordinator.menuNeedsUpdate(menu)
    #expect(menu.items.first { $0.title == "Restore to Original Location…" }?.isEnabled == false)
    tableModel.originalLocation = nil
    coordinator.update(parent: tableModel, tableView: table)
    #expect(table.tableColumns.allSatisfy { $0.title != "Original Location" })
}

@MainActor @Test func storageChangeImmediatelyInvalidatesOldHandles() async throws {
    let model = DeviceBrowserModel(client: DemoBackend(delay: .zero))
    await model.connectAndLoad()
    model.selectAll()
    #expect(!model.selectedFiles.isEmpty)
    model.selectStorage(999)
    #expect(model.selectedStorageID == 1)  // unknown storage is rejected
    model.selectStorage(nil)
    #expect(model.files.isEmpty)
    #expect(model.selectedFileIDs.isEmpty)
    #expect(model.currentPath == "/")
    #expect(model.selectedStorageID == nil)
    await model.disconnectAndReset()
}

@MainActor @Test func partialFailurePreservesSuccessfulFilesAndReportsFailure() async throws {
    let directory = try TestDirectory()
    let backend = DemoBackend(fileCount: 4, failedIDs: [11], delay: .zero)
    let model = DeviceBrowserModel(client: backend)
    await model.connectAndLoad()
    await model.download(files: model.files, to: directory.url)
    #expect(!model.isTransferring)
    #expect(model.transferConfirmation?.contains("3 files downloaded") == true)
    #expect(model.transferConfirmation?.contains("1 failed") == true)
    #expect(
        !FileManager.default.fileExists(
            atPath: directory.url.appendingPathComponent("Demo Files/Sample-0002.txt").path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.url.path) == ["Demo Files"])
}

@MainActor @Test func skipAndReplaceConflicts() async throws {
    let directory = try TestDirectory()
    let backend = DemoBackend(fileCount: 2, delay: .zero)
    _ = try await backend.connect()
    let file = try #require(
        try await backend.contents(storageID: 1, path: "/Demo Files").first { !$0.isFolder })
    let target = directory.url.appendingPathComponent(file.name)
    try Data("old".utf8).write(to: target)
    let coordinator = TransferCoordinator()
    try await coordinator.run(
        backend: backend, storageID: 1, files: [file], destination: directory.url, conflicts: .skip)
    #expect(coordinator.results.first?.outcome == .skipped)
    #expect(try Data(contentsOf: target) == Data("old".utf8))
    try await coordinator.run(
        backend: backend, storageID: 1, files: [file], destination: directory.url, conflicts: .replace)
    #expect(coordinator.results.first?.outcome == .downloaded(target))
    #expect(try Data(contentsOf: target).count == 8192)
}

@MainActor @Test func refusesSymlinkDestinationAndPreservesExternalFile() async throws {
    let directory = try TestDirectory()
    let outside = try TestDirectory()
    let original = outside.url.appendingPathComponent("private.txt")
    try Data("private".utf8).write(to: original)
    let backend = DemoBackend(fileCount: 2, delay: .zero)
    _ = try await backend.connect()
    let file = try #require(
        try await backend.contents(storageID: 1, path: "/Demo Files").first { !$0.isFolder })
    try FileManager.default.createSymbolicLink(
        at: directory.url.appendingPathComponent(file.name), withDestinationURL: original)
    let coordinator = TransferCoordinator()
    try await coordinator.run(
        backend: backend, storageID: 1, files: [file], destination: directory.url, conflicts: .replace)
    #expect(coordinator.results.filter { if case .failed = $0.outcome { true } else { false } }.count == 1)
    #expect(try Data(contentsOf: original) == Data("private".utf8))
}

private actor BrokenBackend: MTPBackend {
    nonisolated let capabilities = BackendCapabilities(reportsProgress: false, canCancelActiveTransfer: false)
    let children: [MTPFile]
    init(children: [MTPFile] = []) { self.children = children }
    func connect() async throws -> [MTPStorage] { [DemoBackend.storage] }
    func disconnect() async throws -> Bool { true }
    func contents(storageID: UInt32, path: String, showHiddenFiles: Bool) async throws -> [MTPFile] {
        children
    }
    func download(
        storageID: UInt32, files: [MTPFile], to destination: URL, progress: @escaping ProgressHandler
    ) async throws {
        try Data([1]).write(to: destination.appendingPathComponent(files[0].name))
    }
}

@MainActor @Test func truncatedDownloadNeverGetsFinalName() async throws {
    let directory = try TestDirectory()
    let coordinator = TransferCoordinator()
    let file = DemoBackend.entry(id: 10, name: "test.txt", parent: "/", folder: false)
    try await coordinator.run(
        backend: BrokenBackend(), storageID: 1, files: [file], destination: directory.url)
    #expect(coordinator.results.filter { if case .failed = $0.outcome { true } else { false } }.count == 1)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.url.path).isEmpty)
}

@MainActor @Test func maliciousNamesAndFolderCyclesFailBeforeWriting() async throws {
    let directory = try TestDirectory()
    let coordinator = TransferCoordinator()
    for name in ["../escape", "..", ".", "", "bad/name", "bad\0name"] {
        let file = DemoBackend.entry(id: 1, name: name, parent: "/", folder: false)
        await #expect(throws: (any Error).self) {
            try await coordinator.run(
                backend: BrokenBackend(), storageID: 1, files: [file], destination: directory.url)
        }
    }
    let cycle = DemoBackend.entry(id: 1, name: "loop", parent: "/", folder: true)
    await #expect(throws: (any Error).self) {
        try await coordinator.run(
            backend: BrokenBackend(children: [cycle]), storageID: 1, files: [cycle],
            destination: directory.url)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.url.path).isEmpty)
    #expect(!coordinator.isRunning)
}

@MainActor @Test func downloadPlanAcceptsColonAndRejectsInconsistentChildEdges() async throws {
    let colon = DemoBackend.entry(id: 1, name: "capture:final.jpg", parent: "/", folder: false)
    let plan = try await DownloadPlan.build(
        files: [colon], backend: BrokenBackend(), storageID: 1, cancelled: { false })
    #expect(plan.map(\.components) == [["capture:final.jpg"]])

    let folder = DemoBackend.entry(id: 2, name: "Album", parent: "/", folder: true)
    let mismatches = [
        MTPFile(
            size: 1, isFolder: false, dateAdded: "", name: "photo.jpg",
            path: "/Elsewhere/photo.jpg", parentPath: "/Elsewhere", fileExtension: "jpg",
            parentID: folder.id, id: 3),
        MTPFile(
            size: 1, isFolder: false, dateAdded: "", name: "photo.jpg",
            path: "/Album/wrong.jpg", parentPath: "/Album", fileExtension: "jpg",
            parentID: folder.id, id: 4),
    ]
    for child in mismatches {
        await #expect(throws: BackendError.invalidPath(child.path)) {
            try await DownloadPlan.build(
                files: [folder], backend: BrokenBackend(children: [child]), storageID: 1,
                cancelled: { false })
        }
    }
}

@MainActor @Test func caseAndCanonicalDistinctRemoteNamesNeverOverwriteLocally() async throws {
    for names in [["photo.jpg", "PHOTO.jpg"], ["é.jpg", "e\u{301}.jpg"]] {
        let directory = try TestDirectory()
        let files = names.enumerated().map { index, name in
            MTPFile(
                size: 1, isFolder: false, dateAdded: "", name: name, path: "/\(name)",
                parentPath: "/", fileExtension: "jpg", parentID: 0, id: UInt32(index + 1))
        }
        let coordinator = TransferCoordinator()
        try await coordinator.run(
            backend: BrokenBackend(), storageID: 1, files: files, destination: directory.url)
        #expect(
            coordinator.results.filter {
                if case .downloaded = $0.outcome { true } else { false }
            }.count == 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.url.path).count == 2)
    }
}

@MainActor @Test func ambiguousLocalFolderNamesAreRejectedBeforeWriting() async throws {
    let collisions = [
        [("Album", true), ("ALBUM", true)],
        [("é", true), ("e\u{301}", true)],
        [("Folder", true), ("FOLDER", false)],
    ]
    for collision in collisions {
        let files = collision.enumerated().map { index, entry in
            DemoBackend.entry(
                id: UInt32(index + 1), name: entry.0, parent: "/", folder: entry.1)
        }
        await #expect(throws: TransferError.ambiguousLocalFolderNames) {
            try await DownloadPlan.build(
                files: files, backend: BrokenBackend(), storageID: 1, cancelled: { false })
        }
    }
}

private actor DelayedBackend: MTPBackend {
    nonisolated let capabilities = BackendCapabilities(reportsProgress: false, canCancelActiveTransfer: false)
    private var pending: [String: CheckedContinuation<[MTPFile], Never>] = [:]
    private var observers: [String: CheckedContinuation<Void, Never>] = [:]
    func connect() async throws -> [MTPStorage] { [DemoBackend.storage] }
    func disconnect() async throws -> Bool { true }
    func download(
        storageID: UInt32, files: [MTPFile], to destination: URL, progress: @escaping ProgressHandler
    ) async throws {}
    func contents(storageID: UInt32, path: String, showHiddenFiles: Bool) async throws -> [MTPFile] {
        if path == "/" { return [] }
        return await withCheckedContinuation {
            pending[path] = $0
            observers.removeValue(forKey: path)?.resume()
        }
    }
    func waitForRequest(_ path: String) async {
        if pending[path] != nil { return }
        await withCheckedContinuation { observers[path] = $0 }
    }
    func complete(_ path: String) { pending.removeValue(forKey: path)?.resume(returning: []) }
}

@MainActor @Test func staleDirectoryResponsesCannotOverwriteNewNavigation() async {
    let backend = DelayedBackend()
    let model = DeviceBrowserModel(client: backend)
    await model.connectAndLoad()
    let old = Task { await model.load(path: "/old") }
    await backend.waitForRequest("/old")
    let new = Task { await model.load(path: "/new") }
    await backend.waitForRequest("/new")
    await backend.complete("/new")
    await new.value
    await backend.complete("/old")
    await old.value
    #expect(model.currentPath == "/new")
    let pending = Task { await model.load(path: "/pending") }
    await backend.waitForRequest("/pending")
    await model.disconnectAndReset()
    await backend.complete("/pending")
    await pending.value
    #expect(model.state == .disconnected)
    #expect(model.currentPath == "/")
}

private actor ConcurrencyProbe {
    private var active = 0
    private(set) var peak = 0
    func exercise() async {
        active += 1
        peak = max(peak, active)
        await Task.yield()
        active -= 1
    }
}

private actor HoldingBackend: MTPBackend {
    nonisolated let capabilities = BackendCapabilities(reportsProgress: false, canCancelActiveTransfer: false)
    private var release: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    private let losesSessionOnCancellation: Bool
    init(losesSessionOnCancellation: Bool = false) {
        self.losesSessionOnCancellation = losesSessionOnCancellation
    }
    func connect() async throws -> [MTPStorage] { [DemoBackend.storage] }
    func disconnect() async throws -> Bool { true }
    func contents(storageID: UInt32, path: String, showHiddenFiles: Bool) async throws -> [MTPFile] { [] }
    func download(
        storageID: UInt32, files: [MTPFile], to destination: URL, progress: @escaping ProgressHandler
    ) async throws {
        await withCheckedContinuation {
            release = $0
            observer?.resume()
            observer = nil
        }
        if losesSessionOnCancellation, Task.isCancelled {
            throw BackendSessionError.reconnectRequired
        }
        try Data(repeating: 65, count: Int(files[0].size)).write(
            to: destination.appendingPathComponent(files[0].name))
    }
    func waitUntilDownloading() async {
        if release != nil { return }
        await withCheckedContinuation { observer = $0 }
    }
    func finishFile() {
        release?.resume()
        release = nil
    }
}

@MainActor @Test func stopAfterCurrentFileAndRejectOverlappingBatch() async throws {
    let directory = try TestDirectory()
    let backend = HoldingBackend()
    let coordinator = TransferCoordinator()
    let files = [
        DemoBackend.entry(id: 10, name: "first.txt", parent: "/", folder: false),
        DemoBackend.entry(id: 11, name: "second.txt", parent: "/", folder: false),
    ]
    let task = Task {
        try await coordinator.run(backend: backend, storageID: 1, files: files, destination: directory.url)
    }
    await backend.waitUntilDownloading()
    await #expect(throws: BackendError.busy) {
        try await coordinator.run(backend: backend, storageID: 1, files: files, destination: directory.url)
    }
    coordinator.stopAfterCurrentFile()
    await backend.finishFile()
    try await task.value
    #expect(
        coordinator.results.map(\.outcome) == [
            .downloaded(directory.url.appendingPathComponent("first.txt")), .notAttempted,
        ])
    #expect(!coordinator.isRunning)
    #expect(!FileManager.default.fileExists(atPath: directory.url.appendingPathComponent("second.txt").path))
}

@MainActor @Test func finderPromiseStopSurvivesPerFileBatchReset() async throws {
    let directory = try TestDirectory()
    let backend = HoldingBackend()
    let coordinator = TransferCoordinator()
    let drag = FilePromiseBatch()
    let first = DemoBackend.entry(id: 10, name: "first.txt", parent: "/", folder: false)
    let second = DemoBackend.entry(id: 11, name: "second.txt", parent: "/", folder: false)
    let writer: RemoteFileTable.PromiseWriter = { file, url in
        try await coordinator.run(
            backend: backend, storageID: 1, files: [file],
            destination: url.deletingLastPathComponent())
    }
    let stop: @MainActor @Sendable () -> Bool = { coordinator.stopRequested }
    let task = Task {
        try await drag.write(
            file: first, to: directory.url.appendingPathComponent(first.name),
            writer: writer, shouldStop: stop)
    }
    await backend.waitUntilDownloading()
    coordinator.stopAfterCurrentFile()
    await backend.finishFile()
    try await task.value
    #expect(FileManager.default.fileExists(atPath: directory.url.appendingPathComponent(first.name).path))
    await #expect(throws: CancellationError.self) {
        try await drag.write(
            file: second, to: directory.url.appendingPathComponent(second.name),
            writer: writer, shouldStop: stop)
    }
    #expect(!FileManager.default.fileExists(atPath: directory.url.appendingPathComponent(second.name).path))

    // A later drag must start normally despite the previous coordinator flag.
    let nextDrag = FilePromiseBatch()
    let next = Task {
        try await nextDrag.write(
            file: second, to: directory.url.appendingPathComponent(second.name),
            writer: writer, shouldStop: stop)
    }
    await backend.waitUntilDownloading()
    await backend.finishFile()
    try await next.value
    #expect(!coordinator.stopRequested)
    #expect(FileManager.default.fileExists(atPath: directory.url.appendingPathComponent(second.name).path))
}

@MainActor @Test func finderPromiseStopSurvivesFailedFolderPromise() async throws {
    let batch = FilePromiseBatch()
    let file = DemoBackend.entry(id: 1, name: "folder", parent: "/", folder: true)
    await #expect(throws: TransferError.invalidDownloadedFile) {
        try await batch.write(file: file, to: URL(fileURLWithPath: "/unused"), writer: { _, _ in
            throw TransferError.invalidDownloadedFile
        }, shouldStop: { true })
    }
    await #expect(throws: CancellationError.self) {
        try await batch.write(file: file, to: URL(fileURLWithPath: "/unused"), writer: { _, _ in
            Issue.record("Stopped drag must not start another writer")
        }, shouldStop: { false })
    }
}

@MainActor @Test func cancelledDownloadCleansStagingAndDoesNotPromote() async throws {
    let directory = try TestDirectory()
    let backend = HoldingBackend()
    let coordinator = TransferCoordinator()
    let file = DemoBackend.entry(id: 10, name: "cancelled.txt", parent: "/", folder: false)
    let task = Task {
        try await coordinator.run(backend: backend, storageID: 1, files: [file], destination: directory.url)
    }
    await backend.waitUntilDownloading()
    task.cancel()
    await backend.finishFile()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.url.path).isEmpty)
    #expect(coordinator.results.count == 1)
    #expect(coordinator.results.first?.outcome == .notAttempted)
    #expect(!coordinator.isRunning)
}

@MainActor @Test func parentCancellationDoesNotInterruptUnsafeBackendOrLoseSession() async throws {
    let directory = try TestDirectory()
    let backend = HoldingBackend(losesSessionOnCancellation: true)
    let model = DeviceBrowserModel(client: backend)
    await model.connectAndLoad()
    let file = DemoBackend.entry(id: 10, name: "lost.txt", parent: "/", folder: false)
    let task = Task { await model.download(files: [file], to: directory.url) }
    await backend.waitUntilDownloading()
    task.cancel()
    await backend.finishFile()
    await task.value
    #expect(model.state == .connected)
    #expect(model.isConnected)
    #expect(model.transfers.results.count == 1)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.url.path).isEmpty)
}

@Test func operationGateSerializesSuspendingOperations() async throws {
    let gate = OperationGate()
    let probe = ConcurrencyProbe()
    try await withThrowingTaskGroup(of: Void.self) { group in
        for _ in 0..<100 { group.addTask { try await gate.run { await probe.exercise() } } }
        try await group.waitForAll()
    }
    #expect(await probe.peak == 1)
    do { try await gate.run { throw SimulatedDeviceError.failure("test") } } catch {}
    try await gate.run { await probe.exercise() }
    #expect(await probe.peak == 1)
}
