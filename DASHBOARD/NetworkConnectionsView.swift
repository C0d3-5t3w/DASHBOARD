import SwiftUI
import AppKit

/// Displays active TCP connections, listening ports, and per-interface network stats.
struct NetworkConnectionsView: View {
    @ObservedObject private var control = SystemControl.shared
    @State private var connections: [SystemControl.NetConnection] = []
    @State private var listeningPorts: [SystemControl.NetConnection] = []
    @State private var isLoadingConnections = false
    @State private var isLoadingPorts = false
    @State private var selectedTab = 0
    @State private var connSearch = ""
    @State private var portSearch = ""
    @State private var interfaceInfo: [InterfaceInfo] = []

    struct InterfaceInfo: Identifiable {
        let id = UUID()
        let name: String
        let address: String
        let flags: String
    }

    var filteredConnections: [SystemControl.NetConnection] {
        guard !connSearch.isEmpty else { return connections }
        let q = connSearch.lowercased()
        return connections.filter {
            $0.process.lowercased().contains(q) ||
            $0.localAddress.contains(q) ||
            $0.remoteAddress.contains(q)
        }
    }

    var filteredPorts: [SystemControl.NetConnection] {
        guard !portSearch.isEmpty else { return listeningPorts }
        let q = portSearch.lowercased()
        return listeningPorts.filter {
            $0.process.lowercased().contains(q) ||
            $0.localAddress.contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar
            Picker("", selection: $selectedTab) {
                Text("Established (\(connections.count))").tag(0)
                Text("Listening (\(listeningPorts.count))").tag(1)
                Text("Interfaces").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            switch selectedTab {
            case 0:
                connectionsTab
            case 1:
                listeningTab
            default:
                interfacesTab
            }
        }
        .navigationTitle("Network")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { refresh() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh")
            }
        }
        .onAppear { refresh() }
    }

    // MARK: - Connections Tab

    @ViewBuilder
    private var connectionsTab: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("Filter by process, address…", text: $connSearch)
                    .textFieldStyle(.plain)
                if isLoadingConnections { ProgressView().scaleEffect(0.7) }
                Spacer()
                Text("\(filteredConnections.count) connections")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()

            List(filteredConnections) { conn in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(conn.process)
                                .font(.headline)
                                .lineLimit(1)
                            Text(conn.proto)
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.blue.opacity(0.15)))
                                .foregroundColor(.blue)
                        }
                        Text(conn.localAddress)
                            .font(.caption.monospaced())
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    if !conn.remoteAddress.isEmpty {
                        Image(systemName: "arrow.right")
                            .foregroundColor(.secondary)
                        Text(conn.remoteAddress)
                            .font(.caption.monospaced())
                            .foregroundColor(.primary)
                    }
                    Text(conn.state)
                        .font(.caption.bold())
                        .foregroundColor(stateColor(conn.state))
                }
                .padding(.vertical, 2)
                .contextMenu {
                    Button("Copy Remote Address") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(conn.remoteAddress, forType: .string)
                    }
                    Button("Copy Local Address") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(conn.localAddress, forType: .string)
                    }
                }
            }
        }
    }

    // MARK: - Listening Tab

    @ViewBuilder
    private var listeningTab: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("Filter by process or port…", text: $portSearch)
                    .textFieldStyle(.plain)
                if isLoadingPorts { ProgressView().scaleEffect(0.7) }
                Spacer()
                Text("\(filteredPorts.count) ports")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()

            List(filteredPorts) { port in
                HStack(spacing: 12) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .foregroundColor(.green)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(port.process)
                            .font(.headline)
                        Text(port.localAddress)
                            .font(.caption.monospaced())
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Text(port.proto)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.green.opacity(0.15)))
                        .foregroundColor(.green)
                }
                .padding(.vertical, 2)
                .contextMenu {
                    Button("Copy Port/Address") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(port.localAddress, forType: .string)
                    }
                }
            }
        }
    }

    // MARK: - Interfaces Tab

    @ViewBuilder
    private var interfacesTab: some View {
        List(interfaceInfo) { iface in
            HStack(spacing: 12) {
                Image(systemName: iface.name.hasPrefix("en") ? "wifi" : "network")
                    .foregroundColor(.blue)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(iface.name)
                        .font(.headline)
                    Text(iface.address)
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                    if !iface.flags.isEmpty {
                        Text(iface.flags)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                Button("Copy IP") {
                    let ip = iface.address.components(separatedBy: " ").first ?? iface.address
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(ip, forType: .string)
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Helpers

    private func refresh() {
        isLoadingConnections = true
        isLoadingPorts = true

        control.getEstablishedConnections { conns in
            connections = conns
            isLoadingConnections = false
        }
        control.getListeningPorts { ports in
            listeningPorts = ports
            isLoadingPorts = false
        }
        loadInterfaces()
    }

    private func loadInterfaces() {
        DispatchQueue.global(qos: .utility).async {
            var addrsPtr: UnsafeMutablePointer<ifaddrs>?
            guard getifaddrs(&addrsPtr) == 0, let first = addrsPtr else { return }
            defer { freeifaddrs(addrsPtr) }

            var result: [InterfaceInfo] = []
            var ptr: UnsafeMutablePointer<ifaddrs>? = first
            while let addr = ptr {
                defer { ptr = addr.pointee.ifa_next }
                let name = String(cString: addr.pointee.ifa_name)
                guard !name.hasPrefix("lo") else { continue }
                guard let sa = addr.pointee.ifa_addr else { continue }
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let flags = addr.pointee.ifa_flags
                guard (flags & UInt32(IFF_UP)) != 0 else { continue }
                let saLen = sa.pointee.sa_family == AF_INET ? socklen_t(MemoryLayout<sockaddr_in>.size)
                                                            : socklen_t(MemoryLayout<sockaddr_in6>.size)
                guard sa.pointee.sa_family == AF_INET || sa.pointee.sa_family == AF_INET6 else { continue }
                getnameinfo(sa, saLen, &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
                let address = String(cString: hostname)
                var flagParts: [String] = []
                if (flags & UInt32(IFF_LOOPBACK)) != 0 { flagParts.append("loopback") }
                if (flags & UInt32(IFF_BROADCAST)) != 0 { flagParts.append("broadcast") }
                if (flags & UInt32(IFF_MULTICAST)) != 0 { flagParts.append("multicast") }
                result.append(InterfaceInfo(name: name, address: address, flags: flagParts.joined(separator: ", ")))
            }

            // Deduplicate by name+address
            var seen = Set<String>()
            let deduped = result.filter { seen.insert("\($0.name)\($0.address)").inserted }

            DispatchQueue.main.async { self.interfaceInfo = deduped }
        }
    }

    private func stateColor(_ state: String) -> Color {
        switch state.uppercased() {
        case "ESTABLISHED": return .green
        case "LISTEN":      return .blue
        case "TIME_WAIT":   return .orange
        case "CLOSE_WAIT":  return .yellow
        default:            return .secondary
        }
    }
}

#Preview {
    NetworkConnectionsView()
        .frame(width: 800, height: 600)
}
