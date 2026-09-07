import SwiftUI

struct ContentView: View {
    @ObservedObject var manager: DeviceManager

    var body: some View {
        HSplitView {
            sidebar.frame(minWidth: 220, idealWidth: 248, maxWidth: 260)
            if let device = manager.selectedDevice {
                SelectedDeviceView(device: device, manager: manager).id(device.id)
                    .frame(minWidth: 580, maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("Connect a Device", systemImage: "cable.connector",
                    description: Text(manager.discoveryError ?? "Connect your phone or camera over USB. Unlock it and choose File Transfer if prompted."))
                    .frame(minWidth: 580, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .overlay(alignment: .bottom) {
            if let hint = manager.dropHint {
                Text(hint).font(.callout).padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(12).allowsHitTesting(false)
            }
        }
        .task { await manager.monitor() }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Devices").font(.headline).foregroundStyle(.secondary)
                Spacer()
                Button { Task { await manager.scan() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(manager.isScanning)
                .help("Look for USB devices").accessibilityLabel("Look for USB devices")
            }.padding(16)
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(manager.devices) { device in
                        DeviceSidebarRow(device: device, browser: device.browser, manager: manager,
                            isSelected: manager.selectedDeviceID == device.id,
                            select: { manager.select(device) },
                            selectStorage: { manager.select(device, storage: $0) })
                    }
                    if let error = manager.discoveryError {
                        Text(error).font(.caption).foregroundStyle(.secondary).padding(12)
                    }
                    if manager.devices.isEmpty && manager.discoveryError == nil {
                        Text("Devices appear here when connected over USB.")
                            .font(.callout).foregroundStyle(.secondary).padding(12)
                    }
                }.padding(.horizontal, 10)
            }
            Spacer(minLength: 0)

        }
        .background(.bar)
    }
}

private struct SelectedDeviceView: View {
    @ObservedObject var device: ManagedDevice
    let manager: DeviceManager
    var body: some View {
        DeviceContentView(model: device.browser, deviceName: device.displayName, modelName: device.modelName, manager: manager, device: device)
    }
}

private struct DeviceSidebarRow: View {
    @ObservedObject var device: ManagedDevice
    @ObservedObject var browser: DeviceBrowserModel
    let manager: DeviceManager
    @State private var targetedStorage: UInt32?
    let isSelected: Bool
    let select: () -> Void
    let selectStorage: (UInt32) -> Void
    @State private var renaming = false
    @State private var draftName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button(action: select) {
                    HStack(spacing: 10) {
                        Image(systemName: device.symbol).frame(width: 18)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(device.displayName).fontWeight(.medium).lineLimit(2)
                            if device.nickname != nil {
                                Text(device.modelName).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .modifier(RemoteDeviceDrop(manager: manager, device: device))
                Button {
                    draftName = device.nickname ?? ""
                    renaming = true
                } label: { Image(systemName: "pencil") }
                    .buttonStyle(.borderless)
                    .help("Rename this device in Piko").accessibilityLabel("Rename \(device.displayName)")
            }
            HStack(spacing: 5) {
                Circle().fill(statusColor).frame(width: 6, height: 6)
                Text(statusText).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 2)
                if device.isAvailable {
                    Button(browser.isConnected ? "Disconnect" : "Connect") {
                        if browser.isConnected { browser.disconnect() }
                        else { select(); browser.connect() }
                    }
                    .buttonStyle(.link).font(.caption)
                    .disabled(browser.isBusy || browser.isQuitting)
                }
            }
            if browser.isConnected {
                ForEach(browser.storages) { storage in
                    Button { selectStorage(storage.id) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: storage.info.storageType == 4 ? "sdcard" : "internaldrive")
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(storage.displayName).lineLimit(2)
                                Text(storage.availableSpaceLabel).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(9).frame(maxWidth: .infinity, alignment: .leading)
                        .background(isSelected && browser.selectedStorageID == storage.id
                            ? Color.accentColor.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                        .foregroundStyle(isSelected && browser.selectedStorageID == storage.id ? Color.accentColor : Color.primary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(browser.isTransferring)
                    .onDrop(of: [RemoteDragItem.pasteboardType.rawValue], delegate:
                        RemoteStorageDropDelegate(manager: manager, device: device, storageID: storage.id,
                            directory: "/", navigate: { Task { await manager.navigateForDrop(to: device, storageID: storage.id, directory: "/") } },
                            onTargetChanged: { targetedStorage = $0 ? storage.id : nil }))
                    .overlay {
                        if targetedStorage == storage.id {
                            RoundedRectangle(cornerRadius: 7).stroke(Color.accentColor, lineWidth: 2).allowsHitTesting(false)
                        }
                    }
                }
            }
            if let transfer = browser.remoteTransfer {
                RemoteTransferStatusView(transfer: transfer, compact: true)
            } else { SidebarTransferView(coordinator: browser.transfers) }
            if let status = browser.binStatus {
                Text(status).font(.caption).lineLimit(2)
            }
            if browser.operationError != nil || browser.transferConfirmation != nil {
                Button(action: select) {
                    Label(browser.operationError != nil ? "View error" : "View transfer results",
                          systemImage: browser.operationError != nil ? "exclamationmark.circle" : "checkmark.circle")
                }.buttonStyle(.link).font(.caption)
            }
        }
        .padding(10)
        .background(isSelected ? Color.primary.opacity(0.045) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
        .sheet(isPresented: $renaming) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Name this device").font(.headline)
                Text(device.modelName).foregroundStyle(.secondary)
                TextField("Device nickname", text: $draftName)
                    .onSubmit(saveName)
                Text(device.persistenceKey == nil
                    ? "No unique device identifier is available yet. This name will apply for this USB connection; connecting may allow Piko to remember it."
                    : "Saved on this Mac. The device’s own name stays the same. Leave empty to use its model name.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Cancel") { renaming = false }.keyboardShortcut(.cancelAction)
                    Button("Save", action: saveName).keyboardShortcut(.defaultAction)
                }
            }.padding(24).frame(width: 360)
        }
    }

    private func saveName() { device.rename(draftName); renaming = false }
    private var statusColor: Color {
        if !device.isAvailable { return .secondary }
        switch browser.state {
        case .connected: return browser.browsingIssue == nil ? .green : .orange
        case .failed, .reconnectRequired: return .orange
        default: return .secondary
        }
    }
    private var statusText: String {
        if !device.isAvailable { return "USB disconnected" }
        switch browser.state {
        case .connected:
            if browser.browsingIssue != nil { return "Browsing needs attention" }
            return browser.uploadNeedsReconnect ? "Inspect upload" : "Connected"
        case .connecting: return "Connecting…"
        case .disconnecting: return "Disconnecting…"
        case .recovering: return "Restoring connection…"
        case .failed, .reconnectRequired: return "Connection needs attention"
        case .disconnected: return "Available via USB"
        }
    }
}

private struct SidebarTransferView: View {
    @ObservedObject var coordinator: TransferCoordinator
    var body: some View {
        if coordinator.isRunning {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(coordinator.isPlanning ? "Preparing…" : coordinator.isUploading ? "Uploading…" : "Downloading…")
                    Spacer()
                    Button(coordinator.stopRequested ? "Stopping…" :
                           (coordinator.canCancelActiveTransfer || coordinator.isPlanning ? "Cancel" : "Stop")) {
                        coordinator.cancelTransfer()
                    }
                        .buttonStyle(.link).disabled(coordinator.stopRequested)
                        .help(coordinator.canCancelActiveTransfer || coordinator.isPlanning
                            ? "Cancel this device’s transfer" : "Stop after the current file finishes")
                }.font(.caption)
                if let progress = coordinator.progress, let total = progress.totalBytes, total > 0 {
                    ProgressView(value: Double(min(progress.bytesTransferred, total)), total: Double(total))
                } else { ProgressView().controlSize(.small) }
            }
        }
    }
}

extension MTPStorage {
    var availableSpaceLabel: String {
        guard info.freeSpaceInBytes != UInt64.max, info.freeSpaceInBytes <= UInt64(Int64.max) else {
            return "Available space unknown"
        }
        return ByteCountFormatter.string(fromByteCount: Int64(info.freeSpaceInBytes), countStyle: .file) + " available"
    }
}
