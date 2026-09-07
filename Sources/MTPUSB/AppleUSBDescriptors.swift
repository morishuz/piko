import Foundation

/// Pure descriptor validation: no device access. Never changes configuration
/// or alternate setting to make an unsupported interface fit.
struct AppleUSBEndpoints: Equatable {
    let input: UInt8
    let output: UInt8
    let inputPacketSize: Int
    let outputPacketSize: Int

    static func accepts(interfaceClass: Int, subclass: Int, protocolCode: Int, name: String?) -> Bool {
        (interfaceClass == 6 && subclass == 1 && protocolCode == 1)
            || (interfaceClass == 255 && subclass == 255 && protocolCode == 0 && name == "MTP")
    }

    static func parse(_ data: Data, interfaceNumber: UInt8, vendorSpecific: Bool) throws -> Self {
        let b = Array(data)
        guard b.count >= 9, b[0] == 9, b[1] == 2,
              Int(b[2]) | (Int(b[3]) << 8) == b.count else { throw USBError.invalidTransfer }
        var offset = 0
        var active = false
        var found = false
        var expected = 0
        var endpoints: [(UInt8, Int, Int)] = []
        while offset < b.count {
            guard offset + 2 <= b.count else { throw USBError.invalidTransfer }
            let length = Int(b[offset])
            guard length >= 2, offset + length <= b.count else { throw USBError.invalidTransfer }
            if b[offset + 1] == 4 {
                guard length >= 9 else { throw USBError.invalidTransfer }
                active = b[offset + 2] == interfaceNumber && b[offset + 3] == 0
                if active {
                    guard !found else { throw USBError.invalidTransfer }
                    found = true
                    expected = Int(b[offset + 4])
                    let cls = b[offset + 5], sub = b[offset + 6], proto = b[offset + 7]
                    guard vendorSpecific ? (cls == 255 && sub == 255 && proto == 0)
                        : (cls == 6 && sub == 1 && proto == 1) else { throw USBError.invalidTransfer }
                }
            } else if b[offset + 1] == 5 && active {
                guard length >= 7 else { throw USBError.invalidTransfer }
                let address = b[offset + 2], type = Int(b[offset + 3] & 3)
                let packet = Int(b[offset + 4]) | (Int(b[offset + 5]) << 8)
                guard address & 15 != 0, address & 0x70 == 0,
                      !endpoints.contains(where: { $0.0 == address }) else { throw USBError.invalidTransfer }
                if type == 2 {
                    guard [8, 16, 32, 64, 512, 1024].contains(packet) else { throw USBError.invalidTransfer }
                } else {
                    guard type == 3, address & 0x80 != 0, packet > 0,
                          packet & 0x7ff > 0, packet & 0x7ff <= 1024, packet & 0xe000 == 0,
                          packet & 0x1800 != 0x1800 else { throw USBError.invalidTransfer }
                }
                endpoints.append((address, type, packet))
            }
            offset += length
        }
        let inputs = endpoints.filter { $0.1 == 2 && $0.0 & 0x80 != 0 }
        let outputs = endpoints.filter { $0.1 == 2 && $0.0 & 0x80 == 0 }
        guard found, endpoints.count == expected, inputs.count == 1, outputs.count == 1,
              !vendorSpecific || (endpoints.count == 3 && endpoints.filter { $0.1 == 3 }.count == 1)
        else { throw USBError.invalidTransfer }
        return Self(input: inputs[0].0, output: outputs[0].0,
                    inputPacketSize: inputs[0].2, outputPacketSize: outputs[0].2)
    }
}
