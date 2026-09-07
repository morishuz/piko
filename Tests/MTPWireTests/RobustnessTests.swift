import Foundation
import Testing

@testable import MTPWire

/// Fixed-seed mutation/property smoke corpus, not a coverage-guided fuzzing claim.
private struct CorpusRandom {
    var state: UInt64 = 0x4d54_505f_5357_4946
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}

@Test func robustnessSeededParserMutationCorpus() throws {
    var storage = DatasetWriter()
    for _ in 0..<3 { storage.append(UInt16(1)) }
    storage.append(UInt64.max)
    storage.append(UInt64(0))
    storage.append(UInt32.max)
    try storage.append(string: "Storage 📷")
    try storage.append(string: "Volume")
    var object = DatasetWriter()
    for _ in 0..<52 { object.append(UInt8(0)) }
    for text in ["photo 📷.jpg", "20260831T120000", "", ""] { try object.append(string: text) }
    var device = DatasetWriter()
    device.append(UInt16(100))
    device.append(UInt32(6))
    device.append(UInt16(100))
    try device.append(string: "extension")
    device.append(UInt16(0))
    for _ in 0..<5 { device.append(UInt32(0)) }
    for text in ["manufacturer", "model", "1", "private-serial"] { try device.append(string: text) }
    _ = try StorageInfo(data: storage.data)
    _ = try ObjectInfo(data: object.data)
    _ = try DeviceInfo(data: device.data)
    let seeds = [storage.data, object.data, device.data, Data(repeating: 255, count: 512)]
    var random = CorpusRandom()
    for iteration in 0..<12000 {
        var data = seeds[iteration % seeds.count]
        switch iteration % 4 {
        case 0:
            data = Data(data.prefix(Int(random.next() % UInt64(data.count + 1))))
        case 1:
            for _ in 0..<4 {
                let offset = Int(random.next() % UInt64(data.count))
                data[offset] = UInt8(truncatingIfNeeded: random.next() >> 32)
            }
        case 2:
            data.append(UInt8(truncatingIfNeeded: random.next() >> 32))
        default:
            data = Data(
                (0..<Int(random.next() % 1025)).map { _ in UInt8(truncatingIfNeeded: random.next() >> 32) })
        }
        // A malformed size/count may never allocate according to its claim.
        for parse: (Data) throws -> Void in [
            { _ = try StorageInfo(data: $0) }, { _ = try ObjectInfo(data: $0) },
            { _ = try DeviceInfo(data: $0) }, { _ = try ContainerHeader(data: $0) },
            {
                var r = DatasetReader($0)
                let a = try r.readUInt32Array()
                #expect(a.count <= $0.count / 4)
            },
            {
                var r = DatasetReader($0)
                let a = try r.readUInt16Array()
                #expect(a.count <= $0.count / 2)
            },
            {
                var r = DatasetReader($0)
                _ = try r.readString()
                #expect(r.remaining >= 0)
            },
        ] {
            do { try parse(data) } catch { #expect(error is WireError) }
        }
    }
}

@Test func robustnessAllUTF16CodeUnitsHaveStrictSingleUnitSemantics() throws {
    for unit in UInt32(0)...UInt32(UInt16.max) {
        var writer = DatasetWriter()
        writer.append(UInt8(2))
        writer.append(UInt16(unit))
        writer.append(UInt16(0))
        var reader = DatasetReader(writer.data)
        if unit == 0 || (0xD800...0xDFFF).contains(unit) {
            #expect(throws: WireError.invalidString) { try reader.readString() }
        } else {
            let string = try reader.readString()
            #expect(Array(string.utf16) == [UInt16(unit)])
            try reader.requireEnd()
        }
    }
}
