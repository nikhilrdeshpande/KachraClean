import Foundation

/// What Docker itself says it can free (`docker system df`), attached to the Docker finding with
/// Docker's own commands (see docs/spec/07). KachraClean never runs those commands.
public struct DockerScanner: Sendable {
    public struct Usage: Sendable, Equatable {
        public var type: String
        public var count: Int
        public var size: Int64
        public var reclaimable: Int64
    }

    public var home: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    /// The first Docker CLI found in the usual places (Docker Desktop, Homebrew, OrbStack).
    public var cli: URL? {
        ["/usr/local/bin/docker", "/opt/homebrew/bin/docker", "/Applications/Docker.app/Contents/Resources/bin/docker",
         home.appendingPathComponent(".docker/bin/docker").path, home.appendingPathComponent(".orbstack/bin/docker").path]
            .map { URL(fileURLWithPath: $0) }
            .first { FileManager().isExecutableFile(atPath: $0.path) }
    }

    /// Adds Docker's breakdown to the Docker Desktop finding, or a separate explained-only finding.
    public func annotate(_ findings: [Finding]) async -> [Finding] {
        guard let cli, let output = await Self.run(cli, ["system", "df", "--format", "{{json .}}"]) else { return findings }
        return Self.annotate(findings, with: Self.parse(output))
    }

    static func annotate(_ findings: [Finding], with usage: [Usage]) -> [Finding] {
        let reclaimable = usage.reduce(0) { $0 + $1.reclaimable }
        guard !usage.isEmpty else { return findings }
        let breakdown = usage.map { u in
            "\(u.type) \(format(u.size))" + (u.reclaimable > 0 ? " (\(format(u.reclaimable)) unused)" : "")
        }.joined(separator: " · ")
        let commands = usage.filter { $0.reclaimable > 0 }.compactMap { u -> String? in
            guard let (label, command) = command(for: u.type) else { return nil }
            return "\(label), \(format(u.reclaimable))\t\(command)"
        }
        let advice = reclaimable > 0
            ? " Docker reports \(format(reclaimable)) it can free itself; use its commands below instead."
            : " Docker reports nothing unused right now."
        var result = findings
        if let i = result.firstIndex(where: { $0.details["rule"] == "docker-vm" }) {
            result[i].details["docker"] = breakdown
            if !commands.isEmpty { result[i].details["commands"] = commands.joined(separator: "\n") }
            result[i].reason += advice
        } else if reclaimable > 0 {
            result.append(Finding(category: .toolCaches, title: "Docker data", owner: "Docker", paths: [],
                                  bytes: reclaimable, safety: .review,
                                  reason: "Space Docker can free with its own commands. KachraClean only explains it; nothing here moves to the Trash.",
                                  details: ["docker": breakdown, "commands": commands.joined(separator: "\n")]))
        }
        return result
    }

    static func command(for type: String) -> (String, String)? {
        switch type {
        case "Images": ("Images no container uses", "docker image prune -a")
        case "Build Cache": ("Build cache", "docker builder prune")
        case "Containers": ("Stopped containers", "docker container prune")
        case "Local Volumes": ("Unused volumes (deletes their data)", "docker volume prune")
        default: nil
        }
    }

    /// One JSON object per line: {"Type":"Images","TotalCount":"5","Size":"2.6GB","Reclaimable":"1.2GB (45%)"}.
    static func parse(_ output: String) -> [Usage] {
        output.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["Type"] as? String else { return nil }
            return Usage(type: type, count: Int("\(object["TotalCount"] ?? "")") ?? 0,
                         size: size(object["Size"] as? String ?? ""),
                         reclaimable: size(object["Reclaimable"] as? String ?? ""))
        }
    }

    /// Docker's decimal sizes: "1.2GB (45%)", "12kB", "0B".
    static func size(_ text: String) -> Int64 {
        let number = text.split(separator: " ").first.map(String.init) ?? ""
        let units: [(String, Double)] = [("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("kB", 1e3), ("KB", 1e3), ("B", 1)]
        for (unit, factor) in units where number.hasSuffix(unit) {
            return Int64((Double(number.dropLast(unit.count)) ?? 0) * factor)
        }
        return 0
    }

    static func format(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    /// Runs a command with a time limit; nil on failure (e.g. Docker isn't running).
    static func run(_ tool: URL, _ arguments: [String], timeout: TimeInterval = 10) async -> String? {
        await Task.detached {
            let process = Process()
            process.executableURL = tool
            process.arguments = arguments
            let out = Pipe()
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return nil }
            let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            timer.cancel()
            return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
        }.value
    }
}
