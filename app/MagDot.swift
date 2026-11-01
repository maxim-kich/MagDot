// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SQLite3
import Darwin
import ServiceManagement
import IOKit

// A custom drawing preserves an adaptive monochrome body and a colored status dot.
final class MenuConnectorView: NSView {
    var isActive = false { didSet { if oldValue != isActive { needsDisplay = true } } }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let origin=NSPoint(x:(bounds.width-18)/2,y:(bounds.height-18)/2)
        NSGraphicsContext.saveGraphicsState()
        let transform=NSAffineTransform();transform.translateX(by:origin.x,yBy:origin.y);transform.scale(by:18.0/22.0);transform.concat()
        NSColor.labelColor.setStroke()
        let body=NSBezierPath(roundedRect:NSRect(x:1.5,y:3.5,width:19,height:12),xRadius:2,yRadius:2);body.lineWidth=1.5;body.stroke()
        let lip=NSBezierPath();lip.move(to:NSPoint(x:4,y:16));lip.line(to:NSPoint(x:4,y:18));lip.line(to:NSPoint(x:18,y:18));lip.line(to:NSPoint(x:18,y:16));lip.lineWidth=1.5;lip.lineJoinStyle = .round;lip.stroke()
        let dot=NSBezierPath(ovalIn:NSRect(x:8.5,y:7,width:5,height:5))
        let green=NSColor(srgbRed:0.1,green:0.8,blue:0.3,alpha:1)
        let amber=NSColor(srgbRed:1,green:0.48,blue:0.08,alpha:1)
        (isActive ? green : amber).setFill();dot.fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

// Read-only, MagSafe-specific IORegistry lookup; never infer from battery charging.
func magSafeConnection() -> Bool? {
#if TESTING
    if let path=ProcessInfo.processInfo.environment["MAGDOT_TEST_CONNECTION_FILE"] {
        guard let value=try? String(contentsOfFile:path,encoding:.utf8) else{return nil}
        return value.trimmingCharacters(in:.whitespacesAndNewlines) == "connected"
    }
    return true
#else
    let matching: [String:Any] = ["IOProviderClass":"IOService", "IOPropertyMatch":["PortType":17]]
    var iterator:io_iterator_t=0
    guard IOServiceGetMatchingServices(kIOMainPortDefault,matching as CFDictionary,&iterator)==KERN_SUCCESS else{return nil}
    defer {IOObjectRelease(iterator)}
    var result:Bool?
    while case let entry=IOIteratorNext(iterator), entry != 0 {
        if let value=IORegistryEntryCreateCFProperty(entry,"ConnectionActive" as CFString,kCFAllocatorDefault,0)?.takeRetainedValue(), CFGetTypeID(value)==CFBooleanGetTypeID() {
            let connected=CFBooleanGetValue((value as! CFBoolean)); result=(result ?? false) || connected
        }
        IOObjectRelease(entry)
    }
    return result
#endif
}
struct ConnectionGate {
    var connected:Bool?
    var pendingStart=false
    var activationEnabled=true
    mutating func observe(_ next:Bool?) -> Bool {
        let changed=next != connected
        if changed {pendingStart = next == true && activationEnabled}
        connected=next
        return changed
    }
    var canRun:Bool {connected == true}
    func iconVisible(hide:Bool)->Bool { !hide || connected != false }
}

func timestamp(_ text: String) -> Double {
    let parser = ISO8601DateFormatter()
    parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = parser.date(from: text) { return date.timeIntervalSince1970 }
    parser.formatOptions = [.withInternetDateTime]
    return parser.date(from: text)?.timeIntervalSince1970 ?? 0
}
struct Turn { let id: String; let thread: String; let status: String; let started: Double; let completed: Double }
struct Tracker {
    var active = Set<String>()
    var finished = [String: Double]()
    mutating func update(_ rows: [Turn], visits: [String: Double], attention: Bool, now: Double, doneDuration: Double = 120, dismissed: Set<String> = []) -> String {
        for row in rows where active.contains(row.id) && row.status == "completed" && row.completed > 0 {
            finished[row.thread] = max(finished[row.thread] ?? 0, row.completed)
        }
        active = Set(rows.filter { $0.status == "running" && now - $0.started < 3600 }.map(\.id))
        finished = finished.filter { thread, completed in
            let restarted = rows.contains { $0.thread == thread && $0.started > completed }
            let seen = dismissed.contains(thread) || (visits[thread] ?? 0) >= completed
            return !restarted && !seen && (doneDuration == 0 || now < completed + doneDuration)
        }
        return attention ? "attention" : !finished.isEmpty ? "finished" : !active.isEmpty ? "working" : "idle"
    }
}
struct DatabaseError: Error {}
func query(_ db: OpaquePointer, _ sql: String) throws -> [[String]] {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw DatabaseError() }
    defer { sqlite3_finalize(statement) }
    var result = [[String]]()
    while true {
        let code = sqlite3_step(statement)
        if code == SQLITE_DONE { return result }
        guard code == SQLITE_ROW else { throw DatabaseError() }
        result.append((0..<sqlite3_column_count(statement)).map { column in
            sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
        })
    }
}
func readT3(observedTurns: Set<String> = []) throws -> ([Turn], [String: Double], Bool, Set<String>) {
    let path = NSHomeDirectory() + "/.t3/userdata/statev2.sqlite"
    var handle: OpaquePointer?
    guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = handle else {
        if let handle { sqlite3_close(handle) }; throw DatabaseError()
    }
    defer { sqlite3_close(db) }
    sqlite3_busy_timeout(db, 150)
    let observed = observedTurns.map { "'" + $0.replacingOccurrences(of:"'",with:"''") + "'" }.joined(separator:",")
    let rows = try query(db, "SELECT p.provider_turn_id,p.thread_id,p.status,p.started_at,p.completed_at FROM orchestration_v2_projection_provider_turns p JOIN orchestration_v2_projection_threads t USING(thread_id) WHERE t.deleted_at IS NULL AND t.archived_at IS NULL AND (p.provider_turn_id IN (\(observed.isEmpty ? "NULL" : observed)) OR p.status='running' OR p.completed_at > strftime('%Y-%m-%dT%H:%M:%fZ','now','-130 seconds'))")
    let visits = try query(db, "SELECT thread_id,json_extract(payload_json,'$.lastVisitedAt'),json_extract(payload_json,'$.snoozedUntil'),archived_at,deleted_at,json_extract(payload_json,'$.settledOverride') FROM orchestration_v2_projection_threads")
    let requests = try query(db, "SELECT count(*) FROM orchestration_v2_projection_runtime_requests r JOIN orchestration_v2_projection_threads t USING(thread_id) WHERE r.resolved_at IS NULL AND r.status NOT IN ('resolved','cancelled','failed','expired') AND r.kind IN ('user_input','approval','permission') AND t.archived_at IS NULL AND t.deleted_at IS NULL")
    return (rows.map { Turn(id: $0[0], thread: $0[1], status: $0[2], started: timestamp($0[3]), completed: timestamp($0[4])) }, Dictionary(uniqueKeysWithValues: visits.map { ($0[0], timestamp($0[1])) }), requests.first?.first != "0", Set(visits.filter { timestamp($0[2]) > Date().timeIntervalSince1970 || !$0[3].isEmpty || !$0[4].isEmpty || $0[5] == "settled" }.map { $0[0] }))
}
func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
func appleQuote(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }

// Sequence IDs are an allowlist shared with the privileged controller.
struct SequencePreference {
    var preset: Int
    var milliseconds: Int
    static func defaults(_ state: String) -> SequencePreference {
        SequencePreference(preset: ["idle":0,"working":3,"finished":1,"attention":2][state] ?? 0, milliseconds: state == "finished" ? 667 : 1000)
    }
    static func load(_ state: String, defaults: UserDefaults = .standard) -> SequencePreference {
        let fallback = Self.defaults(state)
        guard let record = defaults.dictionary(forKey: "sequence.\(state)"),
              let preset = record["preset"] as? Int, (0...3).contains(preset),
              let ms = record["milliseconds"] as? Int, (400...1600).contains(ms) else { return fallback }
        return SequencePreference(preset: fallback.preset, milliseconds: ms)
    }
    func save(_ state: String, defaults: UserDefaults = .standard) {
        defaults.set(["preset":preset,"milliseconds":milliseconds], forKey:"sequence.\(state)")
    }
}
func applyDockPreference(){NSApp.setActivationPolicy(UserDefaults.standard.object(forKey:"hideFromDock") as? Bool ?? true ? .accessory:.regular)}
enum DoneDuration {
    static let values = [60,180,300,600,1200,0]
    static var seconds: Double {
        guard let value=UserDefaults.standard.object(forKey:"doneSeconds") as? Int, values.contains(value) else{return 0}
        return Double(value)
    }
}
func settingsCard(_ frame:NSRect)->NSBox {
    let box=NSBox(frame:frame);box.boxType = .custom;box.borderColor = .separatorColor;box.borderWidth=0.5;box.cornerRadius=12;box.fillColor = .controlBackgroundColor;box.contentViewMargins = .zero;return box
}
func settingsLabel(_ text:String,_ frame:NSRect,size:CGFloat=13,secondary:Bool=false)->NSTextField {
    let l=NSTextField(wrappingLabelWithString:text);l.frame=frame;l.font = .systemFont(ofSize:size,weight:size>=16 ? .semibold:.regular);l.textColor=secondary ? .secondaryLabelColor:.labelColor;return l
}
final class SequenceRow: NSView {
    let state:String
    let pattern=NSTextField(labelWithString:"")
    let revert=NSButton()
    let slider=NSSlider(value:1,minValue:0.625,maxValue:2.5,target:nil,action:nil)
    let speed=NSTextField(labelWithString:"")
    let play=NSButton()
    let duration=NSPopUpButton()
    let runTest:(String)->Void
    init(state:String,name:String,detail:String,y:CGFloat,runTest:@escaping(String)->Void){
        self.state=state;self.runTest=runTest
        let height:CGFloat=state=="finished" ? 188:144
        super.init(frame:NSRect(x:24,y:y,width:592,height:height))
        let box=settingsCard(bounds);addSubview(box);let c=box.contentView!
        let title=settingsLabel(name,NSRect(x:16,y:height-38,width:160,height:24),size:16);title.sizeToFit();c.addSubview(title)
        revert.image=NSImage(systemSymbolName:"arrow.counterclockwise",accessibilityDescription:"Restore \(name) defaults");revert.isBordered=false;revert.target=self;revert.action = #selector(reset);revert.frame=NSRect(x:title.frame.maxX+8,y:height-38,width:22,height:24);revert.toolTip="Restore defaults";c.addSubview(revert)
        c.addSubview(settingsLabel(detail,NSRect(x:16,y:height-61,width:520,height:20),size:12,secondary:true))
        play.bezelStyle = .rounded;play.frame=NSRect(x:532,y:height-55,width:44,height:32);play.target=self;play.action = #selector(testSequence);c.addSubview(play);updatePlaying(false)
        pattern.stringValue=["working":"Green ↔ Amber","finished":"Green (blink)","attention":"Amber (blink)"][state] ?? "";pattern.font = .systemFont(ofSize:12);pattern.textColor = .secondaryLabelColor;pattern.alignment = .right;pattern.frame=NSRect(x:302,y:0,width:218,height:20);pattern.sizeToFit();pattern.frame=NSRect(x:520-pattern.frame.width,y:play.frame.midY-pattern.frame.height/2,width:pattern.frame.width,height:pattern.frame.height);c.addSubview(pattern)
        speed.font = .systemFont(ofSize:12);speed.textColor = .secondaryLabelColor;speed.frame=NSRect(x:16,y:height-90,width:560,height:20);c.addSubview(speed)
        slider.frame=NSRect(x:16,y:height-119,width:560,height:24);slider.isContinuous=true;slider.target=self;slider.action = #selector(changeSpeed);slider.setAccessibilityLabel("\(name) speed");c.addSubview(slider)
        if state=="finished" {
            let divider=NSBox(frame:NSRect(x:16,y:54,width:560,height:1));divider.boxType = .separator;c.addSubview(divider)
            c.addSubview(settingsLabel("Show Done for",NSRect(x:16,y:20,width:250,height:20)))
            duration.addItems(withTitles:["1 minute","3 minutes","5 minutes","10 minutes","20 minutes","Forever"]);duration.selectItem(at:DoneDuration.values.firstIndex(of:Int(DoneDuration.seconds)) ?? 5);duration.frame=NSRect(x:396,y:15,width:180,height:28);duration.target=self;duration.action = #selector(changeDuration);duration.setAccessibilityLabel("Done duration");c.addSubview(duration)
        }
        refresh()
    }
    required init?(coder:NSCoder){fatalError()}
    func updatePlaying(_ playing:Bool){play.image=NSImage(systemSymbolName:playing ? "pause.fill":"play.fill",accessibilityDescription:playing ? "Pause test":"Play test");play.setAccessibilityLabel("\(playing ? "Pause":"Play") \(state) test");play.toolTip=playing ? "Stop preview and resume normal status":"Preview this sequence on the connector"}
    @objc func testSequence(){runTest(state)}
    @objc func changeDuration(){UserDefaults.standard.set(DoneDuration.values[duration.indexOfSelectedItem],forKey:"doneSeconds");refresh()}
    @objc func changeSpeed(){var p=SequencePreference.load(state);p.milliseconds=max(400,min(1600,Int((Double(SequencePreference.defaults(state).milliseconds)/slider.doubleValue).rounded())));p.save(state);refresh()}
    @objc func reset(){SequencePreference.defaults(state).save(state);if state=="finished" {UserDefaults.standard.removeObject(forKey:"doneSeconds")};refresh()}
    func refresh(){let p=SequencePreference.load(state);let base=Double(SequencePreference.defaults(state).milliseconds);slider.minValue=base/1600;slider.maxValue=base/400;slider.doubleValue=base/Double(p.milliseconds);speed.stringValue=String(format:"Speed  %.2f×",base/Double(p.milliseconds));revert.isHidden=p.milliseconds==Int(base) && (state != "finished" || DoneDuration.seconds==0);if state=="finished" {duration.selectItem(at:DoneDuration.values.firstIndex(of:Int(DoneDuration.seconds)) ?? 5)}}

}
final class LinkButton: NSButton {
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
final class CreditLinkField: NSTextField {
    override func resetCursorRects() {
        super.resetCursorRects()
        let text=attributedStringValue
        let range=(text.string as NSString).range(of:"Maxim Kich")
        guard range.location != NSNotFound else{return}
        let prefix=text.attributedSubstring(from:NSRange(location:0,length:range.location)).size().width
        let width=text.attributedSubstring(from:range).size().width
        addCursorRect(NSRect(x:prefix+2,y:0,width:width,height:bounds.height),cursor:.pointingHand)
    }
}
final class SequenceSettings:NSWindowController,NSWindowDelegate,NSTableViewDataSource,NSTableViewDelegate {
    var runTest:((String)->Void)?
    var playingState:(()->String?)?
    var active:(()->Bool)?
    var setActive:((Bool)->Void)?
    var permission:(()->String)?
    var managePermission:(()->Void)?
    let updateButton=NSButton()
    let cancelUpdate=NSButton(title:"Cancel",target:nil,action:nil)
    let updateMessage=NSTextField(wrappingLabelWithString:"")
    let loginSwitch=NSSwitch()
    let dockSwitch=NSSwitch()
    let unpluggedSwitch=NSSwitch()
    var visibilityChanged:(()->Void)?
    let activation=NSSwitch()
    let permissionStatus=NSTextField(labelWithString:"")
    let permissionButton=NSButton(title:"Allow…",target:nil,action:nil)
    let navigation=NSTableView()
    let content=NSView(frame:NSRect(x:220,y:0,width:640,height:640))
    var rows=[SequenceRow]()
    var selected=0
    var statusTimer:Timer?
    init(){
        let w=NSWindow(contentRect:NSRect(x:0,y:0,width:860,height:640),styleMask:[.titled,.closable,.miniaturizable,.fullSizeContentView],backing:.buffered,defer:false)
        w.collectionBehavior = [.managed, .primary, .fullScreenNone]
        w.title="MagDot Settings";w.titleVisibility = .hidden;w.titlebarAppearsTransparent=true;w.isReleasedWhenClosed=false
        let toolbar=NSToolbar(identifier:"SettingsHeader");toolbar.showsBaselineSeparator=false;toolbar.allowsUserCustomization=false;w.toolbar=toolbar;w.toolbarStyle = .unified
        super.init(window:w);w.delegate=self
        let root=w.contentView!;let frame=NSRect(x:8,y:8,width:204,height:624);let inner=NSView(frame:NSRect(origin:.zero,size:frame.size));let sidebar:NSView
        if #available(macOS 26.0,*) {let glass=NSGlassEffectView(frame:frame);glass.style = .regular;glass.cornerRadius=20;glass.contentView=inner;sidebar=glass}
        else {let effect=NSVisualEffectView(frame:frame);effect.material = .sidebar;effect.blendingMode = .behindWindow;effect.state = .active;effect.wantsLayer=true;effect.layer?.cornerRadius=20;effect.layer?.masksToBounds=true;effect.addSubview(inner);sidebar=effect}
        root.addSubview(sidebar)
        let scroll=NSScrollView(frame:NSRect(x:0,y:0,width:204,height:576));scroll.drawsBackground=false
        let column=NSTableColumn(identifier:NSUserInterfaceItemIdentifier("section"));column.width=204;navigation.addTableColumn(column);navigation.headerView=nil;navigation.rowHeight=34;navigation.intercellSpacing=NSSize(width:0,height:4);navigation.style = .sourceList;navigation.backgroundColor = .clear;navigation.dataSource=self;navigation.delegate=self;scroll.documentView=navigation;inner.addSubview(scroll)
        root.addSubview(content);root.addSubview(settingsLabel("MagDot",NSRect(x:248,y:603,width:584,height:22)))
        navigation.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false);refresh();w.center()
        statusTimer=Timer.scheduledTimer(withTimeInterval:0.25,repeats:true){[weak self] _ in self?.updateStatus()}
    }
    required init?(coder:NSCoder){fatalError()}
    func numberOfRows(in tableView:NSTableView)->Int{3}
    func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int)->NSView? {
        let cell=NSTableCellView();let icon=NSImageView();icon.translatesAutoresizingMaskIntoConstraints=false;icon.image=NSImage(systemSymbolName:["gearshape","slider.horizontal.3","info.circle"][row],accessibilityDescription:nil);icon.contentTintColor = .secondaryLabelColor;cell.addSubview(icon)
        let text=NSTextField(labelWithString:["General","States","About"][row]);text.font = .systemFont(ofSize:13);text.translatesAutoresizingMaskIntoConstraints=false;cell.addSubview(text);cell.textField=text;cell.imageView=icon
        NSLayoutConstraint.activate([icon.leadingAnchor.constraint(equalTo:cell.leadingAnchor,constant:8),icon.centerYAnchor.constraint(equalTo:cell.centerYAnchor),icon.widthAnchor.constraint(equalToConstant:18),icon.heightAnchor.constraint(equalToConstant:18),text.leadingAnchor.constraint(equalTo:icon.trailingAnchor,constant:8),text.centerYAnchor.constraint(equalTo:icon.centerYAnchor),text.trailingAnchor.constraint(lessThanOrEqualTo:cell.trailingAnchor,constant:-8)]);return cell
    }
    func tableViewSelectionDidChange(_ notification:Notification){selected=max(0,navigation.selectedRow);refresh()}
    func windowWillClose(_ notification:Notification){cancelPreview();applyDockPreference()}
    func cancelPreview(){if let state=playingState?(){runTest?(state)}}
    func present(){applyDockPreference();showWindow(nil);NSApp.activate(ignoringOtherApps:true);window?.makeKeyAndOrderFront(nil)}
    func updateStatus(){unpluggedSwitch.state=(UserDefaults.standard.object(forKey:"hideWhenUnplugged") as? Bool ?? true) ? .on:.off;loginSwitch.state=SMAppService.mainApp.status == .enabled ? .on:.off;dockSwitch.state=(UserDefaults.standard.object(forKey:"hideFromDock") as? Bool ?? true) ? .on:.off;updateButton.title=UpdateChecker.shared.primaryTitle;updateButton.isEnabled=UpdateChecker.shared.primaryEnabled;cancelUpdate.isHidden = !UpdateChecker.shared.canCancel;updateMessage.stringValue=UpdateChecker.shared.message;activation.state=active?()==true ? .on:.off;let granted=permission?()=="Allowed";permissionStatus.stringValue="Allowed";permissionStatus.isHidden = !granted;permissionButton.isHidden=granted;for row in rows {row.updatePlaying(playingState?()==row.state)}}
    func refresh(){
        content.subviews.forEach{$0.removeFromSuperview()};rows=[]
        content.addSubview(settingsLabel(["General","States","About"][selected],NSRect(x:28,y:544,width:560,height:34),size:24))
        switch selected {
        case 0:
            let control=settingsCard(NSRect(x:24,y:440,width:592,height:64));content.addSubview(control);control.contentView?.addSubview(settingsLabel("Activate",NSRect(x:16,y:21,width:470,height:22)));activation.frame=NSRect(x:528,y:20,width:40,height:24);activation.target=self;activation.action = #selector(toggleActive);activation.setAccessibilityLabel("Activate MagDot");control.contentView?.addSubview(activation)
            let permissions=settingsCard(NSRect(x:24,y:360,width:592,height:64));content.addSubview(permissions)
            permissions.contentView?.addSubview(settingsLabel("Background helper",NSRect(x:16,y:21,width:350,height:22)))
            permissionStatus.frame=NSRect(x:396,y:21,width:180,height:22);permissionStatus.font = .systemFont(ofSize:13);permissionStatus.alignment = .right;permissionStatus.textColor = .systemGreen;permissions.contentView?.addSubview(permissionStatus)
            permissionButton.target=self;permissionButton.action = #selector(openPermissions);permissionButton.bezelStyle = .rounded;permissionButton.frame=NSRect(x:476,y:16,width:100,height:32);permissions.contentView?.addSubview(permissionButton)
            for (index,title) in ["Launch at login","Hide from Dock","Hide menu bar icon when unplugged"].enumerated(){
                let card=settingsCard(NSRect(x:24,y:280-index*80,width:592,height:64));content.addSubview(card)
                card.contentView?.addSubview(settingsLabel(title,NSRect(x:16,y:21,width:470,height:22)))
                let control=[loginSwitch,dockSwitch,unpluggedSwitch][index];control.frame=NSRect(x:528,y:20,width:40,height:24);control.target=self;control.action=[#selector(toggleLogin),#selector(toggleDock),#selector(toggleUnplugged)][index];control.setAccessibilityLabel(title);card.contentView?.addSubview(control)
            }

        case 1:
            let states=["working","finished","attention"],names=["Working","Done","Input"],details=["While threads are running, with no input or completion pending.","Takes priority over Working until dismissed or expired.","When a thread needs your input. Takes priority over Done and Working."]
            for i in 0..<3 {let row=SequenceRow(state:states[i],name:names[i],detail:details[i],y:[384.0,180.0,20.0][i],runTest:{[weak self] in self?.runTest?($0)});content.addSubview(row);rows.append(row)}
        default:
            let box=settingsCard(NSRect(x:24,y:150,width:592,height:378));content.addSubview(box);let c=box.contentView!
            let icon=NSImageView(frame:NSRect(x:246,y:242,width:100,height:100));icon.image=Bundle.main.url(forResource:"MagDot",withExtension:"icns").flatMap { NSImage(contentsOf:$0) };icon.imageScaling = .scaleProportionallyUpOrDown;c.addSubview(icon)
            let name=settingsLabel("MagDot",NSRect(x:16,y:193,width:560,height:34),size:24);name.alignment = .center;c.addSubview(name)
            let version=Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "0.0.1"
            let versionLabel=settingsLabel("Version \(version)",NSRect(x:16,y:158,width:560,height:24),secondary:true);versionLabel.alignment = .center;c.addSubview(versionLabel)
            let tagline=settingsLabel("A T3 Code agent status light for your MagSafe connector.",NSRect(x:16,y:118,width:560,height:24),secondary:true);tagline.alignment = .center;c.addSubview(tagline)
            updateButton.target=self;updateButton.action = #selector(checkUpdate);updateButton.bezelStyle = .rounded;updateButton.frame=NSRect(x:202,y:79,width:188,height:32);c.addSubview(updateButton)
            cancelUpdate.target=self;cancelUpdate.action = #selector(cancelDownload);cancelUpdate.bezelStyle = .rounded;cancelUpdate.frame=NSRect(x:408,y:79,width:88,height:32);c.addSubview(cancelUpdate)
            updateMessage.font = .systemFont(ofSize:11);updateMessage.textColor = .secondaryLabelColor;updateMessage.alignment = .center;updateMessage.frame=NSRect(x:24,y:43,width:544,height:32);c.addSubview(updateMessage)
            let credit=CreditLinkField(labelWithString:"");credit.frame=NSRect(x:28,y:110,width:300,height:22);credit.isSelectable=true;credit.allowsEditingTextAttributes=true
            let text=NSMutableAttributedString(string:"Created by Maxim Kich",attributes:[.font:NSFont.systemFont(ofSize:11),.foregroundColor:NSColor.secondaryLabelColor]);text.addAttribute(.link,value:URL(string:"https://maximkich.com")!,range:(text.string as NSString).range(of:"Maxim Kich"));credit.attributedStringValue=text;content.addSubview(credit)
            let license=LinkButton(title:"Licenses",target:self,action:#selector(openLicense));license.isBordered=false;license.attributedTitle=NSAttributedString(string:"Licenses",attributes:[.font:NSFont.systemFont(ofSize:11),.foregroundColor:NSColor.secondaryLabelColor]);license.frame=NSRect(x:530,y:111,width:80,height:22);content.addSubview(license)

        };updateStatus()
    }
    @objc func toggleLogin(){
        UserDefaults.standard.set(true,forKey:"launchAtLoginDefaultApplied")
        do {if loginSwitch.state == .on {try SMAppService.mainApp.register()} else {try SMAppService.mainApp.unregister()};if SMAppService.mainApp.status == .requiresApproval {SMAppService.openSystemSettingsLoginItems()}}
        catch {let alert=NSAlert();alert.messageText="Could not change launch at login";alert.informativeText=error.localizedDescription;if let window {alert.beginSheetModal(for:window)}}
        updateStatus()
    }
    @objc func toggleUnplugged(){UserDefaults.standard.set(unpluggedSwitch.state == .on,forKey:"hideWhenUnplugged");visibilityChanged?()}
    @objc func toggleDock(){UserDefaults.standard.set(dockSwitch.state == .on,forKey:"hideFromDock");applyDockPreference();window?.makeKeyAndOrderFront(nil)}
    @objc func toggleActive(){setActive?(activation.state == .on);updateStatus()}
    @objc func openPermissions(){managePermission?()}
    @objc func checkUpdate(){UpdateChecker.shared.openUpdate()}
    @objc func cancelDownload(){UpdateChecker.shared.cancel()}
    @objc func openProject(){NSWorkspace.shared.open(URL(string:"https://github.com/maxim-kich/MagDot")!)}
    @objc func openLicense(){NSWorkspace.shared.open(URL(string:"https://github.com/maxim-kich/MagDot/blob/main/ACKNOWLEDGEMENTS.md")!)}
}

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var serviceEnabled: Bool {
#if TESTING
        if let path=ProcessInfo.processInfo.environment["MAGDOT_TEST_APPROVAL_FILE"] {
            return (try? String(contentsOfFile:path,encoding:.utf8)) == "enabled"
        }
        return true
#else
        return service.status == .enabled
#endif
    }
    let service = SMAppService.daemon(plistName: "com.maximkich.magdot.helper.plist")
    var item: NSStatusItem!
    let menu = NSMenu()
    let status = NSMenuItem(title: "Stopped", action: nil, keyEquivalent: "")
    let menuSwitch=NSSwitch()
    let connectorView=MenuConnectorView()
    let launchAtStartupItem=NSMenuItem(title:"Launch at startup",action:#selector(enableLaunchAtStartup),keyEquivalent:"")
    var startItem: NSMenuItem!
    var stopItem: NSMenuItem!
    var timer: Timer?
    var connectionTimer:Timer?
    var onboardingWindow:NSWindow?
    var onboardingMessage:NSTextField?
    var onboardingDoneButton:NSButton?
    var awaitingHelperApproval=false
    var helperRegistrationAttempted=false
    var bundleRemoved=false
    var helperConnectionAttempted=false
    var observedHelperApproval:Bool?
    var connectionGate=ConnectionGate()
    var unpluggedTracker:Tracker?
    var tracker = Tracker()
    var sleepTracker: Tracker?
    var sleeping = false
    var stopping = false, quitting = false, requested = false, ready = false, restored = false
    var socketFD: Int32 = -1, lockFD: Int32 = -1
    var startedAt = Date(), stopAt = Date()
    var received = ""
    var smokeTicks = 0
    var activity: NSObjectProtocol?
    var settingsWindow: SequenceSettings?
    var testState: String?
    var resumeAfterTest=false
    func testSequence(_ state:String){
        guard !stopping else{return}
        if testState == state {testState=nil;if !resumeAfterTest {stop()};return}
        if testState == nil {resumeAfterTest=requested}
        testState=state
        if !requested {start()}
        if !requested {testState=nil}
    }
    @objc func showSettings(){
        if settingsWindow == nil {
            let settings=SequenceSettings();settingsWindow=settings
            settings.visibilityChanged={ [weak self] in self?.updateConnectionVisibility() }
            settings.runTest={ [weak self] in self?.testSequence($0) }
            settings.playingState={ [weak self] in self?.testState }
            settings.active={ [weak self] in self?.requested == true && self?.ready == true && self?.stopping == false }
            settings.setActive={ [weak self] on in if on {self?.start()} else {self?.stop()} }
            settings.permission={ [weak self] in
                guard let self else{return "Unavailable"}
                switch self.service.status {case .enabled:return "Allowed";case .requiresApproval:return "Approval needed in System Settings";case .notRegistered,.notFound:return "Not registered";@unknown default:return "Unavailable"}
            }
            settings.managePermission={ [weak self] in
                guard let self else{return}
                self.prepareHelperRegistration(explicit:true)
                self.start();SMAppService.openSystemSettingsLoginItems()
            }
        };settingsWindow?.present()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        var directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MagDot")
#if TESTING
        directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MAGDOT_TEST_DIR"]!)
#endif
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { NSApp.terminate(nil); return }
        lockFD = open(directory.appendingPathComponent("app.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { NSApp.terminate(nil); return }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.length = 26
        if let button=item.button {
            connectorView.frame=button.bounds;connectorView.autoresizingMask=[.width,.height];button.addSubview(connectorView)
            button.setAccessibilityLabel("MagDot")
        }
        item.button?.toolTip = "MagDot — T3 activity light"
        menu.autoenablesItems = false
        menu.delegate = self
        status.isEnabled = false
        startItem = NSMenuItem(title: "Start", action: #selector(start), keyEquivalent: "")
        stopItem = NSMenuItem(title: "Stop", action: #selector(stop), keyEquivalent: "")
        startItem.target = self; stopItem.target = self; stopItem.isEnabled = false
        let toggleItem=NSMenuItem();let toggleView=NSView(frame:NSRect(x:0,y:0,width:220,height:40))
        let activateLabel=NSTextField(labelWithString:"Activate");activateLabel.font = .systemFont(ofSize:13);activateLabel.sizeToFit();activateLabel.frame.origin=NSPoint(x:16,y:(toggleView.bounds.height-activateLabel.frame.height)/2);toggleView.addSubview(activateLabel)
        menuSwitch.frame=NSRect(x:164,y:8,width:40,height:24);menuSwitch.target=self;menuSwitch.action = #selector(toggleFromMenu);menuSwitch.setAccessibilityLabel("Activate MagDot");toggleView.addSubview(menuSwitch);toggleItem.view=toggleView;menu.addItem(toggleItem);menu.addItem(.separator())
        launchAtStartupItem.target=self;menu.addItem(launchAtStartupItem)
        let settings = NSMenuItem(title:"Settings…",action:#selector(showSettings),keyEquivalent:","); settings.target=self;menu.addItem(settings);menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit MagDot", action: #selector(quit), keyEquivalent: "q"); quit.target = self; menu.addItem(quit)
        item.menu = menu
        _ = NotificationCenter.default.addObserver(forName:Notification.Name("MagDotShowAbout"),object:nil,queue:.main){[weak self] _ in self?.showSettings();self?.settingsWindow?.navigation.selectRowIndexes(IndexSet(integer:2),byExtendingSelection:false)}
        UpdateChecker.shared.activity={ [weak self] in UpdateActivity(controllingLED:self?.requested != false) }
        UpdateChecker.shared.beforeRestart={ [weak self] in guard let self else{return};try self.service.unregister() }
        #if !TESTING
        #endif
        if CommandLine.arguments.contains("--settings") || CommandLine.arguments.contains("--render-settings") {showSettings()}
        if CommandLine.arguments.contains("--render-settings") {
            DispatchQueue.main.asyncAfter(deadline:.now()+0.5){[weak self] in
                guard let view=self?.settingsWindow?.window?.contentView, let rep=view.bitmapImageRepForCachingDisplay(in:view.bounds) else {exit(1)}
                view.cacheDisplay(in:view.bounds,to:rep)
                try? rep.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:"/tmp/magdot-settings-preview.png"))
                NSApp.terminate(nil)
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        applyDockPreference()
        if !CommandLine.arguments.contains("--render-settings") {
#if !TESTING
            if !UserDefaults.standard.bool(forKey:"launchAtLoginDefaultApplied") {
                do {
                    if SMAppService.mainApp.status == .notRegistered {try SMAppService.mainApp.register()}
                    if SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval {
                        UserDefaults.standard.set(true,forKey:"launchAtLoginDefaultApplied")
                    }
                } catch { NSLog("MagDot launch-at-login registration failed: %@",error.localizedDescription) }
            }
#endif
            checkConnection()
            connectionTimer=Timer(timeInterval:1,repeats:true){[weak self] _ in self?.checkConnection()}
            connectionTimer?.tolerance=0.2
            RunLoop.main.add(connectionTimer!,forMode:.common)
        }
    }
    func updateOnboarding(){
#if !TESTING
        guard !UserDefaults.standard.bool(forKey:"magSafeOnboardingCompleted") else{return}
        if onboardingWindow == nil {
            let window=NSWindow(contentRect:NSRect(x:0,y:0,width:480,height:170),styleMask:[.titled,.closable],backing:.buffered,defer:false)
            window.title="Welcome to MagDot";window.isReleasedWhenClosed=false;window.center()
            let title=settingsLabel("Connect your MagSafe 3 cable",NSRect(x:104,y:134,width:348,height:28),size:18)
            title.alignment = .left;title.sizeToFit();title.frame.origin=NSPoint(x:104,y:142-title.frame.height);window.contentView?.addSubview(title)
            let message=settingsLabel("MagDot runs only while MagSafe 3 is connected.",NSRect(x:104,y:88,width:348,height:42),secondary:true)
            message.alignment = .left;message.sizeToFit();message.frame.origin=NSPoint(x:104,y:title.frame.minY-6-message.frame.height);window.contentView?.addSubview(message)
            let textBounds=title.frame.union(message.frame)
            let icon=NSImageView(frame:NSRect(x:28,y:textBounds.midY-32,width:64,height:64))
            icon.image=Bundle.main.url(forResource:"MagDot",withExtension:"icns").flatMap { NSImage(contentsOf:$0) }
            icon.imageScaling = .scaleProportionallyUpOrDown;window.contentView?.addSubview(icon)
            let done=NSButton(title:"Got it",target:self,action:#selector(dismissOnboarding))
            done.bezelStyle = .rounded;done.frame=NSRect(x:352,y:min(icon.frame.minY,message.frame.minY)-48,width:100,height:32);done.isEnabled=false;done.keyEquivalent="\r"
            window.contentView?.addSubview(done);onboardingDoneButton=done
            onboardingMessage=title;onboardingWindow=window
            NSApp.activate(ignoringOtherApps:true);window.makeKeyAndOrderFront(nil)
        }
        let connected=connectionGate.connected == true
        onboardingMessage?.stringValue=connected ? "MagSafe 3 connected" : "Connect your MagSafe 3 cable"
        onboardingMessage?.textColor=connected ? .systemGreen : .labelColor
        onboardingDoneButton?.isEnabled=connected
#endif
    }
    @objc func dismissOnboarding(){
        guard magSafeConnection() == true else {updateOnboarding();return}
        UserDefaults.standard.set(true,forKey:"magSafeOnboardingCompleted")
        onboardingWindow?.close();onboardingWindow=nil
    }
    func updateConnectionVisibility(){
        item?.isVisible=connectionGate.iconVisible(hide:UserDefaults.standard.object(forKey:"hideWhenUnplugged") as? Bool ?? true)
        item?.button?.toolTip = connectionGate.connected == nil ? "MagDot — connection unavailable" : connectionGate.connected == false ? "MagDot — waiting for MagSafe" : "MagDot — T3 activity light"
    }
    func checkConnection(){
        guard !quitting else{return}
#if TESTING
        let executablePath=ProcessInfo.processInfo.environment["MAGDOT_TEST_BUNDLE_EXECUTABLE"] ?? Bundle.main.executablePath ?? ""
#else
        let executablePath=Bundle.main.executablePath ?? ""
#endif
        if !FileManager.default.fileExists(atPath:executablePath) {
            bundleRemoved=true
            NSApp.terminate(nil)
            return
        }
        guard !quitting, !sleeping else{return}
        _ = connectionGate.observe(magSafeConnection())
        let approved=serviceEnabled
        let approvalGranted=observedHelperApproval == false && approved
        observedHelperApproval=approved
        updateConnectionVisibility()
        updateOnboarding()
        if !connectionGate.canRun {
            if requested && !stopping {
                let pending=tracker
                let enabled=connectionGate.activationEnabled
                stop()
                connectionGate.activationEnabled=enabled
                unpluggedTracker=pending
            }
            return
        }
        if connectionGate.activationEnabled && (connectionGate.pendingStart || approvalGranted) && !requested && !stopping {
            connectionGate.pendingStart=false
            let pending=unpluggedTracker;unpluggedTracker=nil
            start()
            if let pending {tracker=pending}
        }
    }
    func sendState(_ mode: String) -> Bool {
        var p = (mode == "system" || mode == "idle") ? SequencePreference(preset:0,milliseconds:1000) : SequencePreference.load(mode)
        #if TESTING
        if mode != "quit", let forced=ProcessInfo.processInfo.environment["MAGDOT_TEST_PRESET"], let value=Int(forced) {p=SequencePreference(preset:value,milliseconds:1600)}
        #endif
        let message = "\(mode) \(Int(Date().timeIntervalSince1970)+4) \(p.preset) \(p.milliseconds)\n"
        return message.withCString { send(socketFD, $0, strlen($0), 0) == strlen($0) }
    }
    func menuWillOpen(_ menu:NSMenu){
        launchAtStartupItem.isHidden = SMAppService.mainApp.status == .enabled
    }
    @objc func enableLaunchAtStartup(){
        do {
            try SMAppService.mainApp.register()
            if SMAppService.mainApp.status == .requiresApproval {SMAppService.openSystemSettingsLoginItems()}
        } catch {
            let alert=NSAlert();alert.messageText="Could not enable launch at startup";alert.informativeText=error.localizedDescription;alert.runModal()
        }
        launchAtStartupItem.isHidden = SMAppService.mainApp.status == .enabled
        settingsWindow?.updateStatus()
    }
    @objc func toggleFromMenu(){if menuSwitch.state == .on {start()} else {stop()};menuSwitch.state = requested && ready && !stopping ? .on:.off}
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool)->Bool {showSettings();return true}
    @objc func start() {
        connectionGate.activationEnabled=true
        guard !requested, !stopping, connectionGate.canRun, !sleeping, !quitting else { return }
        connectionGate.pendingStart=false
        awaitingHelperApproval=true
        helperConnectionAttempted=false
        stopping = false; tracker = Tracker(); smokeTicks = 0; ready = false; restored = false; received = ""
        #if TESTING
        if ProcessInfo.processInfo.environment["MAGDOT_TEST_REGISTER_DEFER"] == "1" && !serviceEnabled {return}
        #endif
        #if !TESTING
        prepareHelperRegistration()
        #endif
        requested = true; connectorView.isActive = false; menuSwitch.state = .off; startedAt = Date()
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Maintain the LED restoration heartbeat")
        status.title = "Starting…"; startItem.isEnabled = false; stopItem.isEnabled = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
    }
    func connectHelper() -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        var socketPath = "/var/run/magdot.sock"
#if TESTING
        socketPath = ProcessInfo.processInfo.environment["MAGDOT_TEST_DIR"]! + "/socket"
#endif
        let path = Array(socketPath.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in bytes.copyBytes(from: path) }
        let result = withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard result == 0 else { close(fd); return false }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        socketFD = fd
        startedAt = Date()
        if sendState("system") {return true}
        close(socketFD);socketFD = -1;return false
    }
    func tick() {
        if socketFD < 0 {
            // Approval and launchd startup have no user-facing deadline. Keep the
            // requested activation until connected, stopped, unplugged, or quit.
            guard connectionGate.canRun else {checkConnection();return}
            guard serviceEnabled else {helperConnectionAttempted=false;status.title="Waiting for helper approval";return}
            guard !helperConnectionAttempted else{return}
            helperConnectionAttempted=true
            guard connectHelper() else {ended(false,message:"Helper connection failed — use Activate to try again");return}
        }
        var buffer = [UInt8](repeating: 0, count: 512)
        let count = recv(socketFD, &buffer, buffer.count, MSG_DONTWAIT)
        if count > 0 {
            received += String(decoding: buffer.prefix(count), as: UTF8.self)
            if received.contains("READY\n") && !stopping { ready = true; awaitingHelperApproval=false;connectorView.isActive=true;menuSwitch.state = .on;settingsWindow?.updateStatus() }
            if received.contains("RESTORED\n") { restored = true }
            if received.count > 4096 { received = String(received.suffix(4096)) }
        } else if count == 0 { ended(restored); return }
        else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { ended(false); return }
        if stopping {
            if Date().timeIntervalSince(stopAt) > 8 { ended(false) }
            return
        }
        if magSafeConnection() != true {
            checkConnection()
            return
        }
        var mode = "idle", available = true
        do { let (rows, visits, attention, dismissed) = try readT3(observedTurns:tracker.active); mode = tracker.update(rows, visits: visits, attention: attention, now: Date().timeIntervalSince1970, doneDuration: DoneDuration.seconds, dismissed: dismissed) }
        catch { available = false }
        if let testing=testState, ready {mode=testing;available=true}
        guard sendState(available ? mode : "system") else { ended(false); return }
        if ready {
            let labels = ["idle":"Idle", "working":"Working", "finished":"Finished", "attention":"Needs input"]
            status.title = available ? labels[mode]! : "T3 unavailable — idle"
            if CommandLine.arguments.contains("--smoke-test") || CommandLine.arguments.contains("--quit-smoke") {
                smokeTicks += 1
                if smokeTicks == 6 {
                    if CommandLine.arguments.contains("--quit-smoke") { print("App Start acknowledged; invoking Quit"); NSApp.terminate(nil) }
                    else { print("App Start acknowledged; invoking Stop"); stop() }
                }
            }
        } else if Date().timeIntervalSince(startedAt) > 20 { ended(false, message:"Waiting for background helper") }
    }
    @objc func willSleep() {
        sleeping = true
        let pending = requested && !stopping ? tracker : unpluggedTracker
        let enabled=connectionGate.activationEnabled
        stop()
        connectionGate.activationEnabled=enabled
        sleepTracker = pending
    }
    @objc func didWake() {
        sleeping = false
        guard !requested, !quitting, let pending = sleepTracker else { return }
        sleepTracker = nil
        _ = connectionGate.observe(magSafeConnection())
        updateConnectionVisibility()
        if connectionGate.canRun {start();tracker=pending}
        else {unpluggedTracker=pending}
    }
    @objc func stop() {
        connectionGate.activationEnabled=false
        awaitingHelperApproval=false
        connectionGate.pendingStart=false
        unpluggedTracker=nil
        sleepTracker = nil
        testState=nil
        guard requested else { return }
        if socketFD < 0 { ended(true); return }
        connectorView.isActive = false
        stopping = true; menuSwitch.state = .off; stopAt = Date(); status.title = "Restoring…"; stopItem.isEnabled = false
        _ = sendState("quit")
    }
    func ended(_ success: Bool, message: String? = nil) {
        awaitingHelperApproval=connectionGate.activationEnabled && !quitting
        testState=nil
        timer?.invalidate(); timer = nil
        if socketFD >= 0 { close(socketFD); socketFD = -1 }
        connectorView.isActive = false
        requested = false; stopping = false; ready = false; menuSwitch.state = .off
        if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
        status.title = message ?? (success ? "Stopped" : ready ? "Restoration not confirmed" : "Controller unavailable — try Start")
        startItem.isEnabled = true; stopItem.isEnabled = false
        if CommandLine.arguments.contains("--smoke-test") {
            print("App Stop completed; restoration acknowledged=\(success)"); NSApp.terminate(nil)
        }
        if CommandLine.arguments.contains("--quit-smoke") && !quitting { print("Start failed: \(status.title)"); exit(1) }
        if !quitting && !sleeping && sleepTracker != nil { didWake() }
        if quitting { print("Quit restoration acknowledged=\(success)"); NSApp.reply(toApplicationShouldTerminate: true) }
    }
    func prepareHelperRegistration(explicit:Bool=false) {
        // Connection retries must never register/unregister a launchd job again.
        guard explicit || !helperRegistrationAttempted else{return}
        helperRegistrationAttempted=true
        do {
            if service.status == .notRegistered || service.status == .notFound {try service.register()}
            UserDefaults.standard.set("socket-v1",forKey:"helperRegistrationVersion")
        } catch {
            status.title="Helper setup needs attention"
            status.toolTip=error.localizedDescription
            NSLog("MagDot helper registration failed: %@",error.localizedDescription)
        }
    }
    func applicationWillTerminate(_ notification:Notification){
        connectionTimer?.invalidate()
#if !TESTING
        if bundleRemoved {
            do {try service.unregister()} catch {fputs("Could not unregister removed app helper: \(error)\n",stderr)}
            if SMAppService.mainApp.status != .notRegistered {try? SMAppService.mainApp.unregister()}
        }
#endif
    }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard bundleRemoved || UpdateChecker.shared.permitsTermination() else {showSettings();settingsWindow?.navigation.selectRowIndexes(IndexSet(integer:2),byExtendingSelection:false);return .terminateCancel}
        guard requested else { return .terminateNow }
        if socketFD < 0 { ended(true); return .terminateNow }
        quitting = true; stop()
        // AppKit suspends normal event processing during deferred termination.
        // Finish the socket handshake off the run loop, then reply on main.
        testState=nil
        timer?.invalidate(); timer = nil
        let fd = socketFD
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var output = "", acknowledged = false
            let deadline = Date().addingTimeInterval(8)
            while Date() < deadline {
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                if poll(&descriptor, 1, 250) <= 0 { continue }
                var bytes = [UInt8](repeating: 0, count: 512)
                let count = recv(fd, &bytes, bytes.count, 0)
                if count <= 0 { break }
                output += String(decoding: bytes.prefix(count), as: UTF8.self)
                if output.contains("RESTORED\n") { acknowledged = true }
            }
            let success = acknowledged
            DispatchQueue.main.async { self?.ended(success) }
        }
        return .terminateLater
    }
}

if CommandLine.arguments.contains("--self-test") {
    var gate=ConnectionGate()
    precondition(!gate.canRun && gate.iconVisible(hide:true))
    precondition(gate.observe(false) && !gate.canRun && !gate.iconVisible(hide:true))
    precondition(gate.iconVisible(hide:false))
    precondition(gate.observe(true) && gate.pendingStart && gate.canRun)
    gate.pendingStart=false // User stopped while still plugged in: don't restart on each poll.
    precondition(!gate.observe(true) && !gate.pendingStart)
    precondition(gate.observe(false) && !gate.pendingStart)
    precondition(gate.observe(true) && gate.pendingStart)
    precondition(gate.observe(nil) && !gate.canRun && gate.iconVisible(hide:true))
    gate.activationEnabled=false;gate.pendingStart=false
    _ = gate.observe(false)
    precondition(gate.observe(true) && !gate.pendingStart && !gate.activationEnabled)
    _ = gate.observe(nil)
    precondition(gate.observe(true) && !gate.pendingStart)
    gate.activationEnabled=true
    _ = gate.observe(false)
    precondition(gate.observe(true) && gate.pendingStart)
    print("Connection gating, reconnect, manual stop, unknown state, and icon visibility passed")
    var tracker = Tracker()
    let running = Turn(id: "a", thread: "chat", status: "running", started: 100, completed: 0)
    let done = Turn(id: "a", thread: "chat", status: "completed", started: 100, completed: 110)
    precondition(tracker.update([running], visits: [:], attention: false, now: 105) == "working")
    precondition(tracker.update([running], visits: [:], attention: true, now: 106) == "attention")
    precondition(tracker.update([done], visits: [:], attention: false, now: 111) == "finished")
    precondition(tracker.update([done], visits: [:], attention: false, now: 229) == "finished")
    precondition(tracker.update([done], visits: [:], attention: false, now: 230) == "idle")
    _ = tracker.update([running], visits: [:], attention: false, now: 105)
    precondition(tracker.update([done], visits: ["chat":111], attention: false, now: 112) == "idle")
    var fresh = Tracker()
    precondition(fresh.update([done], visits: [:], attention: false, now: 111) == "idle")
    _ = fresh.update([running], visits: [:], attention: false, now: 105)
    let cancelled = Turn(id: "a", thread: "chat", status: "cancelled", started: 100, completed: 110)
    precondition(fresh.update([cancelled], visits: [:], attention: false, now: 111) == "idle")
    precondition(fresh.update([running], visits: [:], attention: false, now: 3701) == "idle")
    for duration in [60.0,180,300,600,1200] {
        var timed=Tracker()
        _ = timed.update([running],visits:[:],attention:false,now:105,doneDuration:duration)
        precondition(timed.update([done],visits:[:],attention:false,now:110+duration-1,doneDuration:duration)=="finished")
        precondition(timed.update([done],visits:[:],attention:false,now:110+duration,doneDuration:duration)=="idle")
    }
    var multiple=Tracker()
    let second=Turn(id:"b",thread:"other",status:"running",started:100,completed:0)
    _ = multiple.update([running,second],visits:[:],attention:false,now:105,doneDuration:0)
    precondition(multiple.update([done,second],visits:[:],attention:false,now:111,doneDuration:0)=="finished")
    precondition(multiple.update([done,second],visits:[:],attention:true,now:112,doneDuration:0)=="attention")
    precondition(multiple.update([],visits:[:],attention:false,now:99999,doneDuration:0)=="finished")
    precondition(multiple.update([],visits:["chat":100000],attention:false,now:100001,doneDuration:0)=="idle")
    var priority=Tracker()
    _ = priority.update([running,second],visits:[:],attention:false,now:105,doneDuration:60)
    precondition(priority.update([done,second],visits:[:],attention:false,now:111,doneDuration:60)=="finished")
    precondition(priority.update([done,second],visits:["chat":112],attention:false,now:113,doneDuration:60)=="working")
    var expiry=Tracker()
    _ = expiry.update([running,second],visits:[:],attention:false,now:105,doneDuration:60)
    precondition(expiry.update([done,second],visits:[:],attention:false,now:111,doneDuration:60)=="finished")
    precondition(expiry.update([done,second],visits:[:],attention:false,now:170,doneDuration:60)=="working")
    var unread = Tracker()
    _ = unread.update([running,second], visits:[:], attention:false, now:105, doneDuration:0)
    precondition(unread.update([done,second], visits:[:], attention:false, now:111, doneDuration:0)=="finished")
    // Visiting another thread does not acknowledge the unread completion.
    precondition(unread.update([], visits:["other":112], attention:false, now:99999, doneDuration:0)=="finished")
    // A recorded read clears only this thread, regardless of app focus or lid state.
    precondition(unread.update([], visits:["chat":100000], attention:false, now:100001, doneDuration:0)=="idle")
    var snoozed = Tracker()
    _ = snoozed.update([running], visits:[:], attention:false, now:105)
    precondition(snoozed.update([done], visits:[:], attention:false, now:111, doneDuration:0, dismissed:["chat"])=="idle")
    precondition(snoozed.update([done], visits:[:], attention:false, now:112, doneDuration:0)=="idle")
    var settled = Tracker()
    _ = settled.update([running,second], visits:[:], attention:false, now:105)
    precondition(settled.update([done,second], visits:[:], attention:false, now:111, doneDuration:0)=="finished")
    // Settlement independently dismisses an unread, unsnoozed completion.
    precondition(settled.update([done,second], visits:[:], attention:false, now:112, doneDuration:0, dismissed:["chat"])=="working")
    // Unsettling does not replay the acknowledged completion.
    precondition(settled.update([done,second], visits:[:], attention:false, now:113, doneDuration:0)=="working")
    var pending = Tracker()
    let otherDone = Turn(id:"b",thread:"other",status:"completed",started:100,completed:110)
    _ = pending.update([running,second], visits:[:], attention:false, now:105)
    precondition(pending.update([done,otherDone], visits:[:], attention:false, now:111, doneDuration:0)=="finished")
    precondition(pending.update([], visits:[:], attention:false, now:112, doneDuration:0, dismissed:["chat"])=="finished")
    precondition(pending.finished.keys.sorted()==["other"])
    precondition(pending.update([], visits:["other":113], attention:false, now:114, doneDuration:0)=="idle")
    print("Unread retention, per-thread read/snooze/settle dismissal, multiple threads, and no replay passed")
    precondition(SequencePreference.defaults("finished").milliseconds==667)
    print("Done duration boundaries, Forever, chat visit, and multiple-thread priority passed")
    let testDefaults=UserDefaults(suiteName:"magdot.preference-test.\(UUID().uuidString)")!
    precondition(SequencePreference.load("working",defaults:testDefaults).preset==3)
    SequencePreference(preset:2,milliseconds:400).save("working",defaults:testDefaults)
    precondition(SequencePreference.load("working",defaults:testDefaults).milliseconds==400)
    testDefaults.set(["preset":9,"milliseconds":10],forKey:"sequence.working")
    precondition(SequencePreference.load("working",defaults:testDefaults).preset==3)
    testDefaults.removeObject(forKey:"sequence.working")
    print("Sequence persistence and invalid preference fallback passed")
    print("Native lifecycle tests passed: working, attention, completion, expiry, visit, startup, cancellation, stale turn")
} else if CommandLine.arguments.contains("--connection-status") {
    print(magSafeConnection().map {$0 ? "connected":"disconnected"} ?? "unknown")
} else if CommandLine.arguments.contains("--unregister-helper") {
    do { try SMAppService.daemon(plistName: "com.maximkich.magdot.helper.plist").unregister(); print("Helper unregistered") }
    catch { print(error.localizedDescription); exit(1) }
} else if CommandLine.arguments.contains("--service-status") {
    print("Helper service status: \(SMAppService.daemon(plistName: "com.maximkich.magdot.helper.plist").status.rawValue)")
} else if CommandLine.arguments.contains("--probe-t3") {
    do { let (rows, _, attention, dismissed) = try readT3(); print("T3 read succeeded: \(rows.count) recent/running turns; attention=\(attention); snoozed/settled/archived/deleted=\(dismissed.count)") }
    catch { print("T3 unavailable"); exit(1) }
} else {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = App(); app.delegate = delegate; app.run()
}
