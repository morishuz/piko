import Foundation
import Testing
@testable import Piko

@MainActor
struct DeviceDateFormatterTests {
    @Test(arguments: ["20260902T222248", "20260902T222248.12", "2026-09-02T22:22:48.000"])
    func deviceWallClockUsesRegionalFormattingWithoutTimeShift(_ raw: String) {
        let german = DeviceDateFormatter(locale: Locale(identifier: "de_DE"), timeZone: TimeZone(secondsFromGMT: -18000)!)
        #expect(german.string(from: raw) == "02.09.2026, 22:22")
    }

    @Test(arguments: ["20260902T222248Z", "2026-09-02T22:22:48.000Z",
                      "20260903T002248+0200", "2026-09-02T17:22:48-05:00"])
    func explicitZonesConvertToMacTimeZone(_ raw: String) {
        let formatter = DeviceDateFormatter(locale: Locale(identifier: "de_DE"), timeZone: TimeZone(secondsFromGMT: 7200)!)
        #expect(formatter.string(from: raw) == "03.09.2026, 00:22")
    }

    @Test func missingZoneDoesNotInventDaylightSavingAdjustment() {
        let formatter = DeviceDateFormatter(locale: Locale(identifier: "de_DE"), timeZone: TimeZone(identifier: "Europe/Berlin")!)
        #expect(formatter.string(from: "20260329T023000") == "29.03.2026, 02:30")
        #expect(formatter.string(from: "20240229T120000") == "29.02.2024, 12:00")
    }

    @Test(arguments: ["", "unknown", "00000000T000000", "00000101T000000", "20260230T120000",
                      "20260229T120000", "20261301T000000", "20260902T250000", "20260902T226000",
                      "20260902T222248+2460", "20260902T222248junk", "20260902", String(repeating: "1", count: 65)])
    func absentOrInvalidDatesShowDash(_ raw: String) {
        #expect(DeviceDateFormatter().string(from: raw) == "—")
    }
}
