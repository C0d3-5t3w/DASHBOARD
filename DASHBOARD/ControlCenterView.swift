import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// A macOS "Control Center" style tab with categorized quick actions.
struct ControlCenterView: View {
    @ObservedObject private var control = SystemControl.shared
    @State private var volume: Double = 50
    @State private var publicIP: String = "…"
    @State private var showRestartConfirm = false
    @State private var showShutdownConfirm = false
    @State private var showEmptyTrashConfirm = false
    @State private var clipboardText: String = ""
    @State private var loginItems: [SystemControl.LoginItem] = []
    @State private var wifiNetworks: [String] = []
    @State private var isScanning = false

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                statusBar

                sectionHeader("Power", systemImage: "power")
                LazyVGrid(columns: columns, spacing: 12) {
                    ControlButton(title: "Sleep", systemImage: "moon.fill", tint: .indigo) { control.sleepMac() }
                    ControlButton(title: "Sleep Display", systemImage: "display", tint: .indigo) { control.sleepDisplay() }
                    ControlButton(title: "Lock Screen", systemImage: "lock.fill", tint: .blue) { control.lockScreen() }
                    ControlButton(title: "Screen Saver", systemImage: "sparkles.tv", tint: .cyan) { control.startScreenSaver() }
                    ControlButton(title: "Restart", systemImage: "arrow.clockwise.circle.fill", tint: .orange) { showRestartConfirm = true }
                    ControlButton(title: "Shut Down", systemImage: "power.circle.fill", tint: .red) { showShutdownConfirm = true }
                    ControlButton(title: "Log Out", systemImage: "rectangle.portrait.and.arrow.right", tint: .orange) { control.logOut() }
                    ControlToggleButton(title: "Keep Awake", systemImage: "cup.and.saucer.fill", isOn: control.isCaffeinated, tint: .brown) { control.toggleCaffeinate() }
                }

                sectionHeader("Appearance & Display", systemImage: "paintbrush")
                LazyVGrid(columns: columns, spacing: 12) {
                    ControlToggleButton(title: "Dark Mode", systemImage: "moon.circle.fill", isOn: control.isDarkMode, tint: .purple) { control.toggleDarkMode() }
                    ControlButton(title: "Set Wallpaper…", systemImage: "photo.fill", tint: .pink) { pickWallpaper() }
                    ControlButton(title: "Night Shift", systemImage: "sun.haze.fill", tint: .orange) { control.toggleNightShift() }
                    ControlButton(title: "Display Settings", systemImage: "display", tint: .gray) { control.openSettingsPane(.displays) }
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: "sun.min.fill")
                        Slider(value: Binding(
                            get: { control.brightness },
                            set: { control.setBrightness($0) }
                        ), in: 0...1, step: 0.01)
                        Image(systemName: "sun.max.fill")
                        Text("\(Int(control.brightness * 100))%")
                            .font(.body.monospacedDigit())
                            .frame(width: 44, alignment: .trailing)
                    }
                    Text("Brightness")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(NSColor.controlBackgroundColor)))

                sectionHeader("Sound", systemImage: "speaker.wave.2")
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "speaker.fill")
                        Slider(value: $volume, in: 0...100, step: 1) { editing in
                            if !editing { control.setVolume(Int(volume)) }
                        }
                        Image(systemName: "speaker.wave.3.fill")
                        Text("\(Int(volume))%")
                            .font(.body.monospacedDigit())
                            .frame(width: 44, alignment: .trailing)
                    }
                    HStack {
                        Button { control.toggleMute() } label: { Label("Mute", systemImage: "speaker.slash.fill") }
                        Button { control.mediaPlayPause() } label: { Label("Play / Pause", systemImage: "playpause.fill") }
                        Button { control.openSettingsPane(.sound) } label: { Label("Sound Settings", systemImage: "gear") }
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(NSColor.controlBackgroundColor)))

                sectionHeader("Network", systemImage: "network")
                LazyVGrid(columns: columns, spacing: 12) {
                    ControlToggleButton(title: "Wi-Fi", systemImage: "wifi", isOn: control.isWiFiEnabled, tint: .blue) { control.toggleWiFi() }
                    ControlToggleButton(title: "Bluetooth", systemImage: "antenna.radiowaves.left.and.right", isOn: control.isBluetoothEnabled, tint: .blue) { control.toggleBluetooth() }
                    ControlButton(title: "Flush DNS", systemImage: "arrow.triangle.2.circlepath", tint: .teal) { control.flushDNSCache() }
                    ControlButton(title: "Renew DHCP", systemImage: "arrow.clockwise", tint: .teal) { control.renewDHCPLease() }
                    ControlButton(title: "Network Settings", systemImage: "gear", tint: .gray) { control.openSettingsPane(.network) }
                }
                HStack(spacing: 24) {
                    Label("Local IP: \(control.localIP)", systemImage: "desktopcomputer")
                    Label("Wi-Fi: \(control.wifiSSID)", systemImage: "wifi")
                    Label("Public IP: \(publicIP)", systemImage: "globe")
                    Button("Refresh") {
                        control.refreshStates()
                        refreshIPs()
                    }
                    .buttonStyle(.link)
                }
                .font(.callout)
                .foregroundColor(.secondary)

                // Wi-Fi Scanner
                sectionHeader("Wi-Fi Scanner", systemImage: "wifi.circle")
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button {
                            isScanning = true
                            wifiNetworks = []
                            control.scanWiFiNetworks { networks in
                                wifiNetworks = networks
                                isScanning = false
                            }
                        } label: {
                            Label("Scan for Networks", systemImage: "magnifyingglass")
                        }
                        if isScanning { ProgressView().scaleEffect(0.7) }
                    }
                    if !wifiNetworks.isEmpty {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8)], spacing: 8) {
                            ForEach(wifiNetworks, id: \.self) { ssid in
                                HStack {
                                    Image(systemName: "wifi")
                                        .foregroundColor(.blue)
                                    Text(ssid)
                                        .lineLimit(1)
                                    Spacer()
                                }
                                .padding(8)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.controlBackgroundColor)))
                            }
                        }
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(NSColor.controlBackgroundColor)))

                sectionHeader("Finder & Files", systemImage: "folder")
                LazyVGrid(columns: columns, spacing: 12) {
                    ControlToggleButton(title: "Hidden Files", systemImage: "eye.fill", isOn: control.hiddenFilesShown, tint: .cyan) { control.toggleHiddenFiles() }
                    ControlToggleButton(title: "Hide Desktop Icons", systemImage: "menubar.dock.rectangle", isOn: control.desktopIconsHidden, tint: .cyan) { control.toggleDesktopIcons() }
                    ControlButton(title: "Eject All Disks", systemImage: "eject.fill", tint: .purple) { control.ejectAllDisks() }
                    ControlButton(title: "Empty Trash", systemImage: "trash.fill", tint: .red) { showEmptyTrashConfirm = true }
                    ControlButton(title: "Relaunch Finder", systemImage: "arrow.counterclockwise", tint: .blue) { control.relaunchFinder() }
                    ControlButton(title: "Relaunch Dock", systemImage: "dock.rectangle", tint: .blue) { control.relaunchDock() }
                    ControlButton(title: "Relaunch Menu Bar", systemImage: "menubar.rectangle", tint: .blue) { control.relaunchMenuBar() }
                }

                sectionHeader("Capture", systemImage: "camera")
                LazyVGrid(columns: columns, spacing: 12) {
                    ControlButton(title: "Screenshot", systemImage: "camera.viewfinder", tint: .green) { control.screenshotFullScreen() }
                    ControlButton(title: "Capture Selection", systemImage: "rectangle.dashed", tint: .green) { control.screenshotSelection() }
                    ControlButton(title: "Copy to Clipboard", systemImage: "doc.on.clipboard", tint: .green) { control.screenshotToClipboard() }
                    ControlButton(title: "Screen Recording", systemImage: "record.circle", tint: .red) { control.openScreenCaptureToolbar() }
                }

                sectionHeader("Clipboard", systemImage: "doc.on.clipboard")
                VStack(alignment: .leading, spacing: 8) {
                    Text(clipboardText.isEmpty ? "Press Refresh to preview clipboard contents." : clipboardText)
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .lineLimit(3)
                    HStack {
                        Button { clipboardText = control.clipboardPreview() } label: { Label("Refresh Preview", systemImage: "arrow.clockwise") }
                        Button { control.stripClipboardFormatting(); clipboardText = control.clipboardPreview() } label: { Label("Strip Formatting", systemImage: "textformat") }
                        Button { control.clearClipboard(); clipboardText = "" } label: { Label("Clear", systemImage: "xmark.circle") }
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(NSColor.controlBackgroundColor)))

                sectionHeader("Login Items", systemImage: "person.badge.clock")
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button {
                            control.getLoginItems { items in loginItems = items }
                        } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        Button {
                            let panel = NSOpenPanel()
                            panel.allowedContentTypes = [.application]
                            panel.message = "Choose app to add to Login Items"
                            if panel.runModal() == .OK, let url = panel.url {
                                control.addLoginItem(url: url)
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                    control.getLoginItems { items in loginItems = items }
                                }
                            }
                        } label: { Label("Add App…", systemImage: "plus") }
                    }
                    if loginItems.isEmpty {
                        Text("No login items found. Tap Refresh to load.")
                            .font(.callout)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(loginItems) { item in
                            HStack {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: item.path))
                                    .resizable().frame(width: 20, height: 20)
                                Text(item.name)
                                    .font(.callout)
                                if item.isHidden {
                                    Text("Hidden").font(.caption).foregroundColor(.secondary)
                                }
                                Spacer()
                                Button(role: .destructive) {
                                    control.removeLoginItem(name: item.name)
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                        control.getLoginItems { items in loginItems = items }
                                    }
                                } label: {
                                    Image(systemName: "minus.circle").foregroundColor(.red)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(NSColor.controlBackgroundColor)))

                sectionHeader("Maintenance", systemImage: "wrench.and.screwdriver")
                LazyVGrid(columns: columns, spacing: 12) {
                    ControlButton(title: "Clear Caches", systemImage: "trash.slash.fill", tint: .orange) { control.clearUserCaches() }
                    ControlButton(title: "Purge Memory", systemImage: "memorychip", tint: .orange) { control.purgeMemory() }
                    ControlButton(title: "Reindex Spotlight", systemImage: "magnifyingglass.circle.fill", tint: .yellow) { control.rebuildSpotlightIndex() }
                    ControlButton(title: "Backup Now", systemImage: "clock.arrow.circlepath", tint: .teal) { control.startTimeMachineBackup() }
                    ControlButton(title: "Verify Disk", systemImage: "checkmark.shield", tint: .green) { control.verifyStartupDisk() }
                    ControlButton(title: "Check Updates", systemImage: "arrow.down.circle.fill", tint: .blue) { control.checkForSoftwareUpdates() }
                    ControlToggleButton(title: "Focus / DND", systemImage: "moon.zzz.fill", isOn: control.isDoNotDisturbEnabled, tint: .purple) { control.toggleDoNotDisturb() }
                }

                sectionHeader("System Settings", systemImage: "gearshape")
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(SystemControl.SettingsPane.allCases) { pane in
                        ControlButton(title: pane.title, systemImage: pane.systemImage, tint: .gray) {
                            control.openSettingsPane(pane)
                        }
                    }
                }

                sectionHeader("Utilities", systemImage: "hammer")
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(SystemControl.UtilityApp.allCases.filter(\.exists)) { app in
                        ControlButton(title: app.title, systemImage: app.systemImage, tint: .green) {
                            control.openUtility(app)
                        }
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("Control Center")
        .onAppear {
            DispatchQueue.global(qos: .userInitiated).async {
                let vol = control.getVolume()
                DispatchQueue.main.async { volume = Double(vol) }
            }
            control.refreshStates()
            control.refreshBrightness()
            refreshIPs()
            clipboardText = control.clipboardPreview()
            control.getLoginItems { items in loginItems = items }
        }
        .confirmationDialog("Restart your Mac?", isPresented: $showRestartConfirm) {
            Button("Restart", role: .destructive) { control.restartMac() }
        }
        .confirmationDialog("Shut down your Mac?", isPresented: $showShutdownConfirm) {
            Button("Shut Down", role: .destructive) { control.shutDownMac() }
        }
        .confirmationDialog("Empty the Trash? This cannot be undone.", isPresented: $showEmptyTrashConfirm) {
            Button("Empty Trash", role: .destructive) { control.emptyTrash() }
        }
    }

    private var statusBar: some View {
        HStack {
            Image(systemName: "info.circle")
            Text(control.lastActionMessage.isEmpty ? "Ready." : control.lastActionMessage)
                .lineLimit(2)
            Spacer()
        }
        .font(.callout)
        .foregroundColor(.secondary)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.controlBackgroundColor)))
    }

    private func sectionHeader(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.title3.bold())
            .padding(.top, 4)
    }

    private func refreshIPs() {
        publicIP = "…"
        control.publicIPAddress { publicIP = $0 }
    }

    private func pickWallpaper() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a wallpaper image"
        if panel.runModal() == .OK, let url = panel.url {
            control.setWallpaper(url: url)
        }
    }
}

// MARK: - Reusable Buttons

struct ControlButton: View {
    let title: String
    let systemImage: String
    var tint: Color = .accentColor
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(tint)
                    .frame(width: 26)
                Text(title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(NSColor.controlBackgroundColor)))
        }
        .buttonStyle(.plain)
        .help(title)
    }
}

struct ControlToggleButton: View {
    let title: String
    let systemImage: String
    let isOn: Bool
    var tint: Color = .accentColor
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(isOn ? .white : tint)
                    .frame(width: 26)
                Text(title)
                    .font(.callout.weight(.medium))
                    .foregroundColor(isOn ? .white : .primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Circle()
                    .fill(isOn ? Color.white : Color.secondary.opacity(0.4))
                    .frame(width: 8, height: 8)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isOn ? tint : Color(NSColor.controlBackgroundColor))
            )
        }
        .buttonStyle(.plain)
        .help("\(title): \(isOn ? "On" : "Off")")
    }
}

#Preview {
    ControlCenterView()
        .frame(width: 800, height: 900)
}
