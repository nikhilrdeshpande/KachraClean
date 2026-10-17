import Foundation

/// A known location with a fixed meaning (a tool's cache, a model store, logs).
public struct Rule: Codable, Sendable {
    public var id: String
    public var title: String
    public var owner: String?
    public var category: Category
    /// Paths, `~` expanded against the user's home folder.
    public var paths: [String]
    public var safety: Safety
    public var reason: String
    /// Report each child folder as its own finding (e.g. one per app under ~/Library/Logs).
    public var expandChildren: Bool?
}

public struct RuleSet: Codable, Sendable {
    public var version: Int
    public var rules: [Rule]

    /// The rules shipped with KachraClean (`Resources/rules.json`).
    public static func bundled() throws -> RuleSet {
        guard let url = bundledURL() else { throw CocoaError(.fileNoSuchFile) }
        return try JSONDecoder().decode(RuleSet.self, from: Data(contentsOf: url))
    }

    /// Inside the packaged .app the resource bundle sits in Contents/Resources, where SwiftPM's
    /// `Bundle.module` doesn't look (and would crash if missing), so check there first.
    static func bundledURL() -> URL? {
        if let resources = Bundle.main.resourceURL,
           let inApp = Bundle(url: resources.appendingPathComponent("KachraClean_KachraCore.bundle")),
           let url = inApp.url(forResource: "rules", withExtension: "json") {
            return url
        }
        return Bundle.module.url(forResource: "rules", withExtension: "json")
    }

    /// Every path claimed by a rule, expanded. Other scanners skip these to avoid double counting.
    public func claimedPaths(home: URL) -> Set<String> {
        Set(rules.flatMap { $0.paths.map { PathUtil.expand($0, home: home).path } })
    }
}

enum PathUtil {
    static func expand(_ path: String, home: URL) -> URL {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home.appendingPathComponent(String(path.dropFirst(2))) }
        return URL(fileURLWithPath: path)
    }

    /// `~`-relative display form of a path.
    static func display(_ url: URL, home: URL) -> String {
        let p = url.path
        return p.hasPrefix(home.path + "/") ? "~" + p.dropFirst(home.path.count) : p
    }

    /// Other apps' containers: reading them without Full Disk Access triggers a macOS consent prompt.
    static func isProtected(_ url: URL, home: URL) -> Bool {
        let p = url.path
        return p.hasPrefix(home.appendingPathComponent("Library/Containers").path + "/")
            || p.hasPrefix(home.appendingPathComponent("Library/Group Containers").path + "/")
    }

    static func exists(_ url: URL) -> Bool {
        FileManager().fileExists(atPath: url.path)
    }
}
