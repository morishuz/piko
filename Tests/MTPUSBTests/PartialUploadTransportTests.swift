import Foundation
import MTPWire
import Testing

@testable import MTPUSB

/// Exercises ReadSession through the production USBTransport, including its
/// 64 KiB write limit and the terminal ZLP on packet-aligned range payloads.
private actor PartialUploadIO: USBBulkIO {
    nonisolated let inputPacketSize = 512
    nonisolated let outputPacketSize = 512
    private var incoming: [Data] = []
    private var transaction: UInt32 = 0
    private var expectsHeader = false
    private var expectedBytes: Int?
    private(set) var payload = Data()
    private(set) var writes: [Int] = []
    private(set) var closed = false

    func send(_ data: Data) async -> USBTransfer {
        writes.append(data.count)
        do {
            if let expectedBytes {
                payload.append(data)
                guard payload.count <= expectedBytes else { throw WireError.invalidLength }
                if payload.count == expectedBytes && (data.isEmpty || data.count % outputPacketSize != 0) {
                    try reply(parameters: [UInt32(expectedBytes)])
                    self.expectedBytes = nil
                }
            } else if expectsHeader {
                let header = try ContainerHeader(data: data)
                guard data.count == 12, header.type == .data, header.code == 0x95C2,
                    header.transaction == transaction else { throw WireError.unexpectedContainer }
                expectedBytes = header.payloadLength
                expectsHeader = false
            } else {
                let header = try ContainerHeader(data: Data(data.prefix(12)))
                guard header.type == .command else { throw WireError.unexpectedContainer }
                transaction = header.transaction
                if header.code == 0x95C2 {
                    expectsHeader = true
                } else { try reply() }
            }
            return USBTransfer(status: 0, transferred: data.count, data: Data())
        } catch { return USBTransfer(status: -1, transferred: 0, data: Data()) }
    }

    private func reply(parameters: [UInt32] = []) throws {
        var writer = DatasetWriter()
        for value in parameters { writer.append(value) }
        incoming.append(try ContainerHeader(length: UInt32(12 + writer.data.count),
            type: .response, code: 0x2001, transaction: transaction).encoded() + writer.data)
    }

    func receive(length: Int) async -> USBTransfer {
        guard !incoming.isEmpty else { return USBTransfer(status: -7, transferred: 0, data: Data()) }
        let bytes = incoming.removeFirst()
        return USBTransfer(status: 0, transferred: bytes.count, data: bytes)
    }
    func close() async { closed = true }
}

@Suite struct PartialUploadTransportTests {
    @Test(arguments: [65_535, 65_536, 65_537, 1_048_576])
    func rangePayloadCrossesRealUSBTransportWithoutExceedingWriteLimit(size: Int) async throws {
        let io = PartialUploadIO()
        let log = DiagnosticLog()
        let session = ReadSession(transport: USBTransport(io: io, diagnostics: log), diagnostics: log)
        let payload = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 / 251 + $0) })
        try await session.open()
        try await session.beginEditObject(handle: 42)
        try await session.sendPartialObject(handle: 42, offset: 0, data: payload)
        try await session.endEditObject(handle: 42)
        #expect(await io.payload == payload)
        #expect(await io.writes.allSatisfy { $0 <= 65_536 })
        #expect(await io.writes.filter { $0 == 0 }.count == (size % 512 == 0 ? 1 : 0))
        #expect(log.snapshot().events.allSatisfy { $0.failure == nil })
        #expect(await session.isUsable)
        try await session.close()
        #expect(await io.closed)
    }
}
