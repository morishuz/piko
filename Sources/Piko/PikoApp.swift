import AppKit
import SwiftUI

@MainActor
final class PikoApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var diagnostics: AppDiagnostics?
    weak var manager: DeviceManager?
    private var waitingToQuit = false
    private var orderlyShutdown = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let manager else { return .terminateNow }
        if manager.hasActiveOperations || waitingToQuit {
            let alert = NSAlert()
            alert.messageText = waitingToQuit ? "Still finishing the device operation" : "A device operation is still running"
            let active = manager.devices.map(\.browser).filter(\.isBusy)
            let canCancel = !active.isEmpty && active.allSatisfy { $0.transfers.isRunning && $0.transfers.canCancelActiveTransfer }
            alert.informativeText = canCancel
                ? "Piko will finish the current small part, clean up an incomplete upload and close all device connections before quitting. Quit Now bypasses cleanup and may require unplugging the device."
                : "A safe quit finishes the current operation and closes every device session. Quitting immediately can leave the phone sending file data; unplug and reconnect its USB cable before using Piko again. An interrupted upload or move may need inspection on the device."
            alert.addButton(withTitle: waitingToQuit ? "Keep Waiting" : (canCancel ? "Cancel Transfer and Quit" : "Stop After Current Operation and Quit"))
            alert.addButton(withTitle: "Quit Now")
            if !waitingToQuit { alert.addButton(withTitle: "Keep App Open") }
            let choice = alert.runModal()
            if choice == .alertSecondButtonReturn { return .terminateNow }
            if choice != .alertFirstButtonReturn { return .terminateCancel }
        }
        guard !waitingToQuit else { return .terminateLater }
        waitingToQuit = true
        Task {
            await manager.prepareToQuit()
            orderlyShutdown = true
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        diagnostics?.finishShutdown(clean: orderlyShutdown)
    }
}

@main
struct PikoApp: App {
    @NSApplicationDelegateAdaptor(PikoApplicationDelegate.self) private var appDelegate
    @StateObject private var manager: DeviceManager
    private let diagnostics: AppDiagnostics

    init() {
        let diagnostics = AppDiagnostics()
        self.diagnostics = diagnostics
        let manager = DeviceManager(diagnostics: diagnostics.log)
        _manager = StateObject(wrappedValue: manager)
        appDelegate.manager = manager
        appDelegate.diagnostics = diagnostics
    }

    var body: some Scene {
        WindowGroup {
            ContentView(manager: manager)
                .disabled(manager.isQuitting)
                .frame(minWidth: 880, minHeight: 500)
                .navigationTitle(
                    "Piko \(diagnostics.buildIdentity.version) (\(diagnostics.buildIdentity.build))")
        }
        .defaultSize(width: 1060, height: 650)

        Settings {
            SettingsView(diagnostics: diagnostics)
        }
    }
}

private struct SettingsView: View {
    @ObservedObject var diagnostics: AppDiagnostics

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Diagnostics").font(.headline)
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Record diagnostics", isOn: Binding(
                    get: { diagnostics.isRecording }, set: { diagnostics.requestRecording($0) }))
                Toggle("Include filenames and folder paths", isOn: Binding(
                    get: { diagnostics.recordsFileDetails }, set: { diagnostics.requestFileDetails($0) }))
                    .disabled(!diagnostics.isRecording)
            }
            Text("Logs stay on this Mac. Nothing is sent.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Export Diagnostics…") { diagnostics.exportReport() }
                Button("Delete Diagnostics") { diagnostics.clearDiagnostics() }
            }
        }
        .padding(24)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }
}
