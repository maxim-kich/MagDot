import AppKit

private let green=NSColor(srgbRed:0.26,green:0.75,blue:0.49,alpha:1)
private let foreground=NSColor(srgbRed:0.81,green:0.86,blue:0.80,alpha:1)
private let secondary=NSColor(srgbRed:0.55,green:0.59,blue:0.55,alpha:1)
private var gestureView:GestureView?
private func receiveGestureSample(_ t:Double,_ x:Double,_ y:Double,_ z:Double){gestureView?.sample(t,[x,y,z])}

final class KeyboardView:NSView {
    override var isFlipped:Bool{true}
    var connector=false
    var ripples=[(Double,Int?,Double)]()
    func text(_ s:String,_ r:NSRect,_ size:CGFloat=11){(s as NSString).draw(in:r,withAttributes:[.font:NSFont.systemFont(ofSize:size),.foregroundColor:foreground])}
    func box(_ r:NSRect,_ c:NSColor,_ radius:CGFloat=5){c.setFill();NSBezierPath(roundedRect:r,xRadius:radius,yRadius:radius).fill()}
    override func draw(_ dirty:NSRect){
        let d=bounds.insetBy(dx:12,dy:12)
        box(d,NSColor(white:0.24,alpha:1),18)
        box(NSRect(x:d.minX+20,y:25,width:d.width-40,height:6),NSColor(white:0.10,alpha:1),3)
        box(NSRect(x:d.minX-3,y:70,width:5,height:23),green,2)
        if connector{box(NSRect(x:4,y:67,width:26,height:28),green,5);box(NSRect(x:0,y:77,width:8,height:7),secondary,2)}
        let rows=["esc ◇ ◇ ◇ ◇ ◇ ◇ ◇ ◇ ◇ ◇ ◇ ⏻","` 1 2 3 4 5 6 7 8 9 0 − =","⇥ Q W E R T Y U I O P [ ]","⇪ A S D F G H J K L ; ' ↵","⇧ Z X C V B N M , . / ⇧","fn ⌃ ⌥ ⌘ SPACE ⌘ ⌥ ◀ ▲ ▶"]
        for (j,row) in rows.enumerated(){
            let keys=row.split(separator:" "),unit=(d.width-85)/CGFloat(j==5 ? 14 : keys.count)
            var x=d.minX+38
            for key in keys {let width=key=="SPACE" ? unit*5-4 : unit-4;let r=NSRect(x:x,y:52+CGFloat(j)*35,width:width,height:30);box(r,NSColor(white:0.12,alpha:1));if key != "SPACE"{text(String(key),r.insetBy(dx:5,dy:8),key.count>2 ? 8 : 10)};x+=width+4}
        }
        box(NSRect(x:d.midX-d.width*0.20,y:285,width:d.width*0.40,height:105),NSColor(white:0.29,alpha:1),8)
        text(connector ? "Tap attached connector" : "Chassis target",NSRect(x:22,y:255,width:150,height:20),10)
        let now=ProcessInfo.processInfo.systemUptime
        for (time,side,peak) in ripples where now-time<1.8 {
            let point=NSPoint(x:side==0 ? (connector ? 17:d.minX+20) : side==1 ? d.maxX-55 : d.midX,y:side==0 ? 95 : side==1 ? 225 : 190)
            let color=side==0 ? green : side==1 ? secondary : NSColor.systemOrange
            for i in 0..<3 {
                let radius=CGFloat(20+sqrt(min(peak,1))*80)*(0.5+CGFloat(now-time)*0.6)+CGFloat(i)*9
                let path=NSBezierPath(ovalIn:NSRect(x:point.x-radius,y:point.y-radius,width:radius*2,height:radius*2))
                color.withAlphaComponent(max(0,0.8-(now-time)*0.45-Double(i)*0.12)).setStroke();path.lineWidth=1.5;path.stroke()
            }
        }
    }
}
final class GestureView:NSView {
    override var isFlipped:Bool{true}
    let hardware=Hardware.current()
    var data=GestureDataStore(target:.connector)
    let detector=BurstDetector(),matcher=DoubleTapMatcher(),keyboard=KeyboardView()
    var bank=ContextBank(),bankID=""
    let start=NSButton(title:"Start sensor",target:nil,action:nil)
    let reload=NSButton(title:"Reload recorded anchors",target:nil,action:nil)
    let attention=NSButton(checkboxWithTitle:"Simulate agent Done / Needs input",target:nil,action:nil)
    let typing=NSButton(title:"Typing / false-gesture test…",target:nil,action:nil)
    let collect=NSButton(title:"Collect 10 prompted trials",target:nil,action:nil)
    let showFiles=NSButton(title:"Open dataset folder",target:nil,action:nil)
    let condition=NSPopUpButton(),split=NSPopUpButton(),category=NSPopUpButton(),targetSelector=NSPopUpButton()
    let status=NSTextField(wrappingLabelWithString:""),prompt=NSTextField(wrappingLabelWithString:""),report=NSTextField(wrappingLabelWithString:"")
    var running=false,samples=0,lastSample=0.0,offset=0.0,timer:Timer?,rate=0,rateStart=0.0,rateSamples=0
    var gestureCount=0,lastDecision="No confirmed double-taps",typingController:TypingTestController?
    var preRoll=[MotionSample]()
    var batch=false,index=0,cueAt=0.0,raw=[MotionSample](),candidates=[GestureCandidate](),decisions=[GestureDecision](),batchSummary=[String](),errorText=""
    var armed:Bool{attention.state == .on && !(batch && category.titleOfSelectedItem==data.target.categories[4])}
    var typingActive:Bool{typingController?.isActive==true}
    override init(frame:NSRect){
        super.init(frame:frame);wantsLayer=true;layer?.backgroundColor=NSColor(white:0.065,alpha:1).cgColor
        func label(_ text:String,_ rect:NSRect,_ size:CGFloat=13,_ color:NSColor=foreground){let l=NSTextField(wrappingLabelWithString:text);l.frame=rect;l.font = .systemFont(ofSize:size);l.textColor=color;addSubview(l)}
        label("Tap Lab · MagSafe double-tap",NSRect(x:28,y:22,width:700,height:36),26)
        label("Automatic context · \(hardware.name) / \(hardware.model) · open lid only",NSRect(x:28,y:63,width:730,height:24),12,secondary)
        label("Sandbox: confirms “would focus T3” only. The agent state below is simulated; no T3 navigation is performed.",NSRect(x:28,y:91,width:1060,height:30),12,secondary)
        for (button,action) in [(start,#selector(toggle)),(reload,#selector(loadBank)),(typing,#selector(openTyping)),(collect,#selector(collectTrials)),(showFiles,#selector(files)),(attention,#selector(gateChanged))]{button.target=self;button.action=action;if button !== attention{button.bezelStyle = .rounded};addSubview(button)}
        start.frame=NSRect(x:880,y:24,width:200,height:32)
        attention.frame=NSRect(x:28,y:126,width:420,height:28);attention.state = .on
        reload.frame=NSRect(x:760,y:126,width:320,height:30)
        keyboard.frame=NSRect(x:16,y:170,width:718,height:420);addSubview(keyboard)
        status.frame=NSRect(x:28,y:600,width:700,height:66);status.font = .monospacedSystemFont(ofSize:12,weight:.regular);status.textColor=green;addSubview(status)
        prompt.frame=NSRect(x:28,y:682,width:700,height:78);prompt.font = .systemFont(ofSize:21,weight:.semibold);prompt.textColor=foreground;addSubview(prompt)
        label("DATASET COLLECTION",NSRect(x:760,y:182,width:320,height:24),12,secondary)
        label("Choose the tap target. Connector and chassis recordings/models stay separate; condition is metadata only.",NSRect(x:760,y:213,width:320,height:54),12,secondary)
        condition.addItems(withTitles:["desk","lap","stand","other"]);condition.selectItem(withTitle:"lap")
        split.addItems(withTitles:["Validation","Train"])
        targetSelector.addItems(withTitles:GestureTarget.allCases.map(\.rawValue));targetSelector.selectItem(withTitle:GestureTarget.connector.rawValue);targetSelector.target=self;targetSelector.action = #selector(targetChanged)
        category.addItems(withTitles:data.target.categories);split.selectItem(withTitle:"Train");keyboard.connector=true
        for p in [condition,split,category,targetSelector]{addSubview(p)}
        label("Condition label (collection only)",NSRect(x:760,y:310,width:320,height:20),12,secondary)
        targetSelector.frame=NSRect(x:760,y:270,width:320,height:28)
        condition.frame=NSRect(x:760,y:332,width:320,height:28);split.frame=NSRect(x:760,y:374,width:320,height:28);category.frame=NSRect(x:760,y:416,width:320,height:28)
        collect.frame=NSRect(x:760,y:460,width:320,height:32)
        typing.frame=NSRect(x:760,y:508,width:320,height:32);showFiles.frame=NSRect(x:760,y:554,width:320,height:32)
        report.frame=NSRect(x:760,y:600,width:320,height:164);report.font = .monospacedSystemFont(ofSize:12,weight:.regular);report.textColor=secondary;addSubview(report)
        label("Connector study: collect 10 Train connector doubles, then 10 Train chassis doubles. Switch to Validation for fresh connector, chassis, single taps and cable handling.\nUnknown / 0 confirmations during initial capture is normal; raw motion is still saved. No text or audio is recorded.",NSRect(x:28,y:785,width:1050,height:64),12,secondary)
        detector.onImpact={[weak self] in self?.impact($0)}
        timer=Timer.scheduledTimer(withTimeInterval:1/30,repeats:true){[weak self] _ in self?.tick()}
        NSWorkspace.shared.notificationCenter.addObserver(self,selector:#selector(sleep),name:NSWorkspace.willSleepNotification,object:nil)
        loadBank()
        DispatchQueue.main.async{[weak self] in self?.toggle()}
    }
    required init?(coder:NSCoder){fatalError()}
    @objc func targetChanged(){
        guard !batch,!typingActive,let title=targetSelector.titleOfSelectedItem,let target=GestureTarget(rawValue:title) else{return}
        data=GestureDataStore(target:target);category.removeAllItems();category.addItems(withTitles:target.categories)
        split.selectItem(withTitle:target == .connector ? "Train":"Validation");keyboard.connector=target == .connector
        detector.reset();matcher.reset();preRoll=[];gestureCount=0;batchSummary=[];errorText="";loadBank()
    }
    @objc func loadBank(){
        guard !batch,!typingActive else{return}
        bank=data.bank(hardware:hardware.model,legacyRoot:ProfileStore().root);bankID=bank.id;matcher.reset()
        lastDecision="\(data.target.rawValue) · \(bank.experts.count) context models. Raw recording works before a model is ready."
    }
    @objc func gateChanged(){matcher.reset()}
    @objc func toggle(){
        if running{stop();return}
        guard hardware.isMacBook,lidIsOpen() else{errorText="Open the MacBook lid. Desktop and unknown hardware are unsupported.";return}
        detector.reset();matcher.reset();samples=0;rate=0;lastSample=0;rateStart=ProcessInfo.processInfo.systemUptime;rateSamples=0
        running=sensor_start(receiveGestureSample)==0;start.title=running ? "Stop sensor" : "Retry sensor"
        errorText=running ? "" : "Sensor access failed. Existing data is preserved."
    }
    func stop(){
        if batch{finishTrial(completed:false);batch=false}
        typingController?.end(reason:"sensor stopped");sensor_stop();running=false;start.title="Start sensor";matcher.reset()
    }
    @objc func sleep(){stop()}
    func sample(_ t:Double,_ xyz:[Double]){
        guard running else{return}
        let host=ProcessInfo.processInfo.systemUptime
        if samples==0{offset=host-t}
        lastSample=host;samples+=1
        if batch,host>=cueAt,host<=cueAt+4.25,raw.count<6000{
            if raw.isEmpty {raw=preRoll.map{MotionSample(t:$0.t-cueAt,xyz:$0.xyz)}}
            raw.append(MotionSample(t:host-cueAt,xyz:xyz))
        }
        preRoll.append(MotionSample(t:host,xyz:xyz));preRoll.removeAll{host-$0.t>1.2}
        let wasReady=detector.ready
        matcher.advance(t-0.14)
        detector.ingest(t,xyz)
        if wasReady && !detector.ready {
            if batch{finishTrial(completed:false)}
            typingController?.end(reason:"sensor timestamp gap")
            matcher.reset();errorText="Timestamp gap: active study ended as partial. Wait for a new quiet baseline."
        }
    }
    func impact(_ event:Impact){
        let candidate=GestureCandidate(impact:event,evidence:bank.evidence(event.feature))
        let hostOnset=event.onset+offset
        let inCue=batch && hostOnset>=cueAt && hostOnset<=cueAt+4
        if batch && !inCue{return}
        if inCue{candidates.append(candidate)}
        typingController?.record(event,prediction:candidate.evidence.side)
        keyboard.ripples.append((ProcessInfo.processInfo.systemUptime,candidate.evidence.side,event.peak))
        if let decision=matcher.ingest(candidate,armed:armed){
            if inCue{decisions.append(decision)}
            if decision.accepted{gestureCount+=1;typingController?.recordGesture()}
            lastDecision=(decision.accepted ? "WOULD FOCUS T3 · " : "Pair rejected · ")+decision.reason
        }
    }
    @objc func collectTrials(){
        if batch{finishTrial(completed:false);batch=false;return}
        guard running,detector.ready,!typingActive else{errorText="Start sensor, hold still until baseline ready, and finish any typing run.";return}
        batch=true;index=0;batchSummary=[];nextCue();errorText=""
    }
    func nextCue(){raw=[];candidates=[];decisions=[];cueAt=ProcessInfo.processInfo.systemUptime+1.5;matcher.reset()}
    func finishTrial(completed:Bool){
        guard batch else{return}
        let cat=category.titleOfSelectedItem!
        let row=GestureTrial(id:UUID().uuidString,hardware:hardware.model,machineName:hardware.name,conditionTag:condition.titleOfSelectedItem!,split:split.titleOfSelectedItem!,category:cat,attention:armed,modelBankID:bankID,date:Date(),duration:max(0,min(4.25,ProcessInfo.processInfo.systemUptime-cueAt)),threshold:detector.threshold,completed:completed,raw:raw,candidates:candidates,decisions:decisions,target:data.target.rawValue)
        do{try data.save(row)}catch{batch=false;errorText="Dataset save failed: \(error.localizedDescription)";return}
        let fires=decisions.filter(\.accepted).count
        batchSummary.append("\(index+1): \(fires) gestures / expected \(row.expected), \(candidates.count) impacts\(completed ? "" : " (partial)")")
        if completed{index+=1}
        if !completed || index>=10{
            batch=false;matcher.reset();lastDecision="Batch saved. \(batchSummary.joined(separator:"; "))"
            if completed && split.titleOfSelectedItem=="Train"{loadBank()}
        }
        else{nextCue()}
    }
    @objc func openTyping(){
        guard !batch else{return}
        if typingController==nil {
            let controller=TypingTestController();controller.gestureMode=true
            controller.prepare={[weak self] in
                guard let self,self.running,self.detector.ready,!self.batch,self.armed,lidIsOpen(),ProcessInfo.processInfo.systemUptime-self.lastSample<1 else{return nil}
                self.matcher.reset();return(self.bankID,self.detector.threshold)
            }
            controller.onFinish={[weak self] result in
                guard let self else{return}
                let folder=self.data.root.appendingPathComponent("typing")
                do{try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true);try JSONEncoder().encode(result).write(to:folder.appendingPathComponent(UUID().uuidString+".json"),options:.atomic);self.lastDecision="Typing run saved: \(result.gestureTimes?.count ?? 0) false gestures; text not saved."}
                catch{self.errorText="Typing result save failed: \(error.localizedDescription)"}
                self.matcher.reset()
            }
            typingController=controller
        }
        typingController?.showWindow(nil);typingController?.window?.makeKeyAndOrderFront(nil)
    }
    @objc func files(){do{try FileManager.default.createDirectory(at:data.root,withIntermediateDirectories:true);NSWorkspace.shared.open(data.root)}catch{errorText=error.localizedDescription}}
    func tick(){
        let now=ProcessInfo.processInfo.systemUptime
        if running,now-rateStart>=1 {
            rate=Int(Double(samples-rateSamples)/(now-rateStart));rateStart=now;rateSamples=samples
            if !lidIsOpen(){stop();errorText="Stopped: lid is closed or unknown."}
            else if lastSample>0,now-lastSample>1{stop();errorText="Stream stalled. Current collection was saved as partial."}
        }
        if batch,now>cueAt+4.25{finishTrial(completed:true)}
        let locked=batch || typingActive
        for control in [condition,split,category,targetSelector]{control.isEnabled = !locked}
        attention.isEnabled = !locked;reload.isEnabled = !locked;typing.isEnabled = !batch
        collect.isEnabled = !typingActive;collect.title=batch ? "Cancel batch (save partial)" : "Collect 10 prompted trials"
        keyboard.ripples.removeAll{now-$0.0>1.8};keyboard.needsDisplay=true
        status.stringValue="\(running ? "Live · \(rate) Hz · \(detector.ready ? "baseline ready" : "keep still")" : "Sensor stopped") · threshold \(String(format:"%.3f",detector.threshold)) g\n\(bank.experts.count) contexts / \(bank.examples) examples · bank \(bankID.prefix(10))\n\(matcher.status)"
        prompt.stringValue=errorText.isEmpty ? batch ? "\(now>=cueAt ? "NOW" : "WAIT") · \(category.titleOfSelectedItem!)\nTrial \(index+1)/10 · \(split.titleOfSelectedItem!) · one gesture per cue" : lastDecision : errorText
        report.stringValue="Target: \(data.target.rawValue)\nConfirmed gestures: \(gestureCount)\nAgent attention: \(armed ? "ON (simulated)" : "OFF")\nMatch window: 90–600 ms\nAt least one learned target anchor\nUnknown + unknown: rejected\nNon-target contradiction: rejected\n\nCollection label: \(condition.titleOfSelectedItem!)\nLabel never selects a detector\n\n\(batchSummary.suffix(3).joined(separator:"\n"))"
    }
}
final class GestureDelegate:NSObject,NSApplicationDelegate {
    var window:NSWindow!
    var single:SingleTapLabView!
    func applicationDidFinishLaunching(_ notification:Notification){
        window=NSWindow(contentRect:NSRect(x:0,y:0,width:1120,height:830),styleMask:[.titled,.closable,.miniaturizable],backing:.buffered,defer:false)
        window.title="Tap Lab · MagSafe connector";window.appearance=NSAppearance(named:.darkAqua)
        single=SingleTapLabView(frame:window.contentView!.bounds,fixture:CommandLine.arguments.contains("--render-single"));window.contentView=single;window.center();window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
        if CommandLine.arguments.contains("--render-single"){DispatchQueue.main.asyncAfter(deadline:.now()+0.5){[weak self] in guard let v=self?.single,let rep=v.bitmapImageRepForCachingDisplay(in:v.bounds) else{exit(1)};v.cacheDisplay(in:v.bounds,to:rep);try? rep.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:"/tmp/tap-lab-single.png"));NSApp.terminate(nil)}}
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ app:NSApplication)->Bool{true}
    func applicationWillTerminate(_ notification:Notification){single?.stop()}
}
@main struct GestureApp {
    static func main(){
        if CommandLine.arguments.contains("--single-status") {
            let hardware=Hardware.current().model,store=SingleTapStore()
            if CommandLine.arguments.contains("--recover-previous") {do{let p=try store.recover(hardware,legacy:GestureDataStore(target:.connector)),n=try store.recoverChassis(hardware);print("Recovered connector: \(p), chassis: \(n)")}catch{print(error);exit(1)}}
            let rows=store.load(hardware),model=store.model(rows)
            print("Single-tap training: positive \(model.samples[0]?.count ?? 0), negative \(model.samples[1]?.count ?? 0); ready \(model.trained==[0,1]); Test \(rows.filter{$0.split=="Test"}.count)")
            return
        }
        if let i=CommandLine.arguments.firstIndex(of:"--analyze-profile"),i+1<CommandLine.arguments.count {
            do{try analyzeProfile(URL(fileURLWithPath:CommandLine.arguments[i+1]));return}catch{print(error);exit(1)}
        }
        if CommandLine.arguments.contains("--self-test"){selfTest();profileSelfTest();microphoneSelfTest();freezeSelfTest();gestureSelfTest();datasetSelfTest();singleTapSelfTest();return}
        let app=NSApplication.shared,delegate=GestureDelegate();app.delegate=delegate;app.setActivationPolicy(.regular)
        let menu=NSMenu(),item=NSMenuItem(),submenu=NSMenu();submenu.addItem(withTitle:"Quit Tap Lab",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q");item.submenu=submenu;menu.addItem(item);app.mainMenu=menu;app.run()
    }
}
