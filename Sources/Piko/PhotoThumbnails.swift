import Foundation
import ImageIO
import MTPWire

enum FileViewMode: String, CaseIterable { case list, grid }

enum ThumbnailGenerationError: LocalizedError {
    case unsupportedImage
    var errorDescription: String? { "This photo cannot be decoded safely into a thumbnail." }
}

/// Optional, read-only capability. Cancellation skips unstarted work but must
/// finish an already-started bounded transaction without aborting USB.
protocol MTPThumbnailBackend: MTPBackend {
    func thumbnail(storageID: UInt32, file: MTPFile) async throws -> Data?
}

extension MTPFile {
    var isPhotoThumbnailCandidate: Bool {
        !isFolder && ["jpg", "jpeg", "heic", "heif", "png", "gif", "bmp", "tif", "tiff", "dng"]
            .contains((name as NSString).pathExtension.lowercased())
    }

    var isVideoThumbnailCandidate: Bool {
        !isFolder && ["mp4", "mov", "m4v", "avi", "3gp", "3g2", "mpeg", "mpg", "wmv", "mkv", "webm", "360"]
            .contains((name as NSString).pathExtension.lowercased())
    }

    var isDeviceThumbnailCandidate: Bool { isPhotoThumbnailCandidate || isVideoThumbnailCandidate }
    var isThumbnailSidecar: Bool { !isFolder && (name as NSString).pathExtension.lowercased() == "thm" }
}

/// Match only an unambiguous companion in the same directory and session.
/// No scans, numbered-prefix guesses or cross-chapter substitutions.
struct ThumbnailSidecars {
    private struct Identity: Hashable {
        let session: UUID?
        let parent: String
        let stem: String
        init(_ file: MTPFile) {
            session = file.sessionID
            parent = file.parentPath
            stem = (file.name as NSString).deletingPathExtension.lowercased()
        }
    }
    private let matches: [Identity: [MTPFile]]
    init(_ files: [MTPFile]) {
        matches = Dictionary(grouping: files.filter { $0.isThumbnailSidecar || $0.isVideoThumbnailCandidate }, by: Identity.init)
    }
    func companion(for file: MTPFile) -> MTPFile? {
        guard file.isVideoThumbnailCandidate, let candidates = matches[Identity(file)], candidates.count == 2, candidates.contains(file),
            let candidate = candidates.first(where: \.isThumbnailSidecar), candidate.size > 0,
            candidate.size <= ReadSession.maximumThumbnailBytes else { return nil }
        return candidate
    }
}

struct PhotoThumbnailKey: Hashable, Sendable {
    let connection: Int
    let storageID: UInt32
    let file: MTPFile
    var previewFile: MTPFile? = nil
}

enum ThumbnailDecoder {
    static let maximumDimension = 256

    // Header limits precede decoding; UI views receive already-decoded images.
    static func decode(_ data: Data) -> CGImage? {
        guard !data.isEmpty, data.count <= ReadSession.maximumThumbnailBytes,
            let source = CGImageSourceCreateWithData(data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary),
            let type = CGImageSourceGetType(source) as String?,
            ["public.jpeg", "public.png"].contains(type) else { return nil }
        return downsample(source, maximumSide: 4096, maximumPixels: 4_194_304)
    }

    /// Read a verified temporary download through ImageIO without format-specific
    /// parsing or expanding an original into an NSImage on the main actor.
    static func decodeOriginal(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return downsample(source, maximumSide: 32768, maximumPixels: 100_000_000)
    }

    private static func downsample(_ source: CGImageSource, maximumSide: Int64, maximumPixels: Int64) -> CGImage? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
            let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
            width.int64Value > 0, height.int64Value > 0,
            width.int64Value <= maximumSide, height.int64Value <= maximumSide,
            width.int64Value * height.int64Value <= maximumPixels else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumDimension,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
            image.width <= maximumDimension, image.height <= maximumDimension else { return nil }
        return image
    }

}

@MainActor
final class PhotoThumbnailStore: ObservableObject {
    struct Entry {
        let image: CGImage?
        var cost: Int { image.map { $0.bytesPerRow * $0.height } ?? 0 }
    }
    @Published private(set) var loading: PhotoThumbnailKey?
    @Published private(set) var notice: String?
    @Published private(set) var revision = 0
    @Published private(set) var automaticPaused = false
    var automaticEnabled = true {
        didSet { scheduler?.cancel(); scheduler = nil; scheduleVisible(visible, enabled: visibleEnabled) }
    }
    private var visible: [PhotoThumbnailKey] = []
    private var visibleEnabled = false
    private var attempted: Set<PhotoThumbnailKey> = []
    private var scheduler: Task<Void, Never>?
    private var scheduleID = UUID()
    private var cache: [PhotoThumbnailKey: Entry] = [:]
    private var order: [PhotoThumbnailKey] = []
    private(set) var byteCount = 0
    private var epoch = 0
    private var worker: Task<Data?, any Error>?
    private let backend: (any MTPThumbnailBackend)?
    private let entryLimit: Int
    private let byteLimit: Int

    init(backend: any MTPBackend, entryLimit: Int = 128, byteLimit: Int = 8 * 1024 * 1024) {
        self.backend = backend as? any MTPThumbnailBackend
        self.entryLimit = max(1, entryLimit)
        self.byteLimit = max(0, byteLimit)
    }

    var isSupported: Bool { backend != nil }
    var count: Int { cache.count }
    func entry(for key: PhotoThumbnailKey) -> Entry? { cache[key] }

    func invalidatePending() {
        epoch += 1
        worker?.cancel()
        notice = nil
    }

    func clear() {
        scheduleVisible([], enabled: false)
        automaticPaused = false
        invalidatePending()
        cache.removeAll()
        order.removeAll()
        byteCount = 0
        revision += 1
        // Keep the one-flight reservation until the current response is drained.
    }

    func scheduleVisible(_ keys: [PhotoThumbnailKey], enabled: Bool) {
        let keys = Array(keys.filter { $0.file.isDeviceThumbnailCandidate }.prefix(128))
        guard keys != visible || enabled != visibleEnabled || scheduler == nil else { return }
        visible = keys
        visibleEnabled = enabled
        attempted.formIntersection(keys)
        // A still-visible request cancelled by scrolling/settings must remain
        // eligible after the viewport settles; only completed attempts stick.
        if let loading, cache[loading] == nil { attempted.remove(loading) }
        scheduler?.cancel()
        invalidatePending()
        let token = UUID()
        scheduleID = token
        guard enabled, automaticEnabled, !automaticPaused, isSupported, !keys.isEmpty else {
            scheduler = nil
            return
        }
        scheduler = Task { [weak self] in
            // Let scrolling settle. Never enqueue an entire directory on USB.
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            guard let self else { return }
            defer { if self.scheduleID == token { self.scheduler = nil } }
            while self.scheduleID == token, !Task.isCancelled, !self.automaticPaused {
                if self.loading != nil {
                    do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                    continue
                }
                guard let key = self.visible.first(where: { self.cache[$0] == nil && !self.attempted.contains($0) }) else { return }
                self.attempted.insert(key)
                let start = ContinuousClock.now
                do { try await self.load(key) }
                catch {
                    if self.scheduleID == token { self.automaticPaused = true }
                    self.onSessionFailure?(key, error)
                    return
                }
                if ContinuousClock.now - start > .seconds(1),
                    self.visible.first?.connection == key.connection,
                    self.visible.first?.file.sessionID == key.file.sessionID {
                    self.automaticPaused = true
                }
                guard self.scheduleID == token, !Task.isCancelled else { return }
                if self.notice != nil { self.automaticPaused = true }
                // A foreground request gets the next turn between thumbnails.
                do { try await Task.sleep(for: .milliseconds(75)) } catch { return }
            }
        }
    }

    var onSessionFailure: ((PhotoThumbnailKey, any Error) -> Void)?

    func resumeAutomatic() {
        automaticPaused = false
        attempted.removeAll()
        scheduler?.cancel()
        scheduler = nil
        scheduleVisible(visible, enabled: visibleEnabled)
    }

    func storeOriginal(_ image: CGImage, for key: PhotoThumbnailKey) {
        insert(Entry(image: image), for: key)
    }

    func load(_ key: PhotoThumbnailKey) async throws {
        guard let backend, key.file.isDeviceThumbnailCandidate,
            cache[key] == nil, loading == nil else { return }
        loading = key
        notice = nil
        let generation = epoch
        let task = Task { try await backend.thumbnail(storageID: key.storageID, file: key.previewFile ?? key.file) }
        worker = task
        defer { worker = nil; loading = nil }
        do {
            let data = try await task.value
            guard generation == epoch else { return }
            let image = await Task.detached(priority: .utility) {
                data.flatMap(ThumbnailDecoder.decode)
            }.value
            guard generation == epoch else { return }
            insert(Entry(image: image), for: key)
        } catch {
            // A lost session matters even if selection changed in the meantime.
            if let sessionError = BackendSessionError.from(error) { throw sessionError }
            guard generation == epoch, !(error is CancellationError) else { return }
            if error as? BackendError == .busy {
                notice = "The device is busy. Try again after the current operation."
            } else {
                automaticPaused = true
                insert(Entry(image: nil), for: key)
            }
        }
    }

    private func insert(_ entry: Entry, for key: PhotoThumbnailKey) {
        if let previous = cache.removeValue(forKey: key) {
            byteCount -= previous.cost
            order.removeAll { $0 == key }
        }
        let entry = entry.cost <= byteLimit ? entry : Entry(image: nil)
        while !order.isEmpty && (order.count >= entryLimit || byteCount + entry.cost > byteLimit) {
            let oldest = order.removeFirst()
            byteCount -= cache.removeValue(forKey: oldest)?.cost ?? 0
        }
        cache[key] = entry
        order.append(key)
        byteCount += entry.cost
        revision += 1
    }
}
