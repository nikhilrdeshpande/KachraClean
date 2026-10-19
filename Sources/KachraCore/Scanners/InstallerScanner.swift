import Foundation

/// Disk images and installer packages left in Downloads and on the Desktop, matched by name to
/// the apps they installed (see docs/spec/07). Nothing is mounted or opened.
public struct InstallerScanner: Sendable {
    public struct InstalledApp: Sendable {
        public var name: String
        public var bundleID: String?

        public init(name: String, bundleID: String?) {
            self.name = name
            self.bundleID = bundleID
        }
    }

    public var home: URL
    /// Installed apps; read from the Applications folders when nil.
    public var installed: [InstalledApp]?

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, installed: [InstalledApp]? = nil) {
        self.home = home
        self.installed = installed
    }

    static let extensions: Set<String> = ["dmg", "pkg", "mpkg", "xip"]

    public func scan() async -> [Finding] {
        let apps = installed ?? installedApps()
        var files: [URL] = []
        collect(home.appendingPathComponent("Downloads"), depth: 2, into: &files)
        collect(home.appendingPathComponent("Desktop"), depth: 1, into: &files)
        let sizes = await DiskUsage.allocatedSizes(of: files)
        return zip(files, sizes).filter { $0.1 > 0 }.map { file, bytes in
            finding(for: file, bytes: bytes, match: Self.match(file.lastPathComponent, apps: apps))
        }
    }

    func finding(for file: URL, bytes: Int64, match: InstalledApp?) -> Finding {
        var details = ["kind": file.pathExtension.lowercased() == "xip" ? "Xcode archive" : "Installer"]
        if let source = Self.downloadedFrom(file) { details["source"] = source }
        let reason: String
        if let match {
            details["installs"] = match.name
            reason = "\(match.name) is installed, so this installer has done its job. It can be downloaded again if you ever need it."
        } else {
            reason = "Not matched to an installed app. It may be something you haven't installed yet, or installed under another name."
        }
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return Finding(category: .installers, title: file.lastPathComponent, owner: match?.name,
                       paths: [file.path], bytes: bytes, safety: match == nil ? .review : .safe,
                       reason: reason, lastActivity: modified, details: details)
    }

    private func collect(_ dir: URL, depth: Int, into files: inout [URL]) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]
        let items = (try? FileManager().contentsOfDirectory(at: dir, includingPropertiesForKeys: keys,
                                                            options: [.skipsHiddenFiles])) ?? []
        for item in items {
            guard let v = try? item.resourceValues(forKeys: Set(keys)), v.isSymbolicLink != true else { continue }
            let child = dir.appendingPathComponent(item.lastPathComponent)
            if Self.extensions.contains(item.pathExtension.lowercased()) {
                files.append(child)  // bundle-style .pkg folders count too
            } else if v.isDirectory == true, v.isPackage != true, depth > 1 {
                collect(child, depth: depth - 1, into: &files)
            }
        }
    }

    func installedApps() -> [InstalledApp] {
        AppScanner(home: home).appBundles().map { url in
            InstalledApp(name: url.deletingPathExtension().lastPathComponent, bundleID: Bundle(url: url)?.bundleIdentifier)
        }
    }

    /// Lowercased letters and digits only.
    static func normalized(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) && $0.isASCII })
    }

    /// The installed app this file installs, judged by name; the longest matching name wins.
    static func match(_ fileName: String, apps: [InstalledApp]) -> InstalledApp? {
        var stem = normalized((fileName as NSString).deletingPathExtension)
        for word in ["installer", "install", "setup"] where stem.hasPrefix(word) {
            stem.removeFirst(word.count)
            break
        }
        var best: (app: InstalledApp, length: Int)?
        for app in apps {
            let keys = [normalized(app.name), app.bundleID.map { normalized(String($0.split(separator: ".").last ?? "")) }]
            for case let key? in keys where key.count >= 4 && stem.hasPrefix(key) && key.count > (best?.length ?? 0) {
                best = (app, key.count)
            }
        }
        return best?.app
    }

    /// Host the file was downloaded from, as recorded by the browser.
    static func downloadedFrom(_ file: URL) -> String? {
        let name = "com.apple.metadata:kMDItemWhereFroms"
        let length = getxattr(file.path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard length > 0, length < 64_000 else { return nil }
        var data = Data(count: length)
        let read = data.withUnsafeMutableBytes { getxattr(file.path, name, $0.baseAddress, length, 0, XATTR_NOFOLLOW) }
        guard read == length,
              let urls = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String] else { return nil }
        return urls.lazy.compactMap { URL(string: $0)?.host }.first
    }
}
