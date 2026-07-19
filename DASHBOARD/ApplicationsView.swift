import SwiftUI
import Combine
import AppKit

struct ApplicationsView: View {
    @StateObject private var model = ApplicationsModel()
    
    var body: some View {
        NavigationView {
            List(model.filteredApplications, id: \.url) { app in
                Button {
                    model.launch(app: app)
                } label: {
                    HStack {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                            .resizable()
                            .frame(width: 32, height: 32)
                            .cornerRadius(6)
                        VStack(alignment: .leading) {
                            Text(app.displayName)
                                .font(.headline)
                            Text(app.url.path)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(PlainButtonStyle())
            }
            .navigationTitle("Applications")
            .searchable(text: $model.searchText, placement: .toolbar)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: model.loadApplications) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh Applications List")
                }
            }
        }
        .frame(minWidth: 500, minHeight: 400)
        .onAppear {
            model.loadApplications()
        }
    }
}

final class ApplicationsModel: ObservableObject {
    struct AppEntry: Identifiable {
        let id = UUID()
        let url: URL
        let displayName: String
    }
    
    @Published private(set) var allApps: [AppEntry] = []
    @Published var searchText: String = ""
    
    var filteredApplications: [AppEntry] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return allApps
        }
        let lower = trimmed.lowercased()
        return allApps.filter { $0.displayName.lowercased().contains(lower) }
    }
    
    private let fileManager = FileManager.default
    
    func loadApplications() {
        DispatchQueue.global(qos: .userInitiated).async {
            let roots: [URL] = [
                URL(fileURLWithPath: "/Applications"),
                self.fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
            ]
            var found: [AppEntry] = []
            for root in roots {
                found.append(contentsOf: self.scanApplications(at: root))
            }
            found.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            DispatchQueue.main.async {
                self.allApps = found
            }
        }
    }
    
    private func scanApplications(at root: URL) -> [AppEntry] {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles],
            errorHandler: nil
        ) else { return [] }
        
        var apps: [AppEntry] = []
        
        for case let url as URL in enumerator {
            if url.pathExtension == "app" {
                let displayName = url.deletingPathExtension().lastPathComponent
                apps.append(AppEntry(url: url, displayName: displayName))
                enumerator.skipDescendants()
            }
        }
        
        return apps
    }
    
    func launch(app: AppEntry) {
        NSWorkspace.shared.openApplication(at: app.url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }
}
