import AppKit
import ImageIO
import MTPWire
import Testing

@testable import Piko

func thumbnailPNG(width: Int = 96, height: Int = 64) throws -> Data {
    let context = try #require(CGContext(data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.15, green: 0.55, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

private func photo(in backend: SwiftMTPBackend) async throws -> MTPFile {
    try #require(try await backend.contents(storageID: 1, path: "/", showHiddenFiles: false)
        .first { $0.name == "photo.jpg" })
}

private func waitForThumbnailPause(_ device: SyntheticUploadDevice) async throws {
    for _ in 0..<2000 {
        if await device.isPaused { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("Thumbnail fixture did not reach its pause")
}

struct PhotoThumbnailBackendTests {
    @Test func readsOnlySelectedMetadataAndThumbnailWithEstimatedSize() async throws {
        let data = try thumbnailPNG()
        let device = try SyntheticUploadDevice(advertisedWrites: [ReadSession.getThumbnailCode],
            existingNames: ["photo.jpg"], thumbnailData: data, thumbnailSize: 200 * 1024)
        let backend = try await connectedUploadBackend(device)
        let file = try await photo(in: backend)
        let before = await device.snapshot().commands.count
        #expect(try await backend.thumbnail(storageID: 1, file: file) == data)
        #expect(Array(await device.snapshot().commands.dropFirst(before)) == [0x1008, 0x100A])
        #expect(await device.snapshot().uploads.isEmpty)
        try await backend.disconnect()
    }

    @Test(arguments: [UInt32(0), UInt32(ReadSession.maximumThumbnailBytes + 1)])
    func missingOrOversizedAdvertisementSkipsThumbnail(size: UInt32) async throws {
        let device = try SyntheticUploadDevice(advertisedWrites: [0x100A],
            existingNames: ["photo.jpg"], thumbnailData: Data([1]), thumbnailSize: size)
        let backend = try await connectedUploadBackend(device)
        let file = try await photo(in: backend)
        #expect(try await backend.thumbnail(storageID: 1, file: file) == nil)
        #expect(!(await device.snapshot().commands.contains(0x100A)))
        try await backend.disconnect()
    }

    @Test func unsupportedOperationAndNonPhotoDoNoIO() async throws {
        for supported in [false, true] {
            let device = try SyntheticUploadDevice(advertisedWrites: supported ? [0x100A] : [],
                existingNames: [supported ? "note.txt" : "photo.jpg"], thumbnailData: Data([1]))
            let backend = try await connectedUploadBackend(device)
            let file = try #require(try await backend.contents(storageID: 1, path: "/", showHiddenFiles: false).first)
            let before = await device.snapshot().commands
            #expect(try await backend.thumbnail(storageID: 1, file: file) == nil)
            #expect(await device.snapshot().commands == before)
            try await backend.disconnect()
        }
    }

    @Test(arguments: [UInt16(0x2010), UInt16(0x200F), UInt16(0x2005)])
    func framedRejectionPreservesBrowsing(code: UInt16) async throws {
        let device = try SyntheticUploadDevice(advertisedWrites: [0x100A], existingNames: ["photo.jpg"],
            thumbnailData: Data([1]))
        let backend = try await connectedUploadBackend(device)
        let file = try await photo(in: backend)
        await device.configureFault(reject: 0x100A, rejectionCode: code)
        #expect(try await backend.thumbnail(storageID: 1, file: file) == nil)
        #expect(try await photo(in: backend) == file)
        #expect(await device.snapshot().closed == false)
        try await backend.disconnect()
    }

    @Test func oversizedActualResponseDisposesSessionWithoutDownloadOrRetry() async throws {
        let device = try SyntheticUploadDevice(advertisedWrites: [0x100A], existingNames: ["photo.jpg"],
            thumbnailData: Data(repeating: 0, count: ReadSession.maximumThumbnailBytes + 1), thumbnailSize: 10)
        let backend = try await connectedUploadBackend(device)
        let file = try await photo(in: backend)
        await #expect(throws: BackendSessionError.self) { try await backend.thumbnail(storageID: 1, file: file) }
        let snapshot = await device.snapshot()
        #expect(snapshot.closed)
        #expect(snapshot.commands.filter { $0 == 0x100A }.count == 1)
        #expect(!snapshot.commands.contains(0x1009))
        #expect(await device.cancelCount == 0)
    }

    @Test(arguments: [UInt16(0x1008), UInt16(0x100A)])
    func cancellationDrainsActiveResponseAndSkipsUnstartedWork(operation: UInt16) async throws {
        let device = try SyntheticUploadDevice(advertisedWrites: [0x100A], existingNames: ["photo.jpg"],
            thumbnailData: try thumbnailPNG())
        let backend = try await connectedUploadBackend(device)
        let file = try await photo(in: backend)
        await device.pause(operation: operation, includingCommand: true)
        let request = Task { try await backend.thumbnail(storageID: 1, file: file) }
        try await waitForThumbnailPause(device)
        request.cancel()
        // Optional requests must return busy immediately, never join the queue.
        await #expect(throws: BackendError.busy) { try await backend.thumbnail(storageID: 1, file: file) }
        await device.resume()
        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(await device.snapshot().commands.filter { $0 == 0x100A }.count == (operation == 0x100A ? 1 : 0))
        #expect(try await photo(in: backend) == file)
        #expect(await device.cancelCount == 0)
        #expect(await device.interruptedIO == false)
        try await backend.disconnect()
    }

    @Test func foregroundListingRejectsPreviewAndOldSessionHandlesAreNeverUsed() async throws {
        let device = try SyntheticUploadDevice(advertisedWrites: [0x100A], existingNames: ["photo.jpg"],
            thumbnailData: thumbnailPNG())
        let backend = try await connectedUploadBackend(device)
        let file = try await photo(in: backend)
        await device.pause(operation: 0x1007, includingCommand: true)
        let listing = Task { try await backend.contents(storageID: 1, path: "/", showHiddenFiles: false) }
        try await waitForThumbnailPause(device)
        await #expect(throws: BackendError.busy) { try await backend.thumbnail(storageID: 1, file: file) }
        await device.resume()
        _ = try await listing.value
        try await backend.disconnect()
        await device.prepareReconnect()
        _ = try await backend.connect()
        let before = await device.snapshot().commands
        await #expect(throws: SwiftBackendError.staleSelection) { try await backend.thumbnail(storageID: 1, file: file) }
        #expect(await device.snapshot().commands == before)
        try await backend.disconnect()
    }
}

private actor ThumbnailFixture: MTPThumbnailBackend {
    nonisolated let capabilities = BackendCapabilities(reportsProgress: false, canCancelActiveTransfer: false)
    let data: Data?
    private(set) var calls = 0
    init(_ data: Data?) { self.data = data }
    func connect() -> [MTPStorage] { [DemoBackend.storage] }
    func contents(storageID: UInt32, path: String, showHiddenFiles: Bool) -> [MTPFile] { [] }
    func download(storageID: UInt32, files: [MTPFile], to destination: URL, progress: @escaping ProgressHandler) {}
    func disconnect() -> Bool { true }
    func thumbnail(storageID: UInt32, file: MTPFile) -> Data? { calls += 1; return data }
}

@MainActor struct PhotoThumbnailStoreTests {
    private func key(_ id: UInt32) -> PhotoThumbnailKey {
        PhotoThumbnailKey(connection: 1, storageID: 1,
            file: DemoBackend.entry(id: id, name: "photo\(id).jpg", parent: "/", folder: false))
    }

    @Test func cachesSuccessAndFailureAndBoundsEntryCount() async throws {
        for data in [try thumbnailPNG(), nil] {
            let backend = ThumbnailFixture(data)
            let store = PhotoThumbnailStore(backend: backend, entryLimit: 2)
            try await store.load(key(1))
            try await store.load(key(1))
            #expect(await backend.calls == 1)
            #expect(store.entry(for: key(1)) != nil)
            #expect((store.entry(for: key(1))?.image != nil) == (data != nil))
            try await store.load(key(2))
            try await store.load(key(3))
            #expect(store.count == 2)
            #expect(store.entry(for: key(1)) == nil)
            store.clear()
            #expect(store.count == 0)
            #expect(store.byteCount == 0)
        }
    }

    @Test func boundsDecodedMemory() async throws {
        let data = try thumbnailPNG()
        let image = try #require(ThumbnailDecoder.decode(data))
        let cost = image.bytesPerRow * image.height
        let store = PhotoThumbnailStore(backend: ThumbnailFixture(data), byteLimit: cost)
        try await store.load(key(1))
        try await store.load(key(2))
        #expect(store.count == 1)
        #expect(store.byteCount == cost)
        let tooSmall = PhotoThumbnailStore(backend: ThumbnailFixture(data), byteLimit: cost - 1)
        try await tooSmall.load(key(1))
        #expect(tooSmall.byteCount == 0)
        #expect(tooSmall.entry(for: key(1))?.image == nil)
    }

    @Test func automaticLoadingUsesOnlyVisibleFilesAndDiscardsOldViewport() async throws {
        let device = try SyntheticUploadDevice(advertisedWrites: [0x100A], existingNames: ["photo.jpg", "second.jpg"],
            thumbnailData: thumbnailPNG())
        let model = DeviceBrowserModel(client: SwiftMTPBackend { device })
        await model.connectAndLoad()
        let file = try #require(model.files.first { $0.name == "photo.jpg" })
        let key = try #require(model.thumbnailKey(for: file))
        #expect(!(await device.snapshot().commands.contains(0x100A)))
        await device.pause(operation: 0x100A, includingCommand: true)
        model.updateVisibleThumbnails([file])
        try await waitForThumbnailPause(device)
        #expect(!model.isBusy)
        model.updateVisibleThumbnails([])
        #expect(model.thumbnails.loading != nil)
        await device.resume()
        try await thumbnailWait { model.thumbnails.loading == nil }
        #expect(model.thumbnails.count == 0)
        model.updateVisibleThumbnails([file])
        try await thumbnailWait { model.thumbnails.entry(for: key)?.image != nil }
        #expect(await device.snapshot().commands.filter { $0 == 0x100A }.count == 2)
        model.fileViewMode = .grid
        model.updateVisibleThumbnails([file])
        try await Task.sleep(for: .milliseconds(450))
        #expect(await device.snapshot().commands.filter { $0 == 0x100A }.count == 2)
        await model.disconnectAndReset()
        #expect(model.thumbnails.count == 0)
    }

    @Test func fatalAutomaticFailureRequiresManualReconnect() async throws {
        let device = try SyntheticUploadDevice(advertisedWrites: [0x100A], existingNames: ["photo.jpg"],
            thumbnailData: Data(repeating: 0, count: ReadSession.maximumThumbnailBytes + 1), thumbnailSize: 10)
        let model = DeviceBrowserModel(client: SwiftMTPBackend { device })
        await model.connectAndLoad()
        model.updateVisibleThumbnails(model.files)
        try await thumbnailWait { !model.isConnected }
        #expect(model.operationError != nil)
        #expect(await device.snapshot().commands.filter { $0 == 0x1002 }.count == 1)
    }

    @Test func quitDrainsAutomaticThumbnailWithoutCancellingUSB() async throws {
        let device = try SyntheticUploadDevice(advertisedWrites: [0x100A], existingNames: ["photo.jpg"],
            thumbnailData: thumbnailPNG())
        let model = DeviceBrowserModel(client: SwiftMTPBackend { device })
        await model.connectAndLoad()
        await device.pause(operation: 0x100A, includingCommand: true)
        model.updateVisibleThumbnails(model.files)
        try await waitForThumbnailPause(device)
        let quit = Task { await model.prepareToQuit() }
        try await thumbnailWait { model.isQuitting }
        #expect(await device.snapshot().closed == false)
        await device.resume()
        await quit.value
        #expect(await device.snapshot().closed)
        #expect(await device.cancelCount == 0)
        #expect(await device.interruptedIO == false)
        #expect(model.thumbnails.count == 0)
    }

    @Test(arguments: ["hide", "navigate", "download"])
    func foregroundActionCancelsPendingThumbnail(action: String) async throws {
        let device = try SyntheticUploadDevice(advertisedWrites: [0x100A], existingNames: ["photo.jpg"],
            thumbnailData: thumbnailPNG())
        let model = DeviceBrowserModel(client: SwiftMTPBackend { device })
        await model.connectAndLoad()
        let file = try #require(model.files.first)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        await device.pause(operation: 0x1008, includingCommand: true)
        model.updateVisibleThumbnails([file])
        try await waitForThumbnailPause(device)
        let foreground = Task {
            switch action {
            case "hide": model.updateVisibleThumbnails([])
            case "navigate": await model.load(path: "/")
            default: await model.download(files: [file], to: directory)
            }
        }
        if action == "hide" { await foreground.value }
        else { try await thumbnailWait { model.isBusy } }
        await device.resume()
        await foreground.value
        try await thumbnailWait { model.thumbnails.loading == nil }
        #expect(!(await device.snapshot().commands.contains(0x100A)))
        #expect(model.thumbnails.count == 0)
        #expect(model.isConnected)
        #expect(model.operationError == nil)
        if action == "download" {
            #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(file.name).path))
        }
        #expect(await device.interruptedIO == false)
        await model.disconnectAndReset()
    }

    @Test func scrollingCoalescesAndEvictionDoesNotRefetchVisibleImages() async throws {
        let backend = ThumbnailFixture(try thumbnailPNG())
        let store = PhotoThumbnailStore(backend: backend, entryLimit: 1)
        store.scheduleVisible([key(1)], enabled: true)
        store.scheduleVisible([key(2), key(3)], enabled: true)
        try await thumbnailWait { await backend.calls == 2 && store.loading == nil }
        try await Task.sleep(for: .milliseconds(500))
        #expect(await backend.calls == 2)
        #expect(store.count == 1)
        #expect(store.entry(for: key(1)) == nil)
        store.clear()
    }

    @Test(arguments: [false, true]) func slowDeviceStopsAutomaticRequestsUntilExplicitResume(changedViewport: Bool) async throws {
        let device = try SyntheticUploadDevice(advertisedWrites: [0x100A], existingNames: ["photo.jpg", "second.jpg"],
            thumbnailData: thumbnailPNG())
        let backend = try await connectedUploadBackend(device)
        let files = try await backend.contents(storageID: 1, path: "/", showHiddenFiles: false)
        let keys = files.map { PhotoThumbnailKey(connection: 1, storageID: 1, file: $0) }
        let store = PhotoThumbnailStore(backend: backend)
        await device.pause(operation: 0x100A, includingCommand: true)
        store.scheduleVisible(keys, enabled: true)
        try await waitForThumbnailPause(device)
        try await Task.sleep(for: .milliseconds(1050))
        if changedViewport { store.scheduleVisible([keys[1]], enabled: true) }
        await device.resume()
        try await thumbnailWait { store.automaticPaused }
        #expect(await device.snapshot().commands.filter { $0 == 0x100A }.count == 1)
        store.resumeAutomatic()
        try await thumbnailWait { store.count == (changedViewport ? 1 : 2) }
        #expect(await device.snapshot().commands.filter { $0 == 0x100A }.count == 2)
        store.clear()
        try await backend.disconnect()
    }

    @Test(arguments: ["scroll", "setting"]) func overlappingViewportRetriesCancelledVisibleRequest(change: String) async throws {
        let device = try SyntheticUploadDevice(advertisedWrites: [0x100A], existingNames: ["photo.jpg", "second.jpg"],
            thumbnailData: thumbnailPNG())
        let backend = try await connectedUploadBackend(device)
        let files = try await backend.contents(storageID: 1, path: "/", showHiddenFiles: false)
        let keys = files.map { PhotoThumbnailKey(connection: 1, storageID: 1, file: $0) }
        let store = PhotoThumbnailStore(backend: backend)
        await device.pause(operation: 0x100A, includingCommand: true)
        store.scheduleVisible([keys[0]], enabled: true)
        try await waitForThumbnailPause(device)
        store.scheduleVisible(keys, enabled: true)
        if change == "setting" { store.automaticEnabled = false; store.automaticEnabled = true }
        await device.resume()
        try await thumbnailWait { store.count == 2 }
        #expect(store.entry(for: keys[0])?.image != nil)
        #expect(await device.snapshot().commands.filter { $0 == 0x100A }.count == 3)
        store.clear()
        try await backend.disconnect()
    }

    @Test func oldViewDisappearingDoesNotCancelNewView() async throws {
        let backend = ThumbnailFixture(try thumbnailPNG())
        let model = DeviceBrowserModel(client: backend)
        await model.connectAndLoad()
        let first = UUID(), second = UUID()
        let file = key(1).file
        model.updateVisibleThumbnails([file], owner: first)
        model.updateVisibleThumbnails([file], owner: second)
        model.updateVisibleThumbnails([], owner: first)
        try await thumbnailWait { await backend.calls == 1 }
        await model.disconnectAndReset()
    }

}

struct PhotoThumbnailDecoderTests {
    @Test func downsamplingAndInvalidInput() throws {
        let image = try #require(ThumbnailDecoder.decode(try thumbnailPNG(width: 1024, height: 768)))
        #expect(image.width == 256)
        #expect(image.height == 192)
        #expect(ThumbnailDecoder.decode(Data()) == nil)
        #expect(ThumbnailDecoder.decode(Data("invalid image".utf8)) == nil)
        #expect(ThumbnailDecoder.decode(Data(repeating: 0, count: ReadSession.maximumThumbnailBytes + 1)) == nil)
        #expect(ThumbnailDecoder.decode(try thumbnailPNG(width: 4097, height: 1)) == nil)
        #expect(ThumbnailDecoder.decode(try thumbnailPNG(width: 2049, height: 2049)) == nil)
    }
}

@MainActor func thumbnailWait(_ condition: () async -> Bool) async throws {
    for _ in 0..<400 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Thumbnail condition did not become true")
}
