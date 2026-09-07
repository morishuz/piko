import Foundation
import MTPWire
import Testing
@testable import MTPUSB

private actor ResponderResetIO: USBMTPControlIO {
    nonisolated let inputPacketSize = 512
    nonisolated let outputPacketSize = 512
    let resetResult: USBTransfer
    var pauseSend: Bool
    private var waiter: CheckedContinuation<Void, Never>?
    var paused: Bool { waiter != nil }
    private(set) var requests: [(UInt8, Data, Int)] = []
    private(set) var writes: [Data] = []
    private(set) var closes = 0
    init(status: Int32 = 0, transferred: Int = 0, pauseSend: Bool = false) {
        resetResult = USBTransfer(status: status, transferred: transferred, data: Data())
        self.pauseSend = pauseSend
    }
    func send(_ data: Data) async -> USBTransfer {
        writes.append(data)
        if pauseSend { await withCheckedContinuation { waiter = $0 }; pauseSend = false }
        return USBTransfer(status: 0, transferred: data.count, data: Data())
    }
    func resume() { waiter?.resume(); waiter = nil }
    func receive(length: Int) -> USBTransfer {
        let transaction = writes.last.map { Data($0[8..<12]) } ?? Data(repeating: 0, count: 4)
        let data = Data([12, 0, 0, 0, 3, 0, 1, 32]) + transaction
        return USBTransfer(status: 0, transferred: 12, data: data)
    }
    func receiveForCancellation(length: Int) -> USBTransfer { USBTransfer(status: -7, transferred: 0, data: Data()) }
    func mtpControl(request: UInt8, data: Data, inputLength: Int) -> USBTransfer {
        requests.append((request, data, inputLength))
        return resetResult
    }
    func close() { closes += 1 }
}

struct ResponderResetTests {
    @Test(arguments: [Int32(0), -7, -4, -99])
    func acceptedOrAmbiguousResetRetiresOldSession(status: Int32) async throws {
        let io = ResponderResetIO(status: status)
        let log = DiagnosticLog()
        let transport = USBTransport(io: io, diagnostics: log)
        let session = ReadSession(transport: transport, diagnostics: log)
        try await session.open()
        #expect(await session.resetResponder() == (status == 0 ? .acknowledged : .failed))
        #expect(!(await session.isUsable))
        #expect(await session.resetResponder() == .notAttempted)
        await #expect(throws: (any Error).self) { try await session.objectHandles(storageID: 1) }
        try await session.close()
        let requests = await io.requests
        #expect(requests.count == 1)
        #expect(requests.first?.0 == 0x66 && requests.first?.1 == Data() && requests.first?.2 == 0)
        #expect(await io.writes.count == 1) // OpenSession only; no CloseSession after reset.
        #expect(await io.closes == 1)
        #expect(log.snapshot().events.filter { $0.kind == .sessionReleased }.count == 1)
        #expect(log.snapshot().events.filter { $0.kind == .responderReset }.count == 2)
    }

    @Test func controlStallPreservesBulkSessionAndIsNotRetried() async throws {
        let io = ResponderResetIO(status: -9)
        let log = DiagnosticLog()
        let session = ReadSession(transport: USBTransport(io: io, diagnostics: log), diagnostics: log)
        try await session.open()
        #expect(await session.resetResponder() == .rejected)
        #expect(await session.isUsable)
        #expect(await session.resetResponder() == .rejected)
        #expect(await io.requests.count == 1)
        #expect(await io.closes == 0)
        #expect(log.snapshot().events.filter { $0.kind == .sessionReleased }.isEmpty)
        #expect(log.snapshot().events.last { $0.kind == .responderReset }?.failure == .deviceRejected)
        // A subsequent MTP command uses the same stream and transaction counter.
        try await session.close()
        #expect(await io.writes.count == 2)
        #expect(await io.closes == 1)
    }

    @Test(arguments: [Int32(0), -9])
    func malformedResetResultFailsClosed(status: Int32) async {
        let io = ResponderResetIO(status: status, transferred: 1)
        let transport = USBTransport(io: io)
        #expect(await transport.resetResponder() == .failed)
        #expect(await io.closes == 1)
    }

    @Test func resetCannotInterruptActiveBulkIO() async throws {
        let io = ResponderResetIO(pauseSend: true)
        let transport = USBTransport(io: io)
        let write = Task { try await transport.write(Data([1])) }
        for _ in 0..<1000 {
            if await io.paused { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await io.paused)
        #expect(await transport.resetResponder() == .notAttempted)
        #expect(await io.requests.isEmpty)
        await io.resume()
        try await write.value
        await transport.close()
    }
}
