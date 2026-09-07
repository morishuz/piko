import Foundation

/// Device-reported identity is a mismatch check, not a globally unique identifier.
/// Numeric MTP storage/object handles are deliberately not persisted.
struct BinStorageIdentity: Codable, Equatable, Sendable {
    let manufacturer: String
    let model: String
    let serialNumber: String
    let volumeLabel: String
    let storageDescription: String
    let capacity: UInt64
}

protocol MTPBinBackend: MTPFolderUploadBackend, MTPMoveBackend {
    func supportsBinDeletion(storageID: UInt32) async -> Bool
    func deleteBinItem(storageID: UInt32, file: MTPFile, within root: String) async throws
    func supportsBin(storageID: UInt32) async -> Bool
    func binIdentity(storageID: UInt32) async throws -> BinStorageIdentity
}

enum BinError: LocalizedError, Equatable {
    case missing, unsupported, invalidEntry, emptyEntry, changed, uncertain, deletionUncertain
    case preparationSessionChanged
    case conflict(String)
    var errorDescription: String? {
        switch self {
        case .missing: "No recognised Piko Bin exists on this storage. Reconnect to prepare it."
        case .unsupported: "This storage must support uploads, folders and device-side moves to use the bin."
        case .invalidEntry: "This is not a valid Piko bin entry, or its restore location is unsafe. Inspect the visible Piko Bin folder for manual recovery."
        case .emptyEntry: "This entry contains no recoverable item. It may have been restored already, moved manually, or interrupted before the original was moved. The recovery notes are retained."
        case .changed: "The selected item or its storage changed. Refresh and select it again."
        case .preparationSessionChanged: "The connection was recovered while checking Bin compatibility. The selected item was not moved. Select it again to retry; preparation notes remain in the Bin."
        case .deletionUncertain: "Permanent deletion stopped with an uncertain result. Reconnect and inspect the bin before continuing. No deletion will be retried automatically."
        case .uncertain: "The move outcome is uncertain. Reconnect and inspect the Bin folder before continuing. The recovery information remains on the device; no move will be retried automatically."
        case .conflict(let path): "An item already exists at the destination: \(path). Nothing was overwritten. Move or rename the existing item before restoring."
        }
    }
}

enum BinLayout {
    static let rootName = "Piko Bin"
    static let root = "/" + rootName
    // A navigation destination, never a path passed to an MTP operation.
    static let overview = "piko:bin"
    static let markerName = "Piko-Bin.json"
    static let metadataName = "Restore.json"
    static let payloadName = "Files"
    static func isCandidateRoot(_ path: String) -> Bool {
        guard (path as NSString).deletingLastPathComponent == "/" else { return false }
        let name = (path as NSString).lastPathComponent
        let prefix = rootName + "-"
        return name == rootName || (name.hasPrefix(prefix) && UUID(uuidString: String(name.dropFirst(prefix.count))) != nil)
    }
    static func contains(_ path: String, in ancestor: String) -> Bool {
        let path = RemotePath.collisionKey(path)
        let ancestor = RemotePath.collisionKey(ancestor)
        return path == ancestor || path.hasPrefix(ancestor + "/")
    }
    static func validateSource(_ file: MTPFile, roots: [String] = []) throws {
        try RemotePath.validate(file.parentPath)
        try RemotePath.validateName(file.name)
        guard file.path == RemotePath.appending(file.name, to: file.parentPath),
            !roots.contains(where: { contains(file.path, in: $0) || (file.isFolder && contains($0, in: file.path)) })
        else { throw BinError.invalidEntry }
    }
}

/// This marker identifies our directory; a matching name alone grants no ownership.
struct BinMarker: Codable, Equatable, Sendable {
    let format: String
    let version: Int
    let id: UUID
    let storage: BinStorageIdentity
    init(storage: BinStorageIdentity, id: UUID = UUID()) {
        format = "org.piko.device-bin"
        version = 1
        self.id = id
        self.storage = storage
    }
    func matches(_ identity: BinStorageIdentity) -> Bool {
        format == "org.piko.device-bin" && version == 1 && storage == identity
    }
}

struct BinRecord: Codable, Equatable, Sendable {
    let version: Int
    let entryID: UUID
    let storage: BinStorageIdentity
    let originalParent: String
    let originalName: String
    let isFolder: Bool
    let size: Int64
    let originalDate: String
    let binnedAt: Date

    init(file: MTPFile, storage: BinStorageIdentity, entryID: UUID, roots: [String] = []) throws {
        try BinLayout.validateSource(file, roots: roots)
        version = 1
        self.entryID = entryID
        self.storage = storage
        originalParent = file.parentPath
        originalName = file.name
        isFolder = file.isFolder
        size = file.size
        originalDate = file.dateAdded
        binnedAt = Date()
    }

    var entryName: String {
        var label = String(originalName.prefix(60))
        while label.utf16.count > 100 { label.removeLast() }
        return "Piko-\(label)-\(entryID.uuidString)"
    }
    var originalPath: String { RemotePath.appending(originalName, to: originalParent) }

    func validate(entryName: String, storage: BinStorageIdentity, roots: [String]) throws {
        guard version == 1, self.entryName == entryName, self.storage == storage else {
            throw BinError.invalidEntry
        }
        do {
            try RemotePath.validate(originalParent)
            try RemotePath.validateName(originalName)
        } catch { throw BinError.invalidEntry }
        guard originalParent.split(separator: "/").count <= 128, originalName.utf16.count <= 254,
            !roots.contains(where: { BinLayout.contains(originalPath, in: $0) || (isFolder && BinLayout.contains($0, in: originalPath)) }) else {
            throw BinError.invalidEntry
        }
    }
}

/// Rows carry real payload handles; recovery folders stay separate from the
/// files used for browsing and downloading. No synthetic MTP metadata is sent.
struct BinListing: Sendable {
    struct Item: Sendable {
        let file: MTPFile
        let entry: MTPFile
        let originalPath: String?
    }
    let roots: [String]
    /// Only validated recovery entries are eligible for Empty Bin.
    let entries: [MTPFile]
    let items: [Item]
    var files: [MTPFile] {
        items.map(\.file).sorted {
            if $0.isFolder != $1.isFolder { return $0.isFolder }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
    var retainedEntryCount: Int { entries.count - items.filter { $0.originalPath != nil }.count }
    func item(for file: MTPFile) -> Item? { items.first { $0.file == file } }
}
