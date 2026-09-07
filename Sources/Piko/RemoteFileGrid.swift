import AppKit
import Combine

/// Both presentations use the same controller for actions, promises and drops.
extension RemoteFileTable.Coordinator: NSCollectionViewDataSource, NSCollectionViewDelegate {
    func makeGrid() -> NSScrollView {
        let grid = RemoteCollectionView()
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 128, height: 138)
        layout.minimumInteritemSpacing = 12
        layout.minimumLineSpacing = 12
        layout.sectionInset = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        grid.collectionViewLayout = layout
        grid.autoresizingMask = [.width]
        grid.isSelectable = true
        grid.allowsMultipleSelection = true
        grid.backgroundColors = [.controlBackgroundColor]
        grid.register(RemoteGridItem.self, forItemWithIdentifier: .init("RemoteGridItem"))
        grid.dataSource = self
        grid.delegate = self
        grid.setDraggingSourceOperationMask(.copy, forLocal: false)
        grid.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        grid.registerForDraggedTypes([.fileURL, RemoteDragItem.pasteboardType])
        grid.openItem = { [weak self] index in
            guard let self, self.parent.isEnabled, self.parent.files.indices.contains(index),
                self.parent.files[index].isFolder else { return }
            self.parent.onOpen(self.parent.files[index])
        }
        grid.dragDidExit = { [weak self] in self?.endHover() }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        grid.menu = menu
        collectionView = grid
        let scroll = RemoteTableScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.documentView = grid
        scroll.connectDropTarget(self)
        observe(scroll)
        return scroll
    }

    func updateGrid(parent: RemoteFileTable, grid: NSCollectionView) {
        self.parent = parent
        collectionView?.interactionEnabled = parent.isEnabled
        synchronizingSelection = true
        if displayedFiles != parent.files {
            displayedFiles = parent.files
            grid.reloadData()
        }
        grid.selectionIndexPaths = Set(parent.files.indices.filter { parent.selection.contains(parent.files[$0].id) }
            .map { IndexPath(item: $0, section: 0) })
        synchronizingSelection = false
        reportVisible()
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { parent.files.count }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: .init("RemoteGridItem"), for: indexPath)
        configure(item, row: indexPath.item)
        return item
    }

    func configure(_ item: NSCollectionViewItem, row: Int) {
        guard parent.files.indices.contains(row) else { return }
        let file = parent.files[row]
        configureImage(item.imageView, file: file, symbolSize: 48)
        item.textField?.stringValue = file.name
        item.view.toolTip = [file.name, parent.originalLocation?(file)].compactMap { $0 }.joined(separator: "\n")
        item.view.setAccessibilityLabel(file.name)
    }

    func collectionView(_ collectionView: NSCollectionView, shouldSelectItemsAt indexPaths: Set<IndexPath>) -> Set<IndexPath> {
        parent.isEnabled ? indexPaths : []
    }
    func collectionView(_ collectionView: NSCollectionView, shouldDeselectItemsAt indexPaths: Set<IndexPath>) -> Set<IndexPath> {
        parent.isEnabled ? indexPaths : []
    }
    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { gridSelectionChanged() }
    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { gridSelectionChanged() }
    func gridSelectionChanged() {
        guard !synchronizingSelection, let grid = collectionView else { return }
        parent.selection = Set(grid.selectionIndexPaths.compactMap {
            parent.files.indices.contains($0.item) ? parent.files[$0.item].id : nil
        })
    }

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> (any NSPasteboardWriting)? {
        pasteboardWriter(row: indexPath.item)
    }
    func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession,
        willBeginAt screenPoint: NSPoint, forItemsAt indexPaths: Set<IndexPath>) {
        beginDrag(rows: indexPaths.map(\.item).sorted())
    }
    func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession,
        endedAt screenPoint: NSPoint, dragOperation operation: NSDragOperation) {
        endHover()
        parent.onRemoteDragEnd()
    }
    func collectionView(_ collectionView: NSCollectionView, validateDrop draggingInfo: NSDraggingInfo,
        proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
        dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        let point = collectionView.convert(draggingInfo.draggingLocation, from: nil)
        let row = collectionView.indexPathForItem(at: point)?.item ?? -1
        return validateDrop(draggingInfo, row: row) { folderRow in
            if folderRow >= 0 {
                proposedDropIndexPath.pointee = IndexPath(item: folderRow, section: 0) as NSIndexPath
                proposedDropOperation.pointee = .on
            } else { proposedDropOperation.pointee = .before }
        }
    }
    func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: NSDraggingInfo,
        indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
        let point = collectionView.convert(draggingInfo.draggingLocation, from: nil)
        return acceptDrop(draggingInfo, row: collectionView.indexPathForItem(at: point)?.item ?? -1)
    }

    func observe(_ scroll: NSScrollView) {
        isObserving = true
        scrollView = scroll
        scroll.contentView.postsBoundsChangedNotifications = true
        (scroll as? RemoteTableScrollView)?.visibleAreaChanged = { [weak self] in self?.reportVisible() }
        NotificationCenter.default.publisher(for: NSView.boundsDidChangeNotification, object: scroll.contentView)
            .sink { [weak self] _ in self?.reportVisible() }.store(in: &observers)
        parent.thumbnailStore?.$revision.dropFirst().sink { [weak self] _ in
            self?.refreshVisibleImages()
        }.store(in: &observers)
    }

    func visibleRows() -> [Int] {
        guard let scrollView, scrollView.window != nil else { return [] }
        if let grid = collectionView {
            return grid.indexPathsForVisibleItems().map(\.item).sorted()
        }
        guard let tableView else { return [] }
        let range = tableView.rows(in: tableView.visibleRect)
        guard range.location != NSNotFound else { return [] }
        return Array(range.location..<min(NSMaxRange(range), parent.files.count))
    }

    func reportVisible() {
        guard isObserving, !reportPending else { return }
        reportPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reportPending = false
            guard self.isObserving else { return }
            let files = self.visibleRows().compactMap { self.parent.files.indices.contains($0) ? self.parent.files[$0] : nil }
            guard files != self.lastVisible || self.lastEnabled != self.parent.thumbnailsAllowed else { return }
            self.lastVisible = files
            self.lastEnabled = self.parent.thumbnailsAllowed
            self.parent.onVisibleFiles(files, self.visibilityID)
        }
    }

    func stopObserving() {
        isObserving = false
        observers.removeAll()
        endHover()
        let callback = parent.onVisibleFiles
        let id = visibilityID
        DispatchQueue.main.async { callback([], id) }
    }

    func configureImage(_ view: NSImageView?, file: MTPFile, symbolSize: CGFloat = 14) {
        let image = parent.thumbnailKey(file).flatMap { parent.thumbnailStore?.entry(for: $0)?.image }
        (view as? ThumbnailImageView)?.showsVideoBadge = file.isVideoThumbnailCandidate && image != nil
        view?.imageScaling = image == nil ? .scaleProportionallyDown : .scaleProportionallyUpOrDown
        view?.image = image.map { NSImage(cgImage: $0, size: .zero) }
            ?? NSImage(systemSymbolName: file.isFolder ? "folder.fill" : file.isVideoThumbnailCandidate ? "video" : file.isPhotoThumbnailCandidate ? "photo" : "doc",
                accessibilityDescription: file.isFolder ? "Folder" : "File")?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: symbolSize, weight: .regular))
        view?.contentTintColor = image == nil ? (file.isFolder ? .systemBlue : .secondaryLabelColor) : nil
    }

    func refreshVisibleImages() {
        // Updating images in place avoids reloadData, selection churn and scroll jumps.
        for row in visibleRows() where parent.files.indices.contains(row) {
            if let grid = collectionView, let item = grid.item(at: IndexPath(item: row, section: 0)) {
                configure(item, row: row)
            } else if let cell = tableView?.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView {
                configureImage(cell.imageView, file: parent.files[row])
            }
        }
    }
}

final class RemoteCollectionView: NSCollectionView {
    var contextIndex: IndexPath?
    var interactionEnabled = true
    var openItem: ((Int) -> Void)?
    var dragDidExit: (() -> Void)?
    override func menu(for event: NSEvent) -> NSMenu? {
        guard interactionEnabled else { return nil }
        contextIndex = indexPathForItem(at: convert(event.locationInWindow, from: nil))
        return super.menu(for: event)
    }
    override func mouseDown(with event: NSEvent) {
        guard interactionEnabled else { return }
        let index = indexPathForItem(at: convert(event.locationInWindow, from: nil))
        super.mouseDown(with: event)
        if event.clickCount == 2, let index { openItem?(index.item) }
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { super.draggingExited(sender); dragDidExit?() }
}

final class RemoteGridItem: NSCollectionViewItem {
    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 6
        let image = ThumbnailImageView()
        image.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 48, weight: .regular)
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 11)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        image.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(image)
        view.addSubview(label)
        imageView = image
        textField = label
        NSLayoutConstraint.activate([
            image.topAnchor.constraint(equalTo: view.topAnchor, constant: 7),
            image.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            image.widthAnchor.constraint(equalToConstant: 112), image.heightAnchor.constraint(equalToConstant: 100),
            label.topAnchor.constraint(equalTo: image.bottomAnchor, constant: 8),
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -5),
        ])
    }
    override var isSelected: Bool {
        didSet { view.layer?.backgroundColor = (isSelected ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.25) : .clear).cgColor }
    }
}

/// Shared decoration for video previews in both list and grid presentations.
final class ThumbnailImageView: NSImageView {
    private let badge = NSImageView()
    var showsVideoBadge = false { didSet { badge.isHidden = !showsVideoBadge; needsLayout = true } }
    override init(frame: NSRect) { super.init(frame: frame); configureBadge() }
    required init?(coder: NSCoder) { super.init(coder: coder); configureBadge() }
    private func configureBadge() {
        badge.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)
        badge.contentTintColor = .white
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.65).cgColor
        badge.layer?.cornerRadius = 3
        badge.imageScaling = .scaleProportionallyDown
        badge.isHidden = true
        badge.setAccessibilityElement(false)
        addSubview(badge)
    }
    override func layout() {
        super.layout()
        guard let size = image?.size, size.width > 0, size.height > 0 else { return }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let width = size.width * scale, height = size.height * scale
        let side = min(12, width, height)
        // Attach to the fitted image, not the surrounding letterbox space.
        badge.frame = NSRect(x: bounds.midX + width / 2 - side,
            y: isFlipped ? bounds.midY + height / 2 - side : bounds.midY - height / 2,
            width: side, height: side)
    }
}
