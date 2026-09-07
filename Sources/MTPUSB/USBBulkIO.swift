import Foundation
import MTPWire

public enum USBError: LocalizedError, Equatable, DiagnosticError {
    case noCandidate
    case ambiguousCandidates([String])
    case targetNotFound
    case status(Int32, transferred: Int)
    case invalidTransfer, shortWrite, closed, busy
    public var diagnosticFailure: DiagnosticFailure {
        switch self {
        case .noCandidate: .noCandidate
        case .ambiguousCandidates: .ambiguousCandidates
        case .targetNotFound: .targetNotFound
        case .status: .usbStatus
        case .invalidTransfer: .invalidTransfer
        case .shortWrite: .shortWrite
        case .closed: .disconnected
        case .busy: .busy
        }
    }
    public var errorDescription: String? {
        switch self {
        case .noCandidate:
            return
                "No supported USB MTP interface found. Unlock the device and select file-transfer mode."
        case .ambiguousCandidates(let candidates):
            return
                "Several USB interfaces match. Disconnect other devices, or explicitly select one: \(candidates.joined(separator: ", "))."
        case .targetNotFound:
            return
                "The selected USB interface is no longer available. Enumerate again after reconnecting."
        case .status(let code, let transferred):
            let reason: String
            switch code {
            case -3: reason = "USB access denied. Another app or macOS camera service may be using the device. Close Photos and Image Capture, then reconnect the camera"
            case -4: reason = "USB device disconnected"
            case -6: reason = "USB interface is busy; quit other MTP/photo applications"
            case -7: reason = "USB transfer timed out"
            case -8: reason = "USB receive overflow"
            case -9: reason = "USB endpoint stalled"
            default: reason = "USB operation failed"
            }
            return
                "\(reason) (\(code), \(transferred) bytes transferred). Reconnect before retrying; no automatic replay."
        case .invalidTransfer: return "Invalid USB transfer size or result."
        case .shortWrite: return "The USB command was only partially sent. Reconnect before retrying."
        case .closed: return "The USB interface is closed."
        case .busy: return "USB I/O is already in progress."
        }
    }
}

struct USBTransfer: Sendable {
    let status: Int32
    let transferred: Int
    let data: Data
}

/// Injectable USB packet I/O; error cleanup only closes the selected interface.
protocol USBBulkIO: Sendable {
    var inputPacketSize: Int { get }
    var outputPacketSize: Int { get }
    var transferTimeoutMilliseconds: UInt64 { get }
    func receive(length: Int) async -> USBTransfer
    func send(_ data: Data) async -> USBTransfer
    func close() async
}

extension USBBulkIO {
    var transferTimeoutMilliseconds: UInt64 { 0 }
}

/// Optional, interface-scoped MTP control channel for cancellation and responder
/// recovery. It never resets the USB device or a neighbouring interface.
protocol USBMTPControlIO: USBBulkIO {
    func mtpControl(request: UInt8, data: Data, inputLength: Int) async -> USBTransfer
    func receiveForCancellation(length: Int) async -> USBTransfer
}
