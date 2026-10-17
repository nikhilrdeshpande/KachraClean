import KachraCore
import SwiftUI

enum SidebarItem: Hashable {
    case overview
    case category(Category)
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var item: SidebarItem? = .overview

    /// Order in the sidebar: biggest wins for developers first, apps and Trash last.
    static let categories: [Category] = [
        .projectArtifacts, .models, .toolCaches, .appCaches, .logs, .duplicates, .apps, .trash,
    ]

    var body: some View {
        NavigationSplitView {
            List(selection: $item) {
                Label("Overview", systemImage: "gauge.with.dots.needle.33percent")
                    .tag(SidebarItem.overview)
                Section("Found") {
                    ForEach(Self.categories, id: \.self) { category in
                        let total = model.total(category)
                        if total > 0 {
                            HStack {
                                Label(category.title, systemImage: category.symbol)
                                Spacer()
                                Text(Format.bytes(total))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            .tag(SidebarItem.category(category))
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 300, ideal: 310)
        } detail: {
            VStack(spacing: 0) {
                if !model.hasFullDiskAccess { FullDiskAccessBanner() }
                switch item {
                case .category(let category):
                    CategoryView(category: category)
                default:
                    OverviewView(show: { item = .category($0) })
                }
                if model.report != nil { SelectionBar() }
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    model.scan()
                } label: {
                    Label("Scan", systemImage: "arrow.clockwise")
                }
                .disabled(model.isScanning || model.phase == .cleaning)
            }
        }
        .alert("Scan failed", isPresented: .constant(model.errorMessage != nil)) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

struct FullDiskAccessBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield").font(.title2).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Full Disk Access is off").font(.headline)
                Text("Without it, KachraClean can't see other apps' containers and some caches, so results will be incomplete.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open Settings") { model.openFullDiskAccessSettings() }
            Button("Check Again") { model.recheckFullDiskAccess() }
        }
        .padding(12)
        .background(.orange.opacity(0.08))
    }
}

struct SelectionBar: View {
    @Environment(AppModel.self) private var model
    @State private var confirming = false

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                if let summary = model.lastCleanSummary {
                    Label(summary, systemImage: "checkmark.circle").foregroundStyle(.secondary).lineLimit(2)
                } else {
                    Text("\(model.selection.count) selected · \(Format.bytes(model.selectedBytes))")
                        .monospacedDigit()
                }
                Spacer()
                if model.phase == .cleaning { ProgressView().controlSize(.small) }
                Button("Move to Trash…") { confirming = true }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.selection.isEmpty || model.phase != .ready)
            }
            .padding(12)
        }
        .confirmationDialog("Move \(model.selection.count) items to the Trash?", isPresented: $confirming) {
            Button("Move to Trash", role: .destructive) { model.moveSelectionToTrash() }
        } message: {
            let apps = model.selectedFindings.filter { $0.category == .apps }.count
            let review = model.selectedFindings.filter { $0.safety != .safe }.count
            Text([
                "\(Format.bytes(model.selectedBytes)) will move to the Trash. Nothing is deleted until you empty it.",
                review > 0 ? "\(review) selected items are marked review or risky." : nil,
                apps > 0 ? "This includes \(apps) apps and their data." : nil,
            ].compactMap { $0 }.joined(separator: "\n"))
        }
    }
}

extension Category {
    var symbol: String {
        switch self {
        case .appCaches: "square.stack.3d.up"
        case .logs: "doc.text"
        case .toolCaches: "hammer"
        case .models: "brain"
        case .projectArtifacts: "shippingbox"
        case .duplicates: "doc.on.doc"
        case .apps: "app.badge"
        case .trash: "trash"
        }
    }
}

extension Safety {
    var color: Color {
        switch self {
        case .safe: .green
        case .review: .orange
        case .risky: .red
        }
    }

    var label: String { rawValue.capitalized }
}
