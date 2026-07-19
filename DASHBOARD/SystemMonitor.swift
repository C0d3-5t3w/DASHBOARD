import Foundation
import SwiftUI
import Combine
import Darwin
import IOKit
import IOKit.pwr_mgt
import IOKit.graphics
import IOKit.ps

final class SystemMonitor: ObservableObject {
    @Published var cpuUsage: Double = 0
    @Published var memoryUsed: Double = 0
    @Published var memoryTotal: Double = 0
    @Published var batteryLevel: Double? = nil
    @Published var networkIn: Double = 0
    @Published var networkOut: Double = 0
    @Published var vramTotalBytes: UInt64 = 0
    @Published var gpuUsage: Double? = nil
    @Published var diskUsed: Double = 0     // bytes
    @Published var diskTotal: Double = 0    // bytes
    @Published var uptime: TimeInterval = 0
    @Published var processCount: Int = 0
    @Published var thermalState: ProcessInfo.ThermalState = .nominal
    @Published var isCharging: Bool? = nil
    @Published var swapUsedBytes: UInt64 = 0
    @Published var loadAverage: (one: Double, five: Double, fifteen: Double) = (0, 0, 0)

    // Rolling 60-second histories for sparkline charts
    @Published var cpuHistory: [Double]    = Array(repeating: 0, count: 60)
    @Published var memHistory: [Double]    = Array(repeating: 0, count: 60)
    @Published var netInHistory: [Double]  = Array(repeating: 0, count: 60)
    @Published var netOutHistory: [Double] = Array(repeating: 0, count: 60)
    @Published var gpuHistory: [Double]    = Array(repeating: 0, count: 60)

    let cpuCoreCount: Int = ProcessInfo.processInfo.activeProcessorCount

    private var cancellable: AnyCancellable?
    private var lastBytesIn: UInt64 = 0
    private var lastBytesOut: UInt64 = 0
    private var lastSampleDate: Date?
    private var lastVRAMUpdateDate: Date?
    private var lastCPUTicks: (user: Double, system: Double, idle: Double, nice: Double)?
    /// `mach_host_self()` allocates a new send-right on every call; cache it once
    /// to avoid leaking a Mach port twice per second.
    private let hostPort: host_t = mach_host_self()

    init() {
        memoryTotal = Double(ProcessInfo.processInfo.physicalMemory) / (1024 * 1024) // in MB
        let (initialIn, initialOut) = readInterfaceBytes()
        lastBytesIn = initialIn
        lastBytesOut = initialOut
        lastSampleDate = Date()
        lastVRAMUpdateDate = nil

        cancellable = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                Task { @MainActor in
                    await self?.updateStats()
                }
            }
    }

    deinit {
        cancellable?.cancel()
        mach_port_deallocate(mach_task_self_, hostPort)
    }

    @MainActor
    private func updateStats() async {
        cpuUsage = fetchCPUUsage()
        (memoryUsed, memoryTotal) = fetchMemoryUsage()
        #if os(macOS)
        batteryLevel = fetchBatteryLevel()
        #else
        batteryLevel = nil
        #endif
        updateNetworkUsage()
        // Throttle VRAM update to once every 5 seconds
        let now = Date()
        if lastVRAMUpdateDate == nil || now.timeIntervalSince(lastVRAMUpdateDate!) > 5 {
            let vram = fetchVRAMTotalBytes()
            vramTotalBytes = vram
            lastVRAMUpdateDate = now
            (diskUsed, diskTotal) = fetchDiskUsage()
        }
        gpuUsage = fetchGPUUsage()
        uptime = ProcessInfo.processInfo.systemUptime
        thermalState = ProcessInfo.processInfo.thermalState
        processCount = fetchProcessCount()
        swapUsedBytes = fetchSwapUsedBytes()
        loadAverage = fetchLoadAverage()
        #if os(macOS)
        isCharging = fetchIsCharging()
        #endif

        // Update rolling histories
        appendHistory(&cpuHistory, cpuUsage)
        let memRatio = memoryTotal > 0 ? memoryUsed / memoryTotal : 0
        appendHistory(&memHistory, memRatio)
        appendHistory(&netInHistory, networkIn)
        appendHistory(&netOutHistory, networkOut)
        appendHistory(&gpuHistory, gpuUsage ?? 0)
    }

    private func appendHistory(_ history: inout [Double], _ value: Double) {
        history.append(value)
        if history.count > 60 { history.removeFirst() }
    }

    private func fetchSwapUsedBytes() -> UInt64 {
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 else { return 0 }
        return swap.xsu_used
    }

    private func fetchLoadAverage() -> (Double, Double, Double) {
        var loads = [Double](repeating: 0, count: 3)
        guard getloadavg(&loads, 3) == 3 else { return (0, 0, 0) }
        return (loads[0], loads[1], loads[2])
    }

    private func fetchDiskUsage() -> (used: Double, total: Double) {
        let url = URL(fileURLWithPath: "/")
        do {
            let values = try url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
            let total = Double(values.volumeTotalCapacity ?? 0)
            let available = Double(values.volumeAvailableCapacityForImportantUsage ?? 0)
            return (max(0, total - available), total)
        } catch {
            return (0, 0)
        }
    }

    private func fetchProcessCount() -> Int {
        var size: size_t = 0
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return 0 }
        return size / MemoryLayout<kinfo_proc>.stride
    }

    #if os(macOS)
    private func fetchIsCharging() -> Bool? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return nil
        }
        for ps in sources {
            if let description = IOPSGetPowerSourceDescription(snapshot, ps)?.takeUnretainedValue() as? [String: Any],
               let charging = description[kIOPSIsChargingKey as String] as? Bool {
                return charging
            }
        }
        return nil
    }
    #endif

    private func fetchCPUUsage() -> Double {
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        var cpuInfo = host_cpu_load_info()
        let result = withUnsafeMutablePointer(to: &cpuInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(hostPort, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return 0
        }
        let user = Double(cpuInfo.cpu_ticks.0)
        let system = Double(cpuInfo.cpu_ticks.1)
        let idle = Double(cpuInfo.cpu_ticks.2)
        let nice = Double(cpuInfo.cpu_ticks.3)

        defer { lastCPUTicks = (user, system, idle, nice) }

        // Use the delta between samples so the meter reflects current load,
        // not the average since boot.
        guard let last = lastCPUTicks else {
            return 0
        }
        let deltaUser = user - last.user
        let deltaSystem = system - last.system
        let deltaIdle = idle - last.idle
        let deltaNice = nice - last.nice
        let deltaTotal = deltaUser + deltaSystem + deltaIdle + deltaNice
        guard deltaTotal > 0 else {
            return cpuUsage // no new ticks; keep previous reading
        }
        let usage = (deltaUser + deltaSystem + deltaNice) / deltaTotal
        return max(0, min(1, usage))
    }

    private func fetchMemoryUsage() -> (usedMB: Double, totalMB: Double) {
        var vmStats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &vmStats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(hostPort, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return (0, Double(ProcessInfo.processInfo.physicalMemory) / (1024 * 1024))
        }

        let pageSize = Double(vm_kernel_page_size)
        // Match Activity Monitor's "Memory Used": app memory (anonymous - purgeable)
        // + wired + compressed. Inactive/file-backed pages are cache, not "used".
        let anonymous = Double(vmStats.internal_page_count) * pageSize
        let purgeable = Double(vmStats.purgeable_count) * pageSize
        let wired = Double(vmStats.wire_count) * pageSize
        let compressed = Double(vmStats.compressor_page_count) * pageSize
        let used = max(0, anonymous - purgeable) + wired + compressed
        let usedMB = used / (1024 * 1024)
        let totalMB = Double(ProcessInfo.processInfo.physicalMemory) / (1024 * 1024)
        return (usedMB, totalMB)
    }

    #if os(macOS)
    private func fetchBatteryLevel() -> Double? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return nil
        }
        guard let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef], !sources.isEmpty else {
            return nil
        }
        for ps in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, ps)?.takeUnretainedValue() as? [String: Any] else {
                continue
            }
            if let currentCapacity = description[kIOPSCurrentCapacityKey as String] as? Int,
               let maxCapacity = description[kIOPSMaxCapacityKey as String] as? Int,
               maxCapacity > 0 {
                return Double(currentCapacity) / Double(maxCapacity)
            }
        }
        return nil
    }
    #endif

    private func updateNetworkUsage() {
        let now = Date()
        let (currentIn, currentOut) = readInterfaceBytes()

        guard let lastDate = lastSampleDate else {
            lastBytesIn = currentIn
            lastBytesOut = currentOut
            lastSampleDate = now
            return
        }

        let dt = now.timeIntervalSince(lastDate)
        guard dt > 0 else {
            return
        }

        let deltaIn = currentIn > lastBytesIn ? currentIn - lastBytesIn : 0
        let deltaOut = currentOut > lastBytesOut ? currentOut - lastBytesOut : 0

        networkIn = Double(deltaIn) / dt / 1024.0
        networkOut = Double(deltaOut) / dt / 1024.0

        lastBytesIn = currentIn
        lastBytesOut = currentOut
        lastSampleDate = now
    }

    private func readInterfaceBytes() -> (in: UInt64, out: UInt64) {
        var addrsPointer: UnsafeMutablePointer<ifaddrs>? = nil
        var totalIn: UInt64 = 0
        var totalOut: UInt64 = 0

        guard getifaddrs(&addrsPointer) == 0, let firstAddr = addrsPointer else {
            return (totalIn, totalOut)
        }
        defer { freeifaddrs(addrsPointer) }

        // Iterate the full linked list safely (no force-unwraps, includes the last node).
        var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let addr = ptr {
            defer { ptr = addr.pointee.ifa_next }
            let flags = addr.pointee.ifa_flags
            let name = String(cString: addr.pointee.ifa_name)
            // Skip loopback and down interfaces
            guard !name.hasPrefix("lo"), (flags & UInt32(IFF_UP)) != 0 else { continue }
            if let ifaData = addr.pointee.ifa_data {
                let data = ifaData.assumingMemoryBound(to: if_data.self).pointee
                totalIn += UInt64(data.ifi_ibytes)
                totalOut += UInt64(data.ifi_obytes)
            }
        }
        return (totalIn, totalOut)
    }

    /// Reads GPU utilization from IOAccelerator "PerformanceStatistics".
    /// Works for Apple Silicon (AGXAccelerator) and Intel/AMD GPUs.
    private func fetchGPUUsage() -> Double? {
        let match = IOServiceMatching("IOAccelerator")
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, match, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var best: Double? = nil
        var service: io_object_t = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            guard let props = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any] else {
                continue
            }
            let keys = ["Device Utilization %", "GPU Activity(%)", "GPU Core Utilization"]
            for key in keys {
                if let value = props[key] as? NSNumber {
                    var pct = value.doubleValue
                    // "GPU Core Utilization" is reported scaled by 10^7 on some systems
                    if pct > 100 { pct /= 10_000_000 }
                    let normalized = max(0, min(1, pct / 100))
                    best = max(best ?? 0, normalized)
                    break
                }
            }
        }
        return best
    }

    private func fetchVRAMTotalBytes() -> UInt64 {
        var total: UInt64 = 0
        let match = IOServiceMatching("IOPCIDevice")
        var iterator: io_iterator_t = 0
        if IOServiceGetMatchingServices(kIOMainPortDefault, match, &iterator) == KERN_SUCCESS {
            var service: io_object_t = IOIteratorNext(iterator)
            while service != 0 {
                if let cfName = IORegistryEntryCreateCFProperty(service, "model" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data,
                   let name = String(data: cfName, encoding: .ascii)?.lowercased(),
                   name.contains("gpu") || name.contains("graphics") {
                    if let vramMB = IORegistryEntryCreateCFProperty(service, "VRAM,totalMB" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber {
                        total = max(total, vramMB.uint64Value * 1024 * 1024)
                    } else if let vramBytes = IORegistryEntryCreateCFProperty(service, "VRAM,total" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber {
                        total = max(total, vramBytes.uint64Value)
                    } else if let vramBytes2 = IORegistryEntryCreateCFProperty(service, "VRAM,totalbytes" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber {
                        total = max(total, vramBytes2.uint64Value)
                    }
                }
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            IOObjectRelease(iterator)
        }
        return total
    }
}
