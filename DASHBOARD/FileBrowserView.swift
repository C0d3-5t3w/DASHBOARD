import SwiftUI
import Combine
import AppKit
import QuickLook
import QuickLookUI
import UniformTypeIdentifiers

final class FileBrowserModel: ObservableObject {
    @Published var currentURL: URL {
        didSet {
            loadContents()
        }
    }
    @Published var contents: [URL] = []
    @Published var selectedURL: URL? = nil
    @Published var pathString: String = ""
    @Published var previewURLs: [URL] = []
    
    private var backStack: [URL] = []
    private var forwardStack: [URL] = []
    
    let commonLocations: [(name: String, url: URL)] = {
        let fm = FileManager.default
        var locs: [(String, URL)] = []
        if let home = fm.homeDirectoryForCurrentUser as URL? {
            locs.append(("Home", home))
            locs.append(("Desktop", home.appendingPathComponent("Desktop")))
            locs.append(("Documents", home.appendingPathComponent("Documents")))
            locs.append(("Downloads", home.appendingPathComponent("Downloads")))
            locs.append(("Applications", URL(fileURLWithPath: "/Applications")))
        }
        return locs
    }()
    
    init() {
        self.currentURL = FileManager.default.homeDirectoryForCurrentUser
        self.pathString = currentURL.path
        loadContents()
    }
    
    private func loadContents() {
        pathString = currentURL.path
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: currentURL.path, isDirectory: &isDir), isDir.boolValue {
            do {
                let contents = try FileManager.default.contentsOfDirectory(at: currentURL, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .typeIdentifierKey], options: [.skipsHiddenFiles])
                self.contents = contents.sorted(by: { $0.lastPathComponent.lowercased() < $1.lastPathComponent.lowercased() })
            } catch {
                self.contents = []
            }
        } else {
            self.contents = []
        }
    }
    
    func navigate(to url: URL) {
        guard url != currentURL else { return }
        backStack.append(currentURL)
        forwardStack.removeAll()
        currentURL = url
    }
    
    func goBack() {
        guard let last = backStack.popLast() else { return }
        forwardStack.append(currentURL)
        currentURL = last
    }
    
    func canGoBack() -> Bool {
        !backStack.isEmpty
    }
    
    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(currentURL)
        currentURL = next
    }
    
    func canGoForward() -> Bool {
        !forwardStack.isEmpty
    }
    
    func enterPath(_ path: String) {
        let url = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            navigate(to: url)
        } else {
            // Invalid path, ignore or reset path string to currentURL
            pathString = currentURL.path
        }
    }
    
    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([currentURL])
    }
    
    // File info helpers
    func fileKind(for url: URL) -> String {
        (try? url.resourceValues(forKeys: [.typeIdentifierKey]).typeIdentifier).flatMap { UniformTypeIdentifiers.UTType($0)?.localizedDescription } ?? "File"
    }
    
    func fileSize(for url: URL) -> String {
        if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            return formatter.string(fromByteCount: Int64(size))
        }
        return ""
    }
    
    func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey])).flatMap { $0.isDirectory } ?? false
    }
}

struct IdentifiableURL: Identifiable {
    let id = UUID()
    let url: URL
}

final class QuickLookPanelController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookPanelController()

    private var urls: [URL] = []

    func present(urls: [URL]) {
        guard !urls.isEmpty else { return }
        self.urls = urls
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }
    
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        urls.count
    }
    
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        urls[index] as NSURL
    }
    
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        return false
    }
    
    func panelDidClose(_ panel: QLPreviewPanel!) {
        urls = []
    }
}

struct FileBrowserView: View {
    @StateObject private var model = FileBrowserModel()
    
    var body: some View {
        NavigationSplitView {
            List(selection: $model.currentURL) {
                ForEach(model.commonLocations, id: \.url) { loc in
                    Label(loc.name, systemImage: systemImageName(for: loc.url))
                        .tag(loc.url)
                }
            }
            .frame(minWidth: 180)
        } detail: {
            VStack(spacing: 0) {
                HStack {
                    Button(action: model.goBack) {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(!model.canGoBack())
                    Button(action: model.goForward) {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(!model.canGoForward())
                    
                    TextField("Path", text: $model.pathString)
                        .onSubmit {
                            model.enterPath(model.pathString)
                        }
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .frame(minWidth: 200)
                    
                    Button(action: model.revealInFinder) {
                        Image(systemName: "finder")
                    }
                    .help("Reveal in Finder")
                    
                    Button {
                        // Quick Look the selected file(s) via panel
                        if let selected = model.selectedURL {
                            QuickLookPanelController.shared.present(urls: [selected])
                        }
                    } label: {
                        Image(systemName: "eye")
                    }
                    .disabled(model.selectedURL == nil)
                    .help("Quick Look")
                    
                    Spacer()
                }
                .padding(6)
                .background(Color(NSColor.windowBackgroundColor))
                
                List(selection: $model.selectedURL) {
                    ForEach(model.contents, id: \.self) { url in
                        NavigationLink(value: url) {
                            HStack {
                                Image(nsImage: icon(for: url))
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 16, height: 16)
                                Text(url.lastPathComponent)
                                Spacer()
                                if !model.isDirectory(url) {
                                    Text(model.fileKind(for: url))
                                        .foregroundColor(.secondary)
                                    Text(model.fileSize(for: url))
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .tag(url)
                        .contextMenu {
                            Button("Open") {
                                if model.isDirectory(url) {
                                    model.navigate(to: url)
                                    model.selectedURL = nil
                                } else {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                            }
                            Button("Quick Look") {
                                QuickLookPanelController.shared.present(urls: [url])
                            }
                        }
                        .onTapGesture(count: 2) {
                            if model.isDirectory(url) {
                                model.navigate(to: url)
                                model.selectedURL = nil
                            } else {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
                .frame(minWidth: 300)
            }
            .navigationTitle(model.currentURL.lastPathComponent.isEmpty ? model.currentURL.path : model.currentURL.lastPathComponent)
        }
        .navigationSplitViewStyle(.balanced)
    }
    
    private func icon(for url: URL) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }
    
    private func systemImageName(for url: URL) -> String {
        switch url.path {
        case FileManager.default.homeDirectoryForCurrentUser.path:
            return "house"
        case FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop").path:
            return "desktopcomputer"
        case FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents").path:
            return "doc.text"
        case FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path:
            return "arrow.down.circle"
        case "/Applications":
            return "app"
        default:
            return "folder"
        }
    }
}

struct FileBrowserView_Previews: PreviewProvider {
    static var previews: some View {
        FileBrowserView()
            .frame(width: 800, height: 600)
    }
}
