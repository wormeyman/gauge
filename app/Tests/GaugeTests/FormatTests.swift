import Testing
@testable import Gauge

@Suite struct FormatTests {
    @Test func memoryUsesBinaryUnits() {
        #expect(Fmt.memoryText(16 * 1_073_741_824) == "16.00 GB")
        #expect(Fmt.memoryText(347.2 * 1_048_576) == "347.2 MB")
        #expect(Fmt.memory(1_073_741_823).1 == "MB")
    }

    @Test func storageUsesDecimalUnits() {
        #expect(Fmt.storageText(994_610_000_000) == "994.61 GB")
        #expect(Fmt.storageText(2_000_000_000_000) == "2.00 TB")
        #expect(Fmt.storageText(46_300_000) == "46.3 MB")
        #expect(Fmt.storageText(4_000) == "4 kB")
    }

    @Test func ratesPickTheirUnitAndNeverGoNegative() {
        #expect(Fmt.rateText(512) == "512 B/s")
        #expect(Fmt.rateText(285_000) == "285 kB/s")
        #expect(Fmt.rateText(1_200_000) == "1.2 MB/s")
        #expect(Fmt.rateText(3_450_000_000) == "3.45 GB/s")
        #expect(Fmt.rateText(-20) == "0 B/s")
    }

    @Test func durations() {
        #expect(Fmt.minutes(192) == "3h 12m")
        #expect(Fmt.minutes(45) == "45m")
        #expect(Fmt.cpuTime(3_725) == "1h 2m")
        #expect(Fmt.cpuTime(75) == "1m 15s")
        #expect(Fmt.cpuTime(9.9) == "9s")
    }

    @Test(arguments: [(0.0, 100_000.0), (100_000, 100_000), (100_001, 1_000_000), (85_000_000, 100_000_000), (1e13, 1e11)])
    func rateScaleIsTheSmallestDecadeThatFits(peak: Double, scale: Double) {
        #expect(Fmt.rateScale(peak) == scale)
    }

    @Test func cBufferStopsAtTheTerminator() {
        let buffer: [CChar] = [0x6E, 0x6F, 0x64, 0x65, 0, 0x78, 0x78]
        #expect(String(cBuffer: buffer) == "node")
        #expect(String(cBuffer: [0]) == "")
    }
}
