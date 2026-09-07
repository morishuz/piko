import Foundation
import MTPWire

/// Bounded cancellation at a completed bulk-transfer boundary. Drain only the
/// responder's already queued bytes, never the remainder of a large file.
enum MTPCancellation {
    static func run(io: any USBMTPControlIO, transaction: UInt32) async -> Bool {
        var writer = DatasetWriter()
        writer.append(UInt16(0x4001)) // CancelTransaction dataset code
        writer.append(transaction)
        let cancel = await io.mtpControl(request: 0x64, data: writer.data, inputLength: 0)
        guard cancel.status == 0, cancel.transferred == 6 else { return false }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var drained = 0
        // Each control request has a 1s deadline, each drain read 100ms.
        // A responder must report ready AND have no queued bulk data.
        for _ in 0..<512 {
            guard ContinuousClock.now < deadline else { return false }
            let read = await io.receiveForCancellation(length: 65536)
            guard read.transferred >= 0, read.transferred <= 65536,
                read.data.count == read.transferred else { return false }
            drained += read.transferred
            guard drained <= 16 * 1024 * 1024 else { return false }
            if read.status == 0 { continue }
            guard read.status == -7 && read.transferred == 0 else { return false }
            let status = await io.mtpControl(request: 0x67, data: Data(), inputLength: 4)
            guard status.status == 0, status.transferred == 4, status.data.count == 4 else { return false }
            var reader = DatasetReader(status.data)
            guard (try? reader.readUInt16()) == 4, let code = try? reader.readUInt16() else { return false }
            if code == 0x2001 { return true }
            guard code == 0x2019 else { return false }
        }
        return false
    }
}
