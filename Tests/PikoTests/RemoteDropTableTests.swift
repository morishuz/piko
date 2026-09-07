import AppKit
import SwiftUI
import Testing
@testable import Piko

/// Exercises AppKit's actual pasteboard encoding and table drop delegate without
/// opening USB sessions or synthesizing mouse events on the user's desktop.
@MainActor
final class TableDragInfo: NSObject, NSDraggingInfo {
    let draggingPasteboard = NSPasteboard.withUniqueName()
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { [.copy, .move] }
    var draggingLocation: NSPoint = .zero
    var draggedImageLocation: NSPoint { .zero }
    nonisolated var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions = [], for view: NSView?,
        classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}

@MainActor
struct RemoteDropTableTests {
    @Test func nativePasteboardRoutesFolderAndBackgroundDropsWithoutFulfillingPromises() throws {
        _ = NSApplication.shared
        let folder = DemoBackend.entry(id: 1, name: "Folder", parent: "/", folder: true)
        let file = DemoBackend.entry(id: 2, name: "File.txt", parent: "/", folder: false)
        let browserID = UUID()
        var requested: [String] = [], accepted: [String] = []
        var fulfilledPromise = false, localUpload = false
        let view = RemoteFileTable(files: [folder, file], selection: .constant([file.id]), isEnabled: true,
            onOpen: { _ in }, onDownload: {}, browserDragID: browserID,
            remoteOperation: { tokens, path in
                guard tokens == [RemoteDragItem(browserID: browserID, handle: file.id)] else { return nil }
                requested.append(path); return path == folder.path ? .move : .copy
            }, onRemoteDrop: { _, path in accepted.append(path); return true },
            canUpload: true, onUploadDrop: { _ in localUpload = true; return true },
            writePromise: { _, _ in fulfilledPromise = true })
        let coordinator = view.makeCoordinator(), table = NSTableView()
        table.dataSource = coordinator
        table.reloadData()
        let info = TableDragInfo()
        defer { info.draggingPasteboard.releaseGlobally() }
        let writer = try #require(coordinator.tableView(table, pasteboardWriterForRow: 1))
        #expect(info.draggingPasteboard.writeObjects([writer]))
        #expect(coordinator.tableView(table, validateDrop: info, proposedRow: 0, proposedDropOperation: .above) == .move)
        #expect(coordinator.tableView(table, acceptDrop: info, row: 0, dropOperation: .on))
        #expect(coordinator.tableView(table, validateDrop: info, proposedRow: -1, proposedDropOperation: .on) == .copy)
        #expect(coordinator.tableView(table, acceptDrop: info, row: -1, dropOperation: .on))
        #expect(coordinator.tableView(table, validateDrop: info, proposedRow: 1, proposedDropOperation: .on) == .copy)
        #expect(requested == ["/Folder", "/", "/"])
        #expect(accepted == ["/Folder", "/"])
        #expect(!fulfilledPromise && !localUpload)
    }

    @Test(.timeLimit(.minutes(1))) func hoverThenDropUsesOpenedDirectoryAndOriginalPasteboard() async throws {
        _ = NSApplication.shared
        let folder = DemoBackend.entry(id: 1, name: "Folder", parent: "/", folder: true)
        let file = DemoBackend.entry(id: 2, name: "File.txt", parent: "/", folder: false)
        let originalID = UUID(), spring = SpringLoadedNavigation()
        let navigation = AsyncStream<Void>.makeStream()
        defer { navigation.continuation.finish() }
        var accepted: [String] = []
        var view = RemoteFileTable(files: [folder, file], selection: .constant([file.id]), isEnabled: true,
            onOpen: { _ in navigation.continuation.yield(()) }, onDownload: {}, browserDragID: originalID,
            remoteOperation: { tokens, _ in tokens == [RemoteDragItem(browserID: originalID, handle: file.id)] ? .move : nil },
            onRemoteDrop: { _, path in accepted.append(path); return true }, springNavigation: spring,
            canUpload: false, onUploadDrop: { _ in false }, writePromise: { _, _ in })
        let coordinator = view.makeCoordinator(), table = NSTableView(), scroll = RemoteTableScrollView(), info = TableDragInfo()
        table.dataSource = coordinator; table.reloadData()
        scroll.documentView = table
        scroll.connectDropTarget(coordinator)
        defer { info.draggingPasteboard.releaseGlobally(); spring.cancel() }
        let writer = try #require(coordinator.tableView(table, pasteboardWriterForRow: 1))
        info.draggingPasteboard.writeObjects([writer])
        #expect(coordinator.tableView(table, validateDrop: info, proposedRow: 0, proposedDropOperation: .on) == .move)
        // Await the callback itself: sanitizer load can delay main-actor tasks
        // beyond a short polling deadline. The test time limit bounds failures.
        var opened = navigation.stream.makeAsyncIterator()
        try #require(await opened.next() != nil)
        view.directory = folder.path
        view.browserDragID = UUID()
        // After navigation, the pointer can be over an ordinary file, between
        // rows, or below the table. All three target the newly opened directory.
        let child = DemoBackend.entry(id: 3, name: "Existing.txt", parent: folder.path, folder: false)
        for files in [[child], []] {
            view = RemoteFileTable(files: files, selection: .constant([]), isEnabled: true,
                onOpen: view.onOpen, onDownload: {}, browserDragID: UUID(), directory: folder.path,
                remoteOperation: view.remoteOperation, onRemoteDrop: view.onRemoteDrop,
                springNavigation: spring, canUpload: false, onUploadDrop: { _ in false }, writePromise: { _, _ in })
            coordinator.update(parent: view, tableView: table)
            #expect(coordinator.tableView(table, validateDrop: info, proposedRow: 0, proposedDropOperation: .above) == .move)
            #expect(scroll.draggingEntered(info) == .move)
            #expect(scroll.prepareForDragOperation(info))
            #expect(scroll.performDragOperation(info))
        }
        #expect(accepted == ["/Folder", "/Folder"])
    }

    @Test func malformedRemotePayloadNeverFallsBackToFinderUpload() {
        _ = NSApplication.shared
        var accepted = false
        let view = RemoteFileTable(files: [], selection: .constant([]), isEnabled: true,
            onOpen: { _ in }, onDownload: {}, canUpload: true,
            onUploadDrop: { _ in accepted = true; return true }, writePromise: { _, _ in })
        let coordinator = view.makeCoordinator(), table = NSTableView(), info = TableDragInfo()
        defer { info.draggingPasteboard.releaseGlobally() }
        let item = NSPasteboardItem()
        item.setData(Data("bad".utf8), forType: RemoteDragItem.pasteboardType)
        item.setString("file:///tmp/example.txt", forType: .fileURL)
        info.draggingPasteboard.writeObjects([item])
        #expect(coordinator.tableView(table, validateDrop: info, proposedRow: -1, proposedDropOperation: .on).isEmpty)
        #expect(!coordinator.tableView(table, acceptDrop: info, row: -1, dropOperation: .on))
        #expect(!accepted)
    }
}
