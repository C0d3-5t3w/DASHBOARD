import SwiftUI
import AppKit

/// An inline shell-command runner with scrolling output, command history,
/// working-directory display, and environment-variable browsing.
struct QuickTerminalView: View {
    @State private var command: String = ""
    @State private var outputLines: [OutputLine] = []
    @State private var commandHistory: [String] = []
    @State private var historyIndex: Int = -1
    @State private var isRunning: Bool = false
    @State private var currentDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    @State private var showEnvVars = false
    @State private var envSearch = ""

    private let control = SystemControl.shared

    struct OutputLine: Identifiable {
        let id = UUID()
        let text: String
        let kind: Kind
        enum Kind { case command, stdout, stderr, info }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 8) {
                Image(systemName: "terminal.fill")
                    .foregroundColor(.green)
                Text(currentDirectory)
                    .font(.caption.monospaced())
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer()
                Button {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    panel.allowsMultipleSelection = false
                    panel.message = "Choose working directory"
                    panel.directoryURL = URL(fileURLWithPath: currentDirectory)
                    if panel.runModal() == .OK, let url = panel.url {
                        currentDirectory = url.path
                        appendLine("Changed directory to \(url.path)", kind: .info)
                    }
                } label: {
                    Label("Directory", systemImage: "folder")
                }
                .buttonStyle(.borderless)

                Button { showEnvVars.toggle() } label: {
                    Label("Env Vars", systemImage: "list.bullet.rectangle")
                }
                .buttonStyle(.borderless)

                Button {
                    outputLines.removeAll()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            if showEnvVars {
                EnvVarsView(searchText: $envSearch)
                    .transition(.move(edge: .top).combined(with: .opacity))
                Divider()
            }

            // Output
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(outputLines) { line in
                            Text(line.text)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(lineColor(line.kind))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                        }
                    }
                    .padding(10)
                }
                .background(Color(NSColor.textBackgroundColor))
                .onChange(of: outputLines.count) {
                    if let last = outputLines.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            Divider()

            // Input bar
            HStack(spacing: 8) {
                Text("$")
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.green)

                TextField("Enter command…", text: $command)
                    .font(.system(.body, design: .monospaced))
                    .textFieldStyle(.plain)
                    .onSubmit { runCommand() }
                    .disabled(isRunning)
                    .onKeyPress(.upArrow) { navigateHistory(-1); return .handled }
                    .onKeyPress(.downArrow) { navigateHistory(1); return .handled }

                if isRunning {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 20)
                }

                Button("Run") { runCommand() }
                    .disabled(command.trimmingCharacters(in: .whitespaces).isEmpty || isRunning)
                    .keyboardShortcut(.return, modifiers: [])
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .navigationTitle("Terminal")
        .onAppear {
            appendLine("Quick Terminal ready. Working directory: \(currentDirectory)", kind: .info)
        }
    }

    // MARK: - Actions

    private func runCommand() {
        let cmd = command.trimmingCharacters(in: .whitespaces)
        guard !cmd.isEmpty else { return }

        // Update history
        commandHistory.removeAll { $0 == cmd }
        commandHistory.insert(cmd, at: 0)
        if commandHistory.count > 100 { commandHistory.removeLast() }
        historyIndex = -1

        appendLine("$ \(cmd)", kind: .command)
        command = ""
        isRunning = true

        DispatchQueue.global(qos: .userInitiated).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            proc.arguments = ["-c", cmd]
            proc.currentDirectoryURL = URL(fileURLWithPath: self.currentDirectory)

            // Inherit the user's environment
            var env = ProcessInfo.processInfo.environment
            env["TERM"] = "xterm-256color"
            proc.environment = env

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            proc.standardOutput = stdoutPipe
            proc.standardError = stderrPipe

            do {
                try proc.run()
                proc.waitUntilExit()

                let out = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let err = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let exitCode = proc.terminationStatus

                DispatchQueue.main.async {
                    if !out.isEmpty {
                        self.appendLines(out, kind: .stdout)
                    }
                    if !err.isEmpty {
                        self.appendLines(err, kind: .stderr)
                    }
                    if exitCode != 0 {
                        self.appendLine("Exit code: \(exitCode)", kind: .info)
                    }
                    self.isRunning = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.appendLine("Error: \(error.localizedDescription)", kind: .stderr)
                    self.isRunning = false
                }
            }
        }
    }

    private func navigateHistory(_ delta: Int) {
        guard !commandHistory.isEmpty else { return }
        let newIndex = historyIndex + delta
        if newIndex < -1 {
            return
        } else if newIndex >= commandHistory.count {
            return
        }
        historyIndex = newIndex
        command = historyIndex == -1 ? "" : commandHistory[historyIndex]
    }

    private func appendLine(_ text: String, kind: OutputLine.Kind) {
        outputLines.append(OutputLine(text: text, kind: kind))
    }

    private func appendLines(_ text: String, kind: OutputLine.Kind) {
        var lines = text.components(separatedBy: "\n")
        // Drop trailing empty line from a newline-terminated output
        if lines.last?.isEmpty == true { lines.removeLast() }
        for line in lines {
            outputLines.append(OutputLine(text: line, kind: kind))
        }
    }

    private func lineColor(_ kind: OutputLine.Kind) -> Color {
        switch kind {
        case .command: return .green
        case .stdout:  return .primary
        case .stderr:  return .red
        case .info:    return .secondary
        }
    }
}

// MARK: - Environment Variables Browser

private struct EnvVarsView: View {
    @Binding var searchText: String
    @ObservedObject private var control = SystemControl.shared

    private var envVars: [(key: String, value: String)] {
        let all = control.getEnvironmentVariables()
        guard !searchText.isEmpty else { return all }
        let q = searchText.lowercased()
        return all.filter { $0.key.lowercased().contains(q) || $0.value.lowercased().contains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("Filter env vars…", text: $searchText)
                    .textFieldStyle(.plain)
                Text("\(envVars.count) vars")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(8)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(envVars, id: \.key) { pair in
                        HStack(alignment: .top, spacing: 8) {
                            Text(pair.key)
                                .font(.caption.monospaced().bold())
                                .foregroundColor(.blue)
                                .frame(width: 220, alignment: .leading)
                                .lineLimit(1)
                            Text(pair.value)
                                .font(.caption.monospaced())
                                .foregroundColor(.primary)
                                .lineLimit(2)
                            Spacer()
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 1)
                        .contextMenu {
                            Button("Copy Value") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(pair.value, forType: .string)
                            }
                            Button("Copy Key=Value") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString("\(pair.key)=\(pair.value)", forType: .string)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 200)
        }
        .background(Color(NSColor.textBackgroundColor))
    }
}

#Preview {
    QuickTerminalView()
        .frame(width: 800, height: 600)
}
