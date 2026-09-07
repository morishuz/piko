import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MTPWire

@MainActor
final class SpringLoadedNavigation {
    private var key: String?
    private var task: Task<Void, Never>?
    @discardableResult
    func schedule(key: String, action: @escaping @MainActor () -> Void) -> Bool {
        guard self.key != key else { return false }
        cancel()
        self.key = key
        task = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(750)) } catch { return }
            guard self?.key == key else { return }
            action()
        }
        return true
    }
    func cancel(key: String? = nil) {
        guard key == nil || key == self.key else { return }
        task?.cancel(); task = nil; self.key = nil
    }
}

extension DeviceManager {
    func beginRemoteDrag(device: ManagedDevice, files: [MTPFile], browserID: UUID) {
        endRemoteDrag()
        let model = device.browser
        guard device.isAvailable, model.isConnected, !model.isBusy, let storageID = model.selectedStorageID,
              browserID == model.browserDragID, !files.isEmpty, files.allSatisfy(model.files.contains) else { return }
        dragSelection = RemoteDragSelection(browserID: browserID, source: device,
            connectionToken: model.connectionToken, storageID: storageID, files: files)
        model.diagnosticLog?.record(.dragStarted)
    }

    func endRemoteDrag() {
        dragSelection = nil
        navigationHover = nil
        dropHint = nil
        springNavigation.cancel()
    }

    /// A drag target must explicitly open the requested folder even when that
    /// storage is already selected. Ordinary sidebar clicks keep their history.
    func navigateForDrop(to device: ManagedDevice, storageID: UInt32, directory: String) async {
        guard dragSelection != nil, device.isAvailable, device.browser.isConnected,
              !device.browser.isBusy, !isQuitting else { return }
        device.browser.diagnosticLog?.record(.dragNavigation)
        select(device)
        if device.browser.selectedStorageID != storageID {
            device.browser.selectStorage(storageID) // Storage targets always request root.
        } else if device.browser.currentPath != directory {
            await device.browser.load(path: directory)
        }
    }

    func remoteRequest(_ items: [RemoteDragItem], to device: ManagedDevice, storageID: UInt32,
                       directory: String, forNavigation: Bool = false) -> RemoteTransferRequest? {
        guard !isQuitting, let drag = dragSelection, !items.isEmpty,
              items.count == drag.files.count, Set(items.map(\.handle)) == Set(drag.files.map(\.id)),
              items.allSatisfy({ $0.browserID == drag.browserID }),
              devices.contains(where: { $0 === drag.source }), devices.contains(where: { $0 === device }),
              drag.source.browser.connectionToken == drag.connectionToken,
              drag.source.isAvailable, device.isAvailable,
              drag.source.browser.isConnected, device.browser.isConnected,
              !pendingTransferDevices.contains(drag.source.id), !pendingTransferDevices.contains(device.id),
              !drag.source.browser.isBusy, !device.browser.isBusy,
              !drag.source.browser.isQuitting, !device.browser.isQuitting,
              !drag.source.browser.uploadNeedsReconnect, !device.browser.uploadNeedsReconnect,
              (try? RemotePath.validate(directory)) != nil, !device.browser.isBinPath(directory, storageID: storageID),
              device.browser.storages.contains(where: { $0.id == storageID && $0.info.accessCapability == 0 }),
              drag.source.browser.storages.contains(where: { $0.id == drag.storageID }),
              drag.files.allSatisfy({ drag.source.browser.isValidTransferSource($0, storageID: drag.storageID) }) else { return nil }
        let sameStorage = drag.source === device && drag.storageID == storageID
        if sameStorage {
            guard device.browser.storageWriteCapabilities[storageID]?.move == true,
                  drag.files.allSatisfy({ (forNavigation || $0.parentPath != directory) && (!$0.isFolder || !BinLayout.contains(directory, in: $0.path)) }) else { return nil }
        } else {
            guard device.browser.storageWriteCapabilities[storageID]?.upload == true,
                  !drag.files.contains(where: \.isFolder) || device.browser.client is any MTPFolderUploadBackend else { return nil }
        }
        return RemoteTransferRequest(source: drag, destination: device,
            destinationConnection: device.browser.connectionToken, storageID: storageID,
            directory: directory, operation: sameStorage ? .move : .copy)
    }

    func remoteDropOperation(_ items: [RemoteDragItem], to device: ManagedDevice,
                             storageID: UInt32, directory: String) -> RemoteDropOperation? {
        let request = remoteRequest(items, to: device, storageID: storageID, directory: directory)
        let hint = request.map { "\($0.operation.rawValue) to \(device.displayName): \(directory)" }
        if dropHint != hint { dropHint = hint }
        return request?.operation
    }

    @discardableResult
    func acceptRemoteDrop(_ items: [RemoteDragItem], to device: ManagedDevice,
                          storageID: UInt32, directory: String) -> Bool {
        guard let request = remoteRequest(items, to: device, storageID: storageID, directory: directory) else { return false }
        let transfer = RemoteTransferCoordinator(request: request)
        // Reserve identities immediately, but publish UI changes after AppKit
        // finishes its drag IPC (as for Finder upload drops).
        let participants: Set<String> = [request.source.source.id, device.id]
        pendingTransferDevices.formUnion(participants)
        DispatchQueue.main.async { [self] in
            pendingTransferDevices.subtract(participants)
            guard !isQuitting, request.isCurrent,
                  request.source.source.isAvailable, request.destination.isAvailable else { return }
            for browser in request.participants {
                guard browser.reserve(for: transfer) else {
                    for reserved in request.participants { reserved.release(transfer, sessionError: nil) }
                    device.browser.transferConfirmation = "Transfer not started: a participating device became busy."
                    return
                }
            }
            device.browser.diagnosticLog?.record(.dragDropAccepted)
            endRemoteDrag()
            Task { await finishRemoteTransfer(transfer) }
        }
        return true
    }

    private func finishRemoteTransfer(_ transfer: RemoteTransferCoordinator) async {
        await transfer.run()
        let request = transfer.request
        for browser in request.participants {
            let error: BackendSessionError?
            if request.source.source === request.destination {
                error = transfer.sourceSessionError ?? transfer.destinationSessionError
            } else {
                error = browser === request.source.source.browser ? transfer.sourceSessionError : transfer.destinationSessionError
            }
            browser.release(transfer, sessionError: error)
        }
        request.destination.browser.transferConfirmation = transfer.attentionMessage
        // Cancellation preserves cached listings, as in normal transfers. A
        // later explicit refresh is safe after a completed range cancellation.
        guard !transfer.stopRequested else { return }
        let browser = request.destination.browser
        if browser.isConnected, !browser.isQuitting { await browser.load(path: browser.currentPath) }
    }
}

/// Sidebar and Up use the same target resolution as native folder-row drops.
/// A live in-app drag is required; external file providers use the Finder path.
struct RemoteStorageDropDelegate: DropDelegate {
    let manager: DeviceManager
    let device: ManagedDevice
    let storageID: UInt32
    let directory: String
    let navigate: @MainActor () -> Void
    var onTargetChanged: @MainActor (Bool) -> Void = { _ in }
    var hoverID: String? = nil
    private var key: String { "\(device.id):\(storageID):\(hoverID ?? directory)" }
    private var targetDirectory: String {
        manager.navigationHover.flatMap { $0.key == key ? $0.directory : nil } ?? directory
    }

    func validateDrop(info: DropInfo) -> Bool {
        // Keep receiving updates while source setup or a listing is finishing.
        // This enables tracking only; updateHover and acceptRemoteDrop enforce
        // the full session, selection and destination rules before doing work.
        info.hasItemsConforming(to: [RemoteDragItem.pasteboardType.rawValue])
            && device.isAvailable && device.browser.isConnected
    }
    /// Also called on updates: AppKit may enter before its source callback has
    /// published the drag snapshot, or while a folder listing is finishing.
    @discardableResult
    func updateHover() -> RemoteDropOperation? {
        guard let drag = manager.dragSelection,
              manager.remoteRequest(drag.tokens, to: device, storageID: storageID,
                  directory: targetDirectory, forNavigation: true) != nil else { return nil }
        let target = targetDirectory
        manager.navigationHover = (key, target)
        onTargetChanged(true)
        let operation = manager.remoteDropOperation(drag.tokens, to: device, storageID: storageID, directory: target)
        let scheduled = manager.springNavigation.schedule(key: key) { [manager] in
            guard manager.dragSelection?.browserID == drag.browserID else { return }
            navigate()
        }
        if scheduled { device.browser.diagnosticLog?.record(.dragHover) }
        return operation
    }
    func dropEntered(info: DropInfo) {
        guard info.hasItemsConforming(to: [RemoteDragItem.pasteboardType.rawValue]) else { return }
        updateHover()
    }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard info.hasItemsConforming(to: [RemoteDragItem.pasteboardType.rawValue]),
              let operation = updateHover() else { return DropProposal(operation: .forbidden) }
        return DropProposal(operation: operation == .copy ? .copy : .move)
    }
    func dropExited(info: DropInfo) {
        onTargetChanged(false)
        manager.springNavigation.cancel(key: key)
        if manager.navigationHover?.key == key { manager.navigationHover = nil }
        manager.dropHint = nil
    }
    func performDrop(info: DropInfo) -> Bool {
        onTargetChanged(false)
        manager.springNavigation.cancel(key: key)
        guard validateDrop(info: info), let drag = manager.dragSelection else { return false }
        return manager.acceptRemoteDrop(drag.tokens, to: device, storageID: storageID, directory: targetDirectory)
    }
}

/// Hovering a device or storage opens its root without ending the drag.
struct RemoteDeviceDrop: ViewModifier {
    let manager: DeviceManager
    let device: ManagedDevice
    func body(content: Content) -> some View {
        if let target = device.remoteDropDestination {
            content.onDrop(of: [RemoteDragItem.pasteboardType.rawValue], delegate:
                RemoteStorageDropDelegate(manager: manager, device: device,
                    storageID: target.storageID, directory: target.directory,
                    navigate: { Task { await manager.navigateForDrop(to: device, storageID: target.storageID, directory: "/") } }))
        } else { content }
    }
}

extension ManagedDevice {
    var remoteDropDestination: (storageID: UInt32, directory: String)? {
        guard isAvailable, browser.isConnected,
              let storageID = browser.selectedStorageID else { return nil }
        return (storageID, "/")
    }
}

struct RemoteTransferStatusView: View {
    @ObservedObject var transfer: RemoteTransferCoordinator
    var compact = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !compact { Text(transfer.title).fontWeight(.medium) }
            HStack(alignment: .top) {
                Text(transfer.status).lineLimit(compact ? 2 : 1)
                Spacer(minLength: 4)
                if let active = transfer.active {
                    RemoteTransferCancelButton(transfer: transfer, coordinator: active)
                } else {
                    Button(transfer.stopRequested ? "Stopping…" : "Cancel") { transfer.cancel() }
                        .buttonStyle(.link).disabled(transfer.stopRequested)
                        .help("Finishes the current device command, then stops.")
                }
            }
            if let coordinator = transfer.active {
                RemoteTransferPhaseProgress(coordinator: coordinator, uploading: transfer.phase == .uploading)
            }
            Text("\(transfer.results.count) of \(transfer.plannedCount) items processed")
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(compact ? 0 : 12)
    }
}

private struct RemoteTransferPhaseProgress: View {
    @ObservedObject var coordinator: TransferCoordinator
    let uploading: Bool
    var body: some View {
        if let progress = coordinator.progress, let total = progress.totalBytes, total > 0 {
            let fraction = Double(min(progress.bytesTransferred, total)) / Double(total)
            ProgressView(value: (uploading ? 0.5 : 0) + fraction * 0.5)
        } else { ProgressView().controlSize(.small) }
    }
}

private struct RemoteTransferCancelButton: View {
    @ObservedObject var transfer: RemoteTransferCoordinator
    @ObservedObject var coordinator: TransferCoordinator
    var body: some View {
        Button(transfer.stopRequested ? "Stopping…" : coordinator.isPlanning || coordinator.canCancelActiveTransfer
            ? "Cancel" : "Stop After Current File") { transfer.cancel() }
            .buttonStyle(.link).disabled(transfer.stopRequested)
            .help("Stops at the next safe boundary. Completed copies and original files are kept.")
    }
}

struct RemoteBreadcrumb: Identifiable, Equatable {
    let path: String
    let name: String
    var id: String { path }
    static func items(for path: String) -> [Self] {
        guard (try? RemotePath.validate(path)) != nil else { return [] }
        var items = [Self(path: "/", name: "/")]
        var ancestor = "/"
        for component in path.split(separator: "/") {
            ancestor = RemotePath.appending(String(component), to: ancestor)
            items.append(Self(path: ancestor, name: String(component)))
        }
        return items
    }
}
