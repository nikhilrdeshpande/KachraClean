import KachraCore
import SwiftUI

enum Destination: Hashable {
    case home
    case explorer
    case category(Category)
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var destination: Destination? = .home

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 225, ideal: 255, max: 340)
        } detail: {
            ZStack(alignment: .bottom) {
                switch destination {
                case .category(let category):
                    CategoryDetailView(category: category) { destination = .home }
                case .explorer:
                    DiskExplorerView()
                default:
                    HomeView { destination = .category($0) }
                }
            }
            .overlay(alignment: .top) {
                if let toast = model.toast {
                    ToastView(toast: toast).transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: model.toast)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if model.isScanning {
                    Button {
                        model.cancelScan()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                } else {
                    Button {
                        model.requestScan()
                        destination = .home
                    } label: {
                        Label("Scan", systemImage: "arrow.clockwise")
                    }
                    .help("Scan again (⌘R)")
                    .disabled(model.phase == .cleaning)
                }
            }
        }
        .onAppear {
            // Developer/screenshot hook: `-KCOpen projectArtifacts [-KCFocusFirst YES]`.
            if UserDefaults.standard.bool(forKey: "KCScan") { model.scan() }
            if UserDefaults.standard.string(forKey: "KCOpen") == "explorer" { destination = .explorer }
            if let raw = UserDefaults.standard.string(forKey: "KCOpen"), let category = Category(rawValue: raw) {
                destination = .category(category)
                if UserDefaults.standard.bool(forKey: "KCFocusFirst") {
                    model.focused = model.findings(in: category).max { $0.bytes < $1.bytes }?.id
                }
            }
        }
        .onChange(of: destination, initial: true) { _, new in
            if case .category(let category) = new { model.scope = category } else { model.scope = nil }
            model.onExplorer = new == .explorer
            model.search = ""
        }
        .onChange(of: model.navigationRequest) { _, request in
            guard let request else { return }
            destination = request
            model.navigationRequest = nil
        }
        .sheet(isPresented: Bindable(model).showPermissionGate) { PermissionGate() }
        .confirmationDialog(
            "Remove \(model.pendingConfirmation?.filter { $0.category == .apps }.count ?? 0) apps and their data?",
            isPresented: Binding(get: { model.pendingConfirmation != nil }, set: { if !$0 { model.pendingConfirmation = nil } })
        ) {
            Button("Move to Trash", role: .destructive) { model.confirmPending() }
            Button("Cancel", role: .cancel) { model.pendingConfirmation = nil }
        } message: {
            Text("The apps, their settings and their data move to the Trash. You can undo right after, or restore them from the Trash.")
        }
        .alert("Scan failed", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var sidebar: some View {
        List(selection: $destination) {
            Label {
                HStack {
                    Text("Overview")
                    Spacer()
                    if model.reclaimable > 0 {
                        Text(Format.bytes(model.reclaimable)).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            } icon: {
                Image(systemName: "sparkles")
            }
            .tag(Destination.home)

            Label("Disk Explorer", systemImage: "folder.fill")
                .help("Every folder in your home, biggest first")
                .tag(Destination.explorer)

            let reclaim = Category.displayOrder.filter { $0.countsAsReclaimable && model.total($0) > 0 }
            if !reclaim.isEmpty {
                Section("Clean") {
                    ForEach(reclaim, id: \.self) { sidebarRow($0) }
                }
            }
            let manage = [Category.apps, .trash].filter { model.total($0) > 0 }
            if !manage.isEmpty {
                Section("Manage") {
                    ForEach(manage, id: \.self) { sidebarRow($0) }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func sidebarRow(_ category: Category) -> some View {
        return Label {
            HStack {
                Text(category.title).lineLimit(1)
                Spacer()
                Text(Format.bytes(model.total(category))).foregroundStyle(.secondary).monospacedDigit()
            }
        } icon: {
            Image(systemName: category.symbol).foregroundStyle(category.tint)
        }
        .tag(Destination.category(category))
    }
}
