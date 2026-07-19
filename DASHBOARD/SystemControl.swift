import Foundation
import AppKit
import Combine
import IOKit.pwr_mgt

/// Central controller for macOS system actions used across the dashboard.
/// Real implementations where possible; clearly-marked placeholders otherwise.
final class SystemControl: ObservableObject {
    static let shared = SystemControl()

    @Published var lastActionMessage: String = ""
    @Published var isDarkMode: Bool = false
    @Published var isWiFiEnabled: Bool = true
    @Published var isBluetoothEnabled: Bool = true
    @Published var isDoNotDisturbEnabled: Bool = false
    @Published var hiddenFilesShown: Bool = false
    @Published var isCaffeinated: Bool = false
    @Published var desktopIconsHidden: Bool = false
    @Published var localIP: String = "…"
    @Published var wifiSSID: String = "…"
    @Published var brightness: Double = 0.5

    private var caffeinateProcess: Process?
    private var terminationObserver: NSObjectProtocol?

    private init() {
        refreshStates()
        // Make sure the caffeinate child process doesn't outlive the app.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.caffeinateProcess?.terminate()
        }
    }

    deinit {
        if let observer = terminationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        caffeinateProcess?.terminate()
    }

    // MARK: - Helpers

    @discardableResult
    private func runShell(_ command: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    @discardableResult
    private func runAppleScript(_ source: String) -> String {
        var error: NSDictionary?
        let script = NSAppleScript(source: source)
        let result = script?.executeAndReturnError(&error)
        if let error = error {
            return "AppleScript error: \(error)"
        }
        return result?.stringValue ?? ""
    }

    /// Runs a shell command with admin privileges via an osascript authentication prompt.
    /// Calls completion with the command output (or error text) on the main queue.
    private func runShellAsAdmin(_ command: String, completion: ((String) -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            let escaped = command
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            let out = self.runAppleScript("do shell script \"\(escaped)\" with administrator privileges")
            DispatchQueue.main.async { completion?(out) }
        }
    }

    private func setMessage(_ msg: String) {
        DispatchQueue.main.async { self.lastActionMessage = msg }
    }

    func refreshStates() {
        DispatchQueue.global(qos: .utility).async {
            let dark = self.runShell("defaults read -g AppleInterfaceStyle 2>/dev/null") == "Dark"
            let hidden = self.runShell("defaults read com.apple.finder AppleShowAllFiles 2>/dev/null")
            let iconsHidden = self.runShell("defaults read com.apple.finder CreateDesktop 2>/dev/null") == "0"
            let wifiDevice = self.runShell("networksetup -listallhardwareports | awk '/Wi-Fi/{getline; print $2}'")
            var wifiOn = true
            var ssid = "Not connected"
            if !wifiDevice.isEmpty {
                wifiOn = self.runShell("networksetup -getairportpower \(wifiDevice)").hasSuffix("On")
                let network = self.runShell("networksetup -getairportnetwork \(wifiDevice) 2>/dev/null")
                if let range = network.range(of: "Current Wi-Fi Network: ") {
                    ssid = String(network[range.upperBound...])
                }
            }
            let ip = self.runShell("ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null")
            DispatchQueue.main.async {
                self.isDarkMode = dark
                self.hiddenFilesShown = (hidden == "1" || hidden.lowercased() == "true")
                self.desktopIconsHidden = iconsHidden
                self.isWiFiEnabled = wifiOn
                self.wifiSSID = ssid
                self.localIP = ip.isEmpty ? "Unavailable" : ip
            }
        }
    }

    // MARK: - Power

    func sleepMac() {
        runShell("pmset sleepnow")
        setMessage("Putting Mac to sleep…")
    }

    func sleepDisplay() {
        runShell("pmset displaysleepnow")
        setMessage("Display sleeping…")
    }

    func lockScreen() {
        // Call the real system lock via login.framework (no Accessibility permission needed).
        let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/login", RTLD_NOW)
        if let handle = handle, let sym = dlsym(handle, "SACLockScreenImmediate") {
            typealias LockFunc = @convention(c) () -> Void
            let lock = unsafeBitCast(sym, to: LockFunc.self)
            lock()
            dlclose(handle)
            setMessage("Screen locked.")
        } else {
            // Fallback: sleep the display (locks if "require password immediately" is set).
            runShell("pmset displaysleepnow")
            setMessage("Display slept (screen locks if password is required immediately).")
        }
    }

    func restartMac() {
        runAppleScript("tell application \"System Events\" to restart")
        setMessage("Restarting…")
    }

    func shutDownMac() {
        runAppleScript("tell application \"System Events\" to shut down")
        setMessage("Shutting down…")
    }

    func logOut() {
        runAppleScript("tell application \"System Events\" to log out")
        setMessage("Logging out…")
    }

    /// Keep the Mac awake using `caffeinate`.
    func toggleCaffeinate() {
        if isCaffeinated {
            caffeinateProcess?.terminate()
            caffeinateProcess = nil
            isCaffeinated = false
            setMessage("Caffeinate stopped — Mac may sleep normally.")
        } else {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
            process.arguments = ["-di"]
            // Keep published state in sync if the child dies externally (e.g. killall caffeinate).
            process.terminationHandler = { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, self.isCaffeinated else { return }
                    self.caffeinateProcess = nil
                    self.isCaffeinated = false
                    self.lastActionMessage = "Caffeinate ended — Mac may sleep normally."
                }
            }
            do {
                try process.run()
                caffeinateProcess = process
                isCaffeinated = true
                setMessage("Caffeinate active — Mac will stay awake.")
            } catch {
                setMessage("Failed to start caffeinate: \(error.localizedDescription)")
            }
        }
    }

    func startScreenSaver() {
        runShell("open -a ScreenSaverEngine")
        setMessage("Screen saver started.")
    }

    // MARK: - Appearance

    func toggleDarkMode() {
        runAppleScript("""
        tell application "System Events"
            tell appearance preferences
                set dark mode to not dark mode
            end tell
        end tell
        """)
        isDarkMode.toggle()
        setMessage(isDarkMode ? "Dark Mode enabled." : "Light Mode enabled.")
    }

    /// Placeholder: set wallpaper from a chosen image.
    func setWallpaper(url: URL) {
        do {
            if let screen = NSScreen.main {
                try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
                setMessage("Wallpaper updated.")
            }
        } catch {
            setMessage("Failed to set wallpaper: \(error.localizedDescription)")
        }
    }

    /// Placeholder: Night Shift toggling requires private CoreBrightness API.
    func toggleNightShift() {
        // TODO: Implement via CBBlueLightClient (private API) or Shortcuts integration.
        setMessage("Night Shift toggle not yet implemented (placeholder).")
    }

    // MARK: - Audio

    func setVolume(_ percent: Int) {
        let clamped = max(0, min(100, percent))
        runAppleScript("set volume output volume \(clamped)")
        setMessage("Volume set to \(clamped)%.")
    }

    func getVolume() -> Int {
        Int(runAppleScript("output volume of (get volume settings)")) ?? 50
    }

    func toggleMute() {
        runAppleScript("""
        set curMuted to output muted of (get volume settings)
        set volume output muted (not curMuted)
        """)
        setMessage("Mute toggled.")
    }

    // MARK: - Network

    /// Toggles Wi-Fi power on the primary Wi-Fi interface.
    func toggleWiFi() {
        DispatchQueue.global(qos: .userInitiated).async {
            let device = self.runShell("networksetup -listallhardwareports | awk '/Wi-Fi/{getline; print $2}'")
            guard !device.isEmpty else {
                self.setMessage("No Wi-Fi interface found.")
                return
            }
            let state = self.runShell("networksetup -getairportpower \(device)")
            let turningOn = state.hasSuffix("Off")
            self.runShell("networksetup -setairportpower \(device) \(turningOn ? "on" : "off")")
            DispatchQueue.main.async {
                self.isWiFiEnabled = turningOn
                self.lastActionMessage = "Wi-Fi turned \(turningOn ? "on" : "off")."
            }
            // Re-read SSID / IP after the interface settles.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.refreshStates()
            }
        }
    }

    /// Placeholder: Bluetooth toggling requires `blueutil` (brew) or IOBluetooth private API.
    func toggleBluetooth() {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = self.runShell("command -v blueutil >/dev/null && (blueutil -p toggle && blueutil -p) || echo missing")
            if result == "missing" {
                self.setMessage("Bluetooth toggle requires `blueutil` (brew install blueutil).")
            } else {
                DispatchQueue.main.async {
                    self.isBluetoothEnabled = (result == "1")
                    self.lastActionMessage = "Bluetooth turned \(result == "1" ? "on" : "off")."
                }
            }
        }
    }

    func flushDNSCache() {
        runShellAsAdmin("dscacheutil -flushcache; killall -HUP mDNSResponder") { [weak self] out in
            self?.lastActionMessage = out.contains("error") ? "DNS flush cancelled or failed." : "DNS cache flushed and mDNSResponder restarted."
        }
    }

    func publicIPAddress(completion: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let ip = self.runShell("curl -s --max-time 5 https://api.ipify.org")
            DispatchQueue.main.async { completion(ip.isEmpty ? "Unavailable" : ip) }
        }
    }

    /// Renews the DHCP lease on the primary interface.
    func renewDHCPLease() {
        runShellAsAdmin("ipconfig set en0 DHCP") { [weak self] _ in
            self?.lastActionMessage = "DHCP lease renewal requested for en0."
            self?.refreshStates()
        }
    }

    // MARK: - Finder / Files

    func toggleHiddenFiles() {
        DispatchQueue.global(qos: .userInitiated).async {
            let newValue = !self.hiddenFilesShown
            self.runShell("defaults write com.apple.finder AppleShowAllFiles -bool \(newValue); killall Finder")
            DispatchQueue.main.async {
                self.hiddenFilesShown = newValue
                self.lastActionMessage = "Hidden files \(newValue ? "shown" : "hidden") in Finder."
            }
        }
    }

    func emptyTrash() {
        runAppleScript("tell application \"Finder\" to empty trash")
        setMessage("Trash emptied.")
    }

    func relaunchFinder() {
        runShell("killall Finder")
        setMessage("Finder relaunched.")
    }

    func relaunchDock() {
        runShell("killall Dock")
        setMessage("Dock relaunched.")
    }

    func relaunchMenuBar() {
        runShell("killall SystemUIServer; killall ControlCenter 2>/dev/null")
        setMessage("Menu bar relaunched.")
    }

    /// Hide or show all icons on the Desktop.
    func toggleDesktopIcons() {
        DispatchQueue.global(qos: .userInitiated).async {
            let hide = !self.desktopIconsHidden
            self.runShell("defaults write com.apple.finder CreateDesktop -bool \(hide ? "false" : "true"); killall Finder")
            DispatchQueue.main.async {
                self.desktopIconsHidden = hide
                self.lastActionMessage = "Desktop icons \(hide ? "hidden" : "shown")."
            }
        }
    }

    /// Ejects all removable/external volumes.
    func ejectAllDisks() {
        DispatchQueue.global(qos: .userInitiated).async {
            let volumes = (FileManager.default.mountedVolumeURLs(
                includingResourceValuesForKeys: [.volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsInternalKey],
                options: [.skipHiddenVolumes]) ?? [])
            var ejected = 0
            var failed = 0
            for url in volumes {
                guard let values = try? url.resourceValues(forKeys: [.volumeIsEjectableKey, .volumeIsInternalKey]),
                      values.volumeIsEjectable == true, values.volumeIsInternal != true else { continue }
                do {
                    try NSWorkspace.shared.unmountAndEjectDevice(at: url)
                    ejected += 1
                } catch {
                    failed += 1
                }
            }
            if ejected == 0 && failed == 0 {
                self.setMessage("No ejectable disks found.")
            } else {
                self.setMessage("Ejected \(ejected) disk(s)\(failed > 0 ? ", \(failed) failed (in use?)" : ".")")
            }
        }
    }

    // MARK: - Screenshots

    func screenshotFullScreen() {
        let path = "~/Desktop/Screenshot-\(Int(Date().timeIntervalSince1970)).png"
        runShell("screencapture \(path)")
        setMessage("Screenshot saved to Desktop.")
    }

    func screenshotSelection() {
        let path = "~/Desktop/Screenshot-\(Int(Date().timeIntervalSince1970)).png"
        runShell("screencapture -i \(path)")
        setMessage("Interactive screenshot saved to Desktop.")
    }

    /// Copies the last screenshot region interactively straight to the clipboard.
    func screenshotToClipboard() {
        runShell("screencapture -ic")
        setMessage("Selection captured to clipboard.")
    }

    /// Opens the system screenshot/screen-recording toolbar (⇧⌘5 UI).
    func openScreenCaptureToolbar() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Screenshot.app"))
        setMessage("Screenshot toolbar opened.")
    }

    // MARK: - Clipboard

    func clearClipboard() {
        NSPasteboard.general.clearContents()
        setMessage("Clipboard cleared.")
    }

    func clipboardPreview() -> String {
        guard let str = NSPasteboard.general.string(forType: .string), !str.isEmpty else {
            return "Clipboard is empty or non-text."
        }
        return str.count > 120 ? String(str.prefix(120)) + "…" : str
    }

    /// Strips formatting from clipboard text (paste-as-plain-text helper).
    func stripClipboardFormatting() {
        let pb = NSPasteboard.general
        guard let plain = pb.string(forType: .string) else {
            setMessage("No text on clipboard.")
            return
        }
        pb.clearContents()
        pb.setString(plain, forType: .string)
        setMessage("Clipboard formatting stripped.")
    }

    // MARK: - Maintenance

    func rebuildSpotlightIndex() {
        DispatchQueue.global(qos: .utility).async {
            let out = self.runShell("mdutil -E / 2>&1")
            self.setMessage(out.contains("Error") || out.contains("denied") ? "Spotlight reindex may require admin rights." : "Spotlight reindex started.")
        }
    }

    func clearUserCaches() {
        DispatchQueue.global(qos: .utility).async {
            self.runShell("rm -rf ~/Library/Caches/* 2>/dev/null")
            self.setMessage("User caches cleared.")
        }
    }

    /// Purge inactive memory. Requires admin — prompts for authentication.
    func purgeMemory() {
        setMessage("Purging memory (authentication required)…")
        runShellAsAdmin("purge") { [weak self] out in
            self?.lastActionMessage = out.contains("error") ? "Memory purge cancelled or failed." : "Inactive memory purged."
        }
    }

    func startTimeMachineBackup() {
        DispatchQueue.global(qos: .utility).async {
            let out = self.runShell("tmutil startbackup 2>&1")
            self.setMessage(out.isEmpty ? "Time Machine backup started." : out)
        }
    }

    /// Checks for macOS software updates in the background.
    func checkForSoftwareUpdates() {
        setMessage("Checking for software updates…")
        DispatchQueue.global(qos: .utility).async {
            let out = self.runShell("softwareupdate -l 2>&1")
            if out.contains("No new software available") {
                self.setMessage("macOS is up to date.")
            } else if out.contains("*") || out.contains("Label:") {
                self.setMessage("Updates available — opening Software Update.")
                DispatchQueue.main.async { self.openSettingsPane(.softwareUpdate) }
            } else {
                self.setMessage("Software update check finished.")
            }
        }
    }

    /// Reports battery health (cycle count and condition) from system profiler.
    func batteryHealth(completion: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let cycles = self.runShell("system_profiler SPPowerDataType 2>/dev/null | awk -F': ' '/Cycle Count/{print $2}'")
            let condition = self.runShell("system_profiler SPPowerDataType 2>/dev/null | awk -F': ' '/Condition/{print $2}'")
            let capacity = self.runShell("system_profiler SPPowerDataType 2>/dev/null | awk -F': ' '/Maximum Capacity/{print $2}'")
            var parts: [String] = []
            if !cycles.isEmpty { parts.append("\(cycles) cycles") }
            if !condition.isEmpty { parts.append(condition) }
            if !capacity.isEmpty { parts.append("\(capacity) max capacity") }
            DispatchQueue.main.async {
                completion(parts.isEmpty ? "No battery detected." : parts.joined(separator: " • "))
            }
        }
    }

    /// Runs First Aid–style verification on the startup volume.
    func verifyStartupDisk() {
        setMessage("Verifying startup disk…")
        DispatchQueue.global(qos: .utility).async {
            let out = self.runShell("diskutil verifyVolume / 2>&1 | tail -1")
            self.setMessage(out.isEmpty ? "Disk verification finished." : out)
        }
    }

    // MARK: - Focus / Notifications

    /// Modern Focus modes cannot be toggled via public API; delegates to a Shortcuts automation.
    func toggleDoNotDisturb() {
        DispatchQueue.global(qos: .userInitiated).async {
            let out = self.runShell("command -v shortcuts >/dev/null && shortcuts run 'Toggle Focus' 2>&1 || echo missing")
            DispatchQueue.main.async {
                if out == "missing" || out.lowercased().contains("error") {
                    self.lastActionMessage = "Focus toggle needs a Shortcuts automation named 'Toggle Focus'."
                } else {
                    self.isDoNotDisturbEnabled.toggle()
                    self.lastActionMessage = "Focus \(self.isDoNotDisturbEnabled ? "enabled" : "disabled")."
                }
            }
        }
    }

    // MARK: - Media Keys (placeholders)

    func mediaPlayPause() {
        runAppleScript("tell application \"System Events\" to key code 16 using {function down}") // placeholder
        setMessage("Play/Pause sent (placeholder — may require Accessibility permission).")
    }

    // MARK: - Open System Settings panes

    enum SettingsPane: String, CaseIterable, Identifiable {
        case general = "com.apple.systempreferences.GeneralSettings"
        case displays = "com.apple.Displays-Settings.extension"
        case network = "com.apple.Network-Settings.extension"
        case bluetooth = "com.apple.BluetoothSettings"
        case sound = "com.apple.Sound-Settings.extension"
        case battery = "com.apple.Battery-Settings.extension"
        case privacy = "com.apple.settings.PrivacySecurity.extension"
        case softwareUpdate = "com.apple.Software-Update-Settings.extension"
        case users = "com.apple.Users-Groups-Settings.extension"

        var id: String { rawValue }
        var title: String {
            switch self {
            case .general: return "General"
            case .displays: return "Displays"
            case .network: return "Network"
            case .bluetooth: return "Bluetooth"
            case .sound: return "Sound"
            case .battery: return "Battery"
            case .privacy: return "Privacy & Security"
            case .softwareUpdate: return "Software Update"
            case .users: return "Users & Groups"
            }
        }
        var systemImage: String {
            switch self {
            case .general: return "gear"
            case .displays: return "display"
            case .network: return "network"
            case .bluetooth: return "antenna.radiowaves.left.and.right"
            case .sound: return "speaker.wave.2"
            case .battery: return "battery.75"
            case .privacy: return "hand.raised"
            case .softwareUpdate: return "arrow.triangle.2.circlepath"
            case .users: return "person.2"
            }
        }
    }

    func openSettingsPane(_ pane: SettingsPane) {
        if let url = URL(string: "x-apple.systempreferences:\(pane.rawValue)") {
            NSWorkspace.shared.open(url)
            setMessage("Opening \(pane.title) settings…")
        }
    }

    // MARK: - Utility apps

    enum UtilityApp: String, CaseIterable, Identifiable {
        case activityMonitor = "/System/Applications/Utilities/Activity Monitor.app"
        case terminal = "/System/Applications/Utilities/Terminal.app"
        case diskUtility = "/System/Applications/Utilities/Disk Utility.app"
        case console = "/System/Applications/Utilities/Console.app"
        case keychainAccess = "/System/Applications/Utilities/Keychain Access.app"
        case systemInformation = "/System/Applications/Utilities/System Information.app"
        case airportUtility = "/System/Applications/Utilities/AirPort Utility.app"
        case colorMeter = "/System/Applications/Utilities/Digital Color Meter.app"
        case shortcuts = "/System/Applications/Shortcuts.app"
        case automator = "/System/Applications/Automator.app"
        case textEdit = "/System/Applications/TextEdit.app"
        case scriptEditor = "/System/Applications/Utilities/Script Editor.app"

        var id: String { rawValue }
        var title: String {
            URL(fileURLWithPath: rawValue).deletingPathExtension().lastPathComponent
        }
        var systemImage: String {
            switch self {
            case .activityMonitor: return "waveform.path.ecg"
            case .terminal: return "terminal.fill"
            case .diskUtility: return "internaldrive.fill"
            case .console: return "doc.text.magnifyingglass"
            case .keychainAccess: return "key.fill"
            case .systemInformation: return "info.circle.fill"
            case .airportUtility: return "wifi.circle.fill"
            case .colorMeter: return "eyedropper"
            case .shortcuts: return "square.2.layers.3d"
            case .automator: return "gearshape.2.fill"
            case .textEdit: return "doc.text.fill"
            case .scriptEditor: return "applescript.fill"
            }
        }
        var exists: Bool { FileManager.default.fileExists(atPath: rawValue) }
    }

    func openUtility(_ app: UtilityApp) {
        NSWorkspace.shared.open(URL(fileURLWithPath: app.rawValue))
        setMessage("Opening \(app.title)…")
    }

    func openActivityMonitor() { openUtility(.activityMonitor) }
    func openTerminal() { openUtility(.terminal) }
    func openDiskUtility() { openUtility(.diskUtility) }

    // MARK: - Brightness (DisplayServices private framework via dlopen)

    func refreshBrightness() {
        typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
        let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
        defer { if let h = handle { dlclose(h) } }
        guard let h = handle, let sym = dlsym(h, "DisplayServicesGetBrightness") else { return }
        let fn = unsafeBitCast(sym, to: GetFn.self)
        var value: Float = 0.5
        _ = fn(CGMainDisplayID(), &value)
        DispatchQueue.main.async { self.brightness = Double(value) }
    }

    func setBrightness(_ level: Double) {
        typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
        let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
        defer { if let h = handle { dlclose(h) } }
        guard let h = handle, let sym = dlsym(h, "DisplayServicesSetBrightness") else {
            setMessage("Brightness control unavailable (external display?).")
            return
        }
        let fn = unsafeBitCast(sym, to: SetFn.self)
        _ = fn(CGMainDisplayID(), Float(level))
        DispatchQueue.main.async {
            self.brightness = level
            self.lastActionMessage = "Brightness set to \(Int(level * 100))%."
        }
    }

    // MARK: - Login Items (via System Events AppleScript)

    struct LoginItem: Identifiable, Hashable {
        let id = UUID()
        let name: String
        let path: String
        let isHidden: Bool
    }

    func getLoginItems(completion: @escaping ([LoginItem]) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let raw = self.runAppleScript("""
            tell application "System Events"
                set out to ""
                repeat with li in every login item
                    set out to out & (name of li) & "|" & (path of li) & "|" & (hidden of li as text) & "\n"
                end repeat
                return out
            end tell
            """)
            let items: [LoginItem] = raw.components(separatedBy: "\n").compactMap { line in
                let parts = line.components(separatedBy: "|")
                guard parts.count >= 3 else { return nil }
                return LoginItem(name: parts[0], path: parts[1], isHidden: parts[2].lowercased() == "true")
            }
            DispatchQueue.main.async { completion(items) }
        }
    }

    func addLoginItem(url: URL) {
        let path = url.path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        runAppleScript("""
        tell application "System Events"
            make login item at end with properties {path:"\(path)", hidden:false}
        end tell
        """)
        setMessage("Added \(url.lastPathComponent) to login items.")
    }

    func removeLoginItem(name: String) {
        let safeName = name
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        runAppleScript("""
        tell application "System Events"
            if exists login item "\(safeName)" then delete login item "\(safeName)"
        end tell
        """)
        setMessage("Removed \(name) from login items.")
    }

    // MARK: - Wi-Fi Scanner

    func scanWiFiNetworks(completion: @escaping ([String]) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let raw = self.runShell(
                "/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport -s 2>/dev/null | tail -n +2 | awk '{print $1}' | sort -u"
            )
            let networks = raw.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            DispatchQueue.main.async { completion(networks.isEmpty ? ["No networks found"] : networks) }
        }
    }

    // MARK: - Network Connections

    struct NetConnection: Identifiable {
        let id = UUID()
        let proto: String
        let localAddress: String
        let remoteAddress: String
        let state: String
        let process: String
    }

    func getEstablishedConnections(completion: @escaping ([NetConnection]) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            // Use lsof for per-process info
            let raw = self.runShell("lsof -i -nP 2>/dev/null | grep -E 'ESTABLISHED|LISTEN' | head -40")
            let connections: [NetConnection] = raw.components(separatedBy: "\n").compactMap { line in
                let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                guard parts.count >= 9 else { return nil }
                let processName = parts[0]
                let proto = parts[7]
                let addrField = parts[8]
                let state = parts.count >= 10 ? parts[9].trimmingCharacters(in: CharacterSet(charactersIn: "()")) : ""
                let addrs = addrField.components(separatedBy: "->")
                let local = addrs.first ?? addrField
                let remote = addrs.count > 1 ? addrs[1] : ""
                return NetConnection(proto: proto, localAddress: local, remoteAddress: remote, state: state, process: processName)
            }
            DispatchQueue.main.async { completion(connections) }
        }
    }

    func getListeningPorts(completion: @escaping ([NetConnection]) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let raw = self.runShell("lsof -i -nP 2>/dev/null | grep LISTEN | head -30")
            let connections: [NetConnection] = raw.components(separatedBy: "\n").compactMap { line in
                let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                guard parts.count >= 9 else { return nil }
                return NetConnection(proto: parts[7], localAddress: parts[8], remoteAddress: "", state: "LISTEN", process: parts[0])
            }
            DispatchQueue.main.async { completion(connections) }
        }
    }

    // MARK: - Environment Variables

    func getEnvironmentVariables() -> [(key: String, value: String)] {
        ProcessInfo.processInfo.environment
            .sorted { $0.key < $1.key }
            .map { (key: $0.key, value: $0.value) }
    }
}
