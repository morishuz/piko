import Foundation

public enum WireError: LocalizedError, Equatable, Sendable {
    case truncated, invalidLength, invalidType, invalidString, sizeLimit
    case unexpectedTransaction, unexpectedContainer, objectSizeMismatch
    case streamingWriteUnsupported
    case response(UInt16)
    case disconnected, busy, sessionRequired, sessionAlreadyOpen, transactionExhausted

    public var errorDescription: String? {
        switch self {
        case .truncated: "The device response ended early. Reconnect before retrying."
        case .invalidLength, .invalidType, .invalidString:
            "The device returned malformed MTP data. Reconnect before retrying."
        case .sizeLimit: "This transfer exceeds the supported file size."
        case .unexpectedTransaction, .unexpectedContainer:
            "The MTP response did not match the current transaction. Reconnect before retrying."
        case .objectSizeMismatch: "The transfer size does not match the object's metadata."
        case .streamingWriteUnsupported:
            "This USB transport cannot stream an outbound MTP object safely."
        case .response(let code): "The device rejected the MTP operation (\(String(format: "0x%04x", code)))."
        case .disconnected: "The MTP session is disconnected. Reconnect before retrying."
        case .busy: "An MTP transaction is already in progress."
        case .sessionRequired: "An open MTP session is required."
        case .sessionAlreadyOpen: "The MTP session is already open."
        case .transactionExhausted: "The MTP transaction counter is exhausted. Reconnect before continuing."
        }
    }
}

public enum ContainerType: UInt16, Sendable {
    case command = 1
    case data = 2
    case response = 3
    case event = 4
}

/// A parsed MTP response container. Keeping the response parameters is
/// necessary for SendObjectInfo, whose three returned values identify the
/// storage, parent and newly reserved object handle.
public struct MTPResponse: Equatable, Sendable {
    public let code: UInt16
    public let transaction: UInt32
    public let parameters: [UInt32]

    public init(header: ContainerHeader, payload: Data) throws {
        guard header.type == .response, payload.count == header.payloadLength else {
            throw WireError.invalidLength
        }
        var reader = DatasetReader(payload)
        var parameters: [UInt32] = []
        while reader.remaining > 0 { parameters.append(try reader.readUInt32()) }
        self.code = header.code
        transaction = header.transaction
        self.parameters = parameters
    }
}

/// No unaligned loads, unchecked integer conversions, or allocations from an
/// untrusted array count. Dataset interpretation is separate from USB transport.
public struct DatasetReader {
    private let bytes: [UInt8]
    private var position = 0
    public var remaining: Int { bytes.count - position }
    public init(_ data: Data) { bytes = Array(data) }

    public mutating func readUInt8() throws -> UInt8 {
        guard remaining >= 1 else { throw WireError.truncated }
        defer { position += 1 }
        return bytes[position]
    }
    public mutating func readUInt16() throws -> UInt16 {
        let low = try readUInt8()
        return UInt16(low) | (UInt16(try readUInt8()) << 8)
    }
    public mutating func readUInt32() throws -> UInt32 {
        let low = try readUInt16()
        return UInt32(low) | (UInt32(try readUInt16()) << 16)
    }
    public mutating func readUInt64() throws -> UInt64 {
        let low = try readUInt32()
        return UInt64(low) | (UInt64(try readUInt32()) << 32)
    }
    public mutating func readUInt16Array() throws -> [UInt16] {
        let count = try readUInt32()
        guard UInt64(count) <= UInt64(remaining / 2) else { throw WireError.truncated }
        return try (0..<Int(count)).map { _ in try readUInt16() }
    }
    public mutating func readUInt32Array() throws -> [UInt32] {
        let count = try readUInt32()
        guard UInt64(count) <= UInt64(remaining / 4) else { throw WireError.truncated }
        return try (0..<Int(count)).map { _ in try readUInt32() }
    }
    public mutating func readString() throws -> String {
        let count = Int(try readUInt8())
        if count == 0 { return "" }
        guard remaining >= count * 2 else { throw WireError.truncated }
        let start = position
        position += count * 2
        guard bytes[position - 2] == 0, bytes[position - 1] == 0 else { throw WireError.invalidString }
        let units: [UInt16] = stride(from: start, to: position - 2, by: 2).map {
            UInt16(bytes[$0]) | (UInt16(bytes[$0 + 1]) << 8)
        }
        // Foundation's treatment of malformed UTF-16 varies across macOS
        // releases. Validate explicitly instead of accepting replacement chars.
        var index = 0
        while index < units.count {
            let unit = units[index]
            guard unit != 0 else { throw WireError.invalidString }
            if (0xD800...0xDBFF).contains(unit) {
                guard index + 1 < units.count, (0xDC00...0xDFFF).contains(units[index + 1]) else {
                    throw WireError.invalidString
                }
                index += 2
            } else {
                guard !(0xDC00...0xDFFF).contains(unit) else { throw WireError.invalidString }
                index += 1
            }
        }
        return String(decoding: units, as: UTF16.self)
    }
    public func requireEnd() throws { if remaining != 0 { throw WireError.invalidLength } }
}

public struct DatasetWriter {
    public private(set) var data = Data()
    public init() {}
    public mutating func append(_ value: UInt8) { data.append(value) }
    public mutating func append(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }
    public mutating func append(_ value: UInt32) {
        append(UInt16(truncatingIfNeeded: value))
        append(UInt16(truncatingIfNeeded: value >> 16))
    }
    public mutating func append(_ value: UInt64) {
        append(UInt32(truncatingIfNeeded: value))
        append(UInt32(truncatingIfNeeded: value >> 32))
    }
    public mutating func append(string: String) throws {
        let units = Array(string.utf16)
        guard units.count <= 254, !units.contains(0) else { throw WireError.invalidString }
        if units.isEmpty {
            append(UInt8(0))
            return
        }
        append(UInt8(units.count + 1))
        for unit in units { append(unit) }
        append(UInt16(0))
    }
}

public struct ContainerHeader: Equatable, Sendable {
    public let length: UInt32
    public let type: ContainerType
    public let code: UInt16
    public let transaction: UInt32
    public var payloadLength: Int { Int(length) - 12 }

    public init(length: UInt32, type: ContainerType, code: UInt16, transaction: UInt32) throws {
        guard length >= 12 else { throw WireError.invalidLength }
        if type != .data {
            let maxLength: UInt32 = type == .event ? 24 : 32
            guard length <= maxLength, (length - 12) % 4 == 0 else { throw WireError.invalidLength }
        }
        self.length = length
        self.type = type
        self.code = code
        self.transaction = transaction
    }

    public init(data: Data) throws {
        guard data.count == 12 else { throw WireError.invalidLength }
        var reader = DatasetReader(data)
        let length = try reader.readUInt32()
        guard let type = ContainerType(rawValue: try reader.readUInt16()) else { throw WireError.invalidType }
        try self.init(length: length, type: type, code: reader.readUInt16(), transaction: reader.readUInt32())
    }

    public func encoded() -> Data {
        var writer = DatasetWriter()
        writer.append(length)
        writer.append(type.rawValue)
        writer.append(code)
        writer.append(transaction)
        return writer.data
    }

    public static func command(code: UInt16, transaction: UInt32, parameters: [UInt32] = []) throws -> Data {
        guard parameters.count <= 5 else { throw WireError.invalidLength }
        let header = try Self(
            length: UInt32(12 + parameters.count * 4), type: .command, code: code, transaction: transaction)
        var writer = DatasetWriter()
        for parameter in parameters { writer.append(parameter) }
        return header.encoded() + writer.data
    }

    /// Header for an ordinary (non-extended-length) data container. A length
    /// of 0xFFFFFFFF is reserved for the MTP extended/unknown-size form.
    public static func data(code: UInt16, transaction: UInt32, payloadLength: UInt64) throws -> Data {
        guard payloadLength <= UInt64(UInt32.max) - 13 else { throw WireError.sizeLimit }
        return try Self(
            length: UInt32(payloadLength) + 12, type: .data,
            code: code, transaction: transaction
        ).encoded()
    }
}

public struct DeviceInfo: Sendable, Equatable {
    public let standardVersion: UInt16
    public let vendorExtensionID: UInt32
    public let vendorExtensionVersion: UInt16
    public let vendorExtensionDescription: String
    public let functionalMode: UInt16
    public let operations: [UInt16]
    public let events: [UInt16]
    public let properties: [UInt16]
    public let captureFormats: [UInt16]
    public let imageFormats: [UInt16]
    public let manufacturer: String
    public let model: String
    public let deviceVersion: String
    public let serialNumber: String

    public init(data: Data) throws {
        var reader = DatasetReader(data)
        standardVersion = try reader.readUInt16()
        vendorExtensionID = try reader.readUInt32()
        vendorExtensionVersion = try reader.readUInt16()
        vendorExtensionDescription = try reader.readString()
        functionalMode = try reader.readUInt16()
        operations = try reader.readUInt16Array()
        events = try reader.readUInt16Array()
        properties = try reader.readUInt16Array()
        captureFormats = try reader.readUInt16Array()
        imageFormats = try reader.readUInt16Array()
        manufacturer = try reader.readString()
        model = try reader.readString()
        deviceVersion = try reader.readString()
        serialNumber = try reader.readString()
        try reader.requireEnd()
    }
}
