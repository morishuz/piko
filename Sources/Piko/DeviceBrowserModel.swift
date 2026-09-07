import AppKit
import Foundation
import MTPWire

@MainActor
final class DeviceBrowserModel: ObservableObject {
    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case recovering
        case disconnecting
        case connected
        case failed(String)
        case reconnectRequired(String)
    }

    @Published private(set) var deviceDetails: MTPDeviceDetails?
    @Published private(set) var isDeviceAvailable = true
    @Published private(set) var remoteTransfer: RemoteTransferCoordinator?
    @Published private(set) var storageWriteCapabilities: [UInt32: StorageWriteCapabilities] = [:]
    var connectionToken: Int { sessionGeneration }
    var diagnosticLog: DiagnosticLog? { diagnostics }
    @Published private(set) var isQuitting = false
    @Published private(set) var state: ConnectionState = .disconnected
    @Published private(set) var storages: [MTPStorage] = []
    @Published var selectedStorageID: UInt32?
    @Published private(set) var files: [MTPFile] = [] {
        didSet { thumbnailSidecars = ThumbnailSidecars(files) }
    }
    private var thumbnailSidecars = ThumbnailSidecars([])
    @Published private(set) var currentPath = "/"
    @Published private(set) var isLoadingDirectory = false
    @Published private(set) var isTransferring = false {
        didSet { if isTransferring { thumbnails.scheduleVisible([], enabled: false) } }
    }
    @Published private(set) var selectedFileIDs: Set<UInt32> = []
    @Published var fileViewMode: FileViewMode = .list
    @Published private(set) var isGeneratingThumbnails = false
    @Published private(set) var browsingIssue: String?
    @Published var operationError: String?
    @Published var transferConfirmation: String?
    @Published private(set) var uploadNeedsReconnect = false
    @Published private(set) var uploadCapabilityAvailable = false

    @Published private(set) var binCapabilityAvailable = false
    @Published private(set) var binDeletionAvailable = false
    @Published private(set) var browserDragID = UUID()
    @Published private(set) var binStatus: String?
    @Published private(set) var binListing: BinListing?
    @Published private(set) var binExists: Bool?
    struct BinReadiness {
        var roots: [String] = []
        var count: Int?
        var issue: String?
        var ready = false
    }
    @Published private(set) var binReadiness: [UInt32: BinReadiness] = [:]
    var binCount: Int? { selectedStorageID.flatMap { binReadiness[$0]?.count } }
    var writeRestriction: String? { selectedStorageID.flatMap { binReadiness[$0]?.issue } }
    func isBinPath(_ path: String, storageID: UInt32? = nil) -> Bool {
        if path == BinLayout.overview { return true }
        guard let id = storageID ?? selectedStorageID else { return false }
        return binReadiness[id]?.roots.contains { BinLayout.contains(path, in: $0) } == true
    }
    var isBrowsingBin: Bool { isBinPath(currentPath) }
    func isValidTransferSource(_ file: MTPFile, storageID: UInt32? = nil) -> Bool {
        let roots = (storageID ?? selectedStorageID).flatMap { binReadiness[$0]?.roots } ?? []
        return (try? BinLayout.validateSource(file, roots: roots)) != nil
    }
    private var binFolderPath: String?
    private let deviceBin: DeviceBin?
    var isViewingBin: Bool { currentPath == BinLayout.overview }
    var breadcrumbs: [RemoteBreadcrumb] {
        guard isBrowsingBin else { return RemoteBreadcrumb.items(for: currentPath) }
        var items = [RemoteBreadcrumb(path: "/", name: "/"), RemoteBreadcrumb(path: BinLayout.overview, name: "Bin")]
        if let binFolderPath, BinLayout.contains(currentPath, in: binFolderPath) {
            items += RemoteBreadcrumb.items(for: currentPath).filter { BinLayout.contains($0.path, in: binFolderPath) }
        }
        return items
    }
    var canEmptyBin: Bool { isViewingBin && canDeletePermanently && binListing?.entries.isEmpty == false }
    func originalLocation(for file: MTPFile) -> String? { binListing?.item(for: file)?.originalPath }
    var canUseBin: Bool {
        !isQuitting && isConnected && !isTransferring && !isLoadingDirectory && !uploadNeedsReconnect
            && binCapabilityAvailable
    }
    var canOpenBin: Bool {
        !isQuitting && isConnected && !isTransferring && !isLoadingDirectory && !uploadNeedsReconnect
            && binExists == true && !isViewingBin
    }
    var canDropIntoBin: Bool { canUseBin && !isBrowsingBin }
    var binHelp: String {
        if isViewingBin { return "You are viewing the Bin" }
        if let writeRestriction { return writeRestriction }
        if binExists != true { return "Preparing the Bin before enabling writes" }
        if uploadNeedsReconnect { return "Reconnect the device before using the Bin" }
        if isTransferring || isLoadingDirectory || isQuitting { return "Wait for the current operation to finish" }
        return "Click to open the Bin; drag device items here to move them to the Bin"
    }
    var uploadHelp: String {
        if isBrowsingBin { return "Uploads are unavailable inside the Bin" }
        if let writeRestriction { return writeRestriction }
        if selectedStorage?.info.accessCapability != 0 { return "This storage reports that it is read-only" }
        if !uploadCapabilityAvailable { return "Uploads are unsupported or this storage is read-only" }
        if uploadNeedsReconnect { return "Reconnect the device before uploading" }
        if isTransferring || isLoadingDirectory || isQuitting { return "Wait for the current operation to finish" }
        return "Upload files or folders to the current folder"
    }
    var canDeletePermanently: Bool {
        !isQuitting && isConnected && !isTransferring && !isLoadingDirectory && !uploadNeedsReconnect && binExists == true && binDeletionAvailable
    }
    func canDelete(_ items: [MTPFile]) -> Bool {
        guard !items.isEmpty, items.allSatisfy({ files.contains($0) }) else { return false }
        if isBrowsingBin {
            return canDeletePermanently && items.allSatisfy { file in
                if isViewingBin { return binListing?.item(for: file) != nil }
                return isBinPath(file.path)
            }
        }
        return canUseBin && items.allSatisfy { isValidTransferSource($0) }
    }
    func canAcceptBinDrop(_ items: [RemoteDragItem]) -> Bool {
        guard canDropIntoBin, !items.isEmpty, items.allSatisfy({ $0.browserID == browserDragID }) else { return false }
        let ids = Set(items.map(\.handle))
        let dragged = files.filter { ids.contains($0.id) }
        return dragged.count == ids.count && dragged.allSatisfy { isValidTransferSource($0) }
    }
    func acceptBinDrop(_ items: [RemoteDragItem]) {
        guard canAcceptBinDrop(items) else { return }
        let ids = Set(items.map(\.handle))
        confirmBinAction(.trash, snapshot: files.filter { ids.contains($0.id) })
    }
    var canTrash: Bool {
        canUseBin && !selectedFiles.isEmpty
            && selectedFiles.allSatisfy { isValidTransferSource($0) }
    }
    var canRestore: Bool {
        canRestoreSelection(selectedFiles)
    }
    func canRestoreSelection(_ items: [MTPFile]) -> Bool {
        canUseBin && isViewingBin && !items.isEmpty
            && items.allSatisfy { files.contains($0) && binListing?.item(for: $0)?.originalPath != nil }
    }

    let client: any MTPBackend
    let transfers: TransferCoordinator
    let thumbnails: PhotoThumbnailStore
    var canDownload: Bool {
        !isQuitting && isConnected && selectedStorageID != nil && !selectedFiles.isEmpty
            && !isTransferring && !isLoadingDirectory
    }
    var canUpload: Bool {
        !isQuitting && isConnected && !isTransferring && !isLoadingDirectory && !uploadNeedsReconnect
            && uploadCapabilityAvailable && !isBrowsingBin
            && selectedStorage?.info.accessCapability == 0
    }
    private var loadGeneration = 0 {
        didSet { thumbnails.scheduleVisible([], enabled: false) }
    }
    private var sessionGeneration = 0 {
        didSet { thumbnails.clear() }
    }
    private var selectionAnchorID: UInt32?

    private let diagnostics: DiagnosticLog?
    private let discoveredDevice: DiscoveredDevice?
    init(client: any MTPBackend, diagnostics: DiagnosticLog? = nil, discoveredDevice: DiscoveredDevice? = nil) {
        self.client = client
        deviceBin = (client as? any MTPBinBackend).map { DeviceBin(backend: $0) }
        self.diagnostics = diagnostics
        self.discoveredDevice = discoveredDevice
        transfers = TransferCoordinator(diagnostics: diagnostics)
        thumbnails = PhotoThumbnailStore(backend: client)
        thumbnails.onSessionFailure = { [weak self] key, error in
            Task { await self?.handleThumbnailFailure(key, error: error) }
        }
    }

    func thumbnailKey(for file: MTPFile) -> PhotoThumbnailKey? {
        guard isConnected, let storageID = selectedStorageID else { return nil }
        return PhotoThumbnailKey(connection: sessionGeneration, storageID: storageID, file: file,
            previewFile: thumbnailSidecars.companion(for: file))
    }

    private var thumbnailVisibilityOwner: UUID?
    func updateVisibleThumbnails(_ files: [MTPFile], owner: UUID? = nil) {
        if files.isEmpty, let owner, owner != thumbnailVisibilityOwner { return }
        if !files.isEmpty { thumbnailVisibilityOwner = owner }
        thumbnails.scheduleVisible(files.compactMap { thumbnailKey(for: $0) },
            enabled: !isQuitting && isConnected && !isBusy)
    }

    private func handleThumbnailFailure(_ key: PhotoThumbnailKey, error: any Error) async {
        guard let error = BackendSessionError.from(error) else { return }
        while key.connection == sessionGeneration && isBusy && !isQuitting {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard key.connection == sessionGeneration, isConnected, !isQuitting else { return }
        requireReconnect(error)
    }

    static let maximumThumbnailOriginalBytes: Int64 = 256 * 1024 * 1024

    func missingThumbnailFiles(_ selection: [MTPFile]) -> [MTPFile] {
        guard isConnected, !isBusy, !isQuitting else { return [] }
        return selection.filter { file in
            guard files.contains(file), file.isPhotoThumbnailCandidate, file.size >= 0,
                file.size <= Self.maximumThumbnailOriginalBytes,
                let key = thumbnailKey(for: file) else { return false }
            return thumbnails.entry(for: key)?.image == nil
        }
    }

    func requestThumbnailGeneration(_ selection: [MTPFile]) {
        Task { await generateThumbnails(selection) }
    }

    func generateThumbnails(_ selection: [MTPFile]) async {
        let snapshot = missingThumbnailFiles(selection)
        guard !snapshot.isEmpty, let storageID = selectedStorageID else { return }
        let generation = sessionGeneration
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("piko-thumbnails-" + UUID().uuidString)
        isTransferring = true
        isGeneratingThumbnails = true
        operationError = nil
        defer {
            try? FileManager.default.removeItem(at: directory)
            isGeneratingThumbnails = false
            isTransferring = false
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            try await transfers.run(backend: client, storageID: storageID, files: snapshot,
                destination: directory, consumeDownload: { [weak self] url, file in
                    defer { try? FileManager.default.removeItem(at: url) }
                    let image = await Task.detached(priority: .utility) { ThumbnailDecoder.decodeOriginal(url) }.value
                    guard let self, self.sessionGeneration == generation, !self.isQuitting else { throw CancellationError() }
                    guard let image else { throw ThumbnailGenerationError.unsupportedImage }
                    let key = PhotoThumbnailKey(connection: generation, storageID: storageID, file: file)
                    self.thumbnails.storeOriginal(image, for: key)
                })
            if !transfers.summary.failed.isEmpty {
                operationError = "Could not generate thumbnails for \(transfers.summary.failed.count) photo(s). These files keep their icons; completed previews remain available."
            }
        } catch is CancellationError {
            // Completed previews stay cached; remaining originals are never read.
        } catch let error as BackendSessionError {
            await recoverSession(after: error, preferredStorageID: storageID, preferredPath: currentPath)
        } catch { operationError = error.localizedDescription }
    }

    var isConnected: Bool {
        isDeviceAvailable && state == .connected
    }

    var canNavigateUp: Bool {
        currentPath != "/"
    }

    var selectedStorage: MTPStorage? {
        storages.first { $0.id == selectedStorageID }
    }

    var selectedFile: MTPFile? {
        guard selectedFileIDs.count == 1 else { return nil }
        return files.first { selectedFileIDs.contains($0.id) }
    }

    var selectedFiles: [MTPFile] {
        files.filter { selectedFileIDs.contains($0.id) }
    }

    func connect() {
        Task { await connectAndLoad() }
    }

    func connectAndLoad() async {
        guard isDeviceAvailable, !isQuitting, state != .connecting, state != .recovering, state != .disconnecting,
            !isConnected, !isTransferring
        else {
            return
        }
        sessionGeneration += 1
        let session = sessionGeneration
        state = .connecting
        browsingIssue = nil
        files = []
        selectedFileIDs.removeAll()
        selectionAnchorID = nil
        operationError = nil
        let started = DiagnosticLog.start()
        if let device = discoveredDevice {
            diagnostics?.record(.deviceDetails, usbVendor: device.vendor, usbProduct: device.product,
                details: .device(manufacturer: device.manufacturer, model: device.name,
                    firmware: "", usbRegistryID: device.target))
        }
        do {
            let availableStorages = try await client.connect()
            guard session == sessionGeneration else { return }
            guard let initialStorage = availableStorages.first else { throw BackendError.noStorage }
            deviceDetails = await client.deviceDetails()
            guard session == sessionGeneration else { return }
            try await prepareBins(availableStorages, session: session)
            guard session == sessionGeneration else { return }
            storages = availableStorages
            selectedStorageID = availableStorages.first?.id
            uploadNeedsReconnect = false
            uploadCapabilityAvailable = await supportsUpload(to: selectedStorageID)
            guard session == sessionGeneration else { return }
            loadGeneration += 1
            isLoadingDirectory = true
            let listingStarted = DiagnosticLog.start()
            try await readDirectory(storageID: initialStorage.id, path: "/", generation: loadGeneration)
            guard session == sessionGeneration else { return }
            isLoadingDirectory = false
            if !isDeviceAvailable { await disconnectAndReset(); return }
            diagnostics?.record(.connect, since: started)
            diagnostics?.record(.listing, since: listingStarted)
            recordBrowserCapabilities()
        } catch {
            diagnostics?.record(.connect, since: started, failure: .classify(error))
            guard session == sessionGeneration else { return }
            // A storage ID alone is not a usable connection. Release even a
            // healthy session if its initial root cannot be read, so Retry opens fresh.
            _ = try? await client.disconnect()
            guard session == sessionGeneration else { return }
            isLoadingDirectory = false
            selectedStorageID = nil
            state = .failed(error.localizedDescription)
            operationError = error.localizedDescription
            storages = []
            storageWriteCapabilities = [:]
            binReadiness = [:]
            files = []
            binListing = nil
            binDeletionAvailable = false
            binExists = nil
            binCapabilityAvailable = false
            uploadCapabilityAvailable = false
        }
    }

    var isBusy: Bool {
        isTransferring || isLoadingDirectory || state == .connecting
            || state == .recovering || state == .disconnecting
    }

    func markDeviceUnavailable() {
        isDeviceAvailable = false
        thumbnails.scheduleVisible([], enabled: false)
        remoteTransfer?.cancel()
        transfers.cancelTransfer()
    }

    func deviceWasRemoved() async {
        markDeviceUnavailable()
        while isBusy { try? await Task.sleep(for: .milliseconds(50)) }
        let error = operationError
        let result = transferConfirmation
        await disconnectAndReset()
        operationError = error
        transferConfirmation = result
    }

    /// Quit is deferred until the current operation has returned and released
    /// its session gate. Do not cancel a non-interruptible USB file mid-stream.
    func prepareToQuit() async {
        isQuitting = true
        thumbnails.scheduleVisible([], enabled: false)
        remoteTransfer?.cancel()
        transfers.cancelTransfer()
        while isBusy { try? await Task.sleep(for: .milliseconds(50)) }
        await disconnectAndReset()
    }

    func disconnect() {
        Task { await disconnectAndReset() }
    }

    func disconnectAndReset() async {
        guard !isTransferring, state != .disconnecting else { return }
        sessionGeneration += 1
        loadGeneration += 1
        state = .disconnecting
        let started = DiagnosticLog.start()
        do {
            _ = try await client.disconnect()
            diagnostics?.record(.disconnect, since: started)
        } catch {
            diagnostics?.record(.disconnect, since: started, failure: .classify(error))
        }
        reset()
    }

    func selectStorage(_ id: UInt32?) {
        guard isConnected, !isTransferring else { return }
        if id == selectedStorageID {
            if id != nil, isBrowsingBin { Task { await load(path: "/") } }
            return
        }
        guard id == nil || storages.contains(where: { $0.id == id }) else { return }
        // Invalidate the old storage's handles synchronously, before the new
        // listing task gets a turn or a user can request a download.
        loadGeneration += 1
        files = []
        binListing = nil
        selectedFileIDs.removeAll()
        selectionAnchorID = nil
        currentPath = "/"
        isLoadingDirectory = false
        selectedStorageID = id
        binDeletionAvailable = false
        binExists = nil
        binCapabilityAvailable = false
        uploadCapabilityAvailable = false
        let session = sessionGeneration
        Task {
            let available = await supportsUpload(to: id)
            guard session == sessionGeneration, id == selectedStorageID, isConnected else { return }
            uploadCapabilityAvailable = available
            await load(path: "/")
        }
    }

    func refresh() {
        guard isConnected, !isTransferring else { return }
        Task { await load(path: currentPath, refreshBin: true) }
    }

    func selectAll() {
        guard !isTransferring else { return }
        selectedFileIDs = Set(files.map(\.id))
        selectionAnchorID = files.first?.id
    }

    func clearSelection() {
        guard !isTransferring else { return }
        selectedFileIDs.removeAll()
        selectionAnchorID = nil
    }

    /// Boundary for selection changes made by the AppKit table (keyboard and
    /// accessibility included). Keeping this model-owned prevents a later
    /// shift-click from extending an obsolete anchor.
    func replaceSelection(_ proposedIDs: Set<UInt32>) {
        guard !isTransferring else { return }
        let validIDs = proposedIDs.intersection(files.map(\.id))
        guard validIDs != selectedFileIDs else { return }
        let previousIDs = selectedFileIDs
        let addedIDs = validIDs.subtracting(selectedFileIDs)
        selectedFileIDs = validIDs
        if validIDs.isEmpty {
            selectionAnchorID = nil
        } else if validIDs.count == 1 {
            selectionAnchorID = validIDs.first
        } else if let anchor = selectionAnchorID,
            previousIDs.contains(anchor), validIDs.contains(anchor)
        {
            // Preserve the start while a native keyboard range grows/shrinks.
        } else if addedIDs.count == 1, let added = addedIDs.first {
            selectionAnchorID = added
        } else {
            selectionAnchorID = files.first { validIDs.contains($0.id) }?.id
        }
    }

    func select(_ file: MTPFile, modifiers: NSEvent.ModifierFlags) {
        guard !isTransferring, files.contains(where: { $0.id == file.id }) else { return }
        if modifiers.contains(.shift),
            let anchorID = selectionAnchorID,
            let anchorIndex = files.firstIndex(where: { $0.id == anchorID }),
            let clickedIndex = files.firstIndex(where: { $0.id == file.id })
        {
            let range = min(anchorIndex, clickedIndex)...max(anchorIndex, clickedIndex)
            let rangeIDs = Set(range.map { files[$0].id })
            if modifiers.contains(.command) {
                selectedFileIDs.formUnion(rangeIDs)
            } else {
                selectedFileIDs = rangeIDs
            }
            return
        }

        if modifiers.contains(.command) {
            var replacement = selectedFileIDs
            if replacement.contains(file.id) {
                replacement.remove(file.id)
                selectionAnchorID = nil
            } else {
                replacement.insert(file.id)
                selectionAnchorID = file.id
            }
            replaceSelection(replacement)
        } else {
            selectionAnchorID = file.id
            replaceSelection([file.id])
        }
    }

    func open(_ file: MTPFile) {
        guard isConnected, file.isFolder, !isTransferring, !isLoadingDirectory, files.contains(file) else { return }
        if isViewingBin { binFolderPath = originalLocation(for: file) != nil ? file.path : nil }
        Task { await load(path: file.path) }
    }

    func navigateUp() {
        guard canNavigateUp, !isTransferring else { return }
        let parent = isViewingBin ? "/" : currentPath == binFolderPath ? BinLayout.overview : (currentPath as NSString).deletingLastPathComponent
        Task { await load(path: parent.isEmpty ? "/" : parent) }
    }

    func downloadSelected() {
        guard
            isConnected, selectedStorageID != nil,
            !selectedFiles.isEmpty,
            !isTransferring
        else { return }

        let filesToDownload = selectedFiles
        let itemCount = filesToDownload.count

        let panel = NSOpenPanel()
        panel.title = "Choose Download Folder"
        if let file = filesToDownload.first, itemCount == 1 {
            panel.message = "Choose where to save “\(file.name)”."
        } else {
            panel.message = "Choose where to save \(itemCount) selected items."
        }
        panel.prompt = "Download Here"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message =
            (panel.message ?? "") + " Existing files are kept; duplicates receive a numbered name."

        guard panel.runModal() == .OK, let destination = panel.url else { return }

        Task { await download(files: filesToDownload, to: destination) }
    }

    func download(files: [MTPFile], to destination: URL, conflicts: ConflictPolicy = .keepBoth) async {
        guard !isQuitting, isConnected, let storageID = selectedStorageID, !isTransferring, !files.isEmpty else {
            return
        }
        isTransferring = true
        // A directory response already in flight must not change the selection
        // or current path while a transfer is using this snapshot.
        loadGeneration += 1
        isLoadingDirectory = false
        operationError = nil
        transferConfirmation = nil
        defer { isTransferring = false }
        let started = DiagnosticLog.start()
        let transferID = diagnostics?.nextCorrelationID()
        do {
            try await transfers.run(
                backend: client, storageID: storageID, files: files,
                destination: destination, conflicts: conflicts,
                diagnosticTransferID: transferID)
            let summary = transfers.summary
            diagnostics?.record(
                .download, since: started, failure: summary.downloadFailure,
                transferID: transferID, transferDirection: .download)
            transferConfirmation = summary.requiresAttention(wasCancelled: transfers.stopRequested)
                ? summary.downloadMessage(destination: destination) : nil
        } catch is CancellationError {
            diagnostics?.record(
                .download, since: started, failure: .cancelled,
                transferID: transferID, transferDirection: .download)
            let summary = transfers.summary
            transferConfirmation = summary.requiresAttention(wasCancelled: true)
                ? summary.downloadMessage(destination: destination) : nil
        } catch let error as BackendSessionError {
            diagnostics?.record(
                .download, since: started, failure: .classify(error),
                transferID: transferID, transferDirection: .download)
            let summary = transfers.summary
            transferConfirmation = transfers.cancellationRequested && !summary.requiresAttention(wasCancelled: true)
                ? nil : summary.interruptedDownloadMessage + "\n\n" + summary.downloadMessage(destination: destination)
            await recoverSession(
                after: error, preferredStorageID: storageID, preferredPath: currentPath,
                relatedTransferID: transferID)
            return
        } catch {
            diagnostics?.record(
                .download, since: started, failure: .classify(error),
                transferID: transferID, transferDirection: .download)
            operationError = error.localizedDescription
        }
    }

    /// Fulfills a Finder file promise without presenting a save panel or a
    /// completion alert. The complete file/tree is staged beside the promised
    /// destination and moved into place only after every child succeeds.
    func writeFilePromise(_ file: MTPFile, to promisedURL: URL) async throws {
        guard !isQuitting, isConnected, let storageID = selectedStorageID, !isTransferring,
            files.contains(where: { $0.id == file.id && $0.path == file.path })
        else { throw BackendError.busy }
        guard promisedURL.isFileURL else { throw TransferError.invalidDestination }

        let parent = promisedURL.deletingLastPathComponent()
        let destination = try DownloadDestination(parent)
        let finalURL = destination.root.appendingPathComponent(promisedURL.lastPathComponent)
        let staging = destination.root.appendingPathComponent(
            ".piko-promise-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: staging, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: staging) }

        isTransferring = true
        loadGeneration += 1
        isLoadingDirectory = false
        operationError = nil
        transferConfirmation = nil
        defer { isTransferring = false }
        let started = DiagnosticLog.start()
        let transferID = diagnostics?.nextCorrelationID()

        do {
            try await transfers.run(
                backend: client, storageID: storageID, files: [file],
                destination: staging, conflicts: .skip,
                diagnosticTransferID: transferID)
            if let problem = transfers.results.first(where: {
                switch $0.outcome {
                case .failed, .skipped, .notAttempted: true
                default: false
                }
            }) {
                let message: String
                if case .failed(let failure) = problem.outcome { message = failure }
                else { message = "The promised item was not downloaded." }
                throw TransferError.filePromiseFailed(message)
            }

            let produced = staging.appendingPathComponent(file.name, isDirectory: file.isFolder)
            guard FileManager.default.fileExists(atPath: produced.path) else {
                throw TransferError.invalidDownloadedFile
            }
            guard !FileManager.default.fileExists(atPath: finalURL.path) else {
                throw TransferError.filePromiseDestinationExists
            }
            try FileManager.default.moveItem(at: produced, to: finalURL)
            diagnostics?.record(
                .download, since: started, transferID: transferID,
                transferDirection: .download)
        } catch is CancellationError {
            diagnostics?.record(
                .download, since: started, failure: .cancelled,
                transferID: transferID, transferDirection: .download)
            // An expected stop must not present a Piko error dialog or
            // block browsing. The Finder delegate translates this at its boundary.
            throw CancellationError()
        } catch let error as BackendSessionError {
            diagnostics?.record(
                .download, since: started, failure: .classify(error),
                transferID: transferID, transferDirection: .download)
            await recoverSession(
                after: error, preferredStorageID: storageID,
                preferredPath: currentPath, presentError: false,
                relatedTransferID: transferID)
            throw error
        } catch {
            diagnostics?.record(
                .download, since: started, failure: .classify(error),
                transferID: transferID, transferDirection: .download)
            operationError = "Could not complete drag download: \(error.localizedDescription)"
            throw error
        }
    }

    func openBin() {
        guard canOpenBin else { return }
        Task { await load(path: BinLayout.overview) }
    }

    enum BinAction { case trash, restore, delete }

    func confirmRestoreFromBin() { requestRestore(selectedFiles) }
    func requestRestore(_ snapshot: [MTPFile]) {
        guard canRestoreSelection(snapshot) else { return }
        confirmBinAction(.restore, snapshot: snapshot)
    }
    func requestDelete(_ snapshot: [MTPFile]) {
        guard canDelete(snapshot) else { return }
        let permanent = isBrowsingBin
        confirmBinAction(permanent ? .delete : .trash, snapshot: snapshot)
    }
    func emptyBin() {
        guard canEmptyBin, let binListing else { return }
        confirmBinAction(.delete, snapshot: binListing.entries, emptying: true)
    }

    private func confirmBinAction(_ action: BinAction, snapshot: [MTPFile], emptying: Bool = false) {
        guard !snapshot.isEmpty else { return }
        if emptying { guard canEmptyBin, snapshot == binListing?.entries else { return } }
        else if action == .restore { guard canRestoreSelection(snapshot) else { return } }
        else { guard canDelete(snapshot) else { return } }
        let storage = selectedStorageID
        let session = sessionGeneration
        let alert = NSAlert()
        let verb: String
        switch action {
        case .trash:
            verb = "Move to Bin"
            alert.messageText = "Move \(snapshot.count) items to Bin?"
            alert.informativeText = "Items move to this storage’s Piko Bin and still occupy space. Their original locations are saved for restoration."
        case .restore:
            verb = "Restore"
            alert.messageText = "Restore \(snapshot.count) bin entries?"
            alert.informativeText = "Items return to their original locations. Missing folders are recreated; existing destination names stop restoration.\n\n"
                + snapshot.prefix(8).compactMap { originalLocation(for: $0) }.joined(separator: "\n")
        case .delete:
            verb = emptying ? "Empty Bin Permanently" : "Delete Permanently"
            alert.alertStyle = .warning
            alert.messageText = emptying ? "Permanently empty this storage’s bin?" : "Permanently delete \(snapshot.count) items?"
            alert.informativeText = "This deletes the selected items and everything inside selected folders from the device. This cannot be undone.\n\n"
                + snapshot.prefix(8).map { item in
                    emptying ? (binListing?.items.first { $0.entry == item }?.file.name ?? "Retained recovery notes") : item.name
                }.joined(separator: "\n")
                + (snapshot.count > 8 ? "\n…and \(snapshot.count - 8) more items" : "")
        }
        alert.addButton(withTitle: verb)
        alert.addButton(withTitle: "Cancel")
        alert.buttons.last?.keyEquivalent = "\u{1b}"
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            guard session == sessionGeneration, storage == selectedStorageID else { return }
            await performBinAction(files: snapshot, action: action, emptying: emptying)
        }
    }

    func performBinAction(files snapshot: [MTPFile], restoring: Bool) async {
        await performBinAction(files: snapshot, action: restoring ? .restore : .trash)
    }

    func performBinAction(files snapshot: [MTPFile], action: BinAction, emptying: Bool = false) async {
        guard action == .delete ? canDeletePermanently : canUseBin,
            let storageID = selectedStorageID, let deviceBin, !snapshot.isEmpty else { return }
        if emptying {
            guard action == .delete, canEmptyBin, snapshot == binListing?.entries else { return }
        } else {
            guard snapshot.allSatisfy({ files.contains($0) }) else { return }
            if action == .restore { guard canRestoreSelection(snapshot) else { return } }
        }
        let listing = binListing
        let directory = currentPath
        isTransferring = true
        loadGeneration += 1
        isLoadingDirectory = false
        operationError = nil
        transferConfirmation = nil
        var completed = 0
        var needsReconnect = false
        var reconnectError = BackendSessionError.reconnectRequired
        let verb = action == .restore ? "Restoring" : action == .delete ? "Permanently deleting" : "Moving to bin"
        for file in snapshot {
            binStatus = "\(verb): \(file.name) (\(completed + 1)/\(snapshot.count))"
            do {
                let item = emptying ? nil : listing?.item(for: file)
                    ?? (action == .delete && isBrowsingBin ? BinListing.Item(file: file, entry: file, originalPath: nil) : nil)
                let entry = item?.entry ?? file
                switch action {
                case .restore: try await deviceBin.restore(storageID: storageID, entry: entry, expectedItem: item)
                case .trash: try await deviceBin.trash(storageID: storageID, file: file)
                case .delete: try await deviceBin.permanentlyDelete(storageID: storageID, file: entry, expectedItem: item)
                }
                completed += 1
            } catch {
                needsReconnect = error as? BinError == .uncertain || error as? BinError == .deletionUncertain
                    || BackendSessionError.from(error) != nil
                reconnectError = BackendSessionError.from(error) ?? .reconnectRequired
                operationError = "Stopped at “\(file.name)”. \(completed) of \(snapshot.count) completed.\n\n\(error.localizedDescription)"
                break
            }
        }
        binStatus = nil
        if needsReconnect {
            let message = operationError
            _ = try? await client.disconnect()
            requireReconnect(reconnectError, presentError: false)
            operationError = message
            return
        }
        isTransferring = false
        await load(path: directory, refreshBin: true)
    }

    func chooseUploadFiles() {
        guard canUpload else { return }
        let directory = currentPath
        let panel = NSOpenPanel()
        panel.title = "Upload Files or Folders"
        panel.message =
            "Upload to \(directory). Existing names are reported as conflicts; existing folders and their entire subtrees are not merged. Use disposable files in an empty device folder. Do not modify that folder on the device during upload."
        panel.prompt = "Upload"
        panel.canChooseFiles = true
        panel.canChooseDirectories = client is any MTPFolderUploadBackend
        panel.treatsFilePackagesAsDirectories = true
        panel.resolvesAliases = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        enqueueUpload(panel.urls)
    }

    /// Accepts only concrete local files Finder can make available now. The
    /// full recursive safety pass still runs off the main actor before writing.
    /// Capturing the browser context prevents a delayed drop callback from
    /// uploading into a different session, storage or directory.
    @discardableResult
    func acceptUploadDrop(_ sources: [URL]) -> Bool {
        guard canUpload, !sources.isEmpty, sources.allSatisfy(\.isFileURL) else { return false }

        let supportsFolders = client is any MTPFolderUploadBackend
        do {
            for source in sources {
                let type = try FileManager.default.attributesOfItem(atPath: source.path)[.type]
                    as? FileAttributeType
                guard type == .typeRegular || type == .typeDirectory else {
                    operationError = UploadError.unsupportedSource.localizedDescription
                    return false
                }
                if type == .typeDirectory && !supportsFolders {
                    operationError = "This backend supports file uploads only. Choose files, not folders."
                    return false
                }
            }
        } catch {
            operationError = error.localizedDescription
            return false
        }

        enqueueUpload(sources)
        return true
    }

    private func enqueueUpload(_ sources: [URL]) {
        guard canUpload, !sources.isEmpty else { return }
        let session = sessionGeneration
        let storage = selectedStorageID
        let directory = currentPath
        Task {
            guard session == sessionGeneration, storage == selectedStorageID,
                directory == currentPath, canUpload
            else { return }
            await upload(sources: sources)
        }
    }

    func upload(sources: [URL]) async {
        guard canUpload, let storageID = selectedStorageID, !sources.isEmpty,
            let backend = client as? any MTPUploadBackend
        else { return }
        let directory = currentPath
        isTransferring = true
        loadGeneration += 1
        operationError = nil
        transferConfirmation = nil
        let started = DiagnosticLog.start()
        let transferID = diagnostics?.nextCorrelationID()
        var shouldReloadDirectory = true
        do {
            try await transfers.upload(
                backend: backend, storageID: storageID, sources: sources, directory: directory,
                diagnosticTransferID: transferID)
            let summary = transfers.summary
            shouldReloadDirectory = summary.cancelled.isEmpty
            uploadNeedsReconnect = !summary.uncertain.isEmpty
            diagnostics?.record(
                .upload, since: started, failure: summary.uploadFailure,
                transferID: transferID, transferDirection: .upload)
            transferConfirmation = summary.requiresAttention(wasCancelled: transfers.stopRequested)
                ? summary.uploadMessage(directory: directory) : nil
        } catch is CancellationError {
            shouldReloadDirectory = false
            diagnostics?.record(
                .upload, since: started, failure: .cancelled,
                transferID: transferID, transferDirection: .upload)
            let summary = transfers.summary
            uploadNeedsReconnect = !summary.uncertain.isEmpty
            transferConfirmation = summary.requiresAttention(wasCancelled: true)
                ? summary.cancelledUploadMessage + "\n\n" + summary.uploadMessage(directory: directory) : nil
        } catch let error as BackendSessionError {
            diagnostics?.record(
                .upload, since: started, failure: .classify(error),
                transferID: transferID, transferDirection: .upload)
            let summary = transfers.summary
            uploadNeedsReconnect = !summary.uncertain.isEmpty
            transferConfirmation = transfers.cancellationRequested && !summary.requiresAttention(wasCancelled: true)
                ? nil : summary.interruptedUploadMessage + "\n\n" + summary.uploadMessage(directory: directory)
            shouldReloadDirectory = false
            await recoverSession(
                after: error, preferredStorageID: storageID,
                preferredPath: directory, presentError: transferConfirmation == nil,
                relatedTransferID: transferID)
            return
        } catch {
            diagnostics?.record(
                .upload, since: started, failure: .classify(error),
                transferID: transferID, transferDirection: .upload)
            operationError = error.localizedDescription
        }
        isTransferring = false
        // Preserve the current listing after cancellation, and avoid another
        // device command after an ambiguous write. The user can refresh manually.
        if shouldReloadDirectory && transfers.summary.uncertain.isEmpty {
            await load(path: directory)
        }
    }

    private typealias DirectoryContents = (files: [MTPFile], bin: BinListing?, warning: String?)

    private func directoryContents(storageID: UInt32, path: String) async throws -> DirectoryContents {
        if path == BinLayout.overview, let deviceBin {
            guard binReadiness[storageID]?.ready == true else { throw BinError.missing }
            let listing = try await deviceBin.contents(storageID: storageID)
            return (listing.files, listing, nil)
        }
        let listing = try await client.browseContents(storageID: storageID, path: path,
            showHiddenFiles: isBinPath(path, storageID: storageID))
        let roots = binReadiness[storageID]?.roots ?? []
        return (listing.files.filter { !roots.contains($0.path) }, nil, listing.warning)
    }

    func load(path: String, refreshBin: Bool = false) async {
        guard isConnected, !isTransferring else { return }
        guard let storageID = selectedStorageID else {
            files = []
            binListing = nil
            return
        }

        loadGeneration += 1
        let generation = loadGeneration
        isLoadingDirectory = true
        selectedFileIDs.removeAll()
        selectionAnchorID = nil

        let started = DiagnosticLog.start()
        do {
            try await readDirectory(storageID: storageID, path: path, generation: generation, refreshBin: refreshBin)
            diagnostics?.record(.listing, since: started)
        } catch let error as BackendSessionError {
            diagnostics?.record(.listing, since: started, failure: .classify(error))
            guard generation == loadGeneration else { return }
            isLoadingDirectory = false
            await recoverSession(
                after: error, preferredStorageID: storageID,
                preferredPath: path)
            return
        } catch {
            diagnostics?.record(.listing, since: started, failure: .classify(error))
            guard generation == loadGeneration else { return }
            if isBinPath(path, storageID: storageID) {
                blockWrites(storageID, error: error)
                await applyStorageCapabilities(storageID)
                guard generation == loadGeneration else { return }
            }
            if path == BinLayout.overview, error as? BinError == .missing {
                binExists = false
                isLoadingDirectory = false
                await load(path: "/")
                return
            } else {
                browsingIssue = "Could not open \(path): \(error.localizedDescription)"
                operationError = error.localizedDescription
            }
        }

        if generation == loadGeneration {
            isLoadingDirectory = false
            recordBrowserCapabilities()
        }
    }

    private func readDirectory(storageID: UInt32, path: String, generation: Int, refreshBin: Bool = false) async throws {
        let contents = try await directoryContents(storageID: storageID, path: path)
        guard generation == loadGeneration else { return }
        // Count on connection, Bin access, mutations and explicit Refresh. Ordinary
        // navigation reuses the count instead of downloading every recovery record.
        // Refresh never creates a directory or repeats a failed preparation write.
        if binReadiness[storageID]?.ready == true && (refreshBin || contents.bin != nil) {
            do {
                let listing: BinListing
                if let bin = contents.bin { listing = bin }
                else if let deviceBin { listing = try await deviceBin.contents(storageID: storageID) }
                else { throw BinError.unsupported }
                guard generation == loadGeneration else { return }
                binReadiness[storageID] = BinReadiness(roots: listing.roots, count: listing.files.count, ready: true)
            } catch let error as BackendSessionError { throw error }
            catch {
                guard generation == loadGeneration else { return }
                blockWrites(storageID, error: error)
            }
        }
        await applyStorageCapabilities(storageID)
        guard generation == loadGeneration else { return }
        presentDirectory(contents, path: path)
    }

    // Publish only after the caller validates its generation following the last
    // suspension. Navigation and recovery must discard stale results alike.
    private func presentDirectory(_ contents: DirectoryContents, path: String) {
        browserDragID = UUID()
        currentPath = path
        if let binFolderPath, !BinLayout.contains(path, in: binFolderPath) { self.binFolderPath = nil }
        files = contents.files.sorted {
            if $0.isFolder != $1.isFolder { return $0.isFolder }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        binListing = contents.bin
        browsingIssue = contents.warning
        state = .connected
    }

    private func recordBrowserCapabilities() {
        guard let storage = selectedStorage,
            let index = storages.firstIndex(where: { $0.id == storage.id }) else { return }
        diagnostics?.record(.browserCapabilities, capabilities: DiagnosticCapabilities(
            storageIndex: index, storageAccess: storage.info.accessCapability,
            uploadEnabled: canUpload, binEnabled: canOpenBin,
            binExists: binExists, binDropEnabled: canDropIntoBin,
            binPrepared: selectedStorageID.flatMap { binReadiness[$0]?.ready }, binItemCount: binCount))
    }

    private func requireReconnect(_ error: BackendSessionError, presentError: Bool = true) {
        sessionGeneration += 1
        loadGeneration += 1
        state = .reconnectRequired(error.localizedDescription)
        browsingIssue = nil
        storages = []
        storageWriteCapabilities = [:]
        binReadiness = [:]
        selectedStorageID = nil
        files = []
        binListing = nil
        currentPath = "/"
        isLoadingDirectory = false
        isTransferring = false
        selectedFileIDs.removeAll()
        selectionAnchorID = nil
        binDeletionAvailable = false
        binExists = nil
        binCapabilityAvailable = false
        uploadCapabilityAvailable = false
        operationError = presentError ? error.localizedDescription : nil
    }

    /// Replaces an invalid Swift transport/session without replaying the failed
    /// operation. Object handles are discarded before the first reconnect
    /// attempt and the visible folder is rebuilt from fresh metadata.
    @discardableResult
    private func recoverSession(
        after sessionError: BackendSessionError, preferredStorageID: UInt32?,
        preferredPath: String, presentError: Bool = true,
        relatedTransferID: UInt64? = nil
    ) async -> Bool {
        if isQuitting || !isDeviceAvailable || sessionError == .physicalReconnectRequired || sessionError == .listingRecoveryFailed {
            requireReconnect(sessionError, presentError: true)
            return false
        }
        guard let backend = client as? any MTPFreshSessionBackend else {
            requireReconnect(sessionError, presentError: presentError)
            return false
        }
        let recoveryID = diagnostics?.nextCorrelationID()
        return await DiagnosticContext.$transferID.withValue(relatedTransferID) {
            await DiagnosticContext.$recoveryID.withValue(recoveryID) {
                await self.recoverSessionImpl(
                    backend: backend, after: sessionError,
                    preferredStorageID: preferredStorageID, preferredPath: preferredPath,
                    presentError: presentError, recoveryID: recoveryID)
            }
        }
    }

    private func recoverSessionImpl(
        backend: any MTPFreshSessionBackend, after sessionError: BackendSessionError,
        preferredStorageID: UInt32?, preferredPath: String, presentError: Bool,
        recoveryID: UInt64?
    ) async -> Bool {
        diagnostics?.record(
            .recoveryDecision, failure: .classify(sessionError),
            recoveryID: recoveryID, recoveryAction: .reconnect)

        sessionGeneration += 1
        loadGeneration += 1
        let generation = sessionGeneration
        state = .recovering
        browsingIssue = nil
        isTransferring = false
        isLoadingDirectory = true
        files = []
        binListing = nil
        selectedFileIDs.removeAll()
        selectionAnchorID = nil
        binDeletionAvailable = false
        binExists = nil
        binCapabilityAvailable = false
        uploadCapabilityAvailable = false
        operationError = nil
        let started = DiagnosticLog.start()

        do {
            let available = try await backend.replaceSession()
            guard generation == sessionGeneration else { return false }
            guard !available.isEmpty else { throw BackendError.noStorage }
            try await prepareBins(available, session: generation)
            guard generation == sessionGeneration else { return false }
            storages = available
            let storageID = available.contains(where: { $0.id == preferredStorageID })
                ? preferredStorageID : available.first?.id
            selectedStorageID = storageID
            var path = storageID == preferredStorageID ? preferredPath : "/"
            guard let storageID else { throw BackendError.noStorage }
            let contents: DirectoryContents
            do {
                contents = try await directoryContents(storageID: storageID, path: path)
            } catch let error as BackendError where error == .invalidPath(path) && path != "/" {
                guard generation == sessionGeneration else { return false }
                contents = try await directoryContents(storageID: storageID, path: "/")
                path = "/"
            }
            guard generation == sessionGeneration else { return false }
            await applyStorageCapabilities(storageID)
            guard generation == sessionGeneration else { return false }
            uploadNeedsReconnect = false
            presentDirectory(contents, path: path)
            isLoadingDirectory = false
            diagnostics?.record(.recovery, since: started, recoveryID: recoveryID)
            if transferConfirmation != nil {
                transferConfirmation! += "\n\nThe device connection was restored automatically."
            }
            return true
        } catch {
            diagnostics?.record(
                .recovery, since: started, failure: .classify(error),
                recoveryID: recoveryID)
            guard generation == sessionGeneration else { return false }
            _ = try? await client.disconnect()
            guard generation == sessionGeneration else { return false }
            isLoadingDirectory = false
            let failure = BackendSessionError.usbTransportFailure(error.localizedDescription)
            requireReconnect(failure, presentError: presentError)
            return false
        }
    }

    private func supportsUpload(to storageID: UInt32?) async -> Bool {
        guard let storageID, binReadiness[storageID]?.ready == true,
            let backend = client as? any MTPUploadBackend else { return false }
        return await backend.supportsUpload(to: storageID)
    }

    private func blockWrites(_ storageID: UInt32, error: any Error) {
        let roots = binReadiness[storageID]?.roots ?? []
        binReadiness[storageID] = BinReadiness(roots: roots,
            issue: "Browsing only: the Bin could not be prepared or verified. " + error.localizedDescription
                + " Reconnect to try again.")
        storageWriteCapabilities[storageID] = StorageWriteCapabilities(upload: false, move: false)
        diagnostics?.record(.binLookup, failure: .classify(error))
    }

    private func prepareBins(_ storages: [MTPStorage], session: Int) async throws {
        binReadiness = [:]
        storageWriteCapabilities = [:]
        for storage in storages {
            guard !isQuitting, isDeviceAvailable else { throw CancellationError() }
            do {
                guard let deviceBin else { throw BinError.unsupported }
                let listing = try await deviceBin.prepare(storageID: storage.id)
                guard session == sessionGeneration else { return }
                binReadiness[storage.id] = BinReadiness(roots: listing.roots, count: listing.files.count, ready: true)
            } catch {
                guard session == sessionGeneration else { return }
                if let sessionError = BackendSessionError.from(error) { throw sessionError }
                blockWrites(storage.id, error: error)
            }
            await updateWriteCapabilities(storage.id)
            guard session == sessionGeneration else { return }
        }
    }

    private func updateWriteCapabilities(_ storageID: UInt32) async {
        let session = sessionGeneration
        let upload = await supportsUpload(to: storageID)
        let move = await (client as? any MTPMoveBackend)?.supportsMove(storageID: storageID) ?? false
        guard session == sessionGeneration else { return }
        storageWriteCapabilities[storageID] = StorageWriteCapabilities(upload: upload && binReadiness[storageID]?.ready == true,
            move: move && binReadiness[storageID]?.ready == true)
    }

    private func applyStorageCapabilities(_ storageID: UInt32) async {
        let session = sessionGeneration
        await updateWriteCapabilities(storageID)
        let bin = await (client as? any MTPBinBackend)?.supportsBin(storageID: storageID) ?? false
        let deletion = await (client as? any MTPBinBackend)?.supportsBinDeletion(storageID: storageID) ?? false
        guard session == sessionGeneration, selectedStorageID == storageID else { return }
        binExists = binReadiness[storageID]?.ready == true
        binCapabilityAvailable = bin && binExists == true
        binDeletionAvailable = deletion && binExists == true
        uploadCapabilityAvailable = storageWriteCapabilities[storageID]?.upload == true
    }

    func reserve(for transfer: RemoteTransferCoordinator) -> Bool {
        guard isConnected, !isQuitting, !isBusy, !uploadNeedsReconnect else { return false }
        remoteTransfer = transfer
        isTransferring = true
        operationError = nil
        transferConfirmation = nil
        return true
    }

    func release(_ transfer: RemoteTransferCoordinator, sessionError: BackendSessionError?) {
        guard remoteTransfer === transfer else { return }
        remoteTransfer = nil
        isTransferring = false
        if let sessionError { requireReconnect(sessionError, presentError: false) }
    }

    private func reset() {
        binFolderPath = nil
        uploadNeedsReconnect = false
        binDeletionAvailable = false
        binExists = nil
        binCapabilityAvailable = false
        uploadCapabilityAvailable = false
        loadGeneration += 1
        state = .disconnected
        browsingIssue = nil
        storages = []
        storageWriteCapabilities = [:]
        binReadiness = [:]
        selectedStorageID = nil
        files = []
        binListing = nil
        currentPath = "/"
        isLoadingDirectory = false
        isTransferring = false
        selectedFileIDs.removeAll()
        selectionAnchorID = nil
        operationError = nil
        transferConfirmation = nil
    }
}
