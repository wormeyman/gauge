import Foundation
import Testing
import GaugeKit
@testable import Gauge

@Suite struct LocalAPITests {
    @MainActor @Test func vitalsCarryRawValuesAndSayWhatsUnavailable() {
        var r = Reading()
        r.cpuUser = 12.34
        r.cpuSystem = 5.01
        r.memory = MemoryReading(total: 16e9, app: 6e9, wired: 2e9, compressed: 1e9, pressure: 2)
        r.disk = DiskReading(total: 1_000e9, available: 400e9)
        let v = LocalAPI.vitals(r, cores: 10, chip: "Apple M4")
        #expect(v.cpu.percent == 17.4)
        #expect(v.memory.usedBytes == 9e9)
        #expect(v.memory.pressure == "elevated")
        #expect(v.disk.usedBytes == 600e9)
        #expect(v.gpu.percent == nil)
        #expect(v.battery == nil)
        #expect(v.unavailable.contains { $0.hasPrefix("GPU") })
        #expect(v.unavailable.contains { $0.hasPrefix("Temperatures") })
    }

    @Test func historyMetricsMapToColumns() {
        let p = HistoryPoint(date: Date(), cpu: 1, memoryUsed: 2, memoryTotal: 3, gpu: 4, download: 5, upload: 6, diskRead: 7, diskWrite: 8, battery: nil)
        #expect(API.historyMetrics.map { LocalAPI.value($0.name, p) } == [1, 2, 4, 5, 6, 7, 8, nil])
    }

    /// Listens on a loopback port from this test process, then asks who holds it.
    @Test func portCheckFindsTheListener() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET),
                                  sin_port: 0, sin_addr: in_addr(s_addr: INADDR_LOOPBACK.bigEndian), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        try #require(bound == 0 && listen(fd, 1) == 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        let port = Int(UInt16(bigEndian: address.sin_port))

        let status = PortScan.status(port)
        #expect(!status.free)
        #expect(status.holder?.pid == Int(getpid()))
        #expect(!PortScan.canBind(port))
    }
}
