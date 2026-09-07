import Foundation

struct DownloadPlanItem: Sendable {
    let file: MTPFile
    let components: [String]
}

/// Plans the complete tree before any local writes. Parent selections subsume
/// selected children regardless of input order; handles deduplicate enumeration.
enum DownloadPlan {
    static func build(
        files: [MTPFile], backend: any MTPBackend, storageID: UInt32,
        cancelled: @Sendable () -> Bool
    ) async throws -> [DownloadPlanItem] {
        var items: [DownloadPlanItem] = []
        var visited: Set<UInt32> = []
        let folders = Set(files.filter(\.isFolder).map { Data($0.path.utf8) })
        for file in files {
            try validateEdge(file)
            let parts = file.path.split(separator: "/")
            let hasSelectedParent = (1..<parts.count).contains { count in
                folders.contains(
                    Data(("/" + parts.prefix(count).joined(separator: "/")).utf8))
            }
            if hasSelectedParent { continue }
            try await expand(
                file, expectedParentPath: nil, parents: [], ancestors: [], backend: backend,
                storageID: storageID, items: &items, visited: &visited, cancelled: cancelled)
        }
        try validateLocalFolderNames(items)
        return items
    }

    private static func expand(
        _ file: MTPFile, expectedParentPath: String?, parents: [String], ancestors: Set<UInt32>,
        backend: any MTPBackend, storageID: UInt32,
        items: inout [DownloadPlanItem], visited: inout Set<UInt32>,
        cancelled: @Sendable () -> Bool
    ) async throws {
        try Task.checkCancellation()
        if cancelled() { throw CancellationError() }
        try validateEdge(file, expectedParentPath: expectedParentPath)
        guard parents.count < 128, items.count < 100_000, !ancestors.contains(file.id) else {
            throw TransferError.treeLimit
        }
        guard visited.insert(file.id).inserted else { return }
        let components = parents + [file.name]
        items.append(DownloadPlanItem(file: file, components: components))
        if file.isFolder {
            let children = try await backend.contents(
                storageID: storageID, path: file.path, showHiddenFiles: true)
            for child in children {
                try await expand(
                    child, expectedParentPath: file.path, parents: components,
                    ancestors: ancestors.union([file.id]),
                    backend: backend, storageID: storageID, items: &items, visited: &visited,
                    cancelled: cancelled)
            }
        }
    }

    /// Validate the complete remote edge, not just the display name.
    /// A stale or inconsistent child path
    /// must never be used as a different download source under this local tree.
    private static func validateEdge(_ file: MTPFile, expectedParentPath: String? = nil) throws {
        try RemotePath.validateName(file.name)
        try RemotePath.validate(file.parentPath)
        try RemotePath.validate(file.path)
        if let expectedParentPath,
            Data(file.parentPath.utf8) != Data(expectedParentPath.utf8)
        {
            throw BackendError.invalidPath(file.path)
        }
        let expectedPath =
            RemotePath.appending(file.name, to: file.parentPath)
        guard Data(file.path.utf8) == Data(expectedPath.utf8) else {
            throw BackendError.invalidPath(file.path)
        }
    }

    /// Default APFS volumes are case- and normalization-insensitive. Files can
    /// use the destination's keep-both policy, but merging two distinct remote
    /// folders would also merge all descendants. Reject that tree before any
    /// local directory is created.
    private static func validateLocalFolderNames(_ items: [DownloadPlanItem]) throws {
        struct Key: Hashable {
            let parent: Data
            let localName: String
        }
        var seen: [Key: (id: UInt32, isFolder: Bool)] = [:]
        for item in items {
            let key = Key(
                parent: Data(item.file.parentPath.utf8),
                localName: RemotePath.collisionKey(item.file.name))
            if let previous = seen[key], previous.id != item.file.id,
                previous.isFolder || item.file.isFolder
            {
                throw TransferError.ambiguousLocalFolderNames
            }
            seen[key] = (item.file.id, item.file.isFolder)
        }
    }

}
