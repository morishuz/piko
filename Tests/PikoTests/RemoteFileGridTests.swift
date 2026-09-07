import AppKit
import SwiftUI
import Testing
@testable import Piko

@MainActor struct RemoteFileGridTests {
    @Test func nativeGridRoutesDropsByPointerAndIgnoresStaleContextIndex() throws {
        let folder = DemoBackend.entry(id: 1, name: "Folder", parent: "/", folder: true)
        let file = DemoBackend.entry(id: 2, name: "File.txt", parent: "/", folder: false)
        var accepted: [String] = []
        var fulfilled = false
        let config = RemoteFileTable(mode: .grid, files: [folder, file], selection: .constant([file.id]),
            isEnabled: true, onOpen: { _ in }, onDownload: {},
            remoteOperation: { _, path in path == folder.path ? .move : .copy },
            onRemoteDrop: { _, path in accepted.append(path); return true },
            canUpload: false, onUploadDrop: { _ in false }, writePromise: { _, _ in fulfilled = true })
        let coordinator = config.makeCoordinator()
        let scroll = coordinator.makeGrid()
        let grid = try #require(scroll.documentView as? RemoteCollectionView)
        coordinator.updateGrid(parent: config, grid: grid)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 360),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        let info = TableDragInfo()
        defer { info.draggingPasteboard.releaseGlobally(); coordinator.stopObserving(); window.close() }
        scroll.layoutSubtreeIfNeeded()
        grid.layoutSubtreeIfNeeded()
        let writer = try #require(coordinator.collectionView(grid, pasteboardWriterForItemAt: IndexPath(item: 1, section: 0)))
        #expect(info.draggingPasteboard.writeObjects([writer]))
        for row in [0, 1, -1] {
            let point: NSPoint
            if row >= 0 {
                let frame = try #require(grid.layoutAttributesForItem(at: IndexPath(item: row, section: 0))?.frame)
                point = NSPoint(x: frame.midX, y: frame.midY)
            } else { point = NSPoint(x: 500, y: 300) }
            info.draggingLocation = grid.convert(point, to: nil)
            var proposed = NSIndexPath(forItem: 0, inSection: 0)
            var operation = NSCollectionView.DropOperation.on
            let result = coordinator.collectionView(grid, validateDrop: info, proposedIndexPath: &proposed, dropOperation: &operation)
            #expect(result == (row == 0 ? .move : .copy))
            #expect(operation == (row == 0 ? .on : .before))
            #expect(coordinator.collectionView(grid, acceptDrop: info, indexPath: proposed as IndexPath, dropOperation: operation))
        }
        #expect(accepted == ["/Folder", "/", "/"])
        #expect(!fulfilled)
        grid.contextIndex = IndexPath(item: 100, section: 0)
        coordinator.menuNeedsUpdate(try #require(grid.menu))
        #expect(grid.selectionIndexPaths == [IndexPath(item: 1, section: 0)])
    }

    @Test func visibleItemsSelectionMenuAndPromisesShareTheListController() async throws {
        let files = (0..<80).map { DemoBackend.entry(id: UInt32($0 + 1), name: "photo-\($0).jpg", parent: "/", folder: false) }
        var selection: Set<UInt32> = [1, 2]
        var visible: [MTPFile] = []
        var generated: [MTPFile] = []
        var writes = 0
        let config = RemoteFileTable(mode: .grid, thumbnailsAllowed: true,
            onVisibleFiles: { files, _ in visible = files },
            generationCandidates: { $0 }, onGenerateThumbnails: { generated = $0 },
            files: files, selection: Binding(get: { selection }, set: { selection = $0 }),
            isEnabled: true, onOpen: { _ in }, onDownload: {}, canUpload: false,
            onUploadDrop: { _ in false }, writePromise: { _, _ in writes += 1 })
        let coordinator = config.makeCoordinator()
        let scroll = coordinator.makeGrid()
        let grid = try #require(scroll.documentView as? RemoteCollectionView)
        coordinator.updateGrid(parent: config, grid: grid)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 360),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        defer { coordinator.stopObserving(); window.close() }
        scroll.layoutSubtreeIfNeeded()
        grid.layoutSubtreeIfNeeded()
        coordinator.reportVisible()
        try await thumbnailWait { !visible.isEmpty }
        #expect(visible.count < files.count)
        #expect(grid.selectionIndexPaths == [IndexPath(item: 0, section: 0), IndexPath(item: 1, section: 0)])
        grid.contextIndex = IndexPath(item: 0, section: 0)
        let menu = try #require(grid.menu)
        coordinator.menuNeedsUpdate(menu)
        let action = try #require(menu.items.firstIndex { $0.title == "Generate 2 Thumbnails" })
        menu.performActionForItem(at: action)
        #expect(generated == Array(files.prefix(2)))
        let provider = try #require(coordinator.collectionView(grid, pasteboardWriterForItemAt: IndexPath(item: 0, section: 0)) as? NSFilePromiseProvider)
        #expect(provider.writableTypes(for: .general).contains(RemoteDragItem.pasteboardType))
        #expect(writes == 0)
        grid.selectionIndexPaths = [IndexPath(item: 8, section: 0)]
        coordinator.gridSelectionChanged()
        #expect(selection == [9])
        let oldVisible = visible
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 700))
        scroll.reflectScrolledClipView(scroll.contentView)
        coordinator.reportVisible()
        try await thumbnailWait { visible != oldVisible }
        #expect(!visible.contains(files[0]))
    }

    @Test func gridRendersCachedImagesWithoutReloadingOrChangingSelection() async throws {
        let device = try SyntheticUploadDevice(advertisedWrites: [0x100A], existingNames: ["Mountain.jpg", "Portrait.heic", "notes.txt", "Clip.mp4"],
            thumbnailData: thumbnailPNG())
        let model = DeviceBrowserModel(client: SwiftMTPBackend { device })
        await model.connectAndLoad()
        model.fileViewMode = .grid
        let file = try #require(model.files.first { $0.name == "Mountain.jpg" })
        model.replaceSelection([file.id])
        let view = NSHostingView(rootView: DeviceContentView(model: model, deviceName: "G77", modelName: "Synthetic device"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        view.layoutSubtreeIfNeeded()
        let key = try #require(model.thumbnailKey(for: file))
        try await thumbnailWait { model.thumbnails.entry(for: key)?.image != nil }
        let video = try #require(model.files.first { $0.isVideoThumbnailCandidate })
        let videoKey = try #require(model.thumbnailKey(for: video))
        try await thumbnailWait { model.thumbnails.entry(for: videoKey)?.image != nil }
        #expect(model.selectedFileIDs == [file.id])
        for mode in FileViewMode.allCases {
            model.fileViewMode = mode
            try await Task.sleep(for: .milliseconds(30))
            view.layoutSubtreeIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            // Optional developer-only render output; no device or user images.
            if let directory = ProcessInfo.processInfo.environment["PIKO_UI_RENDER_DIRECTORY"] {
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("thumbnail-\(mode.rawValue).png"))
            }
            #expect(model.selectedFileIDs == [file.id])
        }
        await model.disconnectAndReset()
    }
}
