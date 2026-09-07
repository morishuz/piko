import Darwin
import Foundation

/// Shared POSIX error and short-I/O handling; callers retain their own
/// descriptor ownership, identity checks, size limits and cancellation policy.
enum LocalFileIO {
    static func error(_ code: Int32, for url: URL? = nil) -> NSError {
        var details: [String: Any] = [:]
        if let url { details[NSFilePathErrorKey] = url.path }
        return NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: details)
    }

    static func read(_ descriptor: Int32, into buffer: UnsafeMutableRawPointer?, count: Int) throws -> Int {
        while true {
            let result = Darwin.read(descriptor, buffer, count)
            if result >= 0 { return result }
            let code = errno
            if code != EINTR { throw error(code) }
        }
    }

    static func write(_ descriptor: Int32, from buffer: UnsafeRawPointer?, count: Int) throws -> Int {
        while true {
            let result = Darwin.write(descriptor, buffer, count)
            if result >= 0 { return result }
            let code = errno
            if code != EINTR { throw error(code) }
        }
    }

    static func sourceSize(_ source: URL) throws -> Int64 {
        guard source.isFileURL else { throw UploadError.unsupportedSource }
        try RemotePath.validateName(source.lastPathComponent)
        let attrs = try FileManager.default.attributesOfItem(atPath: source.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular,
            let size = attrs[.size] as? NSNumber,
            try source.resourceValues(forKeys: [.isPackageKey]).isPackage != true
        else {
            throw UploadError.unsupportedSource
        }
        return size.int64Value
    }
}
