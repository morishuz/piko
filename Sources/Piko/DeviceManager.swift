import Combine
import CryptoKit
import Foundation
import MTPUSB
import MTPWire

struct MTPDeviceDetails: Equatable, Codable, Sendable {
    let manufacturer: String
    let model: String
    let firmware: String
    let serialNumber: String
}

/// USB discovery reads registry properties only; it does not claim an interface.
struct DiscoveredDevice: Identifiable, Equatable, Sendable {
    let id: String
    let target: UInt64?
    let vendor: UInt16
    let product: UInt16
    let name: String
    let manufacturer: String
    let serialNumber: String

    var persistenceKey: String? {
        Self.identity(vendor: vendor, product: product, serial: serialNumber)
    }

    // Product IDs may change when a phone unlocks or changes USB mode. Serial
    // identity reconciles sidebar rows; registry IDs still own live sessions.
    var reconnectionKey: String? { Self.identity(vendor: vendor, product: 0, serial: serialNumber) }

    static func identity(vendor: UInt16, product: UInt16, serial: String) -> String? {
        let serial = serial.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !serial.isEmpty, !serial.allSatisfy({ $0 == "0" }), serial.lowercased() != "unknown" else { return nil }
        return SHA256.hash(data: Data("\(vendor):\(product):\(serial)".utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    init(id: String, target: UInt64? = nil, vendor: UInt16 = 0, product: UInt16 = 0,
         name: String, manufacturer: String = "", serialNumber: String = "") {
        self.id = id
        self.target = target
        self.vendor = vendor
        self.product = product
        self.name = name
        self.manufacturer = manufacturer
        self.serialNumber = serialNumber
    }

    init(_ candidate: AppleUSBCandidate) {
        self.init(id: String(candidate.registryID), target: candidate.registryID,
                  vendor: candidate.vendor, product: candidate.product,
                  name: candidate.productName ?? "USB device \(String(format: "%04X:%04X", candidate.vendor, candidate.product))",
                  manufacturer: candidate.manufacturer ?? "", serialNumber: candidate.serialNumber ?? "")
    }
}

@MainActor
final class DevicePreferences {
    private struct Record: Codable {
        var nickname: String?
        var details: MTPDeviceDetails?
    }
    private let defaults: UserDefaults
    private let key = "mtpDeviceNames.v1"
    private var records: [String: Record]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        records = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([String: Record].self, from: $0) } ?? [:]
    }

    func nickname(for key: String?) -> String? { key.flatMap { records[$0]?.nickname } }
    func details(for key: String?) -> MTPDeviceDetails? { key.flatMap { records[$0]?.details } }
    func save(key: String?, nickname: String?, details: MTPDeviceDetails?) {
        guard let key else { return }
        // Keep serials out of preferences; the key is a hash, and diagnostics
        // receive neither this key nor the user-visible names.
        let cached = details.map { MTPDeviceDetails(manufacturer: $0.manufacturer,
            model: $0.model, firmware: $0.firmware, serialNumber: "") }
        records[key] = Record(nickname: nickname, details: cached)
        if let data = try? JSONEncoder().encode(records) { defaults.set(data, forKey: self.key) }
    }
}

@MainActor
final class ManagedDevice: ObservableObject, Identifiable {
    let descriptor: DiscoveredDevice
    let browser: DeviceBrowserModel
    nonisolated var id: String { descriptor.id }
    @Published private(set) var nickname: String?
    @Published private(set) var details: MTPDeviceDetails?
    @Published private(set) var isAvailable = true
    private let preferences: DevicePreferences
    private var observation: AnyCancellable?
    private var removal: Task<Void, Never>?

    init(descriptor: DiscoveredDevice, browser: DeviceBrowserModel, preferences: DevicePreferences) {
        self.descriptor = descriptor
        self.browser = browser
        self.preferences = preferences
        nickname = preferences.nickname(for: descriptor.persistenceKey)
        details = preferences.details(for: descriptor.persistenceKey)
        observation = browser.$deviceDetails.sink { [weak self] details in
            guard let self, let details else { return }
            self.details = details
            if self.nickname == nil { self.nickname = preferences.nickname(for: self.persistenceKey) }
            preferences.save(key: self.persistenceKey, nickname: self.nickname, details: details)
        }
    }

    var persistenceKey: String? {
        descriptor.persistenceKey ?? details.flatMap {
            DiscoveredDevice.identity(vendor: descriptor.vendor, product: descriptor.product, serial: $0.serialNumber)
        }
    }
    var reconnectionKey: String? {
        descriptor.reconnectionKey ?? details.flatMap {
            DiscoveredDevice.identity(vendor: descriptor.vendor, product: 0, serial: $0.serialNumber)
        }
    }
    var removalComplete: Bool { !isAvailable && removal == nil }

    var modelName: String {
        guard let model = details?.model.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty
        else { return descriptor.name }
        let manufacturer = details?.manufacturer.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return manufacturer.isEmpty || model.localizedCaseInsensitiveContains(manufacturer)
            ? model : "\(manufacturer) \(model)"
    }
    var displayName: String { nickname ?? modelName }
    var symbol: String {
        let name = "\(modelName) \(descriptor.manufacturer)".lowercased()
        if ["gopro", "camera", "nikon", "canon", "fujifilm", "olympus"].contains(where: name.contains) { return "camera" }
        if ["phone", "android", "pixel", "galaxy", "motorola"].contains(where: name.contains) { return "smartphone" }
        return "externaldrive.connected.to.line.below"
    }
    func rename(_ value: String) {
        let clean = String(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        nickname = clean.isEmpty ? nil : String(clean.prefix(64))
        preferences.save(key: persistenceKey, nickname: nickname, details: details)
    }
    func markRemoved() {
        guard isAvailable else { return }
        isAvailable = false
        browser.markDeviceUnavailable()
        removal = Task {
            await browser.deviceWasRemoved()
            removal = nil
        }
    }
}

@MainActor
final class DeviceManager: ObservableObject {
    typealias Discover = @Sendable () async throws -> [DiscoveredDevice]
    typealias MakeBackend = @MainActor (DiscoveredDevice, DiagnosticLog?) -> any MTPBackend
    @Published var dropHint: String?
    var pendingTransferDevices: Set<String> = []
    var navigationHover: (key: String, directory: String)?
    var dragSelection: RemoteDragSelection?
    let springNavigation = SpringLoadedNavigation()
    @Published private(set) var devices: [ManagedDevice] = []
    @Published var selectedDeviceID: String?
    @Published private(set) var discoveryError: String?
    @Published private(set) var isScanning = false
    @Published private(set) var isQuitting = false
    private let discover: Discover
    private let makeBackend: MakeBackend
    private let preferences: DevicePreferences
    private let diagnostics: DiagnosticLog?

    init(preferences: DevicePreferences = DevicePreferences(),
         diagnostics: DiagnosticLog? = nil, discover: @escaping Discover, makeBackend: @escaping MakeBackend) {
        self.preferences = preferences
        self.diagnostics = diagnostics
        self.discover = discover
        self.makeBackend = makeBackend
    }

    convenience init(diagnostics: DiagnosticLog?) {
        self.init(diagnostics: diagnostics,
            discover: { try await USBTransport.discoverApple().map(DiscoveredDevice.init) },
            makeBackend: { descriptor, deviceLog in
                SwiftMTPBackend(canCancelActiveTransfer: true, diagnostics: deviceLog) {
                    try await USBTransport.openApple(target: descriptor.target, diagnostics: deviceLog)
                }
            })
    }

    var selectedDevice: ManagedDevice? { devices.first { $0.id == selectedDeviceID } }
    var hasActiveOperations: Bool { devices.contains { $0.browser.isBusy } }

    func select(_ device: ManagedDevice, storage: UInt32? = nil) {
        guard !isQuitting, devices.contains(where: { $0 === device }) else { return }
        selectedDeviceID = device.id
        if let storage, device.isAvailable { device.browser.selectStorage(storage) }
    }

    func scan() async {
        guard !isScanning, !isQuitting else { return }
        isScanning = true
        defer { isScanning = false }
        do {
            let found = try await discover()
            guard !isQuitting, !Task.isCancelled else { return }
            reconcile(found)
            discoveryError = nil
        } catch is CancellationError {} catch { discoveryError = error.localizedDescription }
    }

    // A replug gets a new registry ID and a fresh browser/backend. Never migrate
    // session-local handles, transfer callbacks or a transport factory to it.
    func reconcile(_ found: [DiscoveredDevice]) {
        let ids = Set(found.map(\.id))
        for device in devices where !ids.contains(device.id) { device.markRemoved() }
        for descriptor in found {
            if devices.contains(where: { $0.id == descriptor.id && $0.isAvailable }) { continue }
            let key = descriptor.reconnectionKey
            // Never collapse two simultaneously present devices with duplicated
            // or missing serials. Model names are not device identities.
            let uniqueIdentity = key != nil && found.filter { $0.reconnectionKey == key }.count == 1
            let retired = devices.filter {
                !$0.isAvailable && ($0.id == descriptor.id || uniqueIdentity && $0.reconnectionKey == key)
            }
            // Wait for transfers and USB cleanup before replacing the row.
            guard retired.allSatisfy(\.removalComplete) else { continue }
            let deviceLog = diagnostics?.forDevice()
            let browser = DeviceBrowserModel(client: makeBackend(descriptor, deviceLog), diagnostics: deviceLog, discoveredDevice: descriptor)
            let replacement = ManagedDevice(descriptor: descriptor, browser: browser, preferences: preferences)
            if let nickname = retired.compactMap(\.nickname).first { replacement.rename(nickname) }
            let errors = retired.compactMap { $0.browser.operationError }
            let results = retired.compactMap { $0.browser.transferConfirmation }
            browser.operationError = errors.isEmpty ? nil : errors.joined(separator: "\n\n")
            browser.transferConfirmation = results.isEmpty ? nil : results.joined(separator: "\n\n")
            if retired.contains(where: { $0.id == selectedDeviceID }) { selectedDeviceID = replacement.id }
            devices.removeAll { device in retired.contains { $0 === device } }
            devices.append(replacement)
        }
        let available = devices.filter(\.isAvailable)
        if selectedDevice == nil || (selectedDevice?.isAvailable == false && selectedDevice?.browser.isBusy == false) {
            selectedDeviceID = available.first?.id ?? selectedDeviceID
        }
        // Preserve unavailable rows with pending results so background failures
        // remain reachable. Otherwise discard them once cleanup finishes.
        devices.removeAll { $0.removalComplete && !$0.browser.isBusy && $0.browser.state == .disconnected
            && $0.id != selectedDeviceID && $0.browser.operationError == nil && $0.browser.transferConfirmation == nil }
    }

    func monitor() async {
        while !Task.isCancelled && !isQuitting {
            await scan()
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
        }
    }

    func prepareToQuit() async {
        endRemoteDrag()
        isQuitting = true
        // Begin cancellation on every device before waiting for any one of them.
        let tasks = devices.map { device in Task { await device.browser.prepareToQuit() } }
        for task in tasks { await task.value }
    }
}
