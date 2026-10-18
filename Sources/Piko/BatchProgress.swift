import Foundation

/// Progress through planned file bytes. Resolved conflicts/failures count as
/// processed work, not copied bytes; unattempted/cancelled files stay unfinished.
/// Folders are omitted by callers so the count describes files only.
struct BatchProgress {
    private var sizes: [String: Int64] = [:]
    private var resolved: Set<String> = []
    private var resolvedBytes: Double = 0
    private(set) var totalBytes: Double?
    var fileCount: Int { sizes.count }
    var processedFileCount: Int { resolved.count }

    init(files: [(String, Int64)] = []) {
        sizes = Dictionary(files, uniquingKeysWith: { first, _ in first })
        totalBytes = sizes.values.contains(where: { $0 < 0 }) ? nil
            : sizes.values.reduce(0) { $0 + Double($1) }
    }

    mutating func resolve(_ path: String) {
        guard let size = sizes[path], resolved.insert(path).inserted else { return }
        resolvedBytes += Double(max(0, size))
    }

    func fraction(activePath: String?, activeBytes: Double = 0) -> Double? {
        guard let totalBytes else { return nil }
        guard totalBytes > 0 else {
            return fileCount == 0 ? 0 : Double(processedFileCount) / Double(fileCount)
        }
        var current: Double = 0
        if let activePath, !resolved.contains(activePath), let size = sizes[activePath] {
            current = min(Double(max(0, size)), max(0, activeBytes))
        }
        return min(1, max(0, (resolvedBytes + current) / totalBytes))
    }
}
