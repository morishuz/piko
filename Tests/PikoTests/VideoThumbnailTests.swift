import Foundation
import MTPWire
import Testing
@testable import Piko

private func sampleProperties(_ image: Data, format: UInt16 = 0x3801, size: UInt32? = nil, count: UInt32? = nil) -> [UInt16: Data] {
    var f = DatasetWriter(), s = DatasetWriter(), d = DatasetWriter()
    f.append(format)
    s.append(size ?? UInt32(image.count))
    d.append(count ?? UInt32(image.count))
    return [0xDC81: f.data, 0xDC82: s.data, 0xDC86: d.data + image]
}

@MainActor struct VideoThumbnailTests {
    @Test func goProCompanionLoadsAutomaticallyWithoutReadingVideoOrGeneratingFromIt() async throws {
        let data = try thumbnailPNG()
        let device = try SyntheticUploadDevice(advertisedWrites: [], existingNames: ["GX010001.MP4", "GX010001.THM", "GL010001.LRV"],
            originalData: ["GX010001.MP4": Data("video must never be read".utf8), "GX010001.THM": data])
        let model = DeviceBrowserModel(client: SwiftMTPBackend { device })
        await model.connectAndLoad()
        let video = try #require(model.files.first { $0.isVideoThumbnailCandidate })
        let sidecar = try #require(model.files.first { $0.isThumbnailSidecar })
        let key = try #require(model.thumbnailKey(for: video))
        #expect(key.previewFile == sidecar)
        model.updateVisibleThumbnails([video])
        try await thumbnailWait { model.thumbnails.entry(for: key)?.image != nil }
        #expect(await device.objectReads == [sidecar.id])
        #expect(!(await device.snapshot().commands.contains(0x100A)))
        let before = await device.snapshot().commands
        #expect(model.missingThumbnailFiles([video]).isEmpty)
        await model.generateThumbnails([video])
        #expect(await device.snapshot().commands == before)
        await model.disconnectAndReset()
    }

    @Test(arguments: [0, ReadSession.maximumThumbnailBytes + 1])
    func emptyOrOversizedSidecarsDoNoIO(size: Int) async throws {
        let device = try SyntheticUploadDevice(advertisedWrites: [], existingNames: ["a.THM"],
            originalData: ["a.THM": Data(repeating: 0, count: size)])
        let backend = try await connectedUploadBackend(device)
        let file = try #require(try await backend.contents(storageID: 1, path: "/", showHiddenFiles: false).first)
        let before = await device.snapshot().commands
        #expect(try await backend.thumbnail(storageID: 1, file: file) == nil)
        #expect(await device.snapshot().commands == before)
        try await backend.disconnect()
    }

    @Test(arguments: ["movie.mp4", "movie.MOV", "movie.360"])
    func advertisedVideoThumbnailUsesGetThumbOnly(name: String) async throws {
        let data = try thumbnailPNG()
        let device = try SyntheticUploadDevice(advertisedWrites: [0x100A], existingNames: [name], thumbnailData: data)
        let backend = try await connectedUploadBackend(device)
        let file = try #require(try await backend.contents(storageID: 1, path: "/", showHiddenFiles: false).first)
        #expect(try await backend.thumbnail(storageID: 1, file: file) == data)
        #expect(await device.objectReads.isEmpty)
        try await backend.disconnect()
    }

    @Test(arguments: [false, true]) func representativeSamplesAreCapabilityGatedAndProbeOncePerFormat(rejectedThumb: Bool) async throws {
        let data = try thumbnailPNG()
        let device = try SyntheticUploadDevice(advertisedWrites: [0x100A, 0x9801, 0x9803], existingNames: ["a.mp4", "b.mp4"],
            thumbnailData: rejectedThumb ? data : nil, sampleProperties: sampleProperties(data))
        let backend = try await connectedUploadBackend(device)
        if rejectedThumb { await device.configureFault(reject: 0x100A, rejectionCode: 0x2010) }
        let files = try await backend.contents(storageID: 1, path: "/", showHiddenFiles: false)
        for file in files { #expect(try await backend.thumbnail(storageID: 1, file: file) == data) }
        let commands = await device.snapshot().commands
        #expect(commands.filter { $0 == 0x9801 }.count == 1)
        #expect(commands.filter { $0 == 0x9803 }.count == 6)
        #expect(await device.objectReads.isEmpty)
        try await backend.disconnect()
        await device.prepareReconnect()
        _ = try await backend.connect()
        let fresh = try #require(try await backend.contents(storageID: 1, path: "/", showHiddenFiles: false).first)
        #expect(try await backend.thumbnail(storageID: 1, file: fresh) == data)
        #expect(await device.snapshot().commands.filter { $0 == 0x9801 }.count == 2)
        try await backend.disconnect()
    }

    @Test(arguments: ["noOperations", "noProperties", "videoSample", "oversized", "empty"])
    func unavailablePreviewsNeverReadOriginals(reason: String) async throws {
        let data = try thumbnailPNG()
        let properties: [UInt16: Data] = reason == "noProperties" ? [:] : sampleProperties(data,
            format: reason == "videoSample" ? 0xB982 : 0x3801,
            size: reason == "oversized" ? UInt32(ReadSession.maximumThumbnailBytes + 1) : reason == "empty" ? 0 : nil)
        let device = try SyntheticUploadDevice(advertisedWrites: reason == "noOperations" ? [] : [0x9801, 0x9803],
            existingNames: ["a.mp4", "b.mp4"], sampleProperties: properties)
        let backend = try await connectedUploadBackend(device)
        let files = try await backend.contents(storageID: 1, path: "/", showHiddenFiles: false)
        let before = await device.snapshot().commands
        for file in files { #expect(try await backend.thumbnail(storageID: 1, file: file) == nil) }
        let after = await device.snapshot().commands
        if reason == "noOperations" { #expect(before == after) }
        if reason == "noProperties" {
            #expect(after.filter { $0 == 0x9801 }.count == 1)
            #expect(!after.contains(0x9803))
        }
        if reason == "videoSample" { #expect(after.filter { $0 == 0x9803 }.count == 2) }
        if reason == "oversized" || reason == "empty" { #expect(after.filter { $0 == 0x9803 }.count == 4) }
        #expect(await device.objectReads.isEmpty)
        #expect(await device.snapshot().closed == false)
        try await backend.disconnect()
    }

    @Test(arguments: [UInt16(0x100A), UInt16(0x9801)])
    func sessionLossDuringPreviewDiscoveryNeverFallsThrough(operation: UInt16) async throws {
        let data = try thumbnailPNG()
        let device = try SyntheticUploadDevice(advertisedWrites: [0x100A, 0x9801, 0x9803], existingNames: ["a.mp4"],
            thumbnailData: operation == 0x100A ? data : nil, sampleProperties: sampleProperties(data))
        let backend = try await connectedUploadBackend(device)
        let file = try #require(try await backend.contents(storageID: 1, path: "/", showHiddenFiles: false).first)
        await device.configureFault(reject: operation, rejectionCode: 0x2003)
        await #expect(throws: BackendSessionError.self) { try await backend.thumbnail(storageID: 1, file: file) }
        #expect(await device.snapshot().closed)
        #expect(!(await device.snapshot().commands.contains(0x9803)))
        #expect(await device.objectReads.isEmpty)
    }

    @Test(arguments: ["count", "payload", "format"])
    func malformedSamplesRetireSessionWithoutFallback(fault: String) async throws {
        let data = fault == "payload" ? Data(repeating: 0, count: ReadSession.maximumThumbnailBytes + 1) : try thumbnailPNG()
        var properties = sampleProperties(data, size: 100, count: fault == "count" ? UInt32.max : nil)
        if fault == "format" { properties[0xDC81] = Data([1]) }
        let device = try SyntheticUploadDevice(advertisedWrites: [0x9801, 0x9803], existingNames: ["a.mp4"], sampleProperties: properties)
        let backend = try await connectedUploadBackend(device)
        let file = try #require(try await backend.contents(storageID: 1, path: "/", showHiddenFiles: false).first)
        await #expect(throws: BackendSessionError.self) { try await backend.thumbnail(storageID: 1, file: file) }
        #expect(await device.objectReads.isEmpty)
        #expect(await device.snapshot().closed)
        #expect(await device.cancelCount == 0)
    }

    @Test(arguments: [false, true]) func cancellationDrainsOnlyCurrentPreviewTransaction(sidecar: Bool) async throws {
        let data = try thumbnailPNG()
        let device = try SyntheticUploadDevice(advertisedWrites: [0x9801, 0x9803], existingNames: [sidecar ? "a.THM" : "a.mp4"],
            originalData: ["a.THM": data], sampleProperties: sampleProperties(data))
        let backend = try await connectedUploadBackend(device)
        let file = try #require(try await backend.contents(storageID: 1, path: "/", showHiddenFiles: false).first)
        await device.pause(operation: sidecar ? 0x1009 : 0x9803, includingCommand: true)
        let request = Task { try await backend.thumbnail(storageID: 1, file: file) }
        try await thumbnailWait { await device.isPaused }
        request.cancel()
        await device.resume()
        await #expect(throws: CancellationError.self) { try await request.value }
        if !sidecar { #expect(await device.snapshot().commands.filter { $0 == 0x9803 }.count == 1) }
        #expect(await device.interruptedIO == false)
        #expect(await device.cancelCount == 0)
        #expect(try await backend.contents(storageID: 1, path: "/", showHiddenFiles: false) == [file])
        try await backend.disconnect()
    }

    @Test func companionMatchingRejectsAmbiguityOtherChaptersAndOtherDirectories() {
        let video = DemoBackend.entry(id: 1, name: "GX010001.MP4", parent: "/DCIM", folder: false)
        let thm = DemoBackend.entry(id: 2, name: "gx010001.thm", parent: "/DCIM", folder: false)
        #expect(ThumbnailSidecars([video, thm]).companion(for: video) == thm)
        let duplicate = DemoBackend.entry(id: 3, name: "GX010001.THM", parent: "/DCIM", folder: false)
        #expect(ThumbnailSidecars([video, thm, duplicate]).companion(for: video) == nil)
        let otherVideo = DemoBackend.entry(id: 4, name: "GX010001.MOV", parent: "/DCIM", folder: false)
        #expect(ThumbnailSidecars([video, thm, otherVideo]).companion(for: video) == nil)
        for name in ["GX020001.THM", "GL010001.THM"] {
            let different = DemoBackend.entry(id: 5, name: name, parent: "/DCIM", folder: false)
            #expect(ThumbnailSidecars([video, different]).companion(for: video) == nil)
        }
        let otherFolder = DemoBackend.entry(id: 6, name: thm.name, parent: "/Other", folder: false)
        #expect(ThumbnailSidecars([video, otherFolder]).companion(for: video) == nil)
    }
}
