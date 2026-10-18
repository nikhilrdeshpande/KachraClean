import Foundation
import Testing
@testable import KachraCore

/// A throwaway directory tree; removed when the value goes out of scope.
final class Sandbox {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kachra-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func file(_ path: String, bytes: Int = 16, modified: Date? = nil) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x2A, count: bytes).write(to: url)
        if let modified { try touch(url, modified) }
        return url
    }

    func touch(_ url: URL, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }
}

let longAgo = Date().addingTimeInterval(-200 * 86_400)

@Suite struct ProjectScannerTests {
    @Test func classifiesArtifactsOnlyWithMarkers() throws {
        let box = try Sandbox()
        try box.file("app/package.json")
        try box.file("app/node_modules/left-pad/index.js")
        try box.file("loose/node_modules/x.js")  // no package.json → not a project
        try box.file("py/.venv/pyvenv.cfg")
        try box.file("rust/Cargo.toml")
        try box.file("rust/target/debug/bin")
        try box.file("notrust/target/file")

        #expect(ProjectScanner.classify(box.root.appendingPathComponent("app/node_modules")) == .nodeModules)
        #expect(ProjectScanner.classify(box.root.appendingPathComponent("loose/node_modules")) == nil)
        #expect(ProjectScanner.classify(box.root.appendingPathComponent("py/.venv")) == .pythonEnv)
        #expect(ProjectScanner.classify(box.root.appendingPathComponent("rust/target")) == .rustTarget)
        #expect(ProjectScanner.classify(box.root.appendingPathComponent("notrust/target")) == nil)
    }

    @Test func idleProjectWithLockfileIsSafeActiveIsReview() async throws {
        let box = try Sandbox()
        for name in ["idle", "active"] {
            try box.file("\(name)/package.json")
            try box.file("\(name)/package-lock.json")
            try box.file("\(name)/node_modules/dep/index.js", bytes: 8_192)
        }
        for path in ["idle/package.json", "idle/package-lock.json", "idle/node_modules", "idle"] {
            try box.touch(box.root.appendingPathComponent(path), longAgo)
        }

        let findings = await ProjectScanner(options: .init(roots: [box.root]), home: box.root).scan()
        let idle = try #require(findings.first { $0.owner == "idle" })
        let active = try #require(findings.first { $0.owner == "active" })
        #expect(idle.safety == .safe)
        #expect(idle.details["lockfile"] == "package-lock.json")
        #expect(active.safety == .review)
        #expect(idle.bytes > 0)
    }

    @Test func noLockfileNeedsReview() async throws {
        let box = try Sandbox()
        try box.file("proj/package.json", modified: longAgo)
        try box.file("proj/node_modules/dep/index.js")
        let findings = await ProjectScanner(options: .init(roots: [box.root]), home: box.root).scan()
        #expect(findings.first?.safety == .review)
    }

    @Test func doesNotDescendIntoArtifacts() async throws {
        let box = try Sandbox()
        try box.file("proj/package.json")
        try box.file("proj/node_modules/inner/package.json")
        try box.file("proj/node_modules/inner/node_modules/deep/index.js")
        let findings = await ProjectScanner(options: .init(roots: [box.root]), home: box.root).scan()
        #expect(findings.count == 1)
    }

    @Test func groupsBytecodeByProjectRoot() async throws {
        let box = try Sandbox()
        try box.file("svc/pyproject.toml")
        try box.file("svc/pkg/a/__pycache__/m.pyc", bytes: 4_096)
        try box.file("svc/pkg/b/__pycache__/n.pyc", bytes: 4_096)
        let findings = await ProjectScanner(options: .init(roots: [box.root]), home: box.root).scan()
        #expect(findings.count == 1)
        #expect(findings.first?.paths.count == 2)
        #expect(findings.first?.safety == .safe)
    }
}

@Suite struct DuplicateScannerTests {
    @Test func findsIdenticalCopiesAndKeepsTheOriginal() async throws {
        let box = try Sandbox()
        let content = Data((0..<300_000).map { UInt8($0 % 251) })
        let paths = ["deed.pdf", "deed (1).pdf", "archive (2)/deed.pdf"]
        for p in paths {
            let url = box.root.appendingPathComponent(p)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url)
        }
        // Same size, different bytes: must not be reported.
        var other = content
        other[150_000] = 0
        try other.write(to: box.root.appendingPathComponent("different.pdf"))

        let findings = await DuplicateScanner(roots: [box.root]).scan()
        let group = try #require(findings.first)
        #expect(findings.count == 1)
        #expect(group.details["copies"] == "3")
        #expect(group.details["keep"]?.hasSuffix("/deed.pdf") == true)
        #expect(group.details["keep"]?.contains("(2)") == false)
        #expect(group.paths.count == 2)
        #expect(group.safety == .review)
    }

    @Test func copySuffixDetection() {
        #expect(DuplicateScanner.hasCopySuffix(URL(fileURLWithPath: "/d/file (3).zip")))
        #expect(DuplicateScanner.hasCopySuffix(URL(fileURLWithPath: "/d/folder (1)/file.zip")))
        #expect(DuplicateScanner.hasCopySuffix(URL(fileURLWithPath: "/d/file copy.txt")))
        #expect(!DuplicateScanner.hasCopySuffix(URL(fileURLWithPath: "/d/report 2026.pdf")))
    }
}

@Suite struct CleanerTests {
    @Test func refusesDangerousPaths() throws {
        let box = try Sandbox()
        let cleaner = Cleaner(home: box.root, dryRun: true)
        try box.file("Library/Caches/app/blob")
        try box.file("Documents/x")

        #expect(cleaner.refusal(for: URL(fileURLWithPath: "/etc"), category: .appCaches) != nil)
        #expect(cleaner.refusal(for: box.root, category: .appCaches) != nil)
        #expect(cleaner.refusal(for: box.root.appendingPathComponent("Documents"), category: .appCaches) != nil)
        #expect(cleaner.refusal(for: box.root.appendingPathComponent("Library/Caches"), category: .appCaches) != nil)
        #expect(cleaner.refusal(for: box.root.appendingPathComponent("Library/Caches/app"), category: .appCaches) == nil)
        #expect(cleaner.refusal(for: box.root.appendingPathComponent(".Trash/x"), category: .trash) != nil)
        #expect(cleaner.refusal(for: URL(fileURLWithPath: "/Applications/Foo.app/Contents"), category: .apps) != nil)
    }

    @Test func dryRunTouchesNothing() throws {
        let box = try Sandbox()
        let target = try box.file("Library/Caches/app/blob")
        let finding = Finding(category: .appCaches, title: "app", paths: [target.deletingLastPathComponent().path],
                              bytes: 16, safety: .safe, reason: "test")
        let outcomes = Cleaner(home: box.root, dryRun: true).clean([finding])
        #expect(outcomes.allSatisfy { $0.error == nil && $0.trashedTo == nil })
        #expect(FileManager.default.fileExists(atPath: target.path))
    }
}

@Suite struct UndoTests {
    @Test func restoreMovesItemsBack() throws {
        let box = try Sandbox()
        let original = try box.file("Library/Caches/app/blob")
        let parked = try box.file("Parked/blob")
        try FileManager.default.removeItem(at: original)
        let outcome = Cleaner.Outcome(findingID: "x", path: original.path, trashedTo: parked.path, error: nil)
        let restored = Cleaner(home: box.root).restore([outcome])
        #expect(restored.count == 1)
        #expect(FileManager.default.fileExists(atPath: original.path))
        #expect(!FileManager.default.fileExists(atPath: parked.path))
    }
}

@Suite struct RuleTests {
    @Test func bundledRulesLoadAndAreWellFormed() throws {
        let rules = try RuleSet.bundled()
        #expect(rules.rules.count > 20)
        #expect(Set(rules.rules.map(\.id)).count == rules.rules.count, "rule ids must be unique")
        for rule in rules.rules {
            #expect(!rule.reason.isEmpty)
            #expect(rule.paths.allSatisfy { $0.hasPrefix("~/") }, "rules must stay inside the home folder")
        }
    }

    @Test func purgeableIsImportantMinusFree() {
        let v = VolumeInfo(totalBytes: 100, freeBytes: 30, availableForImportantUsage: 37)
        #expect(v.purgeableBytes == 7)
    }
}

@Suite struct ModelAndLargeFileTests {
    @Test func huggingFaceSharedBlobsAreAttributedAndKept() async throws {
        let box = try Sandbox()
        let hub = box.root.appendingPathComponent(".cache/huggingface/hub")
        let blobs = hub.appendingPathComponent("blobs")
        try box.file(".cache/huggingface/hub/blobs/aaa", bytes: 40_960)  // only model A
        try box.file(".cache/huggingface/hub/blobs/shared", bytes: 8_192)  // A and B
        try box.file(".cache/huggingface/hub/blobs/orphan", bytes: 4_096)  // nobody
        let fm = FileManager.default
        for (repo, files) in [("models--org--a", ["aaa", "shared"]), ("models--org--b", ["shared"])] {
            let snap = hub.appendingPathComponent("\(repo)/snapshots/rev1")
            try fm.createDirectory(at: snap, withIntermediateDirectories: true)
            for f in files {
                try fm.createSymbolicLink(at: snap.appendingPathComponent(f + ".bin"),
                                          withDestinationURL: blobs.appendingPathComponent(f))
            }
        }
        let findings = await ModelScanner(home: box.root, environment: [:]).scan()
        let a = try #require(findings.first { $0.title == "org/a" })
        #expect(a.paths.contains { $0.hasSuffix("blobs/aaa") })
        #expect(!a.paths.contains { $0.hasSuffix("blobs/shared") }, "shared blob must be kept")
        #expect(a.details["shared"] != nil)
        let orphan = try #require(findings.first { $0.title.contains("Unreferenced") })
        #expect(orphan.safety == .safe)
        #expect(orphan.paths.count == 1)
    }

    @Test func classifiesLargeFileKinds() {
        #expect(LargeFileScanner.kind(of: URL(fileURLWithPath: "/x/clip.mp4")) == .video)
        #expect(LargeFileScanner.kind(of: URL(fileURLWithPath: "/x/Installer.dmg")) == .diskImage)
        #expect(LargeFileScanner.kind(of: URL(fileURLWithPath: "/x/data.parquet")) == .dataset)
        #expect(LargeFileScanner.kind(of: URL(fileURLWithPath: "/x/w.safetensors")) == .modelWeights)
        #expect(LargeFileScanner.kind(of: URL(fileURLWithPath: "/x/notes.txt")) == .other)
        #expect(LargeFileScanner.modelFolder(for: URL(fileURLWithPath: "/c/checkpoints/x.safetensors")) == nil)
        #expect(LargeFileScanner.displayName(for: URL(fileURLWithPath: "/a/qwen-seed1/model/model.safetensors"))
            == "qwen-seed1 · model.safetensors")
    }
}

@Suite struct SecurityTests {
    @Test func cleanerRefusesCredentialsAndProtectedAreas() throws {
        let box = try Sandbox()
        let cleaner = Cleaner(home: box.root, dryRun: true)
        for path in [".cache/huggingface/token", ".ssh/id_ed25519", "Library/Keychains/login.keychain-db",
                     "Library/Mobile Documents/com~apple~CloudDocs/big.mov", "code/certs/server.pem"] {
            try box.file(path)
            #expect(cleaner.refusal(for: box.root.appendingPathComponent(path), category: .models) != nil, "\(path)")
        }
    }

    @Test func cleanerChecksEachCategoryCleansItsOwnKind() throws {
        let box = try Sandbox()
        let cleaner = Cleaner(home: box.root, dryRun: true)
        try box.file("Documents/report/a.txt")
        try box.file("proj/package.json")
        try box.file("proj/node_modules/x/index.js")
        try box.file("Library/Logs/app/log.txt")
        func refused(_ path: String, _ category: KachraCore.Category) -> Bool {
            cleaner.refusal(for: box.root.appendingPathComponent(path), category: category) != nil
        }
        #expect(refused("Documents/report", .appCaches))
        #expect(refused("Documents/report", .projectArtifacts))
        #expect(!refused("proj/node_modules", .projectArtifacts))
        #expect(refused("Documents/report", .largeFiles), "large files are files, never folders")
        #expect(!refused("Documents/report/a.txt", .largeFiles))
        #expect(!refused("Library/Logs/app", .logs))
        #expect(refused("Library/Logs/app", .appCaches))
        #expect(refused("Documents/report", .apps))
        #expect(cleaner.refusal(for: URL(fileURLWithPath: "/Applications/A.app/Contents/Helper.app"), category: .apps) != nil)
    }

    @Test func cacheScannerSkipsTokensAndReviewsDotCache() async throws {
        let box = try Sandbox()
        try box.file("Library/Caches/com.example.editor/data", bytes: 8_192)
        try box.file(".cache/huggingface/token")
        try box.file(".cache/huggingface/stored_tokens")
        try box.file(".cache/huggingface/hub/models--a--b/x")
        try box.file(".cache/sometool/blob", bytes: 8_192)
        let hub = box.root.appendingPathComponent(".cache/huggingface/hub").path
        let findings = await AppCacheScanner(home: box.root, claimed: [hub]).scan()
        let paths = findings.flatMap(\.paths)
        #expect(!paths.contains { $0.hasSuffix("token") || $0.hasSuffix("stored_tokens") })
        #expect(findings.first { $0.paths.first?.hasSuffix(".cache/sometool") == true }?.safety == .review)
        #expect(findings.first { $0.paths.first?.hasSuffix("com.example.editor") == true }?.safety == .safe)
    }

    @Test func huggingFaceIgnoresLinksOutsideTheCache() async throws {
        let box = try Sandbox()
        let mine = try box.file("Documents/thesis.pdf", bytes: 8_192)
        let snap = box.root.appendingPathComponent(".cache/huggingface/hub/models--org--m/snapshots/r1")
        try FileManager.default.createDirectory(at: snap, withIntermediateDirectories: true)
        try box.file(".cache/huggingface/hub/blobs/w", bytes: 8_192)
        try FileManager.default.createSymbolicLink(at: snap.appendingPathComponent("w.bin"),
            withDestinationURL: box.root.appendingPathComponent(".cache/huggingface/hub/blobs/w"))
        try FileManager.default.createSymbolicLink(at: snap.appendingPathComponent("notes.pdf"), withDestinationURL: mine)
        let findings = await ModelScanner(home: box.root, environment: [:]).scan()
        let model = try #require(findings.first { $0.title == "org/m" })
        #expect(!findings.flatMap(\.paths).contains { $0.hasSuffix("thesis.pdf") })
        #expect(model.paths.contains { $0.hasSuffix("blobs/w") })
        #expect(model.details["external"] != nil)
    }

    @Test func ollamaDigestsCannotEscapeTheBlobFolder() async throws {
        let box = try Sandbox()
        let hex = String(repeating: "a", count: 64)
        #expect(ModelScanner.blobName(forDigest: "sha256:\(hex)") == "sha256-\(hex)")
        #expect(ModelScanner.blobName(forDigest: "sha256:../../../Documents/x") == nil)
        #expect(ModelScanner.blobName(forDigest: "../../Documents") == nil)

        try box.file("Documents/x", bytes: 8_192)
        let manifest = box.root.appendingPathComponent(".ollama/models/manifests/registry/library/evil/latest")
        try FileManager.default.createDirectory(at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"layers":[{"digest":"sha256:../../../../Documents/x"}]}"#.utf8).write(to: manifest)
        let findings = await ModelScanner(home: box.root, environment: [:]).scan()
        #expect(!findings.flatMap(\.paths).contains { $0.hasSuffix("Documents/x") })
    }

    @Test func appIdentifiersAreUsedOnlyAsPlainNames() {
        #expect(AppScanner.isPlainBundleID("com.example.App-2"))
        #expect(!AppScanner.isPlainBundleID("../../Documents/Work"))
        #expect(!AppScanner.isPlainBundleID("com..example"))
        #expect(!AppScanner.isPlainBundleID("single"))
        #expect(AppScanner.isOwnFolderName("Visual Studio Code"))
        #expect(!AppScanner.isOwnFolderName("Google"))
        #expect(!AppScanner.isOwnFolderName("a/b"))
    }

    @Test func strayComponentFolderDoesNotClaimItsParent() throws {
        let box = try Sandbox()
        try box.file("Documents/work/vae/x.safetensors")
        try box.file("Documents/work/notes.txt")
        #expect(LargeFileScanner.modelFolder(for: box.root.appendingPathComponent("Documents/work/vae/x.safetensors")) == nil)
        try box.file("models/flux/transformer/0.safetensors")
        try box.file("models/flux/model_index.json")
        #expect(LargeFileScanner.modelFolder(for: box.root.appendingPathComponent("models/flux/transformer/0.safetensors"))?
            .lastPathComponent == "flux")
    }

    @Test func savedReportIsPrivate() throws {
        let box = try Sandbox()
        let url = box.root.appendingPathComponent("state/last-scan.json")
        try ScanReport(findings: [], volume: nil, timings: [:]).save(to: url)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func activityWording() {
        #expect(Activity.describe(days: 0) == "today")
        #expect(Activity.describe(days: 1) == "yesterday")
        #expect(Activity.describe(days: 9) == "9 days ago")
        #expect(Activity.days(since: Date().addingTimeInterval(3_600)) == 0)
    }
}
