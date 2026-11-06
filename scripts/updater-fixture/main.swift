// Compiled ONLY by test-updater-local.sh into disposable app bundles, never into MagDot.
import AppKit
import Sparkle

final class Fixture: NSObject, NSApplicationDelegate {
    var checker: UpdateChecker!
    var observer: NSObjectProtocol?
    var activity = UpdateActivity()
    var handledOffer = false
    var handledReady = false
    var cancelledDownload = false
    var consent = false
    var preparations=0
    var vetoed=false
    var report: URL { URL(fileURLWithPath: Bundle.main.infoDictionary!["FixtureReport"] as! String) }
    var mode: String { Bundle.main.infoDictionary!["FixtureMode"] as! String }
    func record(_ event: String) {
        let data = Data((event + "\n").utf8)
        if !FileManager.default.fileExists(atPath: report.path) { FileManager.default.createFile(atPath: report.path, contents: nil) }
        let handle = try! FileHandle(forWritingTo: report)
        try! handle.seekToEnd(); try! handle.write(contentsOf: data); try! handle.close()
    }
    func require(_ condition: Bool, _ label: String) {
        if !condition { record("FAIL " + label); exit(1) }
        record("PASS " + label)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let info = Bundle.main.infoDictionary!
        let version = info["CFBundleVersion"] as! String
        record("LAUNCHED " + version)
        if version == "9.0.2" {
            require(UserDefaults.standard.string(forKey: "fixtureSetting") == "preserved", "settings preserved")
            require(!UserDefaults.standard.bool(forKey: "checkForUpdates"), "daily preference preserved")
            require(UserDefaults.standard.object(forKey: "SUUpdateGroupIdentifier") == nil, "no installation identifier")
            require(UpdateRelaunch.consume() == (mode != "off"), "one-shot original activation intent restored")
            require(UpdateRelaunch.consume() == nil, "relaunch receipt consumed once")
            record("SUCCESS replaced and relaunched 9.0.1 -> 9.0.2")
            NSApp.terminate(nil); return
        }
        UserDefaults.standard.set("preserved", forKey: "fixtureSetting")
        UserDefaults.standard.set(false, forKey: "checkForUpdates")
        checker = UpdateChecker(confirm: { [unowned self] _, _, button in
            self.record("CONFIRM " + button + " " + String(self.consent))
            return self.consent
        })
        checker.activity = { [unowned self] in self.activity }
        activity.activationIntent = mode != "off"
        activity.controllingLED = mode != "off"
        checker.beforeRestart = { [unowned self] stillAuthorized, completion in
            preparations += 1
            record("PREPARE " + String(preparations))
            require(!checker.permitsTermination(), "quit blocked while preparing")
            if mode == "prepare-failure" && preparations == 1 {
                activity.controllingLED=false; activity.activationIntent=false
                completion(false)
                require(!checker.restartAuthorized, "failed preparation never authorizes install")
                require(UserDefaults.standard.object(forKey: UpdateRelaunch.key) == nil, "failed preparation leaves no receipt")
                DispatchQueue.main.async { self.checker.openUpdate() }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                if self.mode == "stop-cancel" { self.checker.cancel() }
                self.record("RESTORATION acknowledged")
                self.activity.controllingLED=false; self.activity.activationIntent=false
                completion(true)
                if self.mode == "stop-cancel" {
                    self.require(!self.checker.restartAuthorized, "late stop cannot install after cancel")
                    self.require(UserDefaults.standard.object(forKey: UpdateRelaunch.key) == nil, "cancel leaves no relaunch receipt")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.finishCancellation() }
                }
            }
        }
        observer = NotificationCenter.default.addObserver(forName: UpdateChecker.changed, object: checker, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { self?.advance() }
        }
        let base = info["FixtureBaseURL"] as! String
        let update = ReleaseUpdate(version: "9.0.2", archive: URL(string: base + "/MagDot-v9.0.2-macOS-arm64.zip")!,
            length: (info["FixtureArchiveLength"] as! NSNumber).uint64Value,
            feed: URL(string: base + "/appcast.xml")!)
        checker.beginCheck(for: update)
        DispatchQueue.main.asyncAfter(deadline: .now() + 80) { self.record("FAIL timeout: " + self.checker.message); exit(2) }
    }
    func advance() {
        switch checker.phase {
        case .available where !handledOffer:
            handledOffer = true
            consent = false; checker.openUpdate()
            require(checker.phase == .available, "declining download does not start it")
            consent = true; checker.openUpdate()
        case .downloading where mode == "download-cancel" && checker.downloadedBytes > 0 && !cancelledDownload:
                cancelledDownload = true
                require(checker.downloadedBytes > 0, "received archive bytes before cancellation")
                checker.cancel()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.finishCancellation() }
        case .ready where !handledReady:
            handledReady = true
            require(!checker.permitsTermination(), "ordinary quit blocked before restart consent")
            if mode == "staged-cancel" {
                checker.cancel()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.finishCancellation() }
            } else {
                consent = false; checker.openUpdate()
                require(!checker.restartAuthorized, "declining restart keeps old app running")
                consent = true; checker.openUpdate()
            }
        case .idle where mode == "bad-archive" || mode == "bad-feed" || mode == "incompatible":
            require(!checker.restartAuthorized, "failure never authorizes restart")
            record("SPARKLE errors " + checker.failureCodes.map(String.init).joined(separator: ","))
            if mode == "bad-archive" { require(checker.failureCodes.contains(where: { [3001, 3002].contains($0) }), "archive signature rejected") }
            if mode == "bad-feed" { require(!handledOffer && [1000, 1002].contains(checker.failureCode ?? -1), "tampered feed rejected before offering download") }
            if mode == "incompatible" { require(!handledOffer && checker.failureCode == 1001, "OS compatibility rejected before offering download") }
            record("SUCCESS rejected " + mode)
            NSApp.terminate(nil)
        default: break
        }
    }
    func finishCancellation() {
        require(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String == "9.0.1", "cancel retains old app")
        require(checker.permitsTermination(), "cancel disarms install-on-quit")
        record("SUCCESS cancelled " + mode)
        NSApp.terminate(nil)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let checker else { return .terminateNow }
        let allowed = checker.permitsTermination()
        if allowed && mode == "termination-retry" && !vetoed {
            vetoed=true
            record("QUIT injected veto")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self.require(self.checker.primaryEnabled, "termination retry offered")
                self.consent=false; self.checker.openUpdate()
                self.require(self.preparations == 1, "declining retry does not prepare again")
                self.consent=true; self.checker.openUpdate()
            }
            return .terminateCancel
        }
        record(allowed ? "QUIT allowed" : "QUIT blocked")
        return allowed ? .terminateNow : .terminateCancel
    }
}
let app = NSApplication.shared
let fixture = Fixture()
app.delegate = fixture
app.run()
