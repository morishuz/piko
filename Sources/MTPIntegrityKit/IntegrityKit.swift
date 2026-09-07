import CryptoKit
import Foundation

public enum KitError: LocalizedError, Equatable {
    case unsafeEntry
    case mismatch(Int)
    case invalidDestination
    public var errorDescription: String? {
        switch self {
        case .unsafeEntry: "Verification refused a symbolic link or nonregular entry."
        case .mismatch(let count):
            "FAIL: \(count) synthetic file, size, hash or tree checks differed. Only expected fixture paths are eligible for content verification."
        case .invalidDestination:
            "Choose a new, nonexistent kit folder inside an existing directory. Existing files are never replaced."
        }
    }
}

public struct IntegrityKit {
    public static let toolVersion = "0.15.2"

    struct File: Codable, Equatable {
        let path: String
        let size: Int
        let byte: UInt8
        var sha256: String {
            var hash = SHA256()
            for chunk in chunks { hash.update(data: chunk) }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
        // Each iteration allocates at most 64 KiB, including the 8 MiB fixture.
        var chunks: AnySequence<Data> {
            AnySequence {
                var remaining = size
                return AnyIterator<Data> {
                    guard remaining > 0 else { return nil }
                    let count = min(remaining, 65536)
                    remaining -= count
                    return Data(repeating: byte, count: count)
                }
            }
        }
    }
    public static let version = "1"
    public static var fileCount: Int { files.count }
    static let directories = ["Empty folder", "Nested"]
    static let files: [File] = {
        let sizes: [Int] = [0, 1, 63, 64, 65, 500, 512, 513, 65524, 65536, 65537, 8 * 1024 * 1024 + 17]
        var result = sizes.enumerated().map { index, size in
            File(path: "Nested/boundary-\(size).bin", size: size, byte: UInt8(index + 33))
        }
        result.append(File(path: "日本語 📷.txt", size: 97, byte: 0x55))
        result.append(File(path: ".hidden-test", size: 31, byte: 0x66))
        return result
    }()

    public static func generate(at kit: URL) throws {
        guard kit.isFileURL, !FileManager.default.fileExists(atPath: kit.path),
            try kit.deletingLastPathComponent().resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        else { throw KitError.invalidDestination }
        try FileManager.default.createDirectory(at: kit, withIntermediateDirectories: false)
        let root = kit.appendingPathComponent("MTP-Synthetic", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        for name in directories {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(name), withIntermediateDirectories: false)
        }
        for file in files {
            let url = root.appendingPathComponent(file.path)
            try Data().write(to: url, options: .withoutOverwriting)
            let handle = try FileHandle(forWritingTo: url)
            do {
                for chunk in file.chunks { try handle.write(contentsOf: chunk) }
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
        }
        // Informational only: verification uses the compiled recipe, never a
        // mutable manifest that could redirect it to private paths or files.
        struct Entry: Encodable {
            let path: String
            let size: Int
            let sha256: String
        }
        let manifest = files.map { Entry(path: $0.path, size: $0.size, sha256: $0.sha256) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(
            to: kit.appendingPathComponent("SHA256.json"), options: .withoutOverwriting)
    }

    public static func verify(root requested: URL) throws -> (files: Int, bytes: Int) {
        guard requested.isFileURL,
            try FileManager.default.attributesOfItem(atPath: requested.path)[.type] as? FileAttributeType
                == .typeDirectory
        else { throw KitError.unsafeEntry }
        // Foundation enumeration canonicalizes /var to /private/var on macOS.
        // Compare components of canonical paths, not character-count prefixes.
        let root = requested.standardizedFileURL.resolvingSymlinksInPath()
        var expected = Set(files.map(\.path) + directories)
        var differences = 0
        var scanError = false
        guard
            let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isSymbolicLinkKey],
                errorHandler: { _, _ in
                    scanError = true
                    return false
                })
        else { throw KitError.unsafeEntry }
        for case let url as URL in enumerator {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let type = attrs[.type] as? FileAttributeType,
                type == .typeRegular || type == .typeDirectory
            else { throw KitError.unsafeEntry }
            let components = url.standardizedFileURL.pathComponents
            guard components.starts(with: root.pathComponents) else { throw KitError.unsafeEntry }
            let relative = components.dropFirst(root.pathComponents.count).joined(separator: "/")
            if url.lastPathComponent == ".DS_Store", type == .typeRegular { continue }
            if expected.remove(relative) == nil { differences += 1 }
        }
        if scanError { throw KitError.unsafeEntry }
        differences += expected.count
        // Unknown entries were counted, never opened. Stop before reading any
        // content when the tree does not match the known synthetic recipe.
        guard differences == 0 else { throw KitError.mismatch(differences) }
        for directory in directories {
            guard
                try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(directory).path)[
                    .type] as? FileAttributeType == .typeDirectory
            else { throw KitError.unsafeEntry }
        }
        for file in files {
            let url = root.appendingPathComponent(file.path)
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attrs[.type] as? FileAttributeType == .typeRegular else { throw KitError.unsafeEntry }
            guard (attrs[.size] as? NSNumber)?.int64Value == Int64(file.size) else {
                differences += 1
                continue
            }
            let handle = try FileHandle(forReadingFrom: url)
            var hash = SHA256()
            var read = 0
            do {
                while let chunk = try handle.read(upToCount: 65536), !chunk.isEmpty {
                    read += chunk.count
                    guard read <= file.size else { throw KitError.mismatch(1) }
                    hash.update(data: chunk)
                }
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
            if read != file.size || actual != file.sha256 { differences += 1 }
        }
        guard differences == 0 else { throw KitError.mismatch(differences) }
        return (files.count, files.reduce(0) { $0 + $1.size })
    }
}
