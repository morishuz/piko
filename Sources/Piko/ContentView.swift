import AppKit
import SwiftUI

struct DeviceContentView: View {
    @ObservedObject var model: DeviceBrowserModel
    let deviceName: String
    let modelName: String
    var manager: DeviceManager?
    var device: ManagedDevice?

    var body: some View {
        VStack(spacing: 0) {
            browserToolbar
            Divider()

            if model.isConnected || !model.files.isEmpty {
                browser
            } else {
                disconnectedView
            }
            if let transfer = model.remoteTransfer {
                RemoteTransferStatusView(transfer: transfer)
            } else { TransferStatusView(coordinator: model.transfers, activity: model.isGeneratingThumbnails ? "Generating thumbnails" : nil) }
            HStack {
                if let storage = model.selectedStorage {
                    Text(storage.availableSpaceLabel)
                }
                Spacer()
                Text(modelName).lineLimit(1)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .alert(
            "\(deviceName) — Piko Error",
            isPresented: Binding(
                get: { model.operationError != nil },
                set: { if !$0 { model.operationError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                model.operationError = nil
            }
        } message: {
            Text(model.operationError ?? "Unknown error")
        }
        .alert(
            "\(deviceName) — Transfer Needs Attention",
            isPresented: Binding(
                get: { model.transferConfirmation != nil },
                set: { if !$0 { model.transferConfirmation = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                model.transferConfirmation = nil
            }
        } message: {
            Text(model.transferConfirmation ?? "Some items could not be transferred.")
        }
    }

    private var browserToolbar: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(deviceName).font(.headline).lineLimit(1)
                Text(model.selectedStorage?.displayName ?? statusText)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if model.isLoadingDirectory { ProgressView().controlSize(.small) }
            Button(action: model.navigateUp) { Image(systemName: "chevron.up") }
                .disabled(!model.isConnected || !model.canNavigateUp || model.isLoadingDirectory || model.isTransferring)
                .help("Up one folder").accessibilityLabel("Up one folder")
                .modifier(ParentFolderDrop(manager: manager, device: device, model: model))
            Button(action: model.refresh) { Image(systemName: "arrow.clockwise") }
                .disabled(!model.isConnected || model.isLoadingDirectory || model.isTransferring)
                .help("Refresh folder").accessibilityLabel("Refresh folder")
            Divider().frame(height: 18)
            Picker("File view", selection: $model.fileViewMode) {
                Image(systemName: "list.bullet").tag(FileViewMode.list)
                Image(systemName: "square.grid.2x2").tag(FileViewMode.grid)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 70)
            .help("Switch between list and grid view")
            .contextMenu {
                Toggle("Load Device Thumbnails Automatically", isOn: Binding(
                    get: { model.thumbnails.automaticEnabled }, set: { model.thumbnails.automaticEnabled = $0 }))
            }
            Divider().frame(height: 18)
            Button(action: model.downloadSelected) {
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(model.canDownload ? Color.blue : Color.secondary)
            }
            .disabled(!model.canDownload)
            .help(model.selectedFiles.isEmpty ? "Select files or folders to download" : downloadButtonTitle)
            .accessibilityLabel(downloadButtonTitle)
            Button(action: model.chooseUploadFiles) { Image(systemName: "arrow.up.circle") }
                .disabled(!model.canUpload).help(model.uploadHelp).accessibilityLabel("Upload files or folders")
            BinButton(enabled: model.canOpenBin, dropEnabled: model.canDropIntoBin, count: model.binCount, help: model.binHelp,
                open: model.openBin, accepts: model.canAcceptBinDrop, drop: model.acceptBinDrop)
                .frame(width: 44, height: 40)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        .frame(height: 68)
    }

    private var browser: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "externaldrive.connected.to.line.below")
                ScrollView(.horizontal, showsIndicators: false) {
                    let crumbs = model.breadcrumbs
                    HStack(spacing: 5) {
                        ForEach(crumbs) { crumb in
                            breadcrumb(crumb)
                            if crumb.path != "/", crumb.path != crumbs.last?.path {
                                Text("/").foregroundStyle(.secondary)
                            }
                        }
                    }.font(.system(.body, design: .monospaced))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Spacer()
                Text("\(model.files.count) items")
                    .foregroundStyle(.secondary)
                if model.selectedFiles.count == 1, let selected = model.selectedFiles.first {
                    Text("• \(selected.name) selected")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if !model.selectedFiles.isEmpty {
                    Text("• \(model.selectedFiles.count) selected")
                        .foregroundStyle(.secondary)
                }
                if !model.files.isEmpty {
                    Button("Select All", action: model.selectAll)
                        .buttonStyle(.link)
                        .disabled(model.isTransferring || model.selectedFiles.count == model.files.count)
                    if !model.selectedFiles.isEmpty {
                        Button("Clear", action: model.clearSelection)
                            .buttonStyle(.link)
                            .disabled(model.isTransferring)
                    }
                }


            }
            .padding(.horizontal, 14)
            .frame(height: 38)

            Divider()

            if let restriction = model.writeRestriction {
                Label(restriction, systemImage: "lock")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 8)
            }

            if let issue = model.browsingIssue {
                Label(issue, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 8)
            }

            if model.isViewingBin {
                HStack {
                    Text("Right-click an item to restore it to its original location or delete it permanently.")
                    Spacer()
                    Button("Restore…", action: model.confirmRestoreFromBin)
                        .disabled(!model.canRestore)
                    Button("Empty Bin…", action: model.emptyBin)
                        .disabled(!model.canEmptyBin)
                    if let retained = model.binListing?.retainedEntryCount, retained > 0 {
                        Text("\(retained) recovery records retained")
                            .help("These entries no longer contain files. Empty Bin also removes their recovery records.")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                if model.binListing?.items.contains(where: { $0.originalPath == nil }) == true {
                    Text("Unrecognised items are excluded from Empty Bin. Inspect them individually before deleting anything.")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14).padding(.bottom, 8)
                }
            }

            ZStack {
                fileTable.id(model.fileViewMode)
                if model.files.isEmpty && !model.isLoadingDirectory {
                    ContentUnavailableView(
                        model.browsingIssue != nil ? "No Available Items" : model.isViewingBin ? "Bin Is Empty" : "Empty Folder",
                        systemImage: model.isViewingBin ? "trash" : "folder",
                        description: Text(model.browsingIssue ?? (model.isViewingBin ? "Deleted files and folders will appear here." : "There are no visible items in this folder."))
                    )
                    .allowsHitTesting(false)
                }
            }
        }
    }

    @ViewBuilder private func breadcrumb(_ crumb: RemoteBreadcrumb) -> some View {
        let label = crumb.path == "/" ? "Open storage root" : "Open \(crumb.name)"
        let button = Button(crumb.name) { Task { await model.load(path: crumb.path) } }
            .buttonStyle(.plain)
            .foregroundStyle(crumb.path == model.currentPath ? Color.primary : Color.accentColor)
            .disabled(model.isBusy)
            .accessibilityLabel(label)
        if let manager, let device, let storage = model.selectedStorageID, !model.isBrowsingBin {
            button.help("Open \(crumb.path); hover while dragging to open, or drop to transfer here")
                .onDrop(of: [RemoteDragItem.pasteboardType.rawValue], delegate:
                    RemoteStorageDropDelegate(manager: manager, device: device,
                        storageID: storage, directory: crumb.path,
                        navigate: { Task { await manager.navigateForDrop(to: device, storageID: storage, directory: crumb.path) } }))
        } else {
            button.help(label)
        }
    }

    private var binLocationReader: ((MTPFile) -> String?)? {
        guard model.isViewingBin else { return nil }
        return { model.originalLocation(for: $0) }
    }

    private var fileTable: RemoteFileTable {
        RemoteFileTable(
            mode: model.fileViewMode,
            thumbnailsAllowed: model.isConnected && !model.isBusy && !model.isQuitting,
            thumbnailStore: model.thumbnails,
            thumbnailKey: model.thumbnailKey,
            onVisibleFiles: { model.updateVisibleThumbnails($0, owner: $1) },
            generationCandidates: model.missingThumbnailFiles,
            onGenerateThumbnails: model.requestThumbnailGeneration,
            files: model.files,
            selection: selectionBinding,
            isEnabled: !model.isTransferring,
            onOpen: { file in
                if let manager, let device, let storage = model.selectedStorageID, manager.dragSelection != nil {
                    Task { await manager.navigateForDrop(to: device, storageID: storage, directory: file.path) }
                } else { model.open(file) }
            },
            onDownload: model.downloadSelected,
            browserDragID: model.browserDragID,
            directory: model.currentPath,
            onRemoteDrag: { files, id in
                if let device { manager?.beginRemoteDrag(device: device, files: files, browserID: id) }
            },
            onRemoteDragEnd: { manager?.endRemoteDrag() },
            remoteOperation: { items, path in
                guard let device, let storage = model.selectedStorageID else { return nil }
                return manager?.remoteDropOperation(items, to: device, storageID: storage, directory: path)
            },
            onRemoteDrop: { items, path in
                guard let device, let storage = model.selectedStorageID else { return false }
                return manager?.acceptRemoteDrop(items, to: device, storageID: storage, directory: path) ?? false
            },
            springNavigation: manager?.springNavigation,
            canDelete: model.canDelete, onDelete: model.requestDelete,
            deleteIsPermanent: model.isBrowsingBin,
            showsRestore: model.isViewingBin,
            canRestore: model.canRestoreSelection, onRestore: model.requestRestore,
            originalLocation: binLocationReader,
            canUpload: model.canUpload,
            onUploadDrop: model.acceptUploadDrop,
            writePromise: model.writeFilePromise,
            shouldStopPromises: { model.transfers.stopRequested }
        )
    }

    private var disconnectedView: some View {
        ContentUnavailableView {
            Label(model.isDeviceAvailable ? "Connect \(deviceName)" : "Device Unplugged", systemImage: "cable.connector")
        } description: {
            Text(disconnectedDescription)
        } actions: {
            Button("Connect") {
                model.connect()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(
                !model.isDeviceAvailable || model.state == .connecting || model.state == .recovering
                    || model.state == .disconnecting)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var selectionBinding: Binding<Set<UInt32>> {
        Binding(
            get: { model.selectedFileIDs },
            set: { model.replaceSelection($0) }
        )
    }

    private var statusText: String {
        if model.isQuitting { return "Finishing the current operation before quitting…" }
        switch model.state {
        case .disconnected:
            return "No device connected"
        case .connecting:
            return "Connecting… Unlock the device and allow file access if prompted."
        case .recovering:
            return "Transfer stopped — restoring a fresh MTP session…"
        case .disconnecting:
            return "Disconnecting…"
        case .connected:
            if model.isTransferring {
                return model.binStatus ?? "Transferring files…"
            } else if model.uploadNeedsReconnect {
                return "Upload outcome uncertain — inspect the device and reconnect before uploading again."
            } else {
                return model.selectedStorage?.displayName ?? "Connected"
            }
        case let .failed(message):
            return message
        case let .reconnectRequired(message):
            return message
        }
    }

    private var disconnectedDescription: String {
        if !model.isDeviceAvailable { return "Reconnect the USB cable to see this device again." }
        return switch model.state {
        case let .failed(message), let .reconnectRequired(message): message
        default: "Unlock your phone, choose File Transfer / Android Auto, then connect it over USB."
        }
    }

    private var downloadButtonTitle: String {
        let count = model.selectedFiles.count
        return count > 1 ? "Download \(count) Items…" : "Download…"
    }
}

private struct TransferStatusView: View {
    @ObservedObject var coordinator: TransferCoordinator
    var activity: String?

    var body: some View {
        if coordinator.isRunning {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(activity.map { "\($0): \(coordinator.results.count) of \(coordinator.plannedCount)" } ?? (coordinator.isPlanning ? (coordinator.isUploading ? "Preparing upload…" : "Preparing file list…") : "\(coordinator.isUploading ? "Upload" : "Download"): \(coordinator.results.count) of \(coordinator.plannedCount) items processed"))
                    Spacer()
                    if coordinator.isPlanning || coordinator.canCancelActiveTransfer {
                        Button(coordinator.stopRequested ? "Cancelling…" : (coordinator.isPlanning ? "Cancel Preparation" : "Cancel Transfer")) {
                            coordinator.cancelTransfer()
                        }
                        .disabled(coordinator.stopRequested)
                    } else {
                        Button(coordinator.stopRequested ? "Stopping after current file…" : "Stop After Current File") {
                            coordinator.stopAfterCurrentFile()
                        }
                        .disabled(coordinator.stopRequested)
                    }
                }
                if let progress = coordinator.progress {
                    Text(progress.fileName).lineLimit(1)
                    if let total = progress.totalBytes, total > 0 {
                        ProgressView(value: Double(min(progress.bytesTransferred, total)), total: Double(total))
                    } else { ProgressView().controlSize(.small) }
                    Text(ByteCountFormatter.string(fromByteCount: progress.bytesTransferred, countStyle: .file) + " transferred")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if coordinator.canCancelActiveTransfer, !coordinator.isPlanning {
                    Text(coordinator.isUploading
                        ? "Cancel finishes the current small part, then removes the incomplete upload."
                        : "Cancel stops after the current small part finishes.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !coordinator.canCancelActiveTransfer, !coordinator.isPlanning {
                    Text("The active file cannot be interrupted safely. Stop takes effect after it finishes or the device times out.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .background(.bar)
        }
    }
}

private struct ParentFolderDrop: ViewModifier {
    let manager: DeviceManager?
    let device: ManagedDevice?
    let model: DeviceBrowserModel
    func body(content: Content) -> some View {
        if let manager, let device, let storage = model.selectedStorageID,
           !model.isBrowsingBin {
            let parent = (model.currentPath as NSString).deletingLastPathComponent
            content.onDrop(of: [RemoteDragItem.pasteboardType.rawValue], delegate:
                RemoteStorageDropDelegate(manager: manager, device: device, storageID: storage,
                    directory: parent.isEmpty ? "/" : parent,
                    navigate: { Task { await manager.navigateForDrop(to: device, storageID: storage, directory: parent.isEmpty ? "/" : parent) } },
                    hoverID: "up"))
        } else { content }
    }
}
