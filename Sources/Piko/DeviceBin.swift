import Foundation

/// Recovery records are immutable and verified by readback before moving any
/// user data. Presence of the payload is authoritative after interruption.
/// Permanent deletion is explicitly requested and limited to verified Bin roots.
actor DeviceBin {
    private let backend: any MTPBinBackend
    private let gate = OperationGate()
    init(backend: any MTPBinBackend) { self.backend = backend }

    func trash(storageID: UInt32, file: MTPFile) async throws {
        try await gate.run { try await self.trashImpl(storageID: storageID, file: file) }
    }

    func restore(storageID: UInt32, entry: MTPFile, expectedItem: BinListing.Item? = nil) async throws {
        try await gate.run { try await self.restoreImpl(storageID: storageID, entry: entry, expectedItem: expectedItem) }
    }

    /// Connection-time preparation performs no moves and never touches user files.
    func prepare(storageID: UInt32) async throws -> BinListing {
        try await gate.run {
            var roots = try await self.binRoots(storageID)
            if roots.isEmpty {
                guard await self.backend.supportsBin(storageID: storageID) else { throw BinError.unsupported }
                let identity = try await self.backend.binIdentity(storageID: storageID)
                let marker = BinMarker(storage: identity)
                let rootEntries = try await self.entries(storageID, "/")
                let occupied = rootEntries.contains { RemotePath.collisionKey($0.name) == RemotePath.collisionKey(BinLayout.rootName) }
                let name = occupied ? "\(BinLayout.rootName)-\(marker.id.uuidString)" : BinLayout.rootName
                let root = RemotePath.appending(name, to: "/")
                guard case .created = try await self.backend.createUploadDirectory(storageID: storageID, parent: "/", name: name)
                else { throw BinError.conflict(root) }
                // Persist and read back the ownership record before enabling writes.
                // Failed preparation leaves its own directory for inspection, never deletes it.
                try await self.putVerified(JSONEncoder().encode(marker), name: BinLayout.markerName,
                    storageID: storageID, directory: root)
                roots = [root]
            }
            return try await self.listing(storageID, roots: roots)
        }
    }

    private func binRoots(_ storageID: UInt32) async throws -> [String] {
        let identity = try await backend.binIdentity(storageID: storageID)
        let rootEntries = try await entries(storageID, "/")
        var result: [String] = []
        for folder in rootEntries where folder.isFolder && BinLayout.isCandidateRoot(folder.path) {
            let siblings = rootEntries.filter { RemotePath.collisionKey($0.name) == RemotePath.collisionKey(folder.name) }
            guard siblings.count == 1 else { throw BinError.conflict(folder.path) }
            let children = try await entries(storageID, folder.path)
            let markers = children.filter { RemotePath.collisionKey($0.name) == RemotePath.collisionKey(BinLayout.markerName) }
            guard markers.count == 1, let file = markers.first, file.name == BinLayout.markerName, !file.isFolder else { continue }
            do {
                let marker = try JSONDecoder().decode(BinMarker.self, from: await readSmall(storageID, file))
                if marker.matches(identity) { result.append(folder.path) }
            } catch is DecodingError { continue }
              catch BinError.invalidEntry { continue }
        }
        return result.sorted()
    }

    func contents(storageID: UInt32) async throws -> BinListing {
        try await gate.run {
            try await self.listing(storageID, roots: self.binRoots(storageID))
        }
    }

    private func listing(_ storageID: UInt32, roots: [String]) async throws -> BinListing {
        guard !roots.isEmpty else { throw BinError.missing }
        let identity = try await backend.binIdentity(storageID: storageID)
        var items: [BinListing.Item] = []
        var managed: [MTPFile] = []
        for root in roots {
            for entry in try await entries(storageID, root) {
                if entry.name == BinLayout.markerName { continue }
                do {
                    let inspected = try await inspectEntry(storageID, entry, identity: identity, roots: roots)
                    managed.append(entry)
                    if let file = inspected.file {
                        items.append(.init(file: file, entry: entry, originalPath: inspected.record.originalPath))
                    }
                } catch is DecodingError, BinError.invalidEntry {
                    items.append(.init(file: entry, entry: entry, originalPath: nil))
                }
                // I/O errors propagate. An incomplete listing never becomes zero.
            }
        }
        return BinListing(roots: roots, entries: managed, items: items)
    }

    /// Delete only the exact selection beneath BIN, children before parents.
    /// A newly appearing child stops deletion of its parent; never use recursive
    /// responder deletion or an all-objects wildcard.
    func permanentlyDelete(storageID: UInt32, file: MTPFile, expectedItem: BinListing.Item? = nil) async throws {
        try await gate.run {
            guard await self.backend.supportsBinDeletion(storageID: storageID) else { throw BinError.unsupported }
            let roots = try await self.binRoots(storageID)
            guard let location = roots.first(where: { file.path != $0 && BinLayout.contains(file.path, in: $0) }),
                file.path != RemotePath.appending(BinLayout.markerName, to: location) else { throw BinError.invalidEntry }
            if let expectedItem {
                guard expectedItem.entry == file else { throw BinError.changed }
            }
            if expectedItem == nil || expectedItem?.originalPath != nil {
                // Empty Bin revalidates every managed record. Unknown contents
                // require an explicit selected row in a marker-owned directory.
                let inspected = try await self.inspectEntry(storageID, file,
                    identity: self.backend.binIdentity(storageID: storageID), roots: roots)
                if let expectedItem {
                    guard inspected.file == expectedItem.file,
                        inspected.record.originalPath == expectedItem.originalPath else { throw BinError.changed }
                }
            }
            var remaining = 100_000
            try await self.deleteTree(storageID, file, root: location, depth: 0, remaining: &remaining)
        }
    }

    private func deleteTree(_ storageID: UInt32, _ file: MTPFile, root: String, depth: Int, remaining: inout Int) async throws {
        guard depth < 128, remaining > 0, file.path != root,
            BinLayout.contains(file.path, in: root) else { throw BinError.invalidEntry }
        remaining -= 1
        guard try await entries(storageID, file.parentPath).contains(file) else { throw BinError.changed }
        if file.isFolder {
            let children = try await entries(storageID, file.path)
            // Files/payload trees precede restore notes so a partial failure
            // retains recovery information for the remaining payload.
            for child in children.sorted(by: { $0.isFolder && !$1.isFolder }) {
                try await deleteTree(storageID, child, root: root, depth: depth + 1, remaining: &remaining)
            }
            guard try await entries(storageID, file.path).isEmpty else { throw BinError.changed }
            let parentEntries = try await entries(storageID, file.parentPath)
            guard let fresh = parentEntries.first(where: {
                $0.id == file.id && $0.sessionID == file.sessionID && $0.path == file.path && $0.isFolder
            }) else { throw BinError.changed }
            try await backend.deleteBinItem(storageID: storageID, file: fresh, within: root)
        } else {
            try await backend.deleteBinItem(storageID: storageID, file: file, within: root)
        }
    }

    private func entries(_ storageID: UInt32, _ path: String) async throws -> [MTPFile] {
        try await backend.contents(storageID: storageID, path: path, showHiddenFiles: true)
    }

    private func directoryExists(_ storageID: UInt32, _ parent: String, _ name: String) async throws -> Bool {
        let existing = try await entries(storageID, parent).filter {
            RemotePath.collisionKey($0.name) == RemotePath.collisionKey(name)
        }
        if existing.count == 1, let folder = existing.first, folder.isFolder,
            Data(folder.name.utf8) == Data(name.utf8) { return true }
        guard existing.isEmpty else { throw BinError.conflict(RemotePath.appending(name, to: parent)) }
        return false
    }

    private func ensureDirectory(_ storageID: UInt32, _ parent: String, _ name: String) async throws {
        if try await directoryExists(storageID, parent, name) { return }
        guard case .created = try await backend.createUploadDirectory(
            storageID: storageID, parent: parent, name: name) else {
            throw BinError.conflict(RemotePath.appending(name, to: parent))
        }
    }

    private func trashImpl(storageID: UInt32, file: MTPFile) async throws {
        guard await backend.supportsBin(storageID: storageID) else { throw BinError.unsupported }
        let roots = try await binRoots(storageID)
        guard let root = roots.first else { throw BinError.missing }
        try BinLayout.validateSource(file, roots: roots)
        guard try await entries(storageID, file.parentPath).contains(file) else { throw BinError.changed }
        let identity = try await backend.binIdentity(storageID: storageID)
        let record = try BinRecord(file: file, storage: identity, entryID: UUID(), roots: roots)
        // Unlike shared parent folders, never adopt an existing entry folder.
        guard case .created = try await backend.createUploadDirectory(
            storageID: storageID, parent: root, name: record.entryName) else {
            throw BinError.conflict(record.entryName)
        }
        let entryPath = RemotePath.appending(record.entryName, to: root)
        try await ensureDirectory(storageID, entryPath, BinLayout.payloadName)
        let payload = RemotePath.appending(BinLayout.payloadName, to: entryPath)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try await putVerified(try encoder.encode(record), name: BinLayout.metadataName,
            storageID: storageID, directory: entryPath)
        let note = """
        Piko recoverable bin — files still occupy device storage.
        Original location: \(record.originalPath)
        Storage: \(identity.storageDescription) \(identity.volumeLabel)
        Binned at: \(record.binnedAt.ISO8601Format())

        To restore manually, move the item inside Files to its original location.
        Restore.json contains the machine-readable recovery information.
        Empty Files means preparation was interrupted, or the item was restored/moved manually.
        Piko never automatically empties this bin.
        """
        try await putVerified(Data(note.utf8), name: "Restore-info.txt",
            storageID: storageID, directory: entryPath)
        // Exercise both directions with our own tiny file before touching the selection.
        let probe = try await putVerified(Data("Piko move compatibility check. Safe to remove manually.\n".utf8),
            name: "Move-check.txt", storageID: storageID, directory: entryPath)
        let movedProbe = try await backend.move(storageID: storageID, file: probe, to: payload)
        let returnedProbe = try await backend.move(storageID: storageID, file: movedProbe, to: entryPath)
        // A recovered probe may belong to a new session. Leave user data
        // untouched until the user selects it again from a refreshed listing.
        guard returnedProbe.sessionID == file.sessionID else { throw BinError.preparationSessionChanged }
        guard try await entries(storageID, payload).isEmpty else { throw BinError.changed }
        // All recovery data is durable on the responder before this call.
        _ = try await backend.move(storageID: storageID, file: file, to: payload)
    }

    private func restoreImpl(storageID: UInt32, entry: MTPFile, expectedItem: BinListing.Item?) async throws {
        guard await backend.supportsBin(storageID: storageID) else { throw BinError.unsupported }
        let roots = try await binRoots(storageID)
        guard roots.contains(entry.parentPath), try await entries(storageID, entry.parentPath).contains(entry) else { throw BinError.invalidEntry }
        let inspected = try await inspectEntry(storageID, entry, identity: backend.binIdentity(storageID: storageID), roots: roots)
        if let expectedItem {
            guard expectedItem.entry == entry, inspected.file == expectedItem.file,
                inspected.record.originalPath == expectedItem.originalPath else { throw BinError.changed }
        }
        guard let file = inspected.file else { throw BinError.emptyEntry }
        let record = inspected.record
        // Recreate missing original parents, but never replace a conflicting item.
        var parent = "/"
        for component in record.originalParent.split(separator: "/") {
            try await ensureDirectory(storageID, parent, String(component))
            parent = RemotePath.appending(String(component), to: parent)
        }
        _ = try await backend.move(storageID: storageID, file: file, to: record.originalParent)
        // Keep metadata and empty entry as a recovery/audit record. No permanent cleanup.
    }

    private func inspectEntry(_ storageID: UInt32, _ entry: MTPFile, identity: BinStorageIdentity, roots: [String])
        async throws -> (record: BinRecord, file: MTPFile?)
    {
        guard entry.isFolder, roots.contains(entry.parentPath),
            entry.path == RemotePath.appending(entry.name, to: entry.parentPath) else { throw BinError.invalidEntry }
        let children = try await entries(storageID, entry.path)
        let notes: Set<String> = [BinLayout.metadataName, "Restore-info.txt", "Move-check.txt"]
        guard children.allSatisfy({ $0.isFolder ? $0.name == BinLayout.payloadName : notes.contains($0.name) }) else {
            throw BinError.invalidEntry
        }
        guard let metadata = children.first(where: { $0.name == BinLayout.metadataName && !$0.isFolder }),
            children.contains(where: { $0.name == BinLayout.payloadName && $0.isFolder }) else {
            throw BinError.invalidEntry
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(BinRecord.self, from: await readSmall(storageID, metadata))
        try record.validate(entryName: entry.name, storage: identity, roots: roots)
        let payload = try await entries(storageID, RemotePath.appending(BinLayout.payloadName, to: entry.path))
        guard !payload.isEmpty else { return (record, nil) }
        guard payload.count == 1, let file = payload.first,
            Data(file.name.utf8) == Data(record.originalName.utf8),
            file.isFolder == record.isFolder, file.size == record.size else { throw BinError.invalidEntry }
        return (record, file)
    }

    @discardableResult
    private func putVerified(_ data: Data, name: String, storageID: UInt32, directory: String) async throws -> MTPFile {
        let temporary = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let local = temporary.appendingPathComponent(name)
        try data.write(to: local, options: .atomic)
        let outcome = try await backend.upload(storageID: storageID, source: local, to: directory, progress: { _ in })
        if case .skippedExisting = outcome { throw BinError.conflict(directory + "/" + name) }
        let matches = try await entries(storageID, directory).filter { Data($0.name.utf8) == Data(name.utf8) }
        guard matches.count == 1, let file = matches.first, !file.isFolder,
            file.size == Int64(data.count), try await readSmall(storageID, file) == data else {
            throw BinError.invalidEntry
        }
        return file
    }

    private func readSmall(_ storageID: UInt32, _ file: MTPFile) async throws -> Data {
        guard !file.isFolder, file.size >= 0, file.size <= 64 * 1024 else { throw BinError.invalidEntry }
        let temporary = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        try await backend.download(storageID: storageID, files: [file], to: temporary, progress: { _ in })
        let data = try Data(contentsOf: temporary.appendingPathComponent(file.name))
        guard data.count == file.size else { throw BinError.invalidEntry }
        return data
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("piko-bin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        return url
    }
}

extension MTPBinBackend {
    func supportsBinDeletion(storageID: UInt32) async -> Bool { false }
    func deleteBinItem(storageID: UInt32, file: MTPFile, within root: String) async throws { throw BinError.unsupported }

    func supportsMove(storageID: UInt32) async -> Bool { await supportsBin(storageID: storageID) }
}
