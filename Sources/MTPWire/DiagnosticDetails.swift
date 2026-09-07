import Foundation

/// Optional remote metadata, collected only while detailed recording is enabled.
/// No local paths, serial numbers, keywords, thumbnails or file payloads.
public enum DiagnosticDetails: Codable, Sendable {
    case device(manufacturer: String, model: String, firmware: String, usbRegistryID: UInt64? = nil)
    case directory(path: String, storageID: UInt32, parentHandle: UInt32, handles: [UInt32], totalHandles: Int?)
    case object(directory: String, storageID: UInt32, parentHandle: UInt32, objectHandle: UInt32, metadata: DiagnosticFileMetadata?)
    case move(sourcePath: String, destinationPath: String, storageID: UInt32, objectHandle: UInt32)

    /// Bounds keep both the in-memory ring and its journal small. An ellipsis
    /// marks shortened strings; totalHandles distinguishes a sampled handle list.
    func bounded() -> Self {
        switch self {
        case let .device(manufacturer, model, firmware, usbRegistryID):
            .device(manufacturer: Self.text(manufacturer, limit: 128), model: Self.text(model, limit: 128),
                    firmware: Self.text(firmware, limit: 128), usbRegistryID: usbRegistryID)
        case let .directory(path, storageID, parentHandle, handles, totalHandles):
            .directory(path: Self.text(path), storageID: storageID, parentHandle: parentHandle,
                       handles: Array(handles.prefix(64)), totalHandles: totalHandles)
        case let .object(directory, storageID, parentHandle, objectHandle, metadata):
            .object(directory: Self.text(directory), storageID: storageID, parentHandle: parentHandle,
                    objectHandle: objectHandle, metadata: metadata)
        case let .move(sourcePath, destinationPath, storageID, objectHandle):
            .move(sourcePath: Self.text(sourcePath), destinationPath: Self.text(destinationPath),
                  storageID: storageID, objectHandle: objectHandle)
        }
    }

    static func text(_ value: String, limit: Int = 512) -> String {
        let clean = String(String.UnicodeScalarView(value.unicodeScalars.prefix(limit + 1).map {
            CharacterSet.controlCharacters.contains($0) ? UnicodeScalar(0xFFFD)! : $0
        }))
        guard clean.utf8.count > limit else { return clean }
        var bytes = 0
        let prefix = clean.unicodeScalars.prefix { scalar in
            bytes += String(scalar).utf8.count
            return bytes <= limit - 3
        }
        return String(String.UnicodeScalarView(prefix)) + "…"
    }
}

public struct DiagnosticFileMetadata: Codable, Sendable {
    public let name: String
    public let storageID: UInt32
    public let parentHandle: UInt32
    public let format: UInt16
    public let protectionStatus: UInt16
    public let size: UInt64?
    public let captureDate: String
    public let modificationDate: String

    public init(_ info: ObjectInfo) {
        name = DiagnosticDetails.text(info.filename, limit: 256)
        storageID = info.storageID
        parentHandle = info.parent
        format = info.format
        protectionStatus = info.protectionStatus
        size = info.byteCount
        captureDate = DiagnosticDetails.text(info.captureDate, limit: 64)
        modificationDate = DiagnosticDetails.text(info.modificationDate, limit: 64)
    }
}
