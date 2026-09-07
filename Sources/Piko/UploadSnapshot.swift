import Darwin
import Foundation

/// Private per-file disk snapshot copied through fixed-size buffers. Caller must
/// clean it up even after cancellation or backend failure.
struct UploadSnapshot: Sendable {
    private static let copyBufferSize = 256 * 1_024

    let folder: URL
    let file: URL
    let size: Int64

    init(
        source: URL, expectedIdentity: UploadSourceIdentity? = nil,
        cancelled: @Sendable () -> Bool = { false },
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) throws {
        func checkCancellation() throws {
            if cancelled() || Task.isCancelled { throw CancellationError() }
        }

        try checkCancellation()
        let selectedIdentity = try expectedIdentity ?? UploadSourceIdentity.capture(at: source)
        guard selectedIdentity.kind == .file else { throw UploadError.unsupportedSource }

        // Capture through the descriptor used for every read. O_NOFOLLOW closes
        // the symlink race; O_NONBLOCK prevents an exchanged FIFO from hanging.
        let sourceDescriptor = Darwin.open(
            source.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard sourceDescriptor >= 0 else {
            let errorCode = errno
            if errorCode == ELOOP { throw UploadError.unsupportedSource }
            throw LocalFileIO.error(errorCode, for: source)
        }
        defer { _ = Darwin.close(sourceDescriptor) }
        let sourceIdentity = try UploadSourceIdentity.capture(descriptor: sourceDescriptor)
        guard sourceIdentity == selectedIdentity, sourceIdentity.kind == .file else {
            throw UploadError.sourceChanged
        }

        let fm = FileManager.default
        let directory = temporaryDirectory.appendingPathComponent(
            "piko-upload-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(
            at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        do {
            let copy = directory.appendingPathComponent(source.lastPathComponent)
            let destinationDescriptor = Darwin.open(
                copy.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode_t(0o600))
            guard destinationDescriptor >= 0 else {
                let errorCode = errno
                throw LocalFileIO.error(errorCode, for: copy)
            }
            defer { _ = Darwin.close(destinationDescriptor) }

            try Self.copy(
                from: sourceDescriptor, to: destinationDescriptor,
                expectedSize: sourceIdentity.size, checkCancellation: checkCancellation)

            // Preserve the user-visible source timestamp without copying broad
            // permissions or extended attributes into this private staging file.
            let timestamps = [
                timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)),
                timespec(
                    tv_sec: Int(sourceIdentity.modificationSeconds),
                    tv_nsec: Int(sourceIdentity.modificationNanoseconds)),
            ]
            let timestampResult = timestamps.withUnsafeBufferPointer {
                futimens(destinationDescriptor, $0.baseAddress)
            }
            if timestampResult != 0 {
                let errorCode = errno
                throw LocalFileIO.error(errorCode, for: copy)
            }

            let afterDescriptor = try UploadSourceIdentity.capture(descriptor: sourceDescriptor)
            guard afterDescriptor == sourceIdentity else { throw UploadError.sourceChanged }
            try sourceIdentity.validate(at: source)

            let copyIdentity = try UploadSourceIdentity.capture(descriptor: destinationDescriptor)
            guard copyIdentity.kind == .file, copyIdentity.size == sourceIdentity.size else {
                throw UploadError.sourceChanged
            }
            try checkCancellation()

            folder = directory
            file = copy
            size = sourceIdentity.size
        } catch {
            try? fm.removeItem(at: directory)
            throw error
        }
    }

    func remove() { try? FileManager.default.removeItem(at: folder) }

    private static func copy(
        from source: Int32, to destination: Int32, expectedSize: Int64,
        checkCancellation: () throws -> Void
    ) throws {
        var buffer = [UInt8](repeating: 0, count: copyBufferSize)
        var copied: Int64 = 0
        while copied < expectedSize {
            try checkCancellation()
            let requested = Int(min(Int64(buffer.count), expectedSize - copied))
            let count = try buffer.withUnsafeMutableBytes { bytes -> Int in
                try LocalFileIO.read(
                    source, into: bytes.baseAddress, count: requested)
            }
            guard count > 0 else { throw UploadError.sourceChanged }

            var written = 0
            while written < count {
                try checkCancellation()
                let amount = try buffer.withUnsafeBytes { bytes -> Int in
                    try LocalFileIO.write(
                        destination, from: bytes.baseAddress?.advanced(by: written),
                        count: count - written)
                }
                guard amount > 0 else { throw LocalFileIO.error(EIO) }
                written += amount
            }
            copied += Int64(count)
        }

        // A file that grew after fstat must not silently produce a truncated
        // snapshot even if its metadata changes again before final validation.
        try checkCancellation()
        var extraByte: UInt8 = 0
        let trailingCount = try withUnsafeMutableBytes(of: &extraByte) { bytes in
            try LocalFileIO.read(source, into: bytes.baseAddress, count: 1)
        }
        guard trailingCount == 0 else { throw UploadError.sourceChanged }
    }

}
