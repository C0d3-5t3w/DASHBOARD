import SwiftUI
import AppKit
import Combine

enum ProcessSort: String, CaseIterable, Identifiable {
    case name = "Name"
    case cpu = "CPU"
    case memory = "Memory"
    case pid = "PID"
    var id: String { rawValue }
}

/// A running-applications manager: activate, hide, quit, or force-quit apps.
struct ProcessesView: View {
    @StateObject private var model = ProcessesModel()
    @State private var searchText = ""
    @State private var sortOrder = ProcessSort.name

    private var filtered: [ProcessesModel.RunningApp] {
        let trimmed = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        var apps = trimmed.isEmpty ? model.apps : model.apps.filter { $0.name.lowercased().contains(trimmed) }
        switch sortOrder {
        case .name:    apps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .cpu:     apps.sort { $0.cpuPercent > $1.cpuPercent }
        case .memory:  apps.sort { $0.memoryMB > $1.memoryMB }
        case .pid:     apps.sort { $0.pid < $1.pid }
        }
        return apps
    }

    var body: some View {
        NavigationView {
            List(filtered) { app in
                HStack(spacing: 12) {
                    Image(nsImage: app.icon)
                        .resizable()
                        .frame(width: 32, height: 32)
                    VStack(alignment: .leading) {
                        Text(app.name).font(.headline)
                        Text("PID \(app.pid)\(app.isHidden ? " • Hidden" : "")\(app.isActive ? " • Active" : "")")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(String(format: "%.1f%%", app.cpuPercent))
                            .font(.caption.monospacedDigit())
                            .foregroundColor(app.cpuPercent > 50 ? .red : app.cpuPercent > 20 ? .orange : .secondary)
                        Text(String(format: "%.0f MB", app.memoryMB))
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                    .frame(width: 64, alignment: .trailing)
                    Button { model.activate(app) } label: {
                        Image(systemName: "arrow.up.forward.app")
                    }
                    .help("Bring to Front")
                    Button { model.hide(app) } label: {
                        Image(systemName: app.isHidden ? "eye" : "eye.slash")
                    }
                    .help(app.isHidden ? "Unhide" : "Hide")
                    Button { model.quit(app) } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .help("Quit")
                    Button(role: .destructive) { model.forceQuit(app) } label: {
                        Image(systemName: "exclamationmark.octagon.fill")
                            .foregroundColor(.red)
                    }
                    .help("Force Quit")
                }
                .padding(.vertical, 2)
                .buttonStyle(.borderless)
                .contextMenu {
                    Button("Bring to Front") { model.activate(app) }
                    Button(app.isHidden ? "Unhide" : "Hide") { model.hide(app) }
                    Divider()
                    Button("Quit") { model.quit(app) }
                    Button("Force Quit", role: .destructive) { model.forceQuit(app) }
                    if let url = app.bundleURL {
                        Divider()
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    }
                }
            }
            .navigationTitle("Processes (\(model.apps.count))")
            .searchable(text: $searchText, placement: .toolbar)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: model.refresh) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh Process List")
                }
                ToolbarItem(placement: .primaryAction) {
                    Picker("Sort", selection: $sortOrder) {
                        ForEach(ProcessSort.allCases) { s in
                            Text(s.rawValue).tag(s)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 240)
                }
            }
        }
        .frame(minWidth: 600, minHeight: 400)
        .onAppear { model.refresh() }
    }
}

final class ProcessesModel: ObservableObject {
    struct RunningApp: Identifiable {
        let id: pid_t
        let name: String
        let pid: pid_t
        let icon: NSImage
        let bundleURL: URL?
        let isHidden: Bool
        let isActive: Bool
        let app: NSRunningApplication
        var cpuPercent: Double
        var memoryMB: Double
    }

    @Published private(set) var apps: [RunningApp] = []
    private var timer: AnyCancellable?

    init() {
        timer = Timer.publish(every: 5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        DispatchQueue.global(qos: .userInitiated).async {
            // Collect CPU and RSS from ps for all pids
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/ps")
            proc.arguments = ["-A", "-o", "pid=,pcpu=,rss="]
            let pipe = Pipe()
            proc.standardOutput = pipe
            try? proc.run(); proc.waitUntilExit()
            let psOutput = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

            var cpuMap: [pid_t: Double] = [:]
            var memMap: [pid_t: Double] = [:]
            for line in psOutput.components(separatedBy: "\n") {
                let cols = line.trimmingCharacters(in: .whitespaces)
                    .components(separatedBy: .whitespaces)
                    .filter { !$0.isEmpty }
                guard cols.count >= 3,
                      let pid = pid_t(cols[0]),
                      let cpu = Double(cols[1]),
                      let rss = Double(cols[2]) else { continue }
                cpuMap[pid] = cpu
                memMap[pid] = rss / 1024.0  // KB → MB
            }

            let running = NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .map { app -> RunningApp in
                    let pid = app.processIdentifier
                    return RunningApp(
                        id: pid,
                        name: app.localizedName ?? "Unknown",
                        pid: pid,
                        icon: app.icon ?? NSImage(),
                        bundleURL: app.bundleURL,
                        isHidden: app.isHidden,
                        isActive: app.isActive,
                        app: app,
                        cpuPercent: cpuMap[pid] ?? 0,
                        memoryMB: memMap[pid] ?? 0
                    )
                }

            DispatchQueue.main.async { self.apps = running }
        }
    }

    func activate(_ entry: RunningApp) { entry.app.activate(); refreshSoon(after: 0.3) }

    func hide(_ entry: RunningApp) {
        if entry.isHidden {
            entry.app.unhide()
        } else {
            entry.app.hide()
        }
        refreshSoon(after: 0.3)
    }

    func quit(_ entry: RunningApp) { entry.app.terminate(); refreshSoon(after: 0.5) }
    func forceQuit(_ entry: RunningApp) { entry.app.forceTerminate(); refreshSoon(after: 0.5) }

    private func refreshSoon(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.refresh() }
    }
}

#Preview {
    ProcessesView()
}
