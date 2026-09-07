import Darwin
import Foundation
import MTPWire

/// Bounded, synchronous sink invoked serially by ReadSession. The lock protects
/// its Sendable boundary; no file-sized Data allocation or overwrite is used.
final class DownloadFileSink: @unchecked Sendable {
    private let lock = NSLock()
    private let file: FileHandle
    private let url: URL
    private let expectedSize: Int64
    private let name: String
    private let progress: ProgressHandler
    private var count: Int64 = 0

    init(url: URL, expectedSize: Int64, name: String, progress: @escaping ProgressHandler) throws {
        let descriptor = Darwin.open(
            url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw LocalFileIO.error(errno) }
        file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        self.url = url
        self.expectedSize = expectedSize
        self.name = name
        self.progress = progress
        progress(TransferProgress(fileName: name, bytesTransferred: 0, totalBytes: expectedSize))
    }

    func append(_ bytes: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        guard Int64(bytes.count) <= expectedSize - count else { throw WireError.objectSizeMismatch }
        try file.write(contentsOf: bytes)
        count += Int64(bytes.count)
        progress(TransferProgress(fileName: name, bytesTransferred: count, totalBytes: expectedSize))
    }

    func finish() throws {
        lock.lock()
        defer { lock.unlock() }
        guard count == expectedSize else { throw WireError.objectSizeMismatch }
        try file.close()
    }

    func discard() {
        lock.lock()
        defer { lock.unlock() }
        try? file.close()
        try? FileManager.default.removeItem(at: url)
    }
}

/// A bounded descriptor-backed source. UploadSnapshot gives this reader a
/// private immutable file; O_NOFOLLOW and fstat still enforce that boundary.
final class UploadFileReader: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32
    private let expectedSize: Int64
    private var count: Int64 = 0
    let modificationDate: String

    init(source: URL, expectedSize: Int64) throws {
        guard source.isFileURL, expectedSize >= 0 else { throw UploadError.unsupportedSource }
        let descriptor = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw LocalFileIO.error(errno) }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw LocalFileIO.error(code)
        }
        guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_size == expectedSize else {
            Darwin.close(descriptor)
            throw UploadError.sourceChanged
        }
        self.descriptor = descriptor
        self.expectedSize = expectedSize
        let timestamp = metadata.st_mtimespec
        let date = Date(
            timeIntervalSince1970: TimeInterval(timestamp.tv_sec)
                + TimeInterval(timestamp.tv_nsec) / 1_000_000_000)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        modificationDate = formatter.string(from: date)
    }

    deinit { if descriptor >= 0 { Darwin.close(descriptor) } }

    func read(maxBytes: Int) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard maxBytes > 0, descriptor >= 0 else { throw WireError.invalidLength }
        let remaining = expectedSize - count
        if remaining == 0 { return Data() }
        let requested = min(maxBytes, Int(remaining))
        var result = Data(count: requested)
        var offset = 0
        try result.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { throw WireError.invalidLength }
            while offset < requested {
                let transferred = try LocalFileIO.read(
                    descriptor, into: base.advanced(by: offset), count: requested - offset)
                if transferred > 0 {
                    offset += transferred
                } else {
                    throw UploadError.sourceChanged
                }
            }
        }
        count += Int64(offset)
        return result
    }

    func finish() throws {
        lock.lock()
        defer { lock.unlock() }
        guard count == expectedSize, descriptor >= 0 else { throw UploadError.sourceChanged }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0, metadata.st_size == expectedSize else {
            throw UploadError.sourceChanged
        }
        Darwin.close(descriptor)
        descriptor = -1
    }
}
