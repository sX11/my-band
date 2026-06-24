import Testing
import Foundation
@testable import My_Band

// Validates the OKOK/Chipsea VC0 weight decode against real "Yoda1" scale advertisements captured
// on hardware (2026-06-23). Each hex is the full BLE manufacturer data: [companyId: UInt16 LE][payload].
@MainActor
struct ScaleWeightParserTests {

    @Test func decodesFinalWeightKg() throws {
        // company id low byte 0xC0 (VC0), kg unit (byte6 = 0x25 → final, scale bits 0).
        let r = try #require(ScaleWeightParser.parse(Fixtures.bytes("c0101f451388000025000000000000")))
        #expect(r.isFinal)
        #expect(abs(r.weightKg - 80.05) < 0.001)
    }

    @Test func decodesDifferentReadings() throws {
        // High byte of the company id varies (0x08 vs 0x10) but the low byte 0xC0 is what matches.
        let a = try #require(ScaleWeightParser.parse(Fixtures.bytes("c0081f541388000025000000000000")))
        let b = try #require(ScaleWeightParser.parse(Fixtures.bytes("c0081ec31388000025000000000000")))
        #expect(abs(a.weightKg - 80.20) < 0.001)
        #expect(abs(b.weightKg - 78.75) < 0.001)
    }

    @Test func settlingFrameIsNotFinal() throws {
        // The zero/settling frame: weight 0, byte6 = 0x24 → final bit clear.
        let r = try #require(ScaleWeightParser.parse(Fixtures.bytes("c01000000000000024000000000000")))
        #expect(!r.isFinal)
        #expect(r.weightKg == 0)
    }

    @Test func rejectsNonVC0AndShortData() {
        // Non-0xC0 company id → unsupported variant here.
        #expect(ScaleWeightParser.parse(Fixtures.bytes("0e052111")) == nil)
        // Too short to hold a company id.
        #expect(ScaleWeightParser.parse(Fixtures.bytes("c0")) == nil)
    }
}
