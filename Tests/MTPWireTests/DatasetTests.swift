import Foundation
import Testing

@testable import MTPWire

private func storageDataset() throws -> Data {
    var writer = DatasetWriter()
    writer.append(UInt16(3))
    writer.append(UInt16(2))
    writer.append(UInt16(0xFFFF))  // Preserve unknown enum values.
    writer.append(UInt64.max)
    writer.append(UInt64(1) << 40)
    writer.append(UInt32.max)
    try writer.append(string: "Storage 📷")
    try writer.append(string: "")
    return writer.data
}

private func objectDataset(format: UInt16 = 0x3801, association: UInt16 = 0, size: UInt32 = 123) throws
    -> Data
{
    var writer = DatasetWriter()
    writer.append(UInt32(0x10001))
    writer.append(format)
    writer.append(UInt16(1))
    writer.append(size)
    writer.append(UInt16(0x3801))
    // Distinct values catch accidental field order/width errors.
    for value: UInt32 in [10, 11, 12, 13, 14, 15, 16] { writer.append(value) }
    writer.append(association)
    writer.append(UInt32(17))
    writer.append(UInt32(18))
    for text in ["日本語 📷.jpg", "20260831T190000", "20260831T180000.125+0200", "tag"] {
        try writer.append(string: text)
    }
    return writer.data
}

@Test func typedStoragePreservesCapacityAndUnknownValues() throws {
    let data = try storageDataset()
    let info = try StorageInfo(data: data)
    #expect(info.storageType == 3)
    #expect(info.filesystemType == 2)
    #expect(info.accessCapability == UInt16.max)
    #expect(info.maxCapacity == UInt64.max)
    #expect(info.freeSpaceInBytes == 1 << 40)
    #expect(info.freeSpaceInImages == UInt32.max)
    #expect(info.storageDescription == "Storage 📷")
    #expect(info.volumeLabel.isEmpty)
}

@Test func typedObjectPreservesAllFieldsAndTimestamps() throws {
    let encoded = try objectDataset()
    let info = try ObjectInfo(data: encoded)
    #expect(info.storageID == 0x10001)
    #expect(info.format == 0x3801)
    #expect(info.protectionStatus == 1)
    #expect(info.byteCount == 123)
    #expect(info.thumbnailFormat == 0x3801)
    #expect(
        [
            info.thumbnailSize, info.thumbnailWidth, info.thumbnailHeight,
            info.imageWidth, info.imageHeight, info.imageBitDepth, info.parent,
        ] == [10, 11, 12, 13, 14, 15, 16])
    #expect(info.associationDescription == 17)
    #expect(info.sequenceNumber == 18)
    #expect(info.filename == "日本語 📷.jpg")
    #expect(info.captureDate == "20260831T190000")
    #expect(info.modificationDate == "20260831T180000.125+0200")
    #expect(info.keywords == "tag")
    #expect(!info.isDirectory)
    #expect(try info.encoded() == encoded)
}

@Test func androidUndefinedAndGenericFolderAssociationsAreDirectories() throws {
    #expect(try ObjectInfo(data: objectDataset(format: 0x3001, association: 0)).isDirectory)
    #expect(try ObjectInfo(data: objectDataset(format: 0x3001, association: 1)).isDirectory)
    #expect(try !ObjectInfo(data: objectDataset(format: 0x3001, association: 2)).isDirectory)
    #expect(try !ObjectInfo(data: objectDataset(format: 0x3801, association: 1)).isDirectory)
    #expect(try ObjectInfo(data: objectDataset(size: UInt32.max)).byteCount == nil)
    #expect(try ObjectInfo(data: objectDataset(size: 0)).byteCount == 0)
}

@Test func typedDatasetsRejectEveryTruncationAndTrailingBytes() throws {
    let storage = try storageDataset()
    let object = try objectDataset()
    for count in 0..<storage.count {
        #expect(throws: (any Error).self) { try StorageInfo(data: Data(storage.prefix(count))) }
    }
    for count in 0..<object.count {
        #expect(throws: (any Error).self) { try ObjectInfo(data: Data(object.prefix(count))) }
    }
    #expect(throws: WireError.invalidLength) { try StorageInfo(data: storage + Data([0])) }
    #expect(throws: WireError.invalidLength) { try ObjectInfo(data: object + Data([0])) }
}
