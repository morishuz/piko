import Foundation

struct MTPStorage: Identifiable, Hashable, Sendable {
    let id: UInt32
    let info: MTPStorageInfo


    var displayName: String {
        if !info.storageDescription.isEmpty {
            return info.storageDescription
        }
        if !info.volumeLabel.isEmpty {
            return info.volumeLabel
        }
        return "Storage \(id)"
    }
}

struct MTPStorageInfo: Hashable, Sendable {
    let storageType: UInt16
    let filesystemType: UInt16
    let accessCapability: UInt16
    let maxCapacity: UInt64
    let freeSpaceInBytes: UInt64
    let freeSpaceInImages: UInt32
    let storageDescription: String
    let volumeLabel: String

}

struct MTPFile: Identifiable, Hashable, Sendable {
    // Device selections may not be reused after reconnect. Demo entries
    // do not belong to a hardware session.
    var sessionID: UUID? = nil
    let size: Int64
    let isFolder: Bool
    let dateAdded: String
    let name: String
    let path: String
    let parentPath: String
    let fileExtension: String
    let parentID: UInt32
    let id: UInt32

}
