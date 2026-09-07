import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// An AppKit table gives the browser native multi-selection, contextual menus,
/// and Finder file promises while the rest of the window remains SwiftUI.
struct RemoteFileTable: NSViewRepresentable {
    typealias PromiseWriter = @MainActor @Sendable (MTPFile, URL) async throws -> Void

    var mode: FileViewMode = .list
    var thumbnailsAllowed = false
    var thumbnailStore: PhotoThumbnailStore?
    var thumbnailKey: (MTPFile) -> PhotoThumbnailKey? = { _ in nil }
    var onVisibleFiles: ([MTPFile], UUID) -> Void = { _, _ in }
    var generationCandidates: ([MTPFile]) -> [MTPFile] = { _ in [] }
    var onGenerateThumbnails: ([MTPFile]) -> Void = { _ in }
    let files: [MTPFile]
    @Binding var selection: Set<UInt32>
    let isEnabled: Bool
    let onOpen: (MTPFile) -> Void
    let onDownload: () -> Void
    var browserDragID = UUID()
    var directory = "/"
    var onRemoteDrag: ([MTPFile], UUID) -> Void = { _, _ in }
    var onRemoteDragEnd: () -> Void = {}
    var remoteOperation: ([RemoteDragItem], String) -> RemoteDropOperation? = { _, _ in nil }
    var onRemoteDrop: ([RemoteDragItem], String) -> Bool = { _, _ in false }
    var springNavigation: SpringLoadedNavigation?
    var canDelete: ([MTPFile]) -> Bool = { _ in false }
    var onDelete: ([MTPFile]) -> Void = { _ in }
    var deleteIsPermanent = false
    var showsRestore = false
    var canRestore: ([MTPFile]) -> Bool = { _ in false }
    var onRestore: ([MTPFile]) -> Void = { _ in }
    var originalLocation: ((MTPFile) -> String?)?
    let canUpload: Bool
    let onUploadDrop: ([URL]) -> Bool
    let writePromise: PromiseWriter
    var shouldStopPromises: @MainActor @Sendable () -> Bool = { false }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        if mode == .grid { return context.coordinator.makeGrid() }
        let table = RemoteDropTableView()
        table.dragDidExit = { [weak coordinator = context.coordinator] in coordinator?.endHover() }
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.autoresizingMask = [.width]
        table.rowHeight = 30
        table.usesAlternatingRowBackgroundColors = false
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.openDoubleClickedRow)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        table.registerForDraggedTypes([.fileURL, RemoteDragItem.pasteboardType])

        let name = NSTableColumn(identifier: .remoteNameColumn)
        name.title = "Name"
        name.minWidth = 220
        name.width = 480
        name.resizingMask = [.autoresizingMask, .userResizingMask]
        table.addTableColumn(name)

        let date = NSTableColumn(identifier: .remoteDateColumn)
        date.title = "Date"
        date.minWidth = 130
        date.width = 170
        date.resizingMask = .userResizingMask
        table.addTableColumn(date)

        let size = NSTableColumn(identifier: .remoteSizeColumn)
        size.title = "Size"
        size.minWidth = 80
        size.width = 100
        size.resizingMask = .userResizingMask
        table.addTableColumn(size)

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = context.coordinator
        table.menu = menu
        context.coordinator.tableView = table

        let scroll = RemoteTableScrollView()
        scroll.connectDropTarget(context.coordinator)
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.documentView = table
        context.coordinator.observe(scroll)
        return scroll
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        if let grid = scrollView.documentView as? NSCollectionView {
            context.coordinator.updateGrid(parent: self, grid: grid)
            return
        }
        guard let table = scrollView.documentView as? NSTableView else { return }
        context.coordinator.update(parent: self, tableView: table)
        (scrollView as? RemoteTableScrollView)?.fitColumns()
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.stopObserving()
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate,
        NSMenuDelegate, NSFilePromiseProviderDelegate
    {
        var parent: RemoteFileTable
        weak var tableView: NSTableView?
        weak var collectionView: RemoteCollectionView?
        weak var scrollView: NSScrollView?
        let visibilityID = UUID()
        var observers: Set<AnyCancellable> = []
        var lastVisible: [MTPFile] = []
        var lastEnabled: Bool?
        var reportPending = false
        var isObserving = false
        private let dates = DeviceDateFormatter()
        var displayedFiles: [MTPFile] = []
        var synchronizingSelection = false
        private var contextFile: MTPFile?
        private var contextSelection: [MTPFile] = []
        private let promiseQueue: OperationQueue = {
            let queue = OperationQueue()
            queue.name = "Piko Finder file promises"
            queue.maxConcurrentOperationCount = 1
            queue.qualityOfService = .userInitiated
            return queue
        }()
        private let promiseGate = OperationGate()
        private var promiseBatch = FilePromiseBatch()
        private var hoverKey: String?

        init(parent: RemoteFileTable) {
            self.parent = parent
            super.init()
        }

        func update(parent: RemoteFileTable, tableView: NSTableView) {
            self.parent = parent
            self.tableView = tableView
            tableView.isEnabled = parent.isEnabled
            let locationColumn = tableView.tableColumn(withIdentifier: .remoteLocationColumn)
            if parent.originalLocation != nil, locationColumn == nil {
                let column = NSTableColumn(identifier: .remoteLocationColumn)
                column.title = "Original Location"
                column.minWidth = 180
                column.width = 260
                column.resizingMask = .userResizingMask
                tableView.addTableColumn(column)
            } else if parent.originalLocation == nil, let locationColumn {
                tableView.removeTableColumn(locationColumn)
            }
            if displayedFiles != parent.files {
                displayedFiles = parent.files
                synchronizingSelection = true
                tableView.reloadData()
                synchronizingSelection = false
            }
            synchronizeSelection(in: tableView)
            reportVisible()
        }

        func numberOfRows(in tableView: NSTableView) -> Int { parent.files.count }

        func tableView(
            _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
        ) -> NSView? {
            guard parent.files.indices.contains(row), let tableColumn else { return nil }
            let file = parent.files[row]
            switch tableColumn.identifier {
            case .remoteNameColumn:
                return nameCell(for: file, in: tableView)
            case .remoteDateColumn:
                return textCell(
                    identifier: .remoteDateCell,
                    text: dates.string(from: file.dateAdded),
                    alignment: .left,
                    in: tableView)
            case .remoteSizeColumn:
                return textCell(
                    identifier: .remoteSizeCell,
                    text: file.isFolder
                        ? "—"
                        : ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file),
                    alignment: .right,
                    in: tableView)
            case .remoteLocationColumn:
                return textCell(identifier: .remoteLocationCell,
                    text: parent.originalLocation?(file) ?? "Unknown — restore unavailable",
                    alignment: .left, in: tableView)
            default:
                return nil
            }
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !synchronizingSelection, let tableView else { return }
            parent.selection = Set(
                tableView.selectedRowIndexes.compactMap { row in
                    parent.files.indices.contains(row) ? parent.files[row].id : nil
                })
        }

        func tableView(
            _ tableView: NSTableView, validateDrop info: NSDraggingInfo,
            proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation
        ) -> NSDragOperation {
            validateDrop(info, row: row) { row in tableView.setDropRow(row, dropOperation: .on) }
        }

        func validateDrop(_ info: NSDraggingInfo, row: Int, highlight: (Int) -> Void) -> NSDragOperation {
            if info.draggingPasteboard.types?.contains(RemoteDragItem.pasteboardType) == true {
                let items = remoteItems(info)
                guard parent.isEnabled, let path = remoteDestination(row: row),
                      let operation = parent.remoteOperation(items, path) else {
                    endHover(); return []
                }
                let folderRow = parent.files.indices.contains(row) && parent.files[row].isFolder
                highlight(folderRow ? row : -1)
                if folderRow {
                    let file = parent.files[row]
                    let key = "table:\(parent.browserDragID):\(file.path)"
                    hoverKey = key
                    parent.springNavigation?.schedule(key: key) { [weak self] in
                        guard let self, self.parent.remoteOperation(items, file.path) != nil else { return }
                        self.parent.onOpen(file)
                    }
                } else { endHover() }
                return operation == .copy ? .copy : .move
            }
            endHover()
            guard parent.isEnabled, parent.canUpload, !fileURLs(from: info).isEmpty else {
                return []
            }
            highlight(-1)
            return .copy
        }

        func tableView(
            _ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
            row: Int, dropOperation: NSTableView.DropOperation
        ) -> Bool { acceptDrop(info, row: row) }

        func acceptDrop(_ info: NSDraggingInfo, row: Int) -> Bool {
            endHover()
            if info.draggingPasteboard.types?.contains(RemoteDragItem.pasteboardType) == true {
                guard parent.isEnabled, let path = remoteDestination(row: row) else { return false }
                return parent.onRemoteDrop(remoteItems(info), path)
            }
            let urls = fileURLs(from: info)
            guard parent.isEnabled, parent.canUpload, !urls.isEmpty else { return false }
            deferUploadDrop(urls)
            return true
        }

        private func remoteItems(_ info: NSDraggingInfo) -> [RemoteDragItem] {
            let items = info.draggingPasteboard.pasteboardItems ?? []
            let decoded = items.compactMap { item -> RemoteDragItem? in
                guard let data = item.data(forType: RemoteDragItem.pasteboardType), data.count < 1024 else { return nil }
                return try? JSONDecoder().decode(RemoteDragItem.self, from: data)
            }
            return decoded.count == items.count ? decoded : []
        }

        private func remoteDestination(row: Int) -> String? {
            if parent.files.indices.contains(row) {
                return parent.files[row].isFolder ? parent.files[row].path : parent.directory
            }
            return row == -1 || row == parent.files.count ? parent.directory : nil
        }

        func endHover() {
            if let hoverKey { parent.springNavigation?.cancel(key: hoverKey) }
            hoverKey = nil
        }

        /// Finish AppKit's drag IPC before changing SwiftUI model state. Calling
        /// into the model synchronously from acceptDrop can re-enter the system
        /// drag session while it is processing LeaveApplication/Completed.
        func deferUploadDrop(_ urls: [URL]) {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                _ = self.parent.onUploadDrop(urls)
            }
        }

        private func fileURLs(from info: NSDraggingInfo) -> [URL] {
            let objects = info.draggingPasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]) ?? []
            return objects.compactMap { object in
                guard let value = object as? NSURL else { return nil }
                return value as URL
            }
        }

        @objc func openDoubleClickedRow() {
            guard let tableView else { return }
            let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
            guard parent.files.indices.contains(row) else { return }
            let file = parent.files[row]
            if file.isFolder { parent.onOpen(file) }
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard parent.isEnabled else { return }
            let rows: [Int]
            if let grid = collectionView {
                if let clicked = grid.contextIndex, parent.files.indices.contains(clicked.item),
                    !grid.selectionIndexPaths.contains(clicked) {
                    grid.selectionIndexPaths = [clicked]
                    parent.selection = [parent.files[clicked.item].id]
                }
                rows = grid.selectionIndexPaths.map(\.item).sorted()
            } else if let tableView {
                let clicked = tableView.clickedRow
                if parent.files.indices.contains(clicked), !tableView.selectedRowIndexes.contains(clicked) {
                    tableView.selectRowIndexes(IndexSet(integer: clicked), byExtendingSelection: false)
                }
                rows = Array(tableView.selectedRowIndexes)
            } else { return }
            let selected = rows.compactMap { parent.files.indices.contains($0) ? parent.files[$0] : nil }
            guard !selected.isEmpty else { return }
            contextSelection = selected
            contextFile = selected.count == 1 ? selected[0] : nil

            if let contextFile, contextFile.isFolder {
                let open = NSMenuItem(
                    title: "Open \(contextFile.name)",
                    action: #selector(openContextFolder), keyEquivalent: "")
                open.target = self
                open.isEnabled = true
                menu.addItem(open)
                menu.addItem(.separator())
            }
            let title = selected.count == 1 ? "Download…" : "Download \(selected.count) Items…"
            let download = NSMenuItem(
                title: title, action: #selector(downloadContextSelection), keyEquivalent: "")
            download.target = self
            download.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
            download.isEnabled = true
            menu.addItem(download)
            let candidates = parent.generationCandidates(selected)
            if selected.contains(where: \.isPhotoThumbnailCandidate) {
                let generate = NSMenuItem(title: candidates.count > 1 ? "Generate \(candidates.count) Thumbnails" : "Generate Thumbnail",
                    action: #selector(generateContextThumbnails), keyEquivalent: "")
                generate.target = self
                generate.image = NSImage(systemSymbolName: "photo.badge.plus", accessibilityDescription: nil)
                generate.isEnabled = !candidates.isEmpty
                generate.toolTip = "Read the selected originals to make previews. Photos up to 256 MiB are supported."
                menu.addItem(generate)
                if !candidates.isEmpty {
                    let bytes = candidates.reduce(Int64(0)) { sum, file in
                        let result = sum.addingReportingOverflow(file.size)
                        return result.overflow ? Int64.max : result.partialValue
                    }
                    let cost = NSMenuItem(title: "Reads up to " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file), action: nil, keyEquivalent: "")
                    cost.isEnabled = false
                    cost.indentationLevel = 1
                    menu.addItem(cost)
                }
            }
            if parent.thumbnailStore?.automaticPaused == true {
                let resume = NSMenuItem(title: "Resume Automatic Thumbnails", action: #selector(resumeThumbnails), keyEquivalent: "")
                resume.target = self
                menu.addItem(resume)
            }
            menu.addItem(.separator())
            if parent.showsRestore {
                let restore = NSMenuItem(title: "Restore to Original Location…",
                    action: #selector(restoreContextSelection), keyEquivalent: "")
                restore.target = self
                restore.image = NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: nil)
                restore.isEnabled = parent.canRestore(selected)
                menu.addItem(restore)
            }
            let delete = NSMenuItem(title: parent.deleteIsPermanent ? "Delete Permanently…" : "Delete (Move to Bin)…",
                action: #selector(deleteContextSelection), keyEquivalent: "")
            delete.target = self
            delete.isEnabled = parent.canDelete(selected)
            menu.addItem(delete)
        }

        @objc private func generateContextThumbnails() { parent.onGenerateThumbnails(contextSelection) }
        @objc private func resumeThumbnails() { parent.thumbnailStore?.resumeAutomatic() }
        @objc private func deleteContextSelection() { parent.onDelete(contextSelection) }
        @objc private func restoreContextSelection() { parent.onRestore(contextSelection) }

        @objc private func openContextFolder() {
            guard let contextFile, contextFile.isFolder else { return }
            parent.onOpen(contextFile)
        }

        @objc private func downloadContextSelection() { parent.onDownload() }

        func tableView(
            _ tableView: NSTableView, pasteboardWriterForRow row: Int
        ) -> (any NSPasteboardWriting)? { pasteboardWriter(row: row) }

        func pasteboardWriter(row: Int) -> (any NSPasteboardWriting)? {
            guard parent.isEnabled, parent.files.indices.contains(row) else { return nil }
            let file = parent.files[row]
            let type = file.isFolder
                ? UTType.directory.identifier
                : UTType(filenameExtension: file.fileExtension)?.identifier ?? UTType.data.identifier
            let provider = RemoteFilePromiseProvider(fileType: type, delegate: self)
            provider.remoteItem = try? JSONEncoder().encode(RemoteDragItem(browserID: parent.browserDragID, handle: file.id))
            provider.userInfo = FilePromisePayload(
                file: file, gate: promiseGate, writer: parent.writePromise,
                batch: promiseBatch, shouldStop: parent.shouldStopPromises,
                delegateRetainer: self)
            return provider
        }

        func tableView(
            _ tableView: NSTableView, draggingSession session: NSDraggingSession,
            willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet
        ) {
            // All providers for this drag already retain the same batch. Future
            // drags get a fresh token, even if Finder fulfills this one later.
            beginDrag(rows: Array(rowIndexes))
        }

        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                       endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            endHover()
            parent.onRemoteDragEnd()
        }

        func beginDrag(rows: [Int]) {
            promiseBatch = FilePromiseBatch()
            parent.onRemoteDrag(rows.compactMap { parent.files.indices.contains($0) ? parent.files[$0] : nil }, parent.browserDragID)
        }

        func filePromiseProvider(
            _ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String
        ) -> String {
            (filePromiseProvider.userInfo as? FilePromisePayload)?.file.name ?? "Piko Download"
        }

        nonisolated func filePromiseProvider(
            _ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
            completionHandler: @escaping (Error?) -> Void
        ) {
            guard let payload = filePromiseProvider.userInfo as? FilePromisePayload else {
                completionHandler(TransferError.invalidDownloadedFile)
                return
            }
            let completion = FilePromiseCompletion(completionHandler)
            Task {
                do {
                    try await payload.gate.run {
                        try await payload.batch.write(
                            file: payload.file, to: url, writer: payload.writer,
                            shouldStop: payload.shouldStop)
                    }
                    completion.call(nil)
                } catch {
                    completion.call(error)
                }
            }
        }

        func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
            promiseQueue
        }

        private func synchronizeSelection(in tableView: NSTableView) {
            let rows = IndexSet(parent.files.indices.filter { parent.selection.contains(parent.files[$0].id) })
            guard rows != tableView.selectedRowIndexes else { return }
            synchronizingSelection = true
            tableView.selectRowIndexes(rows, byExtendingSelection: false)
            synchronizingSelection = false
        }

        private func nameCell(for file: MTPFile, in tableView: NSTableView) -> NSTableCellView {
            let identifier = NSUserInterfaceItemIdentifier.remoteNameCell
            let cell: NSTableCellView
            if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
                cell = reused
            } else {
                cell = NSTableCellView()
                cell.identifier = identifier
                let icon = ThumbnailImageView()
                icon.translatesAutoresizingMaskIntoConstraints = false
                icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
                let label = NSTextField(labelWithString: "")
                label.translatesAutoresizingMaskIntoConstraints = false
                label.lineBreakMode = .byTruncatingTail
                cell.imageView = icon
                cell.textField = label
                cell.addSubview(icon)
                cell.addSubview(label)
                NSLayoutConstraint.activate([
                    icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                    icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    icon.widthAnchor.constraint(equalToConstant: 22),
                    icon.heightAnchor.constraint(equalToConstant: 22),
                    label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
                    label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                    label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
            }
            configureImage(cell.imageView, file: file)
            cell.textField?.stringValue = file.name
            cell.toolTip = file.name
            return cell
        }

        private func textCell(
            identifier: NSUserInterfaceItemIdentifier, text: String,
            alignment: NSTextAlignment, in tableView: NSTableView
        ) -> NSTableCellView {
            let cell: NSTableCellView
            if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
                cell = reused
            } else {
                cell = NSTableCellView()
                cell.identifier = identifier
                let label = NSTextField(labelWithString: "")
                label.translatesAutoresizingMaskIntoConstraints = false
                label.textColor = .secondaryLabelColor
                label.lineBreakMode = .byTruncatingTail
                cell.textField = label
                cell.addSubview(label)
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                    label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                    label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
            }
            cell.textField?.stringValue = text
            cell.textField?.alignment = alignment
            cell.toolTip = text
            return cell
        }
    }
}

/// Finder fulfills each promised item separately; stopping must survive the
/// transfer coordinator resetting its per-item state for the next promise.
@MainActor
final class FilePromiseBatch {
    private var stopped = false

    func write(
        file: MTPFile, to url: URL, writer: RemoteFileTable.PromiseWriter,
        shouldStop: @MainActor @Sendable () -> Bool
    ) async throws {
        guard !stopped else { throw CancellationError() }
        defer { if shouldStop() { stopped = true } }
        try await writer(file, url)
    }
}

private final class FilePromisePayload: @unchecked Sendable {
    let file: MTPFile
    let gate: OperationGate
    let writer: RemoteFileTable.PromiseWriter
    let batch: FilePromiseBatch
    let shouldStop: @MainActor @Sendable () -> Bool
    // NSFilePromiseProvider.delegate is weak. Retain the table coordinator for
    // promises that Finder fulfills after the SwiftUI hierarchy changes.
    let delegateRetainer: AnyObject

    init(
        file: MTPFile, gate: OperationGate, writer: @escaping RemoteFileTable.PromiseWriter,
        batch: FilePromiseBatch, shouldStop: @escaping @MainActor @Sendable () -> Bool,
        delegateRetainer: AnyObject
    ) {
        self.file = file
        self.gate = gate
        self.writer = writer
        self.batch = batch
        self.shouldStop = shouldStop
        self.delegateRetainer = delegateRetainer
    }
}

private final class FilePromiseCompletion: @unchecked Sendable {
    private let handler: (Error?) -> Void
    init(_ handler: @escaping (Error?) -> Void) { self.handler = handler }
    func call(_ error: Error?) {
        // Cocoa distinguishes a user stop from an operation failure. Preserve
        // real errors and never claim that an unfulfilled promise succeeded.
        handler(error is CancellationError ? CocoaError(.userCancelled) : error)
    }
}

private extension NSUserInterfaceItemIdentifier {
    static let remoteNameColumn = Self("RemoteNameColumn")
    static let remoteDateColumn = Self("RemoteDateColumn")
    static let remoteSizeColumn = Self("RemoteSizeColumn")
    static let remoteLocationColumn = Self("RemoteLocationColumn")
    static let remoteNameCell = Self("RemoteNameCell")
    static let remoteDateCell = Self("RemoteDateCell")
    static let remoteSizeCell = Self("RemoteSizeCell")
    static let remoteLocationCell = Self("RemoteLocationCell")
}

private final class RemoteFilePromiseProvider: NSFilePromiseProvider {
    var remoteItem: Data?
    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        super.writableTypes(for: pasteboard) + [RemoteDragItem.pasteboardType]
    }
    override func writingOptions(forType type: NSPasteboard.PasteboardType, pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
        type == RemoteDragItem.pasteboardType ? [] : super.writingOptions(forType: type, pasteboard: pasteboard)
    }
    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        type == RemoteDragItem.pasteboardType ? remoteItem : super.pasteboardPropertyList(forType: type)
    }
}

/// Keep fixed metadata columns visible as the sidebar/window is resized.
/// The Bin's extra location column can still scroll when the minimum widths
/// exceed the available space.
final class RemoteTableScrollView: NSScrollView {
    private weak var dropCoordinator: RemoteFileTable.Coordinator?
    var visibleAreaChanged: (() -> Void)?

    func connectDropTarget(_ coordinator: RemoteFileTable.Coordinator) {
        dropCoordinator = coordinator
        // Empty folders and the space below short tables belong to the scroll
        // view, so registering only the table leaves those areas without a target.
        registerForDraggedTypes([RemoteDragItem.pasteboardType, .fileURL])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let dropCoordinator else { return [] }
        return dropCoordinator.validateDrop(sender, row: -1) { _ in }
    }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { !draggingUpdated(sender).isEmpty }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let dropCoordinator else { return false }
        return dropCoordinator.acceptDrop(sender, row: -1)
    }
    override func draggingExited(_ sender: NSDraggingInfo?) {
        super.draggingExited(sender)
        dropCoordinator?.endHover()
    }

    private var lastWidth: CGFloat = -1
    private var lastColumnCount = 0

    override func layout() {
        super.layout()
        fitColumns()
        if let grid = documentView as? NSCollectionView, grid.frame.width != contentSize.width {
            grid.setFrameSize(NSSize(width: contentSize.width, height: grid.frame.height))
            grid.collectionViewLayout?.invalidateLayout()
        }
        visibleAreaChanged?()
    }

    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); visibleAreaChanged?() }

    func fitColumns() {
        guard let table = documentView as? NSTableView,
              let name = table.tableColumns.first else { return }
        let width = contentSize.width
        guard width > 0, width != lastWidth || table.numberOfColumns != lastColumnCount else { return }
        lastWidth = width
        lastColumnCount = table.numberOfColumns
        let metadataWidth = table.tableColumns.dropFirst().reduce(CGFloat(0)) { $0 + $1.width }
        let spacing = table.intercellSpacing.width * CGFloat(table.numberOfColumns)
        name.width = max(name.minWidth, width - metadataWidth - spacing)
        table.setFrameSize(NSSize(width: max(width, name.width + metadataWidth + spacing), height: table.frame.height))
    }
}

private final class RemoteDropTableView: NSTableView {
    var dragDidExit: (() -> Void)?
    override func draggingExited(_ sender: NSDraggingInfo?) {
        super.draggingExited(sender)
        dragDidExit?()
    }
}
