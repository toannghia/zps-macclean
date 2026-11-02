import XCTest
@testable import MacCleanCore

final class MacCleanCoreTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var temp: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        home = root.appendingPathComponent("home")
        temp = root.appendingPathComponent("tmp")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func file(_ path: String, in base: URL? = nil, daysOld: Int = 1, bytes: Int = 8192) throws -> URL {
        let url = (base ?? home).appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
        let date = Date().addingTimeInterval(-Double(daysOld) * 86_400)
        var current = url
        while current.path.hasPrefix(root.path), current != (base ?? home) {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: current.path)
            current = current.deletingLastPathComponent()
        }
        return url
    }

    private func environment(running: [String] = [], open: Set<String>? = []) -> CleanEnvironment {
        CleanEnvironment(home: home, tempRoot: temp, runningCommands: { running }, openPaths: { open })
    }

    private func scan(_ env: CleanEnvironment? = nil, options: ScanOptions = ScanOptions()) -> [String: CleanItem] {
        let items = (try? JunkScanner(env: env ?? environment()).scan(options: options)) ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func testChromeCloneInUseIsKeptAndOthersDeleted() throws {
        let used = try file("X/com.google.Chrome.code_sign_clone/code_sign_clone.AAA/Chrome.bundle/bin", in: temp)
        let stale = try file("X/com.google.Chrome.code_sign_clone/code_sign_clone.BBB/Chrome.bundle/bin", in: temp)
        let usedDir = used.deletingLastPathComponent().deletingLastPathComponent()
        let env = environment(open: [PathGuard.normalized(usedDir.path)])

        let item = try XCTUnwrap(scan(env)["browser.clones"])
        XCTAssertEqual(item.action.urls.count, 1)
        XCTAssertEqual(item.skippedInUse, 1)
        XCTAssertEqual(item.risk, .safe)

        let report = Cleaner(env: env, projectRoots: []).clean([item])
        XCTAssertTrue(report.failures.isEmpty, "\(report.failures)")
        XCTAssertTrue(exists(used))
        XCTAssertFalse(exists(stale))
    }

    func testHistoryIsNeverOfferedEvenWhenOld() throws {
        let history = [
            ".claude/projects/p/old-session.jsonl", ".claude/projects/p/memory/MEMORY.md", ".claude/file-history/s/f",
            ".gemini/antigravity/conversations/a.pb", ".gemini/antigravity/brain/a/plan.md", ".gemini/tmp/h/chats/c.json",
            ".gemini/history/x", ".codex/sessions/2026/01/s.jsonl",
            "Library/Application Support/Claude/vm_bundles/claudevm.bundle/sessiondata.img",
            "Library/Developer/Xcode/Archives/2024/App.xcarchive/data", ".Trash/file",
            "Library/Application Support/Code/User/workspaceStorage/w/state.vscdb",
        ]
        let guardrail = PathGuard(home: home, tempRoot: temp, projectRoots: [])
        for path in history {
            let url = try file(path, daysOld: 500)
            XCTAssertFalse(guardrail.allows(url), path)
        }
        let targets = scan().values.flatMap(\.action.urls)
        for path in history {
            XCTAssertFalse(targets.contains { home.appendingPathComponent(path).path.hasPrefix($0.path) }, path)
        }
    }

    func testRecentlyWrittenDataIsKept() throws {
        try file("Library/Caches/Homebrew/fresh", daysOld: 0)
        XCTAssertNil(scan()["brew.cache"])
    }

    func testFileOpenedAfterScanIsKept() throws {
        let cache = try file("Library/Caches/Homebrew/pkg")
        let item = try XCTUnwrap(scan()["brew.cache"])
        let busy = environment(open: [PathGuard.normalized(cache.deletingLastPathComponent().path)])
        let report = Cleaner(env: busy, projectRoots: []).clean([item])
        XCTAssertEqual(report.cleanedCount, 0)
        XCTAssertTrue(exists(cache))
    }

    func testUnknownOpenFilesStopsEverything() throws {
        let cache = try file("Library/Caches/Homebrew/pkg")
        let item = try XCTUnwrap(scan()["brew.cache"])
        XCTAssertThrowsError(try JunkScanner(env: environment(open: nil)).scan(options: ScanOptions()))
        _ = Cleaner(env: environment(open: nil), projectRoots: []).clean([item])
        XCTAssertTrue(exists(cache))
    }

    func testProjectWithRunningProcessIsSkipped() throws {
        let projects = root.appendingPathComponent("projects")
        try file("old/package.json", in: projects, daysOld: 90)
        try file("old/node_modules/a/index.js", in: projects, daysOld: 90, bytes: 11_000_000)
        let env = environment(open: [PathGuard.normalized(projects.appendingPathComponent("old").path)])
        XCTAssertTrue(scan(env, options: ScanOptions(projectRoots: [projects])).values.allSatisfy { $0.category != .projects })
    }

    func testCredentialsAreNotMatchedByAnyRule() throws {
        let creds = try file(".gemini/oauth_creds.json", daysOld: 400)
        try file(".gemini/logs/junk", daysOld: 400)
        let urls = scan().values.flatMap(\.action.urls).map(\.path)
        XCTAssertFalse(urls.contains { $0.hasPrefix(creds.path) })
        XCTAssertTrue(urls.contains { $0.hasSuffix(".gemini/logs") })
    }

    func testRunningAppBlocksItemAtScanAndAgainAtClean() throws {
        let cache = try file("Library/Application Support/Claude/Cache/data")
        XCTAssertTrue(try XCTUnwrap(scan(environment(running: ["/Applications/Claude.app/Contents/MacOS/Claude"]))["claude.cache"]).isBlocked)

        // Quét khi app tắt, người dùng mở app trước khi bấm dọn.
        let item = try XCTUnwrap(scan()["claude.cache"])
        XCTAssertFalse(item.isBlocked)
        let report = Cleaner(env: environment(running: ["/Applications/Claude.app/x"]), projectRoots: []).clean([item])
        XCTAssertEqual(report.cleanedCount, 0)
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertTrue(exists(cache))
    }

    func testOldExtensionVersionsKeepHighest() {
        let outdated = ExtensionVersions.outdated([
            "bradlc.vscode-tailwindcss-0.14.29", "bradlc.vscode-tailwindcss-0.16.0",
            "ms.python-2025.2.0-darwin-arm64", "ms.python-2025.10.0-darwin-arm64",
            "ms.python-2025.2.0-linux-x64", "solo.ext-1.0.0", ".obsolete", "extensions.json",
        ])
        XCTAssertEqual(outdated, ["bradlc.vscode-tailwindcss-0.14.29", "ms.python-2025.2.0-darwin-arm64"])
    }

    func testProjectScannerRequiresMarkerAndInactivity() throws {
        let projects = root.appendingPathComponent("projects")
        try file("old/package.json", in: projects, daysOld: 90)
        try file("old/node_modules/a/index.js", in: projects, daysOld: 90, bytes: 11_000_000)
        try file("active/package.json", in: projects, daysOld: 0)
        try file("active/node_modules/a/index.js", in: projects, daysOld: 90, bytes: 11_000_000)
        // Tên "build" và "target" không có file nhận diện thì là thư mục của người dùng.
        try file("assets/package.json", in: projects, daysOld: 90)
        try file("assets/build/photo.raw", in: projects, daysOld: 90, bytes: 11_000_000)

        let items = scan(options: ScanOptions(projectRoots: [projects])).values.filter { $0.category == .projects }
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.action.urls.map(\.lastPathComponent), ["node_modules"])
        XCTAssertEqual(items.first?.title, "old")
    }

    func testGuardRefusesProtectedAndOutsidePaths() throws {
        let guardrail = PathGuard(home: home, tempRoot: temp, projectRoots: [])
        for path in ["", "Library", "Documents", ".ssh/id_rsa", ".gemini/oauth_creds.json", ".claude/projects"] {
            XCTAssertFalse(guardrail.allows(home.appendingPathComponent(path)), path)
        }
        XCTAssertFalse(guardrail.allows(home.appendingPathComponent(".claude/projects/p/memory")))
        XCTAssertFalse(guardrail.allows(URL(fileURLWithPath: "/etc/hosts")))
        XCTAssertFalse(guardrail.allows(root.appendingPathComponent("outside/data")))
        XCTAssertTrue(guardrail.allows(home.appendingPathComponent("Library/Caches/Homebrew")))
    }

    func testGuardRefusesEscapeThroughSymlinkedParent() throws {
        let outside = try file("secret/data", in: root)
        let link = home.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside.deletingLastPathComponent())
        let guardrail = PathGuard(home: home, tempRoot: temp, projectRoots: [])
        XCTAssertFalse(guardrail.allows(link.appendingPathComponent("data")))
    }

    func testGlobDoesNotFollowSymlinkedDirectory() throws {
        let outside = try file("real/Cache/data", in: root)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Library/Application Support"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: home.appendingPathComponent("Library/Application Support/Claude"),
            withDestinationURL: outside.deletingLastPathComponent().deletingLastPathComponent())
        XCTAssertNil(scan()["claude.cache"])
    }

    func testDockerParsingAndNoVolumePrune() throws {
        let output = """
        {"Active":"12","Reclaimable":"33.62GB (68%)","Size":"49.25GB","TotalCount":"43","Type":"Images"}
        {"Active":"6","Reclaimable":"2.564GB (69%)","Size":"3.683GB","TotalCount":"78","Type":"Local Volumes"}
        {"Active":"0","Reclaimable":"21.4GB","Size":"31.77GB","TotalCount":"344","Type":"Build Cache"}
        """
        let usage = try XCTUnwrap(DockerUsage.parse(output, executable: "/x/docker"))
        XCTAssertEqual(usage.buildCacheReclaimable, 21_400_000_000)
        for item in JunkScanner.dockerItems(usage) {
            guard case .command(_, let args) = item.action else { return XCTFail() }
            XCTAssertEqual(args, ["builder", "prune", "-af"])
        }
    }

    func testEveryRuleAndArtifactHasAGuide() {
        for rule in RuleBook.all where !rule.patterns.isEmpty {
            XCTAssertNotNil(Guides.guide(forItem: rule.id), rule.id)
        }
        XCTAssertNotNil(Guides.guide(forItem: "docker.builder"))
        for artifact in ProjectScanner.artifacts {
            XCTAssertNotNil(Guides.artifactGuide(named: artifact.name), artifact.name)
        }
    }

    func testAntigravityMediaIsCleanedButConversationStays() throws {
        let brain = ".gemini/antigravity/brain/abc"
        let recording = try file("\(brain)/test_run_1.webp", daysOld: 30)
        let referenced = try file("\(brain)/demo_2.webp", daysOld: 30)
        let note = try file("\(brain)/walkthrough.md.resolved.3", daysOld: 30)
        try "![demo](demo_2.webp)".write(to: note, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -86_400 * 30)],
                                              ofItemAtPath: note.deletingLastPathComponent().path)
        let recent = try file("\(brain)/fresh_3.webp", daysOld: 2)
        let temp = try file("\(brain)/.tempmediaStorage/media_1.png", daysOld: 30)
        let click = try file("\(brain)/.system_generated/click_feedback/click_1.png", daysOld: 30)
        let shared = try file(".gemini/antigravity-ide/brain/tempmediaStorage/media_2.jpg", daysOld: 30)
        let messages = try file("\(brain)/.system_generated/messages/m.json", daysOld: 30)
        let plan = try file("\(brain)/implementation_plan.md", daysOld: 30)
        let artifact = try file("\(brain)/design.png", daysOld: 30)

        let found = scan()
        let items = try [XCTUnwrap(found["antigravity.media"]), XCTUnwrap(found["antigravity.recordings"])]
        let report = Cleaner(env: environment(), projectRoots: []).clean(items)
        XCTAssertTrue(report.failures.isEmpty, "\(report.failures)")

        for url in [recording, temp, click, shared] { XCTAssertFalse(exists(url), url.path) }
        for url in [referenced, recent, note, messages, plan, artifact] { XCTAssertTrue(exists(url), url.path) }
    }

    func testGuardKeepsAntigravityTextProtected() {
        let guardrail = PathGuard(home: home, tempRoot: temp, projectRoots: [])
        for path in [".gemini/antigravity/brain/abc", ".gemini/antigravity/brain/abc/task.md",
                     ".gemini/antigravity/brain/abc/.tempmediaStorage",
                     ".gemini/antigravity/brain/abc/.system_generated/messages/m.json",
                     ".gemini/antigravity/brain/abc/.system_generated/logs/a.png",
                     ".gemini/antigravity-ide/brain/abc/plan.md", ".gemini/antigravity-ide/conversations/a.pb"] {
            XCTAssertFalse(guardrail.allows(home.appendingPathComponent(path)), path)
        }
        XCTAssertTrue(guardrail.allows(home.appendingPathComponent(".gemini/antigravity/brain/abc/run.webp")))
    }

    func testClonesAreSizedAsOneCopyNotASum() throws {
        try file("X/com.google.Chrome.code_sign_clone/code_sign_clone.A/bin", in: temp, bytes: 1_000_000)
        try file("X/com.google.Chrome.code_sign_clone/code_sign_clone.B/bin", in: temp, bytes: 1_000_000)
        let item = try XCTUnwrap(scan()["browser.clones"])
        XCTAssertEqual(item.action.urls.count, 2)
        XCTAssertLessThan(item.size, 1_500_000)
    }

    func testDomSnapshotInTempMediaIsAllowed() {
        let guardrail = PathGuard(home: home, tempRoot: temp, projectRoots: [])
        XCTAssertTrue(guardrail.allows(home.appendingPathComponent(".gemini/antigravity/brain/abc/.tempmediaStorage/dom_1.txt")))
    }

    func testOnlyUnusedSystemImagesAreOffered() throws {
        let config = try file(".android/avd/Pixel.avd/config.ini")
        try "image.sysdir.1=system-images/android-36/google_apis_playstore/arm64-v8a/\n"
            .write(to: config, atomically: true, encoding: .utf8)
        try file("Library/Android/sdk/system-images/android-36/google_apis_playstore/arm64-v8a/system.img")
        try file("Library/Android/sdk/system-images/android-35/tablet/arm64-v8a/system.img")
        let item = try XCTUnwrap(scan()["android.unusedimages"])
        XCTAssertEqual(item.action.urls.map(\.lastPathComponent), ["tablet"])
    }

    func testSystemImagesKeptWhenNoEmulatorConfigIsReadable() throws {
        try file("Library/Android/sdk/system-images/android-35/tablet/arm64-v8a/system.img")
        XCTAssertNil(scan()["android.unusedimages"])
    }

    func testSharedTempKeepsClaudeSessionAndCanBeCleaned() throws {
        let shared = root.appendingPathComponent("tmp/shared")
        let session = try file("claude-501/scratch/notes", in: shared, daysOld: 20)
        let stale = try file("chrome_profile/data", in: shared, daysOld: 20)
        let item = try XCTUnwrap(scan()["temp.shared"])
        XCTAssertEqual(item.action.urls.map(\.lastPathComponent), ["chrome_profile"])
        let report = Cleaner(env: environment(), projectRoots: []).clean([item])
        XCTAssertTrue(report.failures.isEmpty, "\(report.failures)")
        XCTAssertFalse(exists(stale))
        XCTAssertTrue(exists(session))
    }

    private func entry(_ pid: Int32, user: String = "me", path: String, memory: Int64 = 100) -> ProcessEntry {
        ProcessMonitor.parse(table: "\(pid) 1 \(user) 1.5 1 \(path)", commands: "\(pid) \(path) --flag")
            .map { $0 }.first.map { _ in
                ProcessMonitor.parse(table: "\(pid) 1 \(user) 1.5 1 \(path)", commands: "\(pid) \(path) --flag") { _ in memory }[0]
            }!
    }

    func testProcessTableParsesPathsWithSpacesAndDecimalComma() {
        let result = ProcessMonitor.parse(
            table: "  123     1 me    12,5  2048 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome\n",
            commands: "123 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome --type=gpu\n")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].cpu, 12.5)
        XCTAssertEqual(result[0].memory, 2_097_152)
        XCTAssertEqual(result[0].name, "Google Chrome")
        XCTAssertTrue(result[0].command.hasSuffix("--type=gpu"))
    }

    func testHelpersGroupUnderOutermostApp() {
        let helper = "/Applications/Google Chrome.app/Contents/Frameworks/X.framework/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"
        let groups = ProcessMonitor.group([
            entry(10, path: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", memory: 100),
            entry(11, path: helper, memory: 50),
            entry(12, path: "/opt/homebrew/bin/node"),
            entry(13, path: "/opt/homebrew/bin/node"),
        ], currentUser: "me", currentPID: 999)
        let chrome = groups.first { $0.name == "Google Chrome" }
        XCTAssertEqual(chrome?.processes.count, 2)
        XCTAssertEqual(chrome?.memory, 150)
        XCTAssertEqual(chrome?.bundlePath, "/Applications/Google Chrome.app")
        XCTAssertEqual(groups.first { $0.name == "node" }?.processes.count, 2)
        XCTAssertNotNil(groups.first { $0.name == "node" }?.warning)
    }

    func testSystemAndForeignProcessesAreProtected() {
        func reason(_ item: ProcessEntry) -> String? {
            ProcessMonitor.protection(of: item, currentUser: "me", currentPID: 999)
        }
        XCTAssertNotNil(reason(entry(1, path: "/sbin/launchd")))
        XCTAssertNotNil(reason(entry(50, path: "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock")))
        XCTAssertNotNil(reason(entry(51, user: "root", path: "/opt/homebrew/bin/node")))
        XCTAssertNotNil(reason(entry(999, path: "/Users/me/app")))
        XCTAssertNotNil(reason(entry(52, path: "/Users/me/Applications/ZPS MacClean.app/Contents/MacOS/ZPSMacClean")))
        XCTAssertNotNil(reason(entry(53, path: "/bin/zsh")))
        XCTAssertNil(reason(entry(54, path: "/opt/homebrew/bin/node")))
    }

    func testAppWithSystemHelperDoesNotExposeStopForLockedPart() {
        let groups = ProcessMonitor.group([
            entry(60, user: "root", path: "/Applications/Docker.app/Contents/MacOS/com.docker.vmnetd"),
            entry(61, path: "/Applications/Docker.app/Contents/MacOS/Docker Desktop"),
        ], currentUser: "me", currentPID: 999)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.filter { $0.protection != nil }.count, 1)
        XCTAssertEqual(Set(groups.map(\.id)).count, 2)
    }

    func testStopRefusesProtectedAndReusedPids() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { if child.isRunning { child.terminate() } }

        // /bin là vùng hệ thống nên phải bị từ chối dù cùng người dùng.
        let system = entry(child.processIdentifier, user: NSUserName(), path: "/bin/sleep")
        XCTAssertNotNil(ProcessMonitor.stop(system, force: false))
        XCTAssertTrue(child.isRunning)

        // PID đã thuộc chương trình khác với mẫu đã đọc: không được tắt.
        let reused = entry(child.processIdentifier, user: NSUserName(), path: "/opt/tool/worker")
        XCTAssertNotNil(ProcessMonitor.stop(reused, force: false))
        XCTAssertTrue(child.isRunning)
    }

    func testStopTerminatesOwnUserProcess() throws {
        let copy = root.appendingPathComponent("worker")
        try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: copy.path)
        let child = Process()
        child.executableURL = copy
        child.arguments = ["30"]
        try child.run()
        let target = entry(child.processIdentifier, user: NSUserName(), path: copy.path)
        XCTAssertNil(ProcessMonitor.stop(target, force: false))
        child.waitUntilExit()
        XCTAssertFalse(child.isRunning)
    }

    func testLiveSnapshotAndUsageLookSane() throws {
        let entries = try XCTUnwrap(ProcessMonitor.snapshot())
        XCTAssertGreaterThan(entries.count, 10)
        XCTAssertTrue(entries.contains { $0.pid == getpid() })
        let usage = ProcessMonitor.systemUsage(cpuTotal: 100)
        XCTAssertGreaterThan(usage.memoryUsed, 0)
        XCTAssertLessThanOrEqual(usage.memoryUsed, usage.memoryTotal)
    }

    func testUserAppsInSystemFolderCanBeStoppedButFinderCannot() {
        func reason(_ path: String) -> String? {
            ProcessMonitor.protection(of: entry(70, path: path), currentUser: "me", currentPID: 999)
        }
        XCTAssertNil(reason("/System/Applications/Preview.app/Contents/MacOS/Preview"))
        XCTAssertNil(reason("/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app/Contents/MacOS/Safari"))
        XCTAssertNotNil(reason("/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder"))
    }

    func testRenamedProcessUsesRealPath() {
        let result = ProcessMonitor.parse(table: "80 1 me 0.0 10 next-server (v15.5.28)",
                                          commands: "80 next-server (v15.5.28)",
                                          realPath: { _ in "/opt/homebrew/bin/node" })
        XCTAssertEqual(result[0].path, "/opt/homebrew/bin/node")
        XCTAssertEqual(result[0].command, "next-server (v15.5.28)")
        XCTAssertNil(ProcessMonitor.protection(of: result[0], currentUser: "me", currentPID: 999))
    }

    func testUnknownRenamedProcessStaysLocked() {
        let result = ProcessMonitor.parse(table: "81 1 me 0.0 10 mystery", commands: "81 mystery")
        XCTAssertNotNil(ProcessMonitor.protection(of: result[0], currentUser: "me", currentPID: 999))
    }

    func testSystemGroupsHiddenByDefaultAndSearchable() {
        let groups = ProcessMonitor.group([
            entry(90, path: "/opt/homebrew/bin/node"),
            entry(91, user: "root", path: "/usr/sbin/cfprefsd"),
        ], currentUser: "me", currentPID: 999)
        XCTAssertEqual(ProcessMonitor.visible(groups, includeSystem: false, query: "").map(\.name), ["node"])
        XCTAssertEqual(ProcessMonitor.visible(groups, includeSystem: true, query: "").count, 2)
        XCTAssertEqual(ProcessMonitor.visible(groups, includeSystem: true, query: "91").map(\.name), ["cfprefsd"])
        XCTAssertTrue(ProcessMonitor.visible(groups, includeSystem: false, query: "cfprefsd").isEmpty)
    }
}
