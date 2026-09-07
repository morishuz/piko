import Darwin
import Foundation

/// Stable metadata captured from an open filesystem object. Device and inode
/// distinguish replacements even when a new object has the same name and size.
struct UploadSourceIdentity: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case file, directory
    }

    let kind: Kind
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let changeSeconds: Int64
    let changeNanoseconds: Int64

    static func capture(at url: URL) throws -> Self {
        guard url.isFileURL else { throw UploadError.unsupportedSource }

        // Reject obvious special files before opening them. O_NONBLOCK and the
        // decisive fstat below also make a path-swap to a FIFO safe.
        var pathMetadata = stat()
        if lstat(url.path, &pathMetadata) != 0 {
            let errorCode = errno
            throw LocalFileIO.error(errorCode, for: url)
        }
        guard supportedKind(pathMetadata.st_mode) != nil else {
            throw UploadError.unsupportedSource
        }
        let pathIdentity = try capture(metadata: pathMetadata)

        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            let errorCode = errno
            if errorCode == ELOOP { throw UploadError.unsupportedSource }
            throw LocalFileIO.error(errorCode, for: url)
        }
        defer { _ = Darwin.close(descriptor) }
        let descriptorIdentity = try capture(descriptor: descriptor)
        guard descriptorIdentity == pathIdentity else { throw UploadError.sourceChanged }
        return descriptorIdentity
    }

    static func capture(descriptor: Int32) throws -> Self {
        var metadata = stat()
        if fstat(descriptor, &metadata) != 0 {
            let errorCode = errno
            throw LocalFileIO.error(errorCode)
        }
        return try capture(metadata: metadata)
    }

    private static func capture(metadata: stat) throws -> Self {
        guard let kind = supportedKind(metadata.st_mode), metadata.st_size >= 0 else {
            throw UploadError.unsupportedSource
        }
        return Self(
            kind: kind,
            device: UInt64(bitPattern: Int64(metadata.st_dev)),
            inode: UInt64(metadata.st_ino),
            size: Int64(metadata.st_size),
            modificationSeconds: Int64(metadata.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(metadata.st_mtimespec.tv_nsec),
            changeSeconds: Int64(metadata.st_ctimespec.tv_sec),
            changeNanoseconds: Int64(metadata.st_ctimespec.tv_nsec))
    }

    func validate(at url: URL) throws {
        guard (try? Self.capture(at: url)) == self else { throw UploadError.sourceChanged }
    }

    private static func supportedKind(_ mode: mode_t) -> Kind? {
        switch mode & S_IFMT {
        case S_IFREG: .file
        case S_IFDIR: .directory
        default: nil
        }
    }
}

private struct PlannedUploadAncestor: Sendable {
    let url: URL
    let identity: UploadSourceIdentity
}

struct UploadPlanItem: Sendable {
    enum Kind: Sendable {
        case file, directory
        case excluded(String)
    }
    let source: URL
    let components: [String]
    let kind: Kind
    private let identity: UploadSourceIdentity
    private let ancestors: [PlannedUploadAncestor]

    /// The stable size observed while planning, suitable for checking protocol
    /// limits before spending time making a private snapshot.
    var plannedFileSize: Int64? {
        if case .file = kind { identity.size } else { nil }
    }

    func remoteParent(in directory: String) -> String {
        components.dropLast().reduce(directory) { RemotePath.appending($1, to: $0) }
    }

    /// Ensures no selected ancestor was exchanged for another directory (or a
    /// symlink/package) after the upload tree was planned.
    func validateAncestors() throws {
        for ancestor in ancestors {
            try ancestor.identity.validate(at: ancestor.url)
            guard try ancestor.url.resourceValues(forKeys: [.isPackageKey]).isPackage != true else {
                throw UploadError.sourceChanged
            }
        }
    }

    /// Call immediately before creating a remote directory or snapshotting a
    /// file. This binds the later operation to the exact object selected during
    /// planning, not merely to a reusable pathname.
    func validateForSnapshot() throws {
        try validateAncestors()
        try identity.validate(at: source)
        guard try source.resourceValues(forKeys: [.isPackageKey]).isPackage != true else {
            throw UploadError.sourceChanged
        }
    }

    /// Atomically binds snapshot input to the exact file identity captured by
    /// this plan. Revalidation after copying also closes ancestor-replacement
    /// races; once this returns, the private snapshot no longer depends on the
    /// selected source path.
    func makeSnapshot(
        cancelled: @Sendable () -> Bool = { false },
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) throws -> UploadSnapshot {
        guard case .file = kind else { throw UploadError.unsupportedSource }
        try validateForSnapshot()
        let snapshot = try UploadSnapshot(
            source: source, expectedIdentity: identity, cancelled: cancelled,
            temporaryDirectory: temporaryDirectory)
        do {
            try validateForSnapshot()
            return snapshot
        } catch {
            snapshot.remove()
            throw error
        }
    }

    fileprivate init(
        source: URL, components: [String], kind: Kind,
        identity: UploadSourceIdentity, ancestors: [PlannedUploadAncestor]
    ) {
        self.source = source
        self.components = components
        self.kind = kind
        self.identity = identity
        self.ancestors = ancestors
    }
}

/// Walks metadata only, never follows symbolic links or descends into packages.
/// Complete planning precedes all writes, so an unreadable/unsupported tree fails
/// before any remote object is created. Run outside the main actor.
enum UploadPlan {
    static func build(
        sources: [URL], maximumItems: Int = 100_000, maximumDepth: Int = 128,
        cancelled: @Sendable () -> Bool = { false }
    ) throws -> [UploadPlanItem] {
        let fm = FileManager.default
        var items: [UploadPlanItem] = []
        let roots = try sources.map { source -> (URL, UploadSourceIdentity) in
            guard source.isFileURL else { throw UploadError.unsupportedSource }
            let url = source.standardizedFileURL
            let identity = try UploadSourceIdentity.capture(at: url)
            return (url, identity)
        }

        func visit(
            _ source: URL, components: [String], ancestors: [PlannedUploadAncestor],
            expectedIdentity: UploadSourceIdentity? = nil
        ) throws {
            if cancelled() || Task.isCancelled { throw CancellationError() }
            guard items.count < maximumItems, components.count <= maximumDepth else {
                throw TransferError.treeLimit
            }
            try RemotePath.validateName(source.lastPathComponent)
            let identity = try UploadSourceIdentity.capture(at: source)
            guard expectedIdentity == nil || expectedIdentity == identity else {
                throw UploadError.sourceChanged
            }
            guard try source.resourceValues(forKeys: [.isPackageKey]).isPackage != true else {
                throw UploadError.unsupportedSource
            }
            // Finder metadata is not useful on the device; report the exclusion.
            if source.lastPathComponent == ".DS_Store" {
                items.append(
                    UploadPlanItem(
                        source: source, components: components, kind: .excluded("Finder metadata"),
                        identity: identity, ancestors: ancestors))
                return
            }
            let isDirectory = identity.kind == .directory
            items.append(
                UploadPlanItem(
                    source: source, components: components, kind: isDirectory ? .directory : .file,
                    identity: identity, ancestors: ancestors))
            if isDirectory {
                let children = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
                let descendants = ancestors + [PlannedUploadAncestor(url: source, identity: identity)]
                for child in children {
                    try visit(
                        child, components: components + [child.lastPathComponent],
                        ancestors: descendants)
                }
                // Catch replacement or mutation during enumeration itself.
                try identity.validate(at: source)
            }
        }

        var seenRoots: Set<URL> = []
        for (source, identity) in roots {
            guard seenRoots.insert(source).inserted else { continue }
            // A selected child is already included when its ancestor is selected.
            if roots.contains(where: {
                $0.1.kind == .directory && source.path.hasPrefix($0.0.path + "/")
            }) { continue }
            try visit(
                source, components: [source.lastPathComponent], ancestors: [],
                expectedIdentity: identity)
        }
        return items
    }
}

/// Cancellation for synchronous directory enumeration on the worker task.
final class PlanningCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() {
        lock.lock()
        value = true
        lock.unlock()
    }
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
