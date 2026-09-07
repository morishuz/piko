import Foundation
@testable import Piko

/// In-memory device. No USB access; uploads read only explicitly selected files.
actor DemoBackend: MTPBinBackend, MTPThumbnailBackend {
    nonisolated let capabilities = BackendCapabilities(reportsProgress: true, canCancelActiveTransfer: false)
    private var connected = false
    private var entries: [MTPFile]
    private var uploadedData: [UInt32: Data] = [:]
    private var nextUploadID: UInt32 = 20_000
    private let uploadFailures: [String: DemoUploadFailure]
    private let failedIDs: Set<UInt32>
    private let delay: Duration
    private let gate = OperationGate()

    init(
        fileCount: Int = 30, failedIDs: Set<UInt32> = [], delay: Duration = .milliseconds(30),
        uploadFailures: [String: DemoUploadFailure] = [:]
    ) {
        self.failedIDs = failedIDs
        self.delay = delay
        self.uploadFailures = uploadFailures
        let folder = Self.entry(id: 1, name: "Demo Files", parent: "/", folder: true)
        let nested = Self.entry(id: 2, name: "Nested", parent: folder.path, folder: true)
        var all = [folder, nested]
        for index in 0..<max(0, min(fileCount, 10_000)) {
            let name = String(format: "Sample-%04d.txt", index + 1)
            let parent = index == 0 ? nested.path : folder.path
            all.append(Self.entry(id: UInt32(index + 10), name: name, parent: parent, folder: false))
        }
        entries = all
    }

    static func entry(id: UInt32, name: String, parent: String, folder: Bool) -> MTPFile {
        MTPFile(
            size: folder ? 0 : 8192, isFolder: folder,
            dateAdded: "2026-08-31T12:00:00.000Z", name: name,
            path: RemotePath.appending(name, to: parent), parentPath: parent,
            fileExtension: folder ? "" : "txt", parentID: 0, id: id)
    }

    static let storage = MTPStorage(
        id: 1,
        info: MTPStorageInfo(
            storageType: 3, filesystemType: 2, accessCapability: 0,
            maxCapacity: 1_000_000_000, freeSpaceInBytes: 900_000_000, freeSpaceInImages: 0,
            storageDescription: "Synthetic storage", volumeLabel: "Demo"))

    func connect() async throws -> [MTPStorage] {
        try await gate.run { await self.start() }
    }

    private func start() -> [MTPStorage] {
        connected = true
        return [Self.storage]
    }

    func contents(storageID: UInt32, path: String, showHiddenFiles: Bool = false) async throws -> [MTPFile] {
        try await gate.run { try await self.list(storageID: storageID, path: path, hidden: showHiddenFiles) }
    }

    func thumbnail(storageID: UInt32, file: MTPFile) async throws -> Data? {
        try await gate.runIfIdle { await self.photoData(storageID: storageID, file: file) }
    }

    private func photoData(storageID: UInt32, file: MTPFile) -> Data? {
        guard connected, storageID == 1, entries.contains(file), file.isPhotoThumbnailCandidate,
            let data = uploadedData[file.id], data.count <= 512 * 1024 else { return nil }
        return data
    }

    private func list(storageID: UInt32, path: String, hidden: Bool) throws -> [MTPFile] {
        guard connected, storageID == 1 else { throw BackendError.disconnected }
        guard path == "/" || entries.contains(where: { $0.path == path && $0.isFolder }) else {
            throw BackendError.invalidPath(path)
        }
        return entries.filter { $0.parentPath == path && (hidden || !$0.name.hasPrefix(".")) }
            .sorted { $0.isFolder != $1.isFolder ? $0.isFolder : $0.name < $1.name }
    }

    func download(
        storageID: UInt32, files: [MTPFile], to destination: URL,
        progress: @escaping ProgressHandler = { _ in }
    ) async throws {
        try await gate.run {
            try await self.write(storageID: storageID, files: files, to: destination, progress: progress)
        }
    }

    private func write(
        storageID: UInt32, files: [MTPFile], to destination: URL,
        progress: @escaping ProgressHandler
    ) async throws {
        guard connected, storageID == 1 else { throw BackendError.disconnected }
        for file in files {
            guard entries.contains(file), !file.isFolder else { throw BackendError.invalidPath(file.path) }
            try RemotePath.validateName(file.name)
            if failedIDs.contains(file.id) { throw SimulatedDeviceError.failure(file.name) }
            // ASCII data in small fixed-size files; no misleading fake JPG/RAW contents.
            let data =
                uploadedData[file.id] ?? Data(repeating: UInt8(65 + file.id % 26), count: Int(file.size))
            progress(TransferProgress(fileName: file.name, bytesTransferred: 0, totalBytes: file.size))
            try await Task.sleep(for: delay)
            try data.write(to: destination.appendingPathComponent(file.name), options: .withoutOverwriting)
            progress(
                TransferProgress(fileName: file.name, bytesTransferred: file.size, totalBytes: file.size))
        }
    }

    func supportsBin(storageID: UInt32) async -> Bool { connected && storageID == 1 }
    func supportsBinDeletion(storageID: UInt32) async -> Bool { connected && storageID == 1 }
    func binIdentity(storageID: UInt32) async throws -> BinStorageIdentity {
        guard connected, storageID == 1 else { throw BackendError.disconnected }
        return BinStorageIdentity(manufacturer: "Piko", model: "Demo", serialNumber: "demo",
            volumeLabel: "Demo", storageDescription: "Synthetic storage", capacity: Self.storage.info.maxCapacity)
    }
    func deleteBinItem(storageID: UInt32, file: MTPFile, within root: String) async throws {
        guard connected, storageID == 1, BinLayout.isCandidateRoot(root),
            file.path != root, BinLayout.contains(file.path, in: root),
            file.path != RemotePath.appending(BinLayout.markerName, to: root),
            entries.contains(file), !entries.contains(where: { $0.parentPath == file.path }) else { throw BinError.changed }
        entries.removeAll { $0 == file }
        uploadedData[file.id] = nil
    }

    func supportsMove(storageID: UInt32) async -> Bool { connected && storageID == 1 }

    func move(storageID: UInt32, file: MTPFile, to directory: String) async throws -> MTPFile {
        try await gate.run { try await self.moveImpl(storageID: storageID, file: file, directory: directory) }
    }

    private func moveImpl(storageID: UInt32, file: MTPFile, directory: String) throws -> MTPFile {
        let target = try list(storageID: storageID, path: directory, hidden: true)
        guard entries.contains(file) else { throw SwiftBackendError.staleSelection }
        guard !file.isFolder || !BinLayout.contains(directory, in: file.path) else { throw BinError.invalidEntry }
        guard !target.contains(where: { RemotePath.collisionKey($0.name) == RemotePath.collisionKey(file.name) }) else { throw BinError.conflict(directory) }
        let newPath = RemotePath.appending(file.name, to: directory)
        entries = entries.map { item in
            guard item.id == file.id || file.isFolder && item.path.hasPrefix(file.path + "/") else { return item }
            let path = newPath + item.path.dropFirst(file.path.count)
            return MTPFile(size: item.size, isFolder: item.isFolder, dateAdded: item.dateAdded,
                name: item.name, path: path, parentPath: (path as NSString).deletingLastPathComponent,
                fileExtension: item.fileExtension, parentID: item.parentID, id: item.id)
        }
        guard let moved = entries.first(where: { $0.id == file.id }) else { throw SwiftBackendError.staleSelection }
        return moved
    }

    @discardableResult func disconnect() async throws -> Bool {
        try await gate.run { await self.stop() }
    }
    private func stop() -> Bool {
        connected = false
        return true
    }

    func upload(
        storageID: UInt32, source: URL, to directory: String,
        progress: @escaping ProgressHandler
    ) async throws -> UploadDisposition {
        try await gate.run {
            try await self.uploadImpl(
                storageID: storageID, source: source, directory: directory, progress: progress)
        }
    }

    private func uploadImpl(
        storageID: UInt32, source: URL, directory: String,
        progress: @escaping ProgressHandler
    ) async throws -> UploadDisposition {
        let existing = try list(storageID: storageID, path: directory, hidden: true)
        let size = try LocalFileIO.sourceSize(source)
        let name = source.lastPathComponent
        if existing.contains(where: { RemotePath.collisionKey($0.name) == RemotePath.collisionKey(name) }) {
            return .skippedExisting
        }
        switch uploadFailures[name] {
        case .permissionDenied: throw UploadError.rejected("Demo device: permission denied.")
        case .storageFull: throw UploadError.rejected("Demo device: storage is full.")
        default: break
        }
        // The fake device retains bytes only in memory; cap it explicitly.
        guard size <= 16 * 1024 * 1024,
            uploadedData.values.reduce(Int64(0), { $0 + Int64($1.count) }) + size <= 64 * 1024 * 1024
        else {
            throw UploadError.rejected("Demo upload limit: 16 MiB per file, 64 MiB total.")
        }
        progress(TransferProgress(fileName: name, bytesTransferred: 0, totalBytes: size))
        try await Task.sleep(for: delay)
        var bytes = try Data(contentsOf: source)
        if uploadFailures[name] == .partialDisconnect { bytes = Data(bytes.prefix(bytes.count / 2)) }
        let id = nextUploadID
        nextUploadID += 1
        entries.append(
            MTPFile(
                size: Int64(bytes.count), isFolder: false,
                dateAdded: "2026-08-31T12:00:00.000Z", name: name,
                path: RemotePath.appending(name, to: directory),
                parentPath: directory, fileExtension: source.pathExtension, parentID: 0, id: id))
        uploadedData[id] = bytes
        progress(TransferProgress(fileName: name, bytesTransferred: Int64(bytes.count), totalBytes: size))
        if uploadFailures[name] == .partialDisconnect {
            connected = false
            throw BackendError.disconnected
        }
        return .uploaded
    }

    func createUploadDirectory(storageID: UInt32, parent: String, name: String) async throws
        -> UploadDirectoryDisposition
    {
        try await gate.run {
            try await self.createDirectoryImpl(storageID: storageID, parent: parent, name: name)
        }
    }

    private func createDirectoryImpl(storageID: UInt32, parent: String, name: String) throws
        -> UploadDirectoryDisposition
    {
        try RemotePath.validate(parent)
        try RemotePath.validateName(name)
        let existing = try list(storageID: storageID, path: parent, hidden: true)
        if existing.contains(where: { RemotePath.collisionKey($0.name) == RemotePath.collisionKey(name) }) {
            return .skippedExisting
        }
        switch uploadFailures[name] {
        case .permissionDenied: throw UploadError.rejected("Demo device: folder creation denied.")
        case .storageFull: throw UploadError.rejected("Demo device: storage is full.")
        default: break
        }
        let id = nextUploadID
        nextUploadID += 1
        entries.append(Self.entry(id: id, name: name, parent: parent, folder: true))
        if uploadFailures[name] == .partialDisconnect {
            connected = false
            throw BackendError.disconnected
        }
        return .created
    }
}

enum DemoUploadFailure: Sendable { case permissionDenied, storageFull, partialDisconnect }


enum SimulatedDeviceError: LocalizedError, Equatable {
    case failure(String)
    var errorDescription: String? {
        switch self { case .failure(let message): "Simulated device failure: \(message)" }
    }
}
