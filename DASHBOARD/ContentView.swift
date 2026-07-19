import SwiftUI
import Charts

struct ContentView: View {
    var body: some View {
        TabView {
            ApplicationsView()
                .tabItem { Label("Apps", systemImage: "square.grid.2x2") }
            FileBrowserView()
                .tabItem { Label("Files", systemImage: "folder") }
            SystemDashboardView()
                .tabItem { Label("System", systemImage: "gauge.high") }
            ControlCenterView()
                .tabItem { Label("Control", systemImage: "switch.2") }
            ProcessesView()
                .tabItem { Label("Processes", systemImage: "cpu") }
            QuickTerminalView()
                .tabItem { Label("Terminal", systemImage: "terminal.fill") }
            NetworkConnectionsView()
                .tabItem { Label("Network", systemImage: "network") }
        }
    }
}

// MARK: - Sparkline Chart

struct SparklineChart: View {
    let data: [Double]
    var color: Color = .blue
    var maxValue: Double = 1.0

    private var chartData: [(index: Int, value: Double)] {
        data.enumerated().map { ($0.offset, $0.element) }
    }

    var body: some View {
        Chart(chartData, id: \.index) { item in
            AreaMark(x: .value("t", item.index), y: .value("v", item.value))
                .foregroundStyle(color.opacity(0.25))
            LineMark(x: .value("t", item.index), y: .value("v", item.value))
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
        }
        .chartYScale(domain: 0...max(maxValue, 0.001))
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: 48)
    }
}

// MARK: - System Dashboard

struct SystemDashboardView: View {
    @StateObject private var monitor = SystemMonitor()
    @ObservedObject private var control = SystemControl.shared

    var body: some View {
        List {
            Section(header: Text("Quick Actions")) {
                HStack(spacing: 12) {
                    Button { control.sleepMac() } label: { Label("Sleep", systemImage: "moon.fill") }
                    Button { control.lockScreen() } label: { Label("Lock", systemImage: "lock.fill") }
                    Button { control.screenshotFullScreen() } label: { Label("Screenshot", systemImage: "camera.viewfinder") }
                    Button { control.openActivityMonitor() } label: { Label("Activity Monitor", systemImage: "waveform.path.ecg") }
                    Button { control.purgeMemory() } label: { Label("Purge Memory", systemImage: "memorychip") }
                }
                .buttonStyle(.bordered)
            }
            Section(header: Text("CPU")) {
                ProgressView(value: monitor.cpuUsage, total: 1.0) { Text("CPU Usage") }
                HStack {
                    Text(String(format: "%.0f%%", monitor.cpuUsage * 100))
                    Spacer()
                    Text("\(monitor.cpuCoreCount) cores")
                        .foregroundColor(.secondary)
                }
                SparklineChart(data: monitor.cpuHistory, color: .blue)
                Text(String(format: "Load: %.2f  %.2f  %.2f (1/5/15 min)", monitor.loadAverage.one, monitor.loadAverage.five, monitor.loadAverage.fifteen))
                    .foregroundColor(.secondary)
                Label(thermalDescription, systemImage: "thermometer.medium")
                    .foregroundColor(thermalColor)
            }
            Section(header: Text("Memory")) {
                let usedGB = monitor.memoryUsed / 1024
                let totalGB = monitor.memoryTotal / 1024
                ProgressView(value: monitor.memoryUsed, total: monitor.memoryTotal) { Text("Memory Used") }
                Text(String(format: "%.2f / %.2f GB", usedGB, totalGB))
                SparklineChart(data: monitor.memHistory, color: .green)
                Text("Swap Used: \(formatBytes(Double(monitor.swapUsedBytes)))")
                    .foregroundColor(.secondary)
            }
            Section(header: Text("Disk")) {
                if monitor.diskTotal > 0 {
                    ProgressView(value: monitor.diskUsed, total: monitor.diskTotal) { Text("Startup Disk") }
                    Text("\(formatBytes(monitor.diskUsed)) used of \(formatBytes(monitor.diskTotal))")
                } else {
                    Text("Disk info unavailable")
                }
                Button { control.openDiskUtility() } label: { Label("Open Disk Utility", systemImage: "internaldrive") }
                    .buttonStyle(.link)
            }
            Section(header: Text("GPU")) {
                if let gpu = monitor.gpuUsage {
                    ProgressView(value: gpu, total: 1.0) { Text("GPU Usage") }
                    Text(String(format: "%.0f%%", gpu * 100))
                    SparklineChart(data: monitor.gpuHistory, color: .purple)
                } else {
                    Text("GPU usage unavailable")
                }
                if monitor.vramTotalBytes > 0 {
                    Text("VRAM: \(formatBytes(Double(monitor.vramTotalBytes)))")
                }
            }
            Section(header: Text("Battery")) {
                if let batt = monitor.batteryLevel {
                    ProgressView(value: batt, total: 1.0) { Text("Battery") }
                    HStack {
                        Text(String(format: "%.0f%%", batt * 100))
                        if let charging = monitor.isCharging {
                            Label(charging ? "Charging" : "On Battery", systemImage: charging ? "bolt.fill" : "battery.75")
                                .foregroundColor(charging ? .green : .secondary)
                        }
                    }
                    Button { control.openSettingsPane(.battery) } label: { Label("Battery Settings", systemImage: "gear") }
                        .buttonStyle(.link)
                } else {
                    Text("Battery info unavailable")
                }
                if let health = batteryHealth {
                    Label("Battery Health: \(health)", systemImage: "heart")
                }
            }
            Section(header: Text("Network")) {
                HStack {
                    VStack(alignment: .leading) {
                        Text(String(format: "▼ %.1f KB/s", monitor.networkIn))
                        Text(String(format: "▲ %.1f KB/s", monitor.networkOut))
                    }
                    Spacer()
                    VStack(alignment: .leading) {
                        Text("Local IP: \(control.localIP)")
                        Text("Wi-Fi: \(control.wifiSSID)")
                    }
                }
                SparklineChart(data: monitor.netInHistory, color: .cyan, maxValue: max(monitor.netInHistory.max() ?? 1, 1))
                Button { control.flushDNSCache() } label: { Label("Flush DNS Cache", systemImage: "arrow.triangle.2.circlepath") }
                    .buttonStyle(.link)
            }
            Section(header: Text("System Info")) {
                Label("Uptime: \(formatUptime(monitor.uptime))", systemImage: "clock")
                Label("Processes: \(monitor.processCount)", systemImage: "cpu")
                Label("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)", systemImage: "applelogo")
                Label("Host: \(Host.current().localizedName ?? "Unknown")", systemImage: "desktopcomputer")
            }
        }
        .navigationTitle("System")
        .onAppear {
            control.refreshStates()
            control.batteryHealth { batteryHealth = $0 }
        }
    }

    @State private var batteryHealth: String?

    private var thermalDescription: String {
        switch monitor.thermalState {
        case .nominal: return "Thermal State: Nominal"
        case .fair: return "Thermal State: Fair"
        case .serious: return "Thermal State: Serious"
        case .critical: return "Thermal State: Critical"
        @unknown default: return "Thermal State: Unknown"
        }
    }

    private var thermalColor: Color {
        switch monitor.thermalState {
        case .nominal: return .green
        case .fair: return .yellow
        case .serious: return .orange
        case .critical: return .red
        @unknown default: return .secondary
        }
    }

    private func formatBytes(_ bytes: Double) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    private func formatUptime(_ interval: TimeInterval) -> String {
        let days = Int(interval) / 86_400
        let hours = (Int(interval) % 86_400) / 3_600
        let minutes = (Int(interval) % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h \(minutes)m" }
        return "\(hours)h \(minutes)m"
    }
}

#Preview {
    ContentView()
}
