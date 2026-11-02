import AppKit

private var singleTapView:SingleTapLabView?
private func receiveSingleTap(_ t:Double,_ x:Double,_ y:Double,_ z:Double){singleTapView?.sample(t,[x,y,z])}

final class SingleTapLabView:NSView {
    override var isFlipped:Bool{true}
    let hardware=Hardware.current(),store=SingleTapStore(),detector=BurstDetector(),keyboard=KeyboardView()
    var records=[SingleTapRecord](),classifier=PreparedContextBank(),model=LocationModel()
    var running=false,activeLabel:Int?,timer:Timer?,lastSample=0.0,startedAt=0.0,rateStart=0.0,samples=0,previousSamples=0,rate=0,lastSaved = -1.0
    let sensor=NSButton(title:"Start sensor",target:nil,action:nil),baseline=NSButton(title:"Recalibrate quiet baseline",target:nil,action:nil)
    let positive=NSButton(title:"Collect POSITIVE taps",target:nil,action:nil),negative=NSButton(title:"Collect NEGATIVE taps",target:nil,action:nil),pause=NSButton(title:"Pause collection",target:nil,action:nil)
    let publish=NSButton(title:"Use this model in MagDot",target:nil,action:nil),folder=NSButton(title:"Open recordings",target:nil,action:nil)
    let mode=NSSegmentedControl(labels:["Collect","Test"],trackingMode:.selectOne,target:nil,action:nil)
    let counts=NSTextField(wrappingLabelWithString:""),status=NSTextField(wrappingLabelWithString:""),feedback=NSTextField(wrappingLabelWithString:""),results=NSTextField(wrappingLabelWithString:"")
    let sensitivity=NSSlider(value:0.75,minValue:0,maxValue:1,target:nil,action:nil)
    var captureFrom=0.0,sensorOffset=0.0,waitingForLid=false,lastLidCheck=0.0
    var message="Choose POSITIVE or NEGATIVE, then tap once at a time. Keep roughly half a second between taps.",lastPublished="",error="",lastUI=0.0,lastDiagnostic=0.0
    var split:String{mode.selectedSegment==1 ? "Test":"Train"}
    init(frame:NSRect,fixture:Bool=false){
        super.init(frame:frame);singleTapView=self;wantsLayer=true;layer?.backgroundColor=NSColor(white:0.065,alpha:1).cgColor
        func label(_ text:String,_ r:NSRect,_ size:CGFloat=13,_ muted:Bool=false){let v=NSTextField(wrappingLabelWithString:text);v.frame=r;v.font = .systemFont(ofSize:size,weight:size>=20 ? .semibold:.regular);v.textColor=muted ? .secondaryLabelColor:.labelColor;addSubview(v)}
        label("Tap Lab · MagSafe connector",NSRect(x:28,y:24,width:760,height:36),26)
        label("\(hardware.name) · \(hardware.model) · single-tap collection",NSRect(x:28,y:68,width:750,height:24),13,true)
        label("POSITIVE = tap the attached MagSafe plug. NEGATIVE = tap the laptop, type, or handle the cable.",NSRect(x:28,y:104,width:1050,height:40),14)
        keyboard.connector=true;keyboard.frame=NSRect(x:16,y:160,width:718,height:420);addSubview(keyboard)
        for (b,a) in [(sensor,#selector(toggleSensor)),(baseline,#selector(recalibrate)),(positive,#selector(collectPositive)),(negative,#selector(collectNegative)),(pause,#selector(pauseCapture)),(publish,#selector(useModel)),(folder,#selector(openFolder))]{b.target=self;b.action=a;b.bezelStyle = .rounded;addSubview(b)}
        sensor.frame=NSRect(x:880,y:25,width:200,height:32)
        counts.frame=NSRect(x:760,y:166,width:320,height:80);counts.font = .monospacedSystemFont(ofSize:16,weight:.medium);counts.textColor = .systemGreen;addSubview(counts)
        mode.frame=NSRect(x:760,y:256,width:320,height:30);mode.selectedSegment=0;mode.target=self;mode.action = #selector(changeCollectionMode);addSubview(mode)
        positive.frame=NSRect(x:760,y:306,width:320,height:40);negative.frame=NSRect(x:760,y:358,width:320,height:40);pause.frame=NSRect(x:760,y:410,width:320,height:30)
        publish.frame=NSRect(x:760,y:466,width:320,height:36);folder.frame=NSRect(x:760,y:518,width:320,height:30)
        label("Capture sensitivity",NSRect(x:760,y:578,width:320,height:22),13,true)
        sensitivity.frame=NSRect(x:760,y:606,width:320,height:24);sensitivity.target=self;sensitivity.action = #selector(changeSensitivity);addSubview(sensitivity)
        baseline.frame=NSRect(x:760,y:654,width:320,height:30)
        status.frame=NSRect(x:28,y:594,width:700,height:50);status.font = .monospacedSystemFont(ofSize:12,weight:.regular);status.textColor = .secondaryLabelColor;addSubview(status)
        feedback.frame=NSRect(x:28,y:658,width:700,height:78);feedback.font = .systemFont(ofSize:19,weight:.semibold);feedback.textColor = .labelColor;addSubview(feedback)
        results.frame=NSRect(x:28,y:750,width:1052,height:58);results.font = .systemFont(ofSize:12);results.textColor = .secondaryLabelColor;addSubview(results)
        detector.sensitivity=sensitivity.doubleValue
        detector.onOnset={ [weak self] _,peak in guard let self else{return};self.keyboard.ripples.append((ProcessInfo.processInfo.systemUptime,self.activeLabel,peak)) }
        detector.onImpact={ [weak self] in self?.impact($0) }
        if !fixture {
            do{
                let connector=try store.recover(hardware.model,legacy:GestureDataStore(target:.connector))
                let chassis=try store.recoverChassis(hardware.model)
                if connector+chassis>0{message="Recovered \(connector) connector taps and \(chassis) original chassis taps. Original recordings are unchanged."}
            }catch{self.error="Could not recover previous recordings: \(error.localizedDescription)"}
            records=store.load(hardware.model);refreshModel()
            NSWorkspace.shared.notificationCenter.addObserver(self,selector:#selector(sleep),name:NSWorkspace.willSleepNotification,object:nil)
            NotificationCenter.default.addObserver(self,selector:#selector(lostFocus),name:NSApplication.didResignActiveNotification,object:nil)
            timer=Timer(timeInterval:1/60,repeats:true){[weak self] _ in self?.tick()};RunLoop.main.add(timer!,forMode:.common)
            DispatchQueue.main.async{[weak self] in self?.toggleSensor()}
        }
        updateUI()
    }
    required init?(coder:NSCoder){fatalError()}
    deinit{timer?.invalidate()}
    func refreshModel(){model=store.model(records);classifier=PreparedContextBank(ContextBank(experts:model.trained==[0,1] ? [ContextBank.Expert(source:"connector-singles",model:model)]:[]))}
    @objc func toggleSensor(){
        if running{stop();return}
        guard hardware.isMacBook else{error="This tester requires a MacBook accelerometer.";updateUI();return}
        guard lidIsOpen() else{waitingForLid=true;error="Open the MacBook lid. The sensor will start automatically.";updateUI();return}
        waitingForLid=false
        detector.reset();lastSaved = -1;samples=0;previousSamples=0;lastSample=0;rateStart=ProcessInfo.processInfo.systemUptime
        startedAt=ProcessInfo.processInfo.systemUptime;let result=sensor_start(receiveSingleTap);running=result==0;sensor.title=running ? "Stop sensor":"Retry sensor";error=running ? "":"Sensor unavailable (code \(result)). Check Input Monitoring permission, then reopen Tap Lab.";updateUI()
    }
    func stop(){waitingForLid=false;activeLabel=nil;sensor_stop();running=false;sensor.title="Start sensor";updateUI()}
    @objc func sleep(){stop();waitingForLid=true}
    @objc func lostFocus(){if activeLabel != nil{pauseCapture();message="Paused because Tap Lab lost focus. Select POSITIVE or NEGATIVE to continue.";updateUI()}}
    @objc func recalibrate(){activeLabel=nil;detector.reset();lastSaved = -1;message="Hold the Mac still for one second. Then select POSITIVE or NEGATIVE.";updateUI()}
    @objc func changeSensitivity(){detector.sensitivity=sensitivity.doubleValue}
    @objc func changeCollectionMode(){activeLabel=nil;refreshModel();message=split=="Test" ? "Choose the tap you will make. Test taps are saved separately and never train the model.":"Choose POSITIVE or NEGATIVE, then tap once at a time.";updateUI()}
    @objc func collectPositive(){begin(0)}
    @objc func collectNegative(){begin(1)}
    func begin(_ label:Int){
        guard running,detector.ready else{message="Hold still until the sensor is ready, then choose a label.";updateUI();return}
        guard split != "Test" || model.trained==[0,1] else{message="Collect at least 12 positive and 12 negative taps before testing.";updateUI();return}
        activeLabel=label;captureFrom=ProcessInfo.processInfo.systemUptime+0.35;lastSaved = -1;error="";message=label==0 ? "POSITIVE: tap once on the attached MagSafe plug. Keep tapping to collect more.":"NEGATIVE: tap the laptop or nearby surfaces, type, or gently handle the cable.";updateUI()
    }
    @objc func pauseCapture(){activeLabel=nil;refreshModel();message="Collection paused. Every captured tap has already been saved.";updateUI()}
    func sample(_ t:Double,_ xyz:[Double]){
        guard running else{return};lastSample=ProcessInfo.processInfo.systemUptime;if samples==0{sensorOffset=lastSample-t};samples+=1
        let ready=detector.ready;detector.ingest(t,xyz)
        if ready && !detector.ready{activeLabel=nil;message="Stream interrupted. Saved taps are safe; hold still to recalibrate."}
    }
    func impact(_ event:Impact){
        let predicted=classifier.evidence(event.feature).side
        if !keyboard.ripples.isEmpty{keyboard.ripples[keyboard.ripples.count-1].1 = split=="Test" ? predicted:(activeLabel ?? predicted)}
        guard let label=activeLabel,event.onset+sensorOffset>=captureFrom else{return}
        // Capture independent single taps, suppressing late ringing. No pair
        // timing, pair shape, or exactly-two-in-a-window requirement.
        guard lastSaved<0 || event.onset-lastSaved>=0.35 else{return}
        lastSaved=event.onset
        let row=SingleTapRecord(id:UUID().uuidString,hardware:hardware.model,label:label,split:split,source:"live",date:Date(),impact:event,predicted:split=="Test" ? predicted:nil,threshold:detector.threshold)
        do{try store.save(row);records.append(row)}catch{activeLabel=nil;self.error="Tap could not be saved: \(error.localizedDescription)";updateUI();return}
        if split=="Train"{model.add(row.impact,zone:label);message="Saved \(label==0 ? "POSITIVE connector":"NEGATIVE non-connector") tap · keep tapping, or switch label."}
        else{message="Expected \(label==0 ? "POSITIVE":"NEGATIVE") · detected \(predicted==0 ? "POSITIVE":predicted==1 ? "NEGATIVE":"UNKNOWN")\n\(predicted==label ? "Correct":"Not matched") · saved as Test, not training."}
        updateUI()
    }
    @objc func useModel(){
        activeLabel=nil;refreshModel()
        guard let asset=store.asset(hardware:hardware.model,records:records) else{message="Collect at least 12 positive and 12 negative taps first.";updateUI();return}
        do{try asset.save();lastPublished=asset.id;message="Connector model saved for MagDot. It reloads automatically; no restart needed."}
        catch{self.error="Could not save model for MagDot: \(error.localizedDescription)"}
        updateUI()
    }
    @objc func openFolder(){do{try FileManager.default.createDirectory(at:store.root,withIntermediateDirectories:true);NSWorkspace.shared.open(store.root)}catch{self.error=error.localizedDescription;updateUI()}}
    func tick(){
        let now=ProcessInfo.processInfo.systemUptime
        if !running,waitingForLid,now-lastLidCheck>=0.5{lastLidCheck=now;if lidIsOpen(){toggleSensor()}}
        if running,now-rateStart>=1 {
            rate=Int(Double(samples-previousSamples)/(now-rateStart));previousSamples=samples;rateStart=now
            if !lidIsOpen(){stop();waitingForLid=true;error="Open the MacBook lid. The sensor will resume automatically."}
            else if now-(lastSample>0 ? lastSample:startedAt)>2{stop();error="Sensor stream stopped. Reopen Tap Lab to retry."}

        }
        if now-lastDiagnostic>=1{lastDiagnostic=now
            let diagnostic:[String:Any] = ["version":"0.7","lidOpen":lidIsOpen(),"waitingForLid":waitingForLid,"updatedAt":Date().timeIntervalSince1970,"running":running,"sensorReady":detector.ready,"sampleRate":rate,"positive":model.samples[0]?.count ?? 0,"negative":model.samples[1]?.count ?? 0,"mode":split,"collecting":activeLabel.map{String($0)} ?? "paused","error":error]
            if let bytes=try? JSONSerialization.data(withJSONObject:diagnostic){try? bytes.write(to:store.root.deletingLastPathComponent().appendingPathComponent("connector-single-status.json"),options:.atomic)}
        }
        keyboard.ripples.removeAll{now-$0.0>1.2};if !keyboard.ripples.isEmpty{keyboard.needsDisplay=true}
        if now-lastUI>0.1{lastUI=now;updateUI()}
    }
    func updateUI(){
        let positiveCount=model.samples[0]?.count ?? 0,negativeCount=model.samples[1]?.count ?? 0,ready=model.trained==[0,1]
        counts.stringValue="POSITIVE connector: \(positiveCount)\nNEGATIVE other:     \(negativeCount)\n\(ready ? "Model ready to test":"Need \(max(0,12-positiveCount)) positive + \(max(0,12-negativeCount)) negative")"
        positive.title=(split=="Test" ? "Test":"Collect")+" POSITIVE taps";negative.title=(split=="Test" ? "Test":"Collect")+" NEGATIVE taps"
        positive.state=activeLabel==0 ? .on:.off;negative.state=activeLabel==1 ? .on:.off
        publish.isEnabled=ready;publish.title=lastPublished.isEmpty ? "Use this model in MagDot":"Update model in MagDot"
        status.stringValue="\(running ? "Live · \(rate) Hz · \(detector.ready ? "ready":"hold still for baseline")":"Sensor stopped") · threshold \(String(format:"%.3f",detector.threshold)) g\nSingle taps save immediately · collection target: attached MagSafe plug"
        feedback.stringValue=error.isEmpty ? message:error
        let tests=records.filter{$0.split=="Test"},pos=tests.filter{$0.label==0},neg=tests.filter{$0.label==1}
        results.stringValue="Held-out Test: positive \(pos.filter{$0.predicted==0}.count)/\(pos.count) matched · negative \(neg.filter{$0.predicted==1}.count)/\(neg.count) matched · \(tests.filter{$0.predicted==nil}.count) unknown. Test taps never train.\nThe app still requires a double-tap to navigate. This lab collects individual tap signatures. No text or audio is recorded."
    }
}
