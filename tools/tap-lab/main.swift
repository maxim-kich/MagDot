import AppKit
import IOKit.hid
import AVFoundation

let accent = NSColor(srgbRed: 0.26, green: 0.75, blue: 0.49, alpha: 1)
let ink = NSColor(srgbRed: 0.81, green: 0.86, blue: 0.80, alpha: 1)
let muted = NSColor(srgbRed: 0.53, green: 0.57, blue: 0.53, alpha: 1)
let zoneNames = ["Left side · target", "Not left · right / center"]
let zonePoints: [NSPoint] = [.init(x:0.045,y:0.23),.init(x:0.83,y:0.50)]
struct Ripple { let point: NSPoint; let peak: Double; let time: Double; let demo: Bool; let unknown: Bool }
var lab: LabView?
func sensorCallback(_ t: Double, _ x: Double, _ y: Double, _ z: Double) { lab?.sample(t,x,y,z) }

final class LabView: NSView {
    override var isFlipped: Bool { true }
    let detector = Detector()
    var model = LocationModel()
    var frozen:FrozenMotion?
    var typingTests=[TypingResult]()
    var inferenceModel:LocationModel {frozen?.model ?? model}
    var typingController:TypingTestController?
    var typingActive:Bool {typingController?.isActive == true}
    let typingButton=NSButton(title:"Typing test…",target:nil,action:nil)
    let freezeButton=NSButton(title:"Freeze motion model",target:nil,action:nil)
    var ripples = [Ripple](), waveform = [Double]()
    var running = false, sampleCount = 0, sampleSkip = 0, rate = 0
    var lastSample = 0.0, started = 0.0, rateTime = 0.0, rateCount = 0
    var count = 0, peak = 0.0, region = "No impacts yet", detail = "Start the sensor, then gently tap the chassis."
    let hardware = Hardware.current()
    let store = ProfileStore()
    var trials = [TestTrial](), noiseRuns = [Int]()
    var legacyTrials = [TestTrial](), sourceSizeLabel:String?
    var trialRaw = [MotionSample]()
    let historyField = NSTextField(labelWithString:"")
    let microphone=Microphone()
    let micSwitch=NSButton(checkboxWithTitle:"Include microphone (optional)",target:nil,action:nil)
    var study: String?, studyZone = 0, studyIndex = 0, cueAt = 0.0
    var noiseCount = 0, noiseEnds = 0.0, sensorClockOffset = 0.0
    let sizePicker = NSPopUpButton(), surfacePicker = NSPopUpButton()
    let testButton = NSButton(title:"Test region · 10 trials", target:nil, action:nil)
    let noiseButton = NSButton(title:"Noise test · 20 seconds", target:nil, action:nil)
    let reportField = NSTextField(wrappingLabelWithString:"")
    let promptField = NSTextField(wrappingLabelWithString:"")
    var studyCaptured = 0, lastTrialMissed = false
    var profileReady: Bool { sizePicker.indexOfSelectedItem > 0 && hardware.isMacBook }
    var training: Int? { study == "train" ? studyZone : nil }
    let startButton = NSButton(title: "Start sensor", target: nil, action: nil)
    let demoButton = NSButton(title: "Demo ripple", target: nil, action: nil)
    let learnButton = NSButton(title: "Train region · 20 trials", target: nil, action: nil)
    let clearButton = NSButton(title: "Clear", target: nil, action: nil)
    let resetButton = NSButton(title: "Reset calibration", target: nil, action: nil)
    let permissionButton = NSButton(title: "Sensor access…", target: nil, action: nil)
    let picker = NSPopUpButton()
    let statusField = NSTextField(labelWithString:"Sensor stopped")
    let detailField = NSTextField(wrappingLabelWithString:"")
    let sensitivity = NSSlider(value: 0.012, minValue: 0.003, maxValue: 0.12, target: nil, action: nil)
    var clock: Timer?
    var deck: NSRect { NSRect(x:32,y:134,width:bounds.width-348,height:410) }
    var side: CGFloat { bounds.width-284 }
    override init(frame: NSRect) {
        super.init(frame:frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed:0.067,green:0.071,blue:0.067,alpha:1).cgColor
        for (button,action) in [(startButton,#selector(toggle)),(demoButton,#selector(demo)),(learnButton,#selector(learn)),(clearButton,#selector(clear)),(resetButton,#selector(reset)),(permissionButton,#selector(permission)),(testButton,#selector(testRegion)),(noiseButton,#selector(noiseTest)),(typingButton,#selector(showTyping)),(freezeButton,#selector(freezeMotion))] {
            button.target = self; button.action = action; button.bezelStyle = .rounded; addSubview(button)
        }
        picker.addItems(withTitles:zoneNames); addSubview(picker)
        sizePicker.addItems(withTitles:["Choose chassis…","Small","Big"])
        surfacePicker.addItems(withTitles:["Desk","Stand","Lap"])
        for control in [sizePicker,surfacePicker] { control.target=self;control.action=#selector(changeProfile);addSubview(control) }
        micSwitch.target=self;micSwitch.action=#selector(toggleMicrophone);addSubview(micSwitch)
        historyField.font = .systemFont(ofSize:11);historyField.textColor=muted;addSubview(historyField)
        promptField.font = .systemFont(ofSize:22,weight:.semibold);promptField.textColor=accent;addSubview(promptField)
        reportField.font = .monospacedSystemFont(ofSize:11,weight:.regular);reportField.textColor=muted;addSubview(reportField)
        statusField.font = .systemFont(ofSize:12); addSubview(statusField)
        detailField.font = .systemFont(ofSize:12); detailField.textColor = ink; addSubview(detailField)
        sensitivity.target = self; sensitivity.action = #selector(adjust); addSubview(sensitivity)
        sensitivity.setAccessibilityLabel("Impact threshold in g; lower is more sensitive")
        detector.onImpact = { [weak self] impact in self?.impact(impact) }
        clock = Timer.scheduledTimer(withTimeInterval:1/30, repeats:true) { [weak self] _ in self?.tick() }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector:#selector(sleep), name:NSWorkspace.willSleepNotification, object:nil)
        sizePicker.selectItem(withTitle:"Small");changeProfile()
    }
    required init?(coder:NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        startButton.frame = .init(x:bounds.width-282,y:28,width:132,height:32)
        demoButton.frame = .init(x:bounds.width-142,y:28,width:116,height:32)
        picker.frame = .init(x:side,y:366,width:250,height:28)
        learnButton.frame = .init(x:side,y:402,width:250,height:30)
        testButton.frame = .init(x:side,y:440,width:250,height:28)
        resetButton.frame = .init(x:side,y:478,width:250,height:28)
        noiseButton.frame = .init(x:side,y:638,width:250,height:28)
        reportField.frame = .init(x:side,y:682,width:250,height:145)
        promptField.frame = .init(x:32,y:705,width:bounds.width-360,height:78)
        micSwitch.frame = .init(x:32,y:675,width:350,height:24)
        historyField.frame = .init(x:32,y:600,width:bounds.width-360,height:18)
        typingButton.frame = .init(x:390,y:565,width:150,height:28)
        freezeButton.frame = .init(x:550,y:565,width:250,height:28)
        sizePicker.frame = .init(x:32,y:565,width:190,height:28)
        surfacePicker.frame = .init(x:234,y:565,width:140,height:28)
        sensitivity.frame = .init(x:side,y:558,width:250,height:24)
        permissionButton.frame = .init(x:side,y:600,width:150,height:28)
        clearButton.frame = .init(x:bounds.width-110,y:bounds.height-44,width:80,height:26)
        statusField.frame = .init(x:32,y:100,width:650,height:22)
        detailField.frame = .init(x:32,y:790,width:bounds.width-360,height:40)
    }
    @objc func adjust() {
        guard frozen==nil,!typingActive else{return}
        cancelStudy();detector.threshold=sensitivity.doubleValue;archiveScores();saveProfile()
    }
    @objc func toggleMicrophone(){
        guard frozen==nil,!typingActive else{micSwitch.state = .off;return}
        if micSwitch.state == .on && (!running || !lidIsOpen()) {micSwitch.state = .off;detail="Start the sensor with the lid open before enabling microphone capture.";return}
        if micSwitch.state != .on {microphone.stop();detail="Microphone off. Motion-only sampling continues.";return}
        let enable:()->Void = {[weak self] in
            guard let self,self.micSwitch.state == .on else{return}
            do {try self.microphone.start();self.detail="Microphone on. Retrain both classes for paired comparison; older motion examples remain saved."}
            catch {self.micSwitch.state = .off;self.detail="Microphone could not start: \(error.localizedDescription)"}
        }
        if AVCaptureDevice.authorizationStatus(for:.audio) == .authorized {enable()}
        else {AVCaptureDevice.requestAccess(for:.audio){[weak self] allowed in DispatchQueue.main.async {
            if allowed{enable()}else{self?.micSwitch.state = .off;self?.detail="Microphone not allowed. Motion-only tester remains available."}
        }}}
    }
    @objc func freezeMotion(){
        guard frozen==nil,!typingActive,study==nil,model.trained.count==2 else{return}
        do {
            let selected=model.pairedMotionModel.trained.count==2 ? model.pairedMotionModel : model
            let snapshot=try FrozenMotion.make(model:selected,threshold:detector.threshold,source:model.pairedMotionModel.trained.count==2 ? "paired-motion" : "all-motion")
            let original=store.url(hardware.model,sizePicker.titleOfSelectedItem!,surfacePicker.titleOfSelectedItem!)
            let archive=store.root.appendingPathComponent("archives")
            try FileManager.default.createDirectory(at:archive,withIntermediateDirectories:true)
            if FileManager.default.fileExists(atPath:original.path){
                try FileManager.default.copyItem(at:original,to:archive.appendingPathComponent("before-freeze-"+UUID().uuidString+".json"))
            }
            frozen=snapshot;archiveScores();microphone.stop();micSwitch.state = .off;saveProfile()
            detail="Motion model frozen: \(snapshot.id.prefix(12)). Training, threshold edits and microphone capture are locked."
        }catch{detail="Could not freeze: \(error.localizedDescription)"}
    }
    @objc func showTyping(){
        if typingController==nil {
            let controller=TypingTestController()
            controller.prepare={[weak self] in
                guard let self,let f=self.frozen,self.running,self.detector.ready,self.study==nil,lidIsOpen(),ProcessInfo.processInfo.systemUptime-self.lastSample<1 else{return nil}
                return(f.id,self.detector.effectiveThreshold)
            }
            controller.onFinish={[weak self] result in
                guard let self else{return};self.typingTests.append(result);self.saveProfile()
                self.detail="Typing session saved: \(result.falseLeft) false left detections. Typed text was not saved."
            }
            typingController=controller
        }
        typingController?.showWindow(nil);typingController?.window?.makeKeyAndOrderFront(nil)
    }
    func archiveScores(){legacyTrials.append(contentsOf:trials);trials=[];noiseRuns=[]}
    func cancelStudy(){study=nil;noiseEnds=0;learnButton.title="Train region · 20 trials"}
    @objc func changeProfile(){
        typingController?.end(reason:"profile changed");microphone.stop();micSwitch.state = .off
        frozen=nil;typingTests=[]
        cancelStudy();model=LocationModel();trials=[];noiseRuns=[];legacyTrials=[];sourceSizeLabel=nil;ripples=[];detector.reset()
        detector.threshold=0.012;sensitivity.doubleValue=0.012
        guard profileReady else {detail="Choose Small or Big for this MacBook. Desktop Macs are unsupported.";return}
        do {
            if let p=try store.load(hardware.model,sizePicker.titleOfSelectedItem!,surfacePicker.titleOfSelectedItem!){
                model=p.model;trials=p.trials;noiseRuns=p.noiseRuns;frozen=p.frozen;typingTests=p.typingTests ?? [];legacyTrials=p.legacyTrials ?? [];sourceSizeLabel=p.sourceSizeLabel;detector.threshold=p.threshold;sensitivity.doubleValue=p.threshold
            }
            if let f=frozen {detector.threshold=f.threshold;sensitivity.doubleValue=f.threshold}
            else if sizePicker.titleOfSelectedItem == "Small",model.trained.count==2 {freezeMotion()}
            detail="Profile: \(hardware.name) · \(sizePicker.titleOfSelectedItem!) · \(surfacePicker.titleOfSelectedItem!). Keep hands still for one second."
        } catch {detail="Profile could not be loaded. No calibration used: \(error.localizedDescription)"}
    }
    func saveProfile(){
        guard profileReady else{return}
        do {try store.save(CalibrationProfile(schema:3,hardware:hardware.model,size:sizePicker.titleOfSelectedItem!,surface:surfacePicker.titleOfSelectedItem!,threshold:detector.threshold,model:model,trials:trials,noiseRuns:noiseRuns,legacyTrials:legacyTrials,frozen:frozen,typingTests:typingTests,sourceSizeLabel:sourceSizeLabel,classifierVersion:classifierVersion))}
        catch {detail="Could not save profile: \(error.localizedDescription)"}
    }
    func beginStudy(_ kind:String){
        guard !typingActive else{detail="Finish the typing test first.";return}
        guard kind != "train" || frozen==nil else{detail="Training is locked by the frozen model.";return}
        guard profileReady else{detail="Choose Small or Big first.";return}
        guard running else{detail="Sensor is stopped. Click Start sensor, wait for baseline ready, then try again.";return}
        guard lastSample>0,ProcessInfo.processInfo.systemUptime-lastSample<1 else{detail="No live sensor samples. Stop and restart the sensor.";return}
        guard detector.ready else{detail="Keep the Mac still for one second while noise calibration finishes.";return}
        if kind == "test" {
            let count=model.samples[picker.indexOfSelectedItem]?.count ?? 0
            guard model.trained.contains(picker.indexOfSelectedItem),model.trained.count>=2 else {
                detail="Test blocked: selected region has \(count)/12 captures; \(model.trained.count)/2 regions ready. Completed trials without captured taps do not train the model."
                return
            }
        }
        cancelStudy();study=kind;studyZone=picker.indexOfSelectedItem;studyIndex=0;studyCaptured=0;lastTrialMissed=false
        if kind == "train" {archiveScores();saveProfile()}
        trialRaw=[];cueAt=ProcessInfo.processInfo.systemUptime+1.4
        detail="Get ready. Follow the visual cues; one tap per trial."
    }
    @objc func testRegion(){beginStudy("test")}
    @objc func noiseTest(){
        guard !typingActive else{return}
        guard running,detector.ready else{detail="Start sensor and wait for baseline first.";return}
        cancelStudy();study="noise";noiseCount=0;noiseEnds=ProcessInfo.processInfo.systemUptime+20
        detail="Noise test: type, use trackpad, or handle cables. Do not deliberately tap."
    }
    func finishTrial(_ event:Impact?){
        guard let kind=study,kind != "noise" else{return}
        lastTrialMissed = event == nil
        if kind == "train" {if let event {model.add(event,zone:studyZone);studyCaptured+=1}}
        else {trials.append(TestTrial(expected:studyZone,predicted:event.flatMap{inferenceModel.estimate($0.feature)?.0},missed:event == nil,impact:event,diagnostic:trialRaw,classifierVersion:frozen?.id ?? classifierVersion,micPredicted:event.flatMap{e in e.audio.flatMap{model.pairedModel.estimate(e.feature+$0)?.0}},pairedMotionPredicted:event.flatMap{model.pairedMotionModel.estimate($0.feature)?.0},micAvailable:event?.audio != nil,pairedModelReady:microphone.enabled && model.pairedModel.trained.count==2))}
        studyIndex+=1
        saveProfile()
        if studyIndex >= (kind == "train" ? 20 : 10) {
            cancelStudy();saveProfile()
            detail=kind == "train" ? "Training: \(studyCaptured)/20 captured this session; \(model.samples[studyZone]?.count ?? 0) saved total. Need 12 captures per region and two ready regions for Test." : "Test complete. Fresh raw sensor windows saved, including missed taps. Unknown is not a left trigger."
        } else {trialRaw=[];cueAt=ProcessInfo.processInfo.systemUptime+1.4}
    }
    @objc func toggle() {
        if running { stop(); return }
        guard profileReady else{detail="Choose Small or Big first. Only MacBooks are supported.";return}
        guard lidIsOpen() else{detail="Open the MacBook lid before starting. Unknown lid state is unsupported.";return}
        detector.reset(); sampleCount = 0; rate = 0; rateCount = 0
        started = ProcessInfo.processInfo.systemUptime; rateTime = started; lastSample = 0
        let result = sensor_start(sensorCallback)
        running = result == 0
        startButton.title = running ? "Stop sensor" : "Retry sensor"
        detail = running ? "Connecting to accelerometer…" : "Sensor unavailable (\(result)). Try Sensor access."
        needsDisplay = true
    }
    func stop() { typingController?.end(reason:"sensor stopped");microphone.stop();micSwitch.state = .off;saveProfile();sensor_stop(); running = false; cancelStudy(); startButton.title = "Start sensor"; detail = "Sensor stopped. Calibration is saved in this machine’s profile."; rate = 0; needsDisplay = true }
    @objc func sleep() { if running { stop() } }
    @objc func permission() {
        // Requests a macOS prompt; it never grants permission on the user's behalf.
        if !IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) {
            NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
        }
        detail = "After granting access, quit and reopen Tap Lab."
    }
    @objc func demo() {
        let zone = picker.indexOfSelectedItem
        ripples.append(Ripple(point:zonePoints[zone],peak:0.18,time:ProcessInfo.processInfo.systemUptime,demo:true,unknown:false))
        detail = "Demo only · simulated impact, not sensor data."
    }
    @objc func learn() { if study != nil {cancelStudy();saveProfile();detail="Study cancelled. Captured examples have been saved."} else {beginStudy("train")} }
    @objc func reset() { guard frozen==nil,!typingActive else{return};cancelStudy();model=LocationModel();trials=[];noiseRuns=[];legacyTrials=[];saveProfile();detail="Current profile calibration and scores cleared." }
    @objc func clear() { ripples = []; waveform = []; count = 0; peak = 0; region = "No impacts yet" }
    func sample(_ t:Double,_ x:Double,_ y:Double,_ z:Double) {
        guard running,x.isFinite,y.isFinite,z.isFinite,t.isFinite else { return }
        if sampleCount == 0 { sensorClockOffset=ProcessInfo.processInfo.systemUptime-t; detail = "Live. Gently tap the chassis; train regions for location estimates." }
        lastSample = ProcessInfo.processInfo.systemUptime; sampleCount += 1
        if study == "test",lastSample>=cueAt,lastSample<=cueAt+4.25,trialRaw.count<10000 {
            trialRaw.append(MotionSample(t:lastSample-cueAt,xyz:[x,y,z]))
        }
        detector.ingest(t,[x,y,z]); sampleSkip += 1
        if sampleSkip % 8 == 0 { waveform.append(min(detector.magnitude,0.5)); if waveform.count > 230 { waveform.removeFirst() } }
    }
    func impact(_ captured:Impact) {
        var event=captured
        if microphone.enabled {event.audio=microphone.features(at:event.onset+sensorClockOffset);event.audioSource=microphone.source}
        typingController?.record(event,prediction:inferenceModel.estimate(event.feature)?.0)
        count += 1; peak = event.peak
        var point = NSPoint(x:0.5,y:0.5), unknown = true
        if study == "noise" {noiseCount+=1}
        if let kind=study,kind != "noise" {
            if event.onset+sensorClockOffset >= cueAt,event.onset+sensorClockOffset <= cueAt+4 {
                let zone=studyZone
                if kind == "train" {point=zonePoints[zone];unknown=false;region="Training \(zoneNames[zone])"}
                else if let (estimated,_) = inferenceModel.estimate(event.feature) {point=zonePoints[estimated];unknown=false;region=zoneNames[estimated]}
                else {region="Test: unknown location"}
                finishTrial(event)
            } else {region="Ignored · wait for visual cue"}
        } else if let (zone,margin) = inferenceModel.estimate(event.feature) {
            point = zonePoints[zone]; unknown = false; region = zone == 0 ? "LEFT SIDE detected" : "Not left side"
            detail = "Experimental match · \(margin > 0.6 ? "clearer" : "weak") separation, not a probability."
        } else {
            region = "Location unknown"
            detail = "No left-side confirmation · train left and varied right/center examples."
        }
        ripples.append(Ripple(point:point,peak:event.peak,time:ProcessInfo.processInfo.systemUptime,demo:false,unknown:unknown))
        if ripples.count > 32 { ripples.removeFirst() }
    }
    func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        ripples.removeAll { now - $0.time > 2 }
        if running, now - rateTime >= 1 {
            if !lidIsOpen(){stop();detail="Stopped: lid is closed or its state is unknown."}
            rate = Int(Double(sampleCount-rateCount)/(now-rateTime)); rateCount = sampleCount; rateTime = now
            if now-started > 3, lastSample == 0 { detail = "No samples received. Try Sensor access, then relaunch." }
            else if lastSample > 0, now-lastSample > 2 { detail = "Sensor stream stalled. Stop and restart the sensor."; detector.reset();cancelStudy();typingController?.end(reason:"sensor stalled") }
        }
        if study == "noise",now>=noiseEnds {noiseRuns.append(noiseCount);cancelStudy();saveProfile();detail="Noise test complete: \(noiseCount) detected impacts in 20 seconds. These are candidates, not navigation actions."}
        if let kind=study,kind != "noise" {
            let total=kind == "train" ? 20 : 10
            if now>cueAt+4.25 {finishTrial(nil)}
            else if now>=cueAt {detail="TAP NOW · \(zoneNames[studyZone]) · \(studyIndex+1)/\(total) · one gentle tap"}
            else {detail=lastTrialMissed ? "No impact captured. Tap more firmly or lower threshold after cancelling. Next cue soon." : "Wait… \(zoneNames[studyZone]) · trial \(studyIndex+1)/\(total)"}
        }
        for control in [picker,sizePicker,surfacePicker] {control.isEnabled = study == nil && !typingActive}
        sensitivity.isEnabled = study == nil && frozen==nil && !typingActive
        micSwitch.isEnabled = study == nil && frozen==nil && !typingActive
        testButton.isEnabled = study == nil && !typingActive;noiseButton.isEnabled = study == nil && !typingActive;resetButton.isEnabled = study == nil && frozen==nil && !typingActive
        freezeButton.isEnabled=frozen==nil && study==nil && !typingActive && model.trained.count==2
        freezeButton.title=frozen.map{"Frozen · \($0.id.prefix(12))"} ?? "Freeze motion model"
        learnButton.isEnabled = !typingActive && (frozen==nil || study != nil)
        learnButton.title=study == nil ? "Train region · 20 trials" : "Cancel study"
        let selectedTrials=trials.filter{$0.expected == picker.indexOfSelectedItem}
        let correct=trials.filter{!$0.missed && $0.predicted == $0.expected}.count
        let missed=trials.filter(\.missed).count
        let unknown=trials.filter{!$0.missed && $0.predicted == nil}.count
        let wrong=trials.count-correct-missed-unknown
        let selectedCorrect=selectedTrials.filter{!$0.missed && $0.predicted == $0.expected}.count
        let left=model.samples[0]?.count ?? 0,right=model.samples[1]?.count ?? 0
        reportField.stringValue=trials.isEmpty ? "Left:    \(left)/12 captured\nNot left: \(right)/12 captured\nReady regions: \(model.trained.count)/2 needed\nFresh test trials: none\nNoise runs: \(noiseRuns.count)" : "Fresh trials: \(trials.count)\nCorrect \(correct) · Wrong \(wrong)\nUnknown \(unknown) · Missed \(missed)\nAll-trial accuracy: \(Int(Double(correct)/Double(trials.count)*100))%\nSelected region: \(selectedCorrect)/\(selectedTrials.count) correct\nLast noise run: \(noiseRuns.last.map(String.init) ?? "not run")"
        if let kind=study,kind != "noise" {
            promptField.stringValue=now>=cueAt ? "TAP NOW · \(zoneNames[studyZone])\n\(studyIndex+1)/\(kind == "train" ? 20 : 10) trials · \(studyCaptured) captured this session" : "WAIT · next tap cue soon"
        } else if !running {promptField.stringValue="1. Start sensor  →  2. Train both sides  →  3. Test"}
        else {promptField.stringValue="Saved: Left \(left) · Not left \(right) captures\n\(model.trained.count >= 2 ? "Ready to test left versus not-left" : "Each side needs at least 12 captured taps")"}
        if let f=frozen {
            promptField.stringValue=typingActive ? "Typing test running · model locked" : "Frozen motion model · \(f.model.samples.values.reduce(0){$0+$1.count}) examples\nUse Typing test to check for false left triggers."
        }
        if let last=typingTests.last {reportField.stringValue += "\nTyping: \(last.falseLeft) false left / \(Int(last.duration))s"}
        let old=legacyTrials.filter{$0.classifierVersion == "legacy-v2"}
        let oldLeft=old.filter{$0.expected==0}, oldOther=old.filter{$0.expected==1}
        historyField.stringValue=old.isEmpty ? "No imported historical tests for this profile." : "Old v2 tests: left \(oldLeft.filter{!$0.missed && $0.predicted==0}.count)/\(oldLeft.count), not-left \(oldOther.filter{!$0.missed && $0.predicted==1}.count)/\(oldOther.count) correct. New version needs fresh tests."
        let paired=model.pairedModel
        let micRows=trials.filter{$0.pairedModelReady == true}
        let micCorrect=micRows.filter{!$0.missed && $0.micPredicted == $0.expected}.count
        let motionCorrect=micRows.filter{!$0.missed && $0.pairedMotionPredicted == $0.expected}.count
        if microphone.enabled {
            let a=paired.samples[0]?.count ?? 0,b=paired.samples[1]?.count ?? 0
            promptField.stringValue += "\nMic pairs: left \(a), not-left \(b) · need 12 each"
        }
        if !micRows.isEmpty {reportField.stringValue += "\nPaired motion: \(motionCorrect)/\(micRows.count)\nFusion: \(micCorrect)/\(micRows.count)\nMic features: \(micRows.filter{$0.micAvailable == true}.count)/\(micRows.count)"}
        micSwitch.title=microphone.enabled ? microphone.status : "Include microphone (optional)"
        let live = running && lastSample > 0 && now-lastSample < 2
        statusField.stringValue = live ? "●  Live accelerometer · \(rate) Hz · \(sampleCount) samples · \(detector.ready ? "baseline ready" : "keep still")" : running ? "○  Waiting for sensor" : "○  Sensor stopped"
        statusField.textColor = live ? accent : muted
        detailField.stringValue = detail
        needsDisplay = true
    }
    func text(_ value:String,_ x:CGFloat,_ y:CGFloat,_ size:CGFloat = 13,_ color:NSColor = ink,_ weight:NSFont.Weight = .regular,_ width:CGFloat = 900) {
        let p = NSMutableParagraphStyle(); p.lineBreakMode = .byWordWrapping
        (value as NSString).draw(in:NSRect(x:x,y:y,width:width,height:70),withAttributes:[.font:NSFont.systemFont(ofSize:size,weight:weight),.foregroundColor:color,.paragraphStyle:p])
    }
    func rounded(_ r:NSRect,_ color:NSColor,_ radius:CGFloat = 8) { color.setFill(); NSBezierPath(roundedRect:r,xRadius:radius,yRadius:radius).fill() }
    override func draw(_ dirtyRect:NSRect) {
        super.draw(dirtyRect)
        text("Tap Lab",32,24,27,ink,.semibold)
        text("\(hardware.name) · \(hardware.model) · open lid only",32,62,13,muted)
        let d = deck
        rounded(d,NSColor(srgbRed:0.28,green:0.30,blue:0.29,alpha:1),18)
        rounded(d.insetBy(dx:2,dy:2),NSColor(srgbRed:0.23,green:0.25,blue:0.24,alpha:1),16)
        rounded(.init(x:d.minX+18,y:d.minY+12,width:d.width-36,height:6),NSColor(white:0.12,alpha:1),3)
        // Speaker grilles and the MagSafe port establish the physical orientation.
        for side in [d.minX+18,d.maxX-29] { for row in 0..<28 { for col in 0..<3 {
            rounded(.init(x:side+CGFloat(col)*3,y:d.minY+48+CGFloat(row)*5,width:1.4,height:1.4),NSColor(white:0.12,alpha:1),0.7)
        } } }
        rounded(.init(x:d.minX-3,y:d.minY+76,width:5,height:22),accent,2)
        let rows = ["esc  ◇  ◇  ◇  ◇  ◇  ◇  ◇  ◇  ◇  ◇  ◇  ⏻", "`  1  2  3  4  5  6  7  8  9  0  −  =", "⇥  Q  W  E  R  T  Y  U  I  O  P  [  ]", "⇪  A  S  D  F  G  H  J  K  L  ;  '  ↵", "⇧  Z  X  C  V  B  N  M  ,  .  /  ⇧"]
        let keyboard = NSRect(x:d.minX+42,y:d.minY+38,width:d.width-84,height:204)
        rounded(keyboard.insetBy(dx:-5,dy:-5),NSColor(white:0.10,alpha:1),7)
        for (row,line) in rows.enumerated() {
            let keys = line.components(separatedBy:"  ")
            let kw = (keyboard.width-CGFloat(keys.count-1)*4)/CGFloat(keys.count)
            for (col,key) in keys.enumerated() {
                let r = NSRect(x:keyboard.minX+CGFloat(col)*(kw+4),y:keyboard.minY+CGFloat(row)*39,width:kw,height:33)
                rounded(r,NSColor(white:0.13,alpha:1),4)
                text(key,r.minX+5,r.minY+10,key.count > 2 ? 8 : 10,NSColor(white:0.72,alpha:1))
            }
        }
        let bottom = ["fn","⌃","⌥","⌘","","⌘","⌥","◀","▲▼","▶"]
        var kx = keyboard.minX
        let unit = (keyboard.width-36)/14
        for key in bottom {
            let w = key.isEmpty ? unit*5 : unit
            rounded(.init(x:kx,y:keyboard.minY+195,width:w,height:31),NSColor(white:0.13,alpha:1),4)
            text(key,kx+4,keyboard.minY+205,9,NSColor(white:0.72,alpha:1)); kx += w+4
        }
        let track = NSRect(x:d.midX-d.width*0.19,y:d.minY+278,width:d.width*0.38,height:110)
        rounded(track,NSColor(srgbRed:0.26,green:0.28,blue:0.27,alpha:1),8)
        NSColor(white:0.4,alpha:0.6).setStroke(); NSBezierPath(roundedRect:track,xRadius:8,yRadius:8).stroke()
        text("MagSafe",d.minX+8,d.minY+257,9,muted)
        if let kind=study,kind != "noise" {
            let pos=zonePoints[studyZone]
            let center=NSPoint(x:d.minX+d.width*pos.x,y:d.minY+d.height*pos.y)
            let p=NSBezierPath(ovalIn:NSRect(x:center.x-20,y:center.y-20,width:40,height:40))
            (ProcessInfo.processInfo.systemUptime>=cueAt ? accent : muted).setStroke();p.lineWidth=2;p.stroke()
            text("TARGET",max(d.minX,center.x-23),center.y+27,10,accent)
        }
        for r in ripples {
            let age = ProcessInfo.processInfo.systemUptime-r.time
            let center = NSPoint(x:d.minX+d.width*r.point.x,y:d.minY+d.height*r.point.y)
            let size = CGFloat(16+min(sqrt(r.peak)*110,105))
            let color = r.demo ? NSColor.systemBlue : r.unknown ? NSColor.systemOrange : r.point.x < 0.5 ? accent : muted
            for ring in 0..<3 {
                let radius = size*(0.45+CGFloat(age)*0.60)+CGFloat(ring)*10
                let p = NSBezierPath(ovalIn:.init(x:center.x-radius,y:center.y-radius,width:radius*2,height:radius*2))
                color.withAlphaComponent(max(0,(1-age/2)*0.65-Double(ring)*0.12)).setStroke(); p.lineWidth = 1.5; p.stroke()
            }
            rounded(.init(x:center.x-3,y:center.y-3,width:6,height:6),color,3)
        }
        text("TOP VIEW",d.minX+12,d.maxY+3,10,muted,.medium)
        text("Bigger circle = stronger motion",d.maxX-245,d.maxY+16,12,muted)
        text("LAST IMPACT",side,110,10,muted,.semibold)
        text(String(format:"%.3f",peak),side,135,43,ink,.light)
        text("g · peak dynamic acceleration",side,190,12,muted)
        text(region,side,228,17,ink,.medium,250)
        text("\(count) physical impacts detected",side,271,12,muted)
        text("GUIDED CALIBRATION & TESTING",side,325,10,muted,.semibold)
        let trained = model.trained.count
        text("\(trained)/2 ready · selected: \(model.samples[picker.indexOfSelectedItem]?.count ?? 0) examples",side,513,12,muted)
        text(String(format:"Effective threshold · %.3f g",detector.effectiveThreshold),side,537,12,muted)
        text("More sensitive ←                  → Less",side,584,10,muted)
        let graph = NSRect(x:32,y:620,width:d.width,height:58)
        rounded(graph,NSColor(white:0.10,alpha:1),6)
        if waveform.count > 1 {
            let path = NSBezierPath()
            for (i,value) in waveform.enumerated() {
                let p = NSPoint(x:graph.minX+CGFloat(i)/229*graph.width,y:graph.maxY-6-CGFloat(value)*95)
                if i == 0 {path.move(to:p)} else {path.line(to:p)}
            }
            accent.setStroke(); path.lineWidth = 1.2; path.stroke()
        }
        text("Left-side experiment · green confirms left; gray is not-left; orange is unknown. Points are schematic, not coordinates.",32,842,11,muted,.regular,bounds.width-64)
    }
}
final class Delegate: NSObject, NSApplicationDelegate {
    var window:NSWindow!
    func applicationDidFinishLaunching(_ notification:Notification) {
        window = NSWindow(contentRect:.init(x:0,y:0,width:1120,height:890),styleMask:[.titled,.closable,.miniaturizable],backing:.buffered,defer:false)
        window.title = "Tap Lab · MacBook impact visualizer"
        window.appearance = NSAppearance(named:.darkAqua)
        let view = LabView(frame:window.contentView!.bounds); lab = view; window.contentView = view
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool { true }
    func applicationWillTerminate(_ notification:Notification) { lab?.typingController?.end(reason:"app quit");lab?.microphone.stop();sensor_stop() }
}
if let i=CommandLine.arguments.firstIndex(of:"--analyze-profile"),i+1<CommandLine.arguments.count {
    do {try analyzeProfile(URL(fileURLWithPath:CommandLine.arguments[i+1]));exit(0)} catch {print(error);exit(1)}
}
if CommandLine.arguments.contains("--self-test") { selfTest(); profileSelfTest();microphoneSelfTest();freezeSelfTest(); exit(0) }
let app = NSApplication.shared
let delegate = Delegate(); app.delegate = delegate; app.setActivationPolicy(.regular)
let menu = NSMenu(); let item = NSMenuItem(); let submenu = NSMenu()
submenu.addItem(withTitle:"Quit Tap Lab",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
item.submenu = submenu; menu.addItem(item); app.mainMenu = menu
app.run()
