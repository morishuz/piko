import Foundation
import Testing
@testable import MTPUSB

private func configuration(vendor: Bool = false) -> Data {
    var bytes: [UInt8] = [9, 2, 0, 0, 1, 1, 0, 0x80, 50,
                         9, 4, 2, 0, vendor ? 3 : 2, vendor ? 255 : 6, vendor ? 255 : 1, vendor ? 0 : 1, 1,
                         7, 5, 0x81, 2, 0, 2, 0,
                         7, 5, 0x02, 2, 0, 2, 0]
    if vendor { bytes += [7, 5, 0x83, 3, 64, 0, 1] }
    bytes[2] = UInt8(bytes.count)
    return Data(bytes)
}

@Test func appleUSBDiscoveryOnlyAcceptsMTPShapesAndExactVendorName() {
    #expect(AppleUSBEndpoints.accepts(interfaceClass: 6, subclass: 1, protocolCode: 1, name: nil))
    #expect(AppleUSBEndpoints.accepts(interfaceClass: 255, subclass: 255, protocolCode: 0, name: "MTP"))
    for name in [nil, "ADB", "MTP extra", "mtp", "MTP\0"] as [String?] {
        #expect(!AppleUSBEndpoints.accepts(interfaceClass: 255, subclass: 255, protocolCode: 0, name: name))
    }
    for cls in [3, 8, 9] {
        #expect(!AppleUSBEndpoints.accepts(interfaceClass: cls, subclass: 1, protocolCode: 1, name: "MTP"))
    }
}

@Test(arguments: [false, true]) func appleUSBParsesSelectedEndpoints(vendor: Bool) throws {
    let endpoints = try AppleUSBEndpoints.parse(configuration(vendor: vendor), interfaceNumber: 2, vendorSpecific: vendor)
    #expect(endpoints.input == 0x81 && endpoints.output == 2)
    #expect(endpoints.inputPacketSize == 512 && endpoints.outputPacketSize == 512)
}

@Test func appleUSBRejectsTruncatedAndMalformedDescriptors() throws {
    let good = configuration()
    for size in 0..<good.count {
        #expect(throws: USBError.self) { try AppleUSBEndpoints.parse(Data(good.prefix(size)), interfaceNumber: 2, vendorSpecific: false) }
    }
    for (index, value) in [(0, UInt8(0)), (12, 1), (13, 3), (14, 8), (18, 0), (20, 0x80), (23, 3), (27, 0x81)] {
        var malformed = good
        malformed[index] = value
        #expect(throws: USBError.self) { try AppleUSBEndpoints.parse(malformed, interfaceNumber: 2, vendorSpecific: false) }
    }
    #expect(throws: USBError.self) { try AppleUSBEndpoints.parse(good, interfaceNumber: 4, vendorSpecific: false) }
    #expect(throws: USBError.self) { try AppleUSBEndpoints.parse(good, interfaceNumber: 2, vendorSpecific: true) }
}
