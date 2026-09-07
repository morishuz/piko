import Foundation
@testable import Piko

/// Supplies an existing, empty, marker-owned Bin around transfer-only fixtures.
/// User transfer faults/counters remain on the wrapped backend; no production bypass.
struct PreparedBinFixture<Backend: MTPUploadBackend>: MTPBinBackend {
    let backend: Backend
    init(_ backend: Backend) { self.backend = backend }
    var capabilities: BackendCapabilities { backend.capabilities }
    var maximumUploadFileSize: Int64? { backend.maximumUploadFileSize }
    private func identity(_ storageID: UInt32) -> BinStorageIdentity {
        BinStorageIdentity(manufacturer: "Fixture", model: "Transfer", serialNumber: "test",
            volumeLabel: String(storageID), storageDescription: "Fixture", capacity: 1_000_000)
    }
    func binIdentity(storageID: UInt32) async throws -> BinStorageIdentity { identity(storageID) }
    private func marker(_ storageID: UInt32) throws -> Data {
        try JSONEncoder().encode(BinMarker(storage: identity(storageID),
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!))
    }
    func deviceDetails() async -> MTPDeviceDetails? { await backend.deviceDetails() }
    func connect() async throws -> [MTPStorage] { try await backend.connect() }
    func disconnect() async throws -> Bool { try await backend.disconnect() }
    func supportsBin(storageID: UInt32) async -> Bool { await backend.supportsUpload(to: storageID) }
    func supportsUpload(to storageID: UInt32) async -> Bool { await backend.supportsUpload(to: storageID) }
    func supportsUploadCancellation(to storageID: UInt32) async -> Bool { await backend.supportsUploadCancellation(to: storageID) }
    func supportsDownloadCancellation() async -> Bool { await backend.supportsDownloadCancellation() }
    func supportsMove(storageID: UInt32) async -> Bool {
        await (backend as? any MTPMoveBackend)?.supportsMove(storageID: storageID) ?? false
    }
    func contents(storageID: UInt32, path: String, showHiddenFiles: Bool) async throws -> [MTPFile] {
        if path == BinLayout.root {
            return [MTPFile(size: Int64(try marker(storageID).count), isFolder: false, dateAdded: "",
                name: BinLayout.markerName, path: path + "/" + BinLayout.markerName, parentPath: path,
                fileExtension: "json", parentID: 0, id: 0xffff0001)]
        }
        var result = try await backend.contents(storageID: storageID, path: path, showHiddenFiles: showHiddenFiles)
        if path == "/" { result.append(DemoBackend.entry(id: 0xffff0000, name: "Piko Bin", parent: "/", folder: true)) }
        return result
    }
    func download(storageID: UInt32, files: [MTPFile], to destination: URL, progress: @escaping ProgressHandler) async throws {
        if files.count == 1, files[0].id == 0xffff0001 {
            try marker(storageID).write(to: destination.appendingPathComponent(BinLayout.markerName))
        } else { try await backend.download(storageID: storageID, files: files, to: destination, progress: progress) }
    }
    func upload(storageID: UInt32, source: URL, to directory: String, progress: @escaping ProgressHandler) async throws -> UploadDisposition {
        try await backend.upload(storageID: storageID, source: source, to: directory, progress: progress)
    }
    func createUploadDirectory(storageID: UInt32, parent: String, name: String) async throws -> UploadDirectoryDisposition {
        guard let folders = backend as? any MTPFolderUploadBackend else { throw BinError.unsupported }
        return try await folders.createUploadDirectory(storageID: storageID, parent: parent, name: name)
    }
    func move(storageID: UInt32, file: MTPFile, to directory: String) async throws -> MTPFile {
        guard let moves = backend as? any MTPMoveBackend else { throw BinError.unsupported }
        return try await moves.move(storageID: storageID, file: file, to: directory)
    }
}
