import Foundation
import MTPWire
import Testing
@testable import MTPUSB

private actor CancellationIO: USBMTPControlIO {
    nonisolated let inputPacketSize = 512
    nonisolated let outputPacketSize = 512
    var replies = Data()
    var blocked: CheckedContinuation<Void, Never>?
    private(set) var atBoundary = false
    private(set) var controls: [(UInt8, Data, Int)] = []
    private(set) var closes = 0
    private var sentDataHeader = false
    private let reject: Bool
    private let endlessDrain: Bool
    private(set) var drains = 0
    init(reject: Bool = false, endlessDrain: Bool = false) {
        self.reject = reject; self.endlessDrain = endlessDrain
    }
    private func response(_ tx: UInt32, parameters: [UInt32] = []) throws -> Data {
        var data = try ContainerHeader(length: UInt32(12 + parameters.count * 4), type: .response, code: 0x2001, transaction: tx).encoded()
        var writer = DatasetWriter()
        for p in parameters { writer.append(p) }
        data.append(writer.data)
        return data
    }
    func send(_ data: Data) async -> USBTransfer {
        if let header = try? ContainerHeader(data: Data(data.prefix(12))) {
            if header.type == .command {
                switch header.code {
                case 0x1002: replies = try! response(0)
                case 0x1009:
                    replies = try! ContainerHeader.data(code: 0x1009, transaction: header.transaction, payloadLength: 1024 * 1024)
                    replies.append(Data(repeating: 0x41, count: 65536 - 12))
                default: break
                }
            } else if header.type == .data, header.code == 0x100C {
                replies = try! response(header.transaction, parameters: [1, 0, 10])
            } else if header.type == .data, header.code == 0x100D {
                atBoundary = true
                await withCheckedContinuation { blocked = $0 }
            }
        }
        return USBTransfer(status: 0, transferred: data.count, data: Data())
    }
    func receive(length: Int) async -> USBTransfer {
        if !replies.isEmpty {
            let data = Data(replies.prefix(length)); replies.removeFirst(data.count)
            return USBTransfer(status: 0, transferred: data.count, data: data)
        }
        atBoundary = true
        await withCheckedContinuation { blocked = $0 }
        return USBTransfer(status: 0, transferred: length, data: Data(repeating: 0x41, count: length))
    }
    func release() { blocked?.resume(); blocked = nil }
    func mtpControl(request: UInt8, data: Data, inputLength: Int) async -> USBTransfer {
        controls.append((request, data, inputLength))
        if reject { return USBTransfer(status: -9, transferred: 0, data: Data()) }
        if request == 0x64 { return USBTransfer(status: 0, transferred: data.count, data: Data()) }
        return USBTransfer(status: 0, transferred: 4, data: Data([4, 0, 1, 0x20]))
    }
    func receiveForCancellation(length: Int) async -> USBTransfer {
        drains += 1
        if drains == 1 || endlessDrain { return USBTransfer(status: 0, transferred: length, data: Data(repeating: 1, count: length)) }
        return USBTransfer(status: -7, transferred: 0, data: Data())
    }
    func close() async { closes += 1 }
}

struct CancellationTests {
    @Test(arguments: [false, true]) func activeFileCancellationReachesDeviceAndCloses(uploading: Bool) async throws {
        let io = CancellationIO()
        let transport = USBTransport(io: io)
        let session = ReadSession(transport: transport)
        try await session.open()
        let task = Task {
            if uploading {
                let info = try ObjectInfo.uploadFile(storageID: 1, parent: UInt32.max, size: 1024 * 1024, filename: "large.bin")
                _ = try await session.uploadObject(info: info, read: { Data(repeating: 0x41, count: $0) })
            } else {
                try await session.download(handle: 10, expectedSize: 1024 * 1024, sink: { _ in })
            }
        }
        for _ in 0..<2000 {
            if await io.atBoundary { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await io.atBoundary)
        task.cancel()
        await io.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        let controls = await io.controls
        #expect(controls.map(\.0) == [0x64, 0x67])
        #expect(controls[0].1 == Data([1, 0x40, uploading ? 2 : 1, 0, 0, 0]))
        #expect(await io.closes == 1)
        #expect(await session.cancellationNeedsPhysicalReconnect == false)
        #expect(await session.isUsable == false)
        try await session.close()
        #expect(await io.closes == 1)
    }

    @Test func rejectedCancellationClosesAndRequiresPhysicalReconnect() async {
        let io = CancellationIO(reject: true)
        let transport = USBTransport(io: io)
        #expect(await transport.cancel(transaction: 4) == false)
        #expect(await transport.cancellationNeedsPhysicalReconnect)
        #expect(await io.controls.count == 1)
        #expect(await io.closes == 1)
    }

    @Test func cancellationNeverDrainsEntireLargeFile() async {
        let io = CancellationIO(endlessDrain: true)
        let transport = USBTransport(io: io)
        #expect(await transport.cancel(transaction: 4) == false)
        #expect(await io.drains <= 257)
        #expect(await transport.cancellationNeedsPhysicalReconnect)
        #expect(await io.closes == 1)
    }
}
