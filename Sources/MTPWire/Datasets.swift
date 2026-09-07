import Foundation

public enum MTPObjectName {
    public static func isSafePathComponent(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".."
            && !name.contains("/") && !name.contains("\0")
    }

    public static func validateUploadPathComponent(_ name: String) throws {
        guard isSafePathComponent(name), name.utf16.count <= 254 else {
            throw WireError.invalidString
        }
    }
}

/// Standard StorageInfo dataset. Unknown enum values and capacity sentinels are
/// retained verbatim: decoding metadata does not grant write permission.
public struct StorageInfo: Equatable, Sendable {
    public let storageType: UInt16
    public let filesystemType: UInt16
    public let accessCapability: UInt16
    public let maxCapacity: UInt64
    public let freeSpaceInBytes: UInt64
    public let freeSpaceInImages: UInt32
    public let storageDescription: String
    public let volumeLabel: String

    public init(data: Data) throws {
        var reader = DatasetReader(data)
        storageType = try reader.readUInt16()
        filesystemType = try reader.readUInt16()
        accessCapability = try reader.readUInt16()
        maxCapacity = try reader.readUInt64()
        freeSpaceInBytes = try reader.readUInt64()
        freeSpaceInImages = try reader.readUInt32()
        storageDescription = try reader.readString()
        volumeLabel = try reader.readString()
        try reader.requireEnd()
    }
}

/// Standard ObjectInfo, independent of local paths and session-scoped handles.
/// Keep timestamps as device strings: an absent timezone must not become UTC.
public struct ObjectInfo: Equatable, Sendable {
    /// Largest payload representable by an ordinary MTP data-container length.
    /// 0xFFFFFFFF is the extended/unknown-length sentinel, so it is excluded.
    public static let maximumOrdinaryObjectSize = UInt64(UInt32.max) - 13

    public let storageID: UInt32
    public let format: UInt16
    public let protectionStatus: UInt16
    public let compressedSize: UInt32
    public let thumbnailFormat: UInt16
    public let thumbnailSize: UInt32
    public let thumbnailWidth: UInt32
    public let thumbnailHeight: UInt32
    public let imageWidth: UInt32
    public let imageHeight: UInt32
    public let imageBitDepth: UInt32
    public let parent: UInt32
    public let associationType: UInt16
    public let associationDescription: UInt32
    public let sequenceNumber: UInt32
    public let filename: String
    public let captureDate: String
    public let modificationDate: String
    public let keywords: String

    /// Android may report undefined AssociationType (0) for filesystem
    /// directories. GenericFolder (1) is the standard directory subtype;
    /// album and sequence associations are not filesystem paths.
    public var isDirectory: Bool {
        format == 0x3001 && (associationType == 0 || associationType == 1)
    }
    /// 0xffffffff is not proof that a file is exactly 4 GiB minus one byte.
    public var byteCount: UInt64? {
        compressedSize == UInt32.max ? nil : UInt64(compressedSize)
    }

    public init(data: Data) throws {
        var reader = DatasetReader(data)
        storageID = try reader.readUInt32()
        format = try reader.readUInt16()
        protectionStatus = try reader.readUInt16()
        compressedSize = try reader.readUInt32()
        thumbnailFormat = try reader.readUInt16()
        thumbnailSize = try reader.readUInt32()
        thumbnailWidth = try reader.readUInt32()
        thumbnailHeight = try reader.readUInt32()
        imageWidth = try reader.readUInt32()
        imageHeight = try reader.readUInt32()
        imageBitDepth = try reader.readUInt32()
        parent = try reader.readUInt32()
        associationType = try reader.readUInt16()
        associationDescription = try reader.readUInt32()
        sequenceNumber = try reader.readUInt32()
        filename = try reader.readString()
        captureDate = try reader.readString()
        modificationDate = try reader.readString()
        keywords = try reader.readString()
        try reader.requireEnd()
    }

    private init(
        storageID: UInt32, format: UInt16, compressedSize: UInt32,
        parent: UInt32, associationType: UInt16, filename: String,
        modificationDate: String
    ) {
        self.storageID = storageID
        self.format = format
        protectionStatus = 0
        self.compressedSize = compressedSize
        thumbnailFormat = 0
        thumbnailSize = 0
        thumbnailWidth = 0
        thumbnailHeight = 0
        imageWidth = 0
        imageHeight = 0
        imageBitDepth = 0
        self.parent = parent
        self.associationType = associationType
        associationDescription = 0
        sequenceNumber = 0
        self.filename = filename
        captureDate = ""
        self.modificationDate = modificationDate
        keywords = ""
    }

    /// Constructs conservative metadata for an arbitrary filesystem file.
    /// `parent == 0xFFFFFFFF` denotes the storage root at the API boundary;
    /// ObjectInfo itself encodes the standard root value of zero.
    public static func uploadFile(
        storageID: UInt32, parent: UInt32, size: UInt64, filename: String,
        modificationDate: String = ""
    ) throws -> Self {
        try validateUploadDestination(storageID: storageID, filename: filename)
        guard size <= maximumOrdinaryObjectSize else { throw WireError.sizeLimit }
        try validateUploadString(modificationDate)
        return Self(
            storageID: storageID, format: 0x3000, compressedSize: UInt32(size),
            parent: normalizedDatasetParent(parent), associationType: 0,
            filename: filename, modificationDate: modificationDate)
    }

    /// Constructs the Association ObjectInfo used to create a generic folder.
    /// A folder is complete after SendObjectInfo and has no SendObject phase.
    public static func uploadDirectory(
        storageID: UInt32, parent: UInt32, filename: String,
        modificationDate: String = ""
    ) throws -> Self {
        try validateUploadDestination(storageID: storageID, filename: filename)
        try validateUploadString(modificationDate)
        return Self(
            storageID: storageID, format: 0x3001, compressedSize: 0,
            parent: normalizedDatasetParent(parent), associationType: 1,
            filename: filename, modificationDate: modificationDate)
    }

    public func encoded() throws -> Data {
        try MTPObjectName.validateUploadPathComponent(filename)
        var writer = DatasetWriter()
        writer.append(storageID)
        writer.append(format)
        writer.append(protectionStatus)
        writer.append(compressedSize)
        writer.append(thumbnailFormat)
        writer.append(thumbnailSize)
        writer.append(thumbnailWidth)
        writer.append(thumbnailHeight)
        writer.append(imageWidth)
        writer.append(imageHeight)
        writer.append(imageBitDepth)
        writer.append(parent)
        writer.append(associationType)
        writer.append(associationDescription)
        writer.append(sequenceNumber)
        try writer.append(string: filename)
        try writer.append(string: captureDate)
        try writer.append(string: modificationDate)
        try writer.append(string: keywords)
        return writer.data
    }

    var uploadCommandParent: UInt32 { parent == 0 ? UInt32.max : parent }

    private static func normalizedDatasetParent(_ parent: UInt32) -> UInt32 {
        parent == UInt32.max ? 0 : parent
    }

    private static func validateUploadDestination(storageID: UInt32, filename: String) throws {
        guard storageID != 0, storageID != UInt32.max else { throw WireError.invalidLength }
        try MTPObjectName.validateUploadPathComponent(filename)
    }

    private static func validateUploadString(_ string: String) throws {
        guard string.utf16.count <= 254, !string.utf16.contains(0) else {
            throw WireError.invalidString
        }
    }
}

public enum ReadOperation: UInt16, CaseIterable, Sendable {
    case deviceInfo = 0x1001
    case openSession = 0x1002
    case closeSession = 0x1003
    case storageIDs = 0x1004
    case storageInfo = 0x1005
    case objectHandles = 0x1007
    case objectInfo = 0x1008
    case getObject = 0x1009
}

public enum WriteOperation: UInt16, CaseIterable, Sendable {
    case sendObjectInfo = 0x100C
    case sendObject = 0x100D
    case moveObject = 0x1019
}

extension DeviceInfo {
    public func supports(_ operation: ReadOperation) -> Bool {
        operations.contains(operation.rawValue)
    }

    public func supports(_ operation: WriteOperation) -> Bool {
        operations.contains(operation.rawValue)
    }
}
