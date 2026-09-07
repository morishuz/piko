import Foundation

/// Local destination validation and publishing, independent of USB or UI state.
/// Staging stays on the destination filesystem; existing files remain intact
/// until a complete size-checked download can be published.
struct DownloadDestination {
    let root: URL
    init(_ url: URL) throws {
        guard url.isFileURL else { throw TransferError.invalidDestination }
        root = url.standardizedFileURL.resolvingSymlinksInPath()
        guard try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw TransferError.invalidDestination
        }
    }

    func prepare(_ item: DownloadPlanItem, conflicts: ConflictPolicy) throws -> URL? {
        let target = try parent(for: item).appendingPathComponent(item.file.name)
        if item.file.isFolder {
            try ensureDirectory(target)
            return target
        }
        return try resolveConflict(target, policy: conflicts)
    }

    func makeStagingDirectory() throws -> URL {
        let staging = root.appendingPathComponent(".piko-staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return staging
    }

    func publish(_ staged: URL, item: DownloadPlanItem, target: URL, conflicts: ConflictPolicy) throws -> URL?
    {
        let attributes = try FileManager.default.attributesOfItem(atPath: staged.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
            let size = attributes[.size] as? NSNumber
        else { throw TransferError.invalidDownloadedFile }
        if item.file.size >= 0, size.int64Value != item.file.size {
            throw TransferError.sizeMismatch(expected: item.file.size, actual: size.int64Value)
        }
        // Recheck after I/O. Never knowingly replace a symlink or directory.
        _ = try parent(for: item)
        guard let destination = try resolveConflict(target, policy: conflicts) else { return nil }
        if conflicts == .replace, try attributesIfPresent(destination) != nil {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
        } else {
            try FileManager.default.moveItem(at: staged, to: destination)
        }
        return destination
    }

    private func parent(for item: DownloadPlanItem) throws -> URL {
        try ensureDirectory(root)
        var parent = root
        for component in item.components.dropLast() {
            parent.appendPathComponent(component, isDirectory: true)
            try ensureDirectory(parent)
        }
        return parent
    }

    private func resolveConflict(_ url: URL, policy: ConflictPolicy) throws -> URL? {
        guard let attributes = try attributesIfPresent(url) else { return url }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw TransferError.invalidDestination
        }
        switch policy {
        case .skip: return nil
        case .keepBoth: return try uniqueTarget(url)
        case .replace: return url
        }
    }

    private func attributesIfPresent(_ url: URL) throws -> [FileAttributeKey: Any]? {
        do { return try FileManager.default.attributesOfItem(atPath: url.path) } catch let error as NSError
            where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError
        {
            return nil
        }
    }

    private func ensureDirectory(_ url: URL) throws {
        if let attributes = try attributesIfPresent(url) {
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw TransferError.invalidDestination
            }
        } else {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        }
    }

    private func uniqueTarget(_ url: URL) throws -> URL {
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        for index in 2...100_000 {
            let name = "\(base) (\(index))" + (ext.isEmpty ? "" : ".\(ext)")
            let candidate = url.deletingLastPathComponent().appendingPathComponent(name)
            if try attributesIfPresent(candidate) == nil { return candidate }
        }
        throw BackendError.invalidPath(url.lastPathComponent)
    }
}
