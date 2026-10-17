import Foundation

/// Turns the known locations in `rules.json` into findings.
struct RuleScanner {
    let rules: RuleSet
    let home: URL
    var avoidProtected = false

    func scan() async -> [Finding] {
        var targets: [(rule: Rule, url: URL)] = []
        for rule in rules.rules {
            for path in rule.paths {
                let url = PathUtil.expand(path, home: home)
                guard PathUtil.exists(url) else { continue }
                if avoidProtected, PathUtil.isProtected(url, home: home) { continue }
                if rule.expandChildren == true {
                    let children = (try? FileManager().contentsOfDirectory(
                        at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
                    )) ?? []
                    targets += children.map { (rule, $0) }
                } else {
                    targets.append((rule, url))
                }
            }
        }

        let sizes = await DiskUsage.allocatedSizes(of: targets.map(\.url))
        var findings: [Finding] = []
        // Rules with several paths become one finding per rule (unless expanded per child).
        var grouped: [String: (rule: Rule, urls: [URL], bytes: Int64)] = [:]
        for (index, target) in targets.enumerated() where sizes[index] > 0 {
            if target.rule.expandChildren == true {
                findings.append(Finding(
                    category: target.rule.category,
                    title: target.url.lastPathComponent,
                    owner: target.rule.owner ?? target.url.lastPathComponent,
                    paths: [target.url.path],
                    bytes: sizes[index],
                    safety: target.rule.safety,
                    reason: target.rule.reason,
                    lastActivity: DiskUsage.lastModified(target.url),
                    details: ["rule": target.rule.id]
                ))
            } else {
                grouped[target.rule.id, default: (target.rule, [], 0)].urls.append(target.url)
                grouped[target.rule.id]!.bytes += sizes[index]
            }
        }
        for (_, entry) in grouped {
            findings.append(Finding(
                category: entry.rule.category,
                title: entry.rule.title,
                owner: entry.rule.owner,
                paths: entry.urls.map(\.path),
                bytes: entry.bytes,
                safety: entry.rule.safety,
                reason: entry.rule.reason,
                lastActivity: entry.urls.compactMap(DiskUsage.lastModified).max(),
                details: ["rule": entry.rule.id]
            ))
        }
        return findings
    }
}
