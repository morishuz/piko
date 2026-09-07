import AppKit
import SwiftUI

struct RemoteDragItem: Codable, Equatable {
    static let pasteboardType = NSPasteboard.PasteboardType("com.piko.mac.remote-item")
    let browserID: UUID
    let handle: UInt32
}

/// Accepts only our current browser's remote-item tokens, never Finder files.
struct BinButton: NSViewRepresentable {
    let enabled: Bool
    let dropEnabled: Bool
    let count: Int?
    let help: String
    let open: () -> Void
    let accepts: ([RemoteDragItem]) -> Bool
    let drop: ([RemoteDragItem]) -> Void

    func makeNSView(context: Context) -> ButtonContainer { ButtonContainer() }

    func updateNSView(_ view: ButtonContainer, context: Context) {
        view.toolTip = help
        view.button.toolTip = help
        view.button.isEnabled = enabled
        view.button.contentTintColor = enabled ? .secondaryLabelColor : .disabledControlTextColor
        view.setCount(count)
        view.button.setAccessibilityLabel(count.map { "Bin, \($0) items" } ?? "Bin, contents not verified")
        view.button.open = open
        view.dropEnabled = dropEnabled
        view.accepts = accepts
        view.drop = drop
    }

    /// Both clicks and drops obey preparation state; the badge is never a hit target.
    final class ButtonContainer: NSView {
        let button = DropButton()
        let badge = NSTextField(labelWithString: "")
        let hoverLabel = NSTextField(labelWithString: "Move to Bin")
        var dropEnabled = false
        var accepts: (([RemoteDragItem]) -> Bool)?
        var drop: (([RemoteDragItem]) -> Void)?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            button.bezelStyle = .texturedRounded
            button.isBordered = false
            button.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Open Bin")
            button.imagePosition = .imageOnly
            button.setAccessibilityLabel("Bin")
            button.target = button
            button.action = #selector(DropButton.clicked)
            button.translatesAutoresizingMaskIntoConstraints = false
            addSubview(button)
            NSLayoutConstraint.activate([
                button.leadingAnchor.constraint(equalTo: leadingAnchor),
                button.trailingAnchor.constraint(equalTo: trailingAnchor),
                button.topAnchor.constraint(equalTo: topAnchor),
                button.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            wantsLayer = true
            layer?.cornerRadius = 9
            badge.font = .systemFont(ofSize: 10, weight: .semibold)
            badge.textColor = .white
            badge.alignment = .center
            badge.wantsLayer = true
            badge.layer?.backgroundColor = NSColor.systemBlue.cgColor
            badge.layer?.cornerRadius = 8
            badge.isHidden = true
            badge.setAccessibilityElement(false)
            addSubview(badge)
            hoverLabel.font = .systemFont(ofSize: 10, weight: .medium)
            hoverLabel.textColor = .controlAccentColor
            hoverLabel.alignment = .center
            hoverLabel.isHidden = true
            hoverLabel.setAccessibilityElement(false)
            addSubview(hoverLabel)
            registerForDraggedTypes([RemoteDragItem.pasteboardType])
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard super.hitTest(point) != nil else { return nil }
            return button
        }
        override func layout() {
            super.layout()
            let width = max(16, badge.intrinsicContentSize.width + 7)
            badge.frame = NSRect(x: bounds.maxX - width, y: bounds.maxY - 16, width: width, height: 16)
            hoverLabel.frame = NSRect(x: -12, y: -10, width: bounds.width + 24, height: 14)
        }
        func setCount(_ count: Int?) {
            badge.stringValue = count.map { $0 > 99 ? "99+" : String($0) } ?? ""
            badge.isHidden = count == nil || count == 0
            needsLayout = true
        }
        private func highlightDrop(_ active: Bool) {
            layer?.backgroundColor = active ? NSColor.controlAccentColor.withAlphaComponent(0.14).cgColor : nil
            button.contentTintColor = active ? .controlAccentColor : button.isEnabled ? .secondaryLabelColor : .disabledControlTextColor
            hoverLabel.isHidden = !active
        }
        private func items(_ sender: NSDraggingInfo) -> [RemoteDragItem] {
            let raw = sender.draggingPasteboard.pasteboardItems ?? []
            let decoded = raw.compactMap { item -> RemoteDragItem? in
                guard let data = item.data(forType: RemoteDragItem.pasteboardType), data.count < 1024 else { return nil }
                return try? JSONDecoder().decode(RemoteDragItem.self, from: data)
            }
            return decoded.count == raw.count ? decoded : []
        }
        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            let accepted = dropEnabled && accepts?(items(sender)) == true
            highlightDrop(accepted)
            return accepted ? .move : []
        }
        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
        override func draggingExited(_ sender: NSDraggingInfo?) { highlightDrop(false) }
        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            highlightDrop(false)
            let selection = items(sender)
            guard dropEnabled, accepts?(selection) == true else { return false }
            // End AppKit drag IPC before presenting confirmation.
            DispatchQueue.main.async { [weak self] in self?.drop?(selection) }
            return true
        }
    }

    final class DropButton: NSButton {
        var open: (() -> Void)?
        @objc func clicked() { if isEnabled { open?() } }
    }
}
