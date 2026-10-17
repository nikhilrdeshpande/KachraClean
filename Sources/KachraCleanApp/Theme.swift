import AppKit
import KachraCore
import SwiftUI

// MARK: - Categories & safety

extension Category {
    var symbol: String {
        switch self {
        case .appCaches: "square.stack.3d.up.fill"
        case .logs: "doc.text.fill"
        case .toolCaches: "hammer.fill"
        case .models: "brain.fill"
        case .projectArtifacts: "shippingbox.fill"
        case .duplicates: "doc.on.doc.fill"
        case .apps: "app.badge.fill"
        case .trash: "trash.fill"
        }
    }

    var tint: Color {
        switch self {
        case .projectArtifacts: .indigo
        case .models: .purple
        case .toolCaches: .orange
        case .appCaches: .blue
        case .logs: .teal
        case .duplicates: .pink
        case .apps: .green
        case .trash: .gray
        }
    }

    /// One line explaining the category in plain words.
    var blurb: String {
        switch self {
        case .projectArtifacts: "Dependencies and build output inside your code projects. Rebuilt from lockfiles."
        case .models: "AI model weights and datasets you downloaded. Large, and slow to fetch again."
        case .toolCaches: "Package-manager and build-tool caches. Re-downloaded when needed."
        case .appCaches: "Data apps keep to load faster. Recreated automatically."
        case .logs: "Diagnostic logs apps write. Only useful when debugging."
        case .duplicates: "Identical copies of the same file in Downloads. One copy is always kept."
        case .apps: "Installed apps with everything they store on your Mac."
        case .trash: "Things you already deleted."
        }
    }

    /// Display order: biggest wins for developers first; apps and Trash last.
    static let displayOrder: [Category] = [
        .projectArtifacts, .models, .toolCaches, .appCaches, .logs, .duplicates, .apps, .trash,
    ]
}

extension Safety {
    var color: Color {
        switch self {
        case .safe: .green
        case .review: .orange
        case .risky: .red
        }
    }

    var label: String {
        switch self {
        case .safe: "Safe"
        case .review: "Review"
        case .risky: "Careful"
        }
    }

    var symbol: String {
        switch self {
        case .safe: "checkmark.shield.fill"
        case .review: "eye.fill"
        case .risky: "exclamationmark.triangle.fill"
        }
    }

    var explanation: String {
        switch self {
        case .safe: "Regenerates by itself. Pre-selected."
        case .review: "Probably fine to remove, but worth a look first."
        case .risky: "Removing this deletes data or settings. Never pre-selected."
        }
    }
}

// MARK: - Formatting

enum Format {
    static func bytes(_ n: Int64) -> String {
        n == 0 ? "0 KB" : ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    static func relative(_ date: Date?) -> String? {
        guard let date else { return nil }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: Date())
    }

    static func path(_ p: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
    }

    static func duration(_ seconds: TimeInterval) -> String {
        seconds < 60 ? "\(Int(seconds))s" : "\(Int(seconds) / 60)m \(Int(seconds) % 60)s"
    }
}

// MARK: - Glass

extension View {
    /// Liquid Glass on macOS 26, a regular material before that.
    @ViewBuilder
    func glassSurface<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            self.background(.regularMaterial, in: shape)
                .overlay(shape.stroke(.separator.opacity(0.6), lineWidth: 0.5))
        }
    }

    @ViewBuilder
    func prominentGlassButton() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    func glassButton() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
    }
}

// MARK: - Icons

/// App icons for findings owned by an app, symbols for everything else. Cached per bundle.
@MainActor
enum IconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(for finding: Finding) -> NSImage? {
        if finding.category == .apps, let path = finding.paths.first {
            return cached(path) { NSWorkspace.shared.icon(forFile: path) }
        }
        if let id = finding.details["bundleID"] ?? finding.details["folder"], id.contains(".") {
            return cached(id) {
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
                    .map { NSWorkspace.shared.icon(forFile: $0.path) }
            }
        }
        return nil
    }

    private static func cached(_ key: String, _ make: () -> NSImage?) -> NSImage? {
        if let hit = cache[key] { return hit }
        let image = make()
        if let image { cache[key] = image }
        return image
    }
}

struct ItemIcon: View {
    var finding: Finding
    var size: CGFloat = 28

    var body: some View {
        if let image = IconCache.icon(for: finding) {
            Image(nsImage: image).resizable().frame(width: size, height: size)
        } else {
            Image(systemName: symbol)
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(finding.category.tint)
                .frame(width: size, height: size)
                .background(finding.category.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: size * 0.24))
        }
    }

    private var symbol: String {
        switch finding.details["kind"] {
        case "node_modules", "Framework build cache": "curlybraces"
        case "Python environment", "Python bytecode": "chevron.left.forwardslash.chevron.right"
        case "Rust build output": "gearshape.2.fill"
        case "CocoaPods", "Gradle build output": "hammer.fill"
        default: finding.category.symbol
        }
    }
}
