import Foundation
import IOKit
import IOUSBHost
import MTPWire

public struct AppleUSBCandidate: Sendable {
    public let registryID: UInt64
    public let vendor: UInt16
    public let product: UInt16
    public let manufacturer: String?
    public let productName: String?
    public let serialNumber: String?
    let interfaceNumber: UInt8
    let vendorSpecific: Bool
}

extension USBTransport {
    public static func discoverApple(diagnostics: DiagnosticLog? = nil) async throws -> [AppleUSBCandidate] {
        try await AppleUSBDevice.discover(diagnostics: diagnostics)
    }

    public static func openApple(target: UInt64? = nil, diagnostics: DiagnosticLog? = nil) async throws -> USBTransport {
        try await opening(diagnostics: diagnostics) { id in
            try await AppleUSBDevice.open(target: target, diagnostics: diagnostics, transportID: id)
        }
    }
}

/// All IOUSBHost operations and handle destruction run on one private serial
/// queue, never the main thread or Swift's cooperative executor. Synchronous
/// I/O is bounded to 15s; cancellation runs at completed chunk boundaries.
/// No device object, capture, configuration changes, USB reset or driver detach.
final class AppleUSBDevice: USBMTPControlIO, @unchecked Sendable {
    let inputPacketSize: Int
    let outputPacketSize: Int
    let transferTimeoutMilliseconds: UInt64 = 15_000
    private let queue: DispatchQueue
    private let interfaceNumber: UInt16
    private let host: IOUSBHostInterface
    private let input: IOUSBHostPipe
    private let output: IOUSBHostPipe
    private var closed = false // queue-confined
    private let diagnostics: DiagnosticLog?
    private let transportID: UInt64?

    private init(service: io_service_t, candidate: AppleUSBCandidate, queue: DispatchQueue,
                 diagnostics: DiagnosticLog?, transportID: UInt64?) throws {
        self.interfaceNumber = UInt16(candidate.interfaceNumber)
        self.queue = queue
        self.diagnostics = diagnostics
        self.transportID = transportID
        // Keep Apple's event-service queue separate from our blocking I/O queue.
        let interface = try IOUSBHostInterface(__ioService: service, options: [], queue: nil, interestHandler: nil)
        do {
            let descriptor = interface.interfaceDescriptor.pointee
            guard descriptor.bInterfaceNumber == candidate.interfaceNumber,
                  descriptor.bAlternateSetting == 0 else { throw USBError.invalidTransfer }
            let config = interface.configurationDescriptor
            let length = Int(UInt16(littleEndian: config.pointee.wTotalLength))
            guard length >= 9, length <= 65535 else { throw USBError.invalidTransfer }
            let endpoints = try AppleUSBEndpoints.parse(Data(bytes: config, count: length),
                interfaceNumber: candidate.interfaceNumber, vendorSpecific: candidate.vendorSpecific)
            input = try interface.copyPipe(withAddress: Int(endpoints.input))
            output = try interface.copyPipe(withAddress: Int(endpoints.output))
            inputPacketSize = endpoints.inputPacketSize
            outputPacketSize = endpoints.outputPacketSize
            host = interface
        } catch {
            interface.destroy()
            throw error
        }
    }

    deinit {
        // Queued operations retain self, so none can still be running here.
        // Normal close already destroyed the interface; do not destroy it twice.
        guard !closed else { return }
        // Normal close is queued and awaited. Unexpected owner disposal also
        // releases the interface on its queue, without retaining self.
        let owned = InterfaceRelease(host: host)
        queue.async { owned.host.destroy() }
    }

    // Transfers an otherwise queue-confined reference solely for final cleanup.
    private struct InterfaceRelease: @unchecked Sendable { let host: IOUSBHostInterface }

    static func discover(diagnostics: DiagnosticLog?) async throws -> [AppleUSBCandidate] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try candidates(diagnostics: diagnostics, transportID: nil) })
            }
        }
    }

    static func open(target: UInt64?, diagnostics: DiagnosticLog?, transportID: UInt64?) async throws -> AppleUSBDevice {
        try await withCheckedThrowingContinuation { continuation in
            let queue = DispatchQueue(label: "Piko.apple-usb.io")
            queue.async {
                let started = DiagnosticLog.start()
                var attemptedOpen = false
                do {
                    let all = try candidates(diagnostics: diagnostics, transportID: transportID)
                    let matching = target.map { id in all.filter { $0.registryID == id } } ?? all
                    guard !matching.isEmpty else { throw target == nil ? USBError.noCandidate : USBError.targetNotFound }
                    guard matching.count == 1 else { throw USBError.ambiguousCandidates(matching.map { String($0.registryID) }) }
                    let candidate = matching[0]
                    let service = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(candidate.registryID))
                    guard service != 0 else { throw USBError.status(-4, transferred: 0) }
                    defer { IOObjectRelease(service) }
                    attemptedOpen = true
                    diagnostics?.record(.usbOpenAttempt, phase: .command, transportID: transportID,
                                        usbVendor: candidate.vendor, usbProduct: candidate.product)
                    let device = try AppleUSBDevice(service: service, candidate: candidate, queue: queue,
                                                    diagnostics: diagnostics, transportID: transportID)
                    diagnostics?.record(.usbOpenAttempt, phase: .complete, transportID: transportID)
                    diagnostics?.record(.usbOpen, since: started, transportID: transportID,
                                        usbVendor: candidate.vendor, usbProduct: candidate.product,
                                        usbInterface: candidate.interfaceNumber,
                                        usbInputPacketSize: device.inputPacketSize, usbOutputPacketSize: device.outputPacketSize)
                    continuation.resume(returning: device)
                } catch {
                    let mapped = mapError(error, diagnostics: diagnostics, transportID: transportID)
                    if attemptedOpen {
                        diagnostics?.record(.usbOpenAttempt, failure: .classify(mapped), phase: .complete,
                                            transportID: transportID)
                    }
                    diagnostics?.record(.usbOpen, since: started, failure: .classify(mapped), transportID: transportID)
                    continuation.resume(throwing: mapped)
                }
            }
        }
    }

    private static func property(_ service: io_service_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func candidates(diagnostics: DiagnosticLog?, transportID: UInt64?) throws -> [AppleUSBCandidate] {
        diagnostics?.record(.appleUSBDiscovery, phase: .command, transportID: transportID)
        var iterator: io_iterator_t = 0
        let status = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostInterface"), &iterator)
        guard status == KERN_SUCCESS else { throw NSError(domain: NSMachErrorDomain, code: Int(status)) }
        defer { IOObjectRelease(iterator) }
        var result: [AppleUSBCandidate] = []
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }
            func number(_ key: String) -> Int { (property(service, key) as? NSNumber)?.intValue ?? -1 }
            let cls = number("bInterfaceClass"), sub = number("bInterfaceSubClass"), proto = number("bInterfaceProtocol")
            var name = property(service, "USB Interface Name") as? String
            if name == nil {
                var registryName = [CChar](repeating: 0, count: 128)
                if IORegistryEntryGetName(service, &registryName) == KERN_SUCCESS {
                    name = String(decoding: registryName.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                }
            }
            guard AppleUSBEndpoints.accepts(interfaceClass: cls, subclass: sub, protocolCode: proto, name: name),
                  let interface = UInt8(exactly: number("bInterfaceNumber")) else { continue }
            var id: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS else { continue }
            func inheritedNumber(_ key: String) -> UInt16 {
                let value = IORegistryEntrySearchCFProperty(service, kIOServicePlane, key as CFString,
                    kCFAllocatorDefault, IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
                return UInt16(exactly: (value as? NSNumber)?.intValue ?? -1) ?? 0
            }
            func inheritedString(_ key: String) -> String? {
                let value = IORegistryEntrySearchCFProperty(service, kIOServicePlane, key as CFString,
                    kCFAllocatorDefault, IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
                guard let text = value as? String else { return nil }
                let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return clean.isEmpty ? nil : String(clean.prefix(256))
            }
            result.append(AppleUSBCandidate(registryID: id, vendor: inheritedNumber("idVendor"),
                product: inheritedNumber("idProduct"),
                manufacturer: inheritedString("USB Vendor Name"),
                productName: inheritedString("USB Product Name"),
                serialNumber: inheritedString("USB Serial Number"), interfaceNumber: interface, vendorSpecific: cls == 255))
            guard result.count <= 128 else { throw USBError.invalidTransfer }
        }
        diagnostics?.record(.appleUSBDiscovery, phase: .complete, transportID: transportID,
                            discoveryValue: UInt32(result.count))
        return result
    }

    private static func mapError(_ error: Error, diagnostics: DiagnosticLog?, transportID: UInt64?) -> USBError {
        if let error = error as? USBError { return error }
        let raw = Int32(truncatingIfNeeded: (error as NSError).code)
        diagnostics?.record(.appleUSBError, usbStatus: raw, failure: .usbStatus, transportID: transportID)
        // Normalize for the shared transport/session policy. Raw IOReturn is
        // retained separately; unknown Apple errors are never guessed away.
        let status: Int32
        switch raw {
        case kIOReturnNoDevice, kIOReturnNotAttached: status = -4
        case kIOReturnExclusiveAccess, kIOReturnBusy: status = -6
        case kIOReturnNotPermitted, kIOReturnNotPrivileged: status = -3
        case kIOReturnTimeout, Int32(bitPattern: 0xe0004051): status = -7
        case Int32(bitPattern: 0xe000404f), Int32(bitPattern: 0xe0005000): status = -9
        case kIOReturnAborted: status = -10
        default: status = -99
        }
        return .status(status, transferred: 0)
    }

    func receive(length: Int) async -> USBTransfer { await transfer(Data(count: length), input: true) }
    func send(_ data: Data) async -> USBTransfer { await transfer(data, input: false) }
    private func transfer(_ data: Data, input reading: Bool, timeout: TimeInterval = 15) async -> USBTransfer {
        await withCheckedContinuation { continuation in
            queue.async {
                guard !self.closed else {
                    continuation.resume(returning: USBTransfer(status: -4, transferred: 0, data: Data()))
                    return
                }
                let buffer = NSMutableData(data: data)
                var count = 0
                var status: Int32 = 0
                do {
                    try (reading ? self.input : self.output).__sendIORequest(
                        with: buffer, bytesTransferred: &count, completionTimeout: timeout)
                } catch {
                    if case .status(let code, _) = Self.mapError(error, diagnostics: self.diagnostics, transportID: self.transportID) { status = code }
                }
                guard count >= 0, count <= data.count else {
                    continuation.resume(returning: USBTransfer(status: -99, transferred: 0, data: Data()))
                    return
                }
                continuation.resume(returning: USBTransfer(status: status, transferred: count,
                    data: reading ? Data(bytes: buffer.bytes, count: count) : Data()))
            }
        }
    }

    func receiveForCancellation(length: Int) async -> USBTransfer {
        await transfer(Data(count: length), input: true, timeout: 0.1)
    }

    func mtpControl(request: UInt8, data: Data, inputLength: Int) async -> USBTransfer {
        await withCheckedContinuation { continuation in
            queue.async {
                guard !self.closed else {
                    continuation.resume(returning: USBTransfer(status: -4, transferred: 0, data: Data()))
                    return
                }
                let reading = inputLength > 0
                let buffer = NSMutableData(data: reading ? Data(count: inputLength) : data)
                let request = IOUSBDeviceRequest(bmRequestType: reading ? 0xA1 : 0x21,
                    bRequest: request, wValue: 0, wIndex: self.interfaceNumber,
                    wLength: UInt16(buffer.length))
                var count = 0
                var status: Int32 = 0
                do {
                    try self.host.__send(request, data: buffer,
                        bytesTransferred: &count, completionTimeout: 1)
                } catch {
                    if case .status(let code, _) = Self.mapError(error,
                        diagnostics: self.diagnostics, transportID: self.transportID) { status = code }
                }
                guard count >= 0, count <= buffer.length else {
                    continuation.resume(returning: USBTransfer(status: -99, transferred: 0, data: Data()))
                    return
                }
                continuation.resume(returning: USBTransfer(status: status, transferred: count,
                    data: reading ? Data(bytes: buffer.bytes, count: count) : Data()))
            }
        }
    }

    func close() async {
        await withCheckedContinuation { continuation in
            queue.async {
                if !self.closed { self.host.destroy(); self.closed = true }
                continuation.resume()
            }
        }
    }
}
