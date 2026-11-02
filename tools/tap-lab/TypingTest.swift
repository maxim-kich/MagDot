import AppKit

final class TypingTestController:NSWindowController,NSTextViewDelegate {
    let editor=NSTextView(),status=NSTextField(wrappingLabelWithString:"")
    let start=NSButton(title:"Start 60-second test",target:nil,action:nil)
    let finish=NSButton(title:"Finish now",target:nil,action:nil)
    var prepare:(()->(String,Double)?)?
    var onFinish:((TypingResult)->Void)?
    private(set) var isActive=false
    private var began=0.0,wall=Date(),modelID="",threshold=0.0,edits=0
    private var events=[TypingImpact](),timer:Timer?
    private var gestures=[Double](),editTimes=[Double]()
    let instructionField=NSTextField(wrappingLabelWithString:"")
    var gestureMode=false {didSet{
        if gestureMode{instructionField.stringValue="Type normally for 60 seconds without deliberate chassis taps. Confirmed double-tap gestures count as false triggers; individual left candidates are diagnostic only. Your text is never saved."}
    }}
    init(){
        let w=NSWindow(contentRect:NSRect(x:0,y:0,width:720,height:530),styleMask:[.titled,.closable,.miniaturizable],backing:.buffered,defer:false)
        super.init(window:w);w.title="Tap Lab · Typing test";w.appearance=NSAppearance(named:.darkAqua)
        let content=w.contentView!
        let instruction=instructionField;instruction.stringValue="Type normally for 60 seconds. Do not deliberately tap the chassis. Left-side detections during this session count as false triggers. Your text stays in this window and is never saved."
        instruction.frame=NSRect(x:24,y:442,width:672,height:64);content.addSubview(instruction)
        let scroll=NSScrollView(frame:NSRect(x:24,y:140,width:672,height:288));scroll.hasVerticalScroller=true;scroll.borderType = .bezelBorder
        editor.frame=NSRect(x:0,y:0,width:672,height:288);editor.isVerticallyResizable=true;editor.autoresizingMask = [.width];editor.textContainer?.widthTracksTextView=true
        editor.font = .systemFont(ofSize:17);editor.isRichText=false;editor.delegate=self;editor.isEditable=false
        editor.isAutomaticSpellingCorrectionEnabled=false;editor.isAutomaticTextReplacementEnabled=false
        editor.setAccessibilityLabel("Typing test input; text is not saved")
        scroll.documentView=editor;content.addSubview(scroll)
        status.frame=NSRect(x:24,y:62,width:672,height:64);status.font = .monospacedSystemFont(ofSize:13,weight:.regular);status.stringValue="Ready. Start the main sensor, then click Start test.";content.addSubview(status)
        start.frame=NSRect(x:24,y:20,width:205,height:30);start.target=self;start.action=#selector(begin);content.addSubview(start)
        finish.frame=NSRect(x:240,y:20,width:130,height:30);finish.target=self;finish.action=#selector(finishNow);finish.isEnabled=false;content.addSubview(finish)
        NotificationCenter.default.addObserver(self,selector:#selector(closing),name:NSWindow.willCloseNotification,object:w)
        w.center()
    }
    required init?(coder:NSCoder){fatalError()}
    @objc func begin(){
        guard !isActive else{return}
        guard let (id,t)=prepare?() else{status.stringValue=gestureMode ? "Start the sensor, wait for baseline ready, enable simulated agent attention, and finish any active collection." : "Start the sensor and wait for baseline ready. A frozen model is required.";return}
        modelID=id;threshold=t;began=ProcessInfo.processInfo.systemUptime;wall=Date();events=[];edits=0;editor.string=""
        gestures=[];editTimes=[];isActive=true;editor.isEditable=true;start.isEnabled=false;finish.isEnabled=true
        window?.makeFirstResponder(editor)
        timer=Timer.scheduledTimer(withTimeInterval:0.2,repeats:true){[weak self] _ in self?.tick()};tick()
    }
    func textDidChange(_ notification:Notification){if isActive{edits+=1;editTimes.append(ProcessInfo.processInfo.systemUptime-began)}}
    func record(_ event:Impact,prediction:Int?){
        guard isActive else{return}
        events.append(TypingImpact(elapsed:ProcessInfo.processInfo.systemUptime-began,predicted:prediction,peak:event.peak,impact:event))
    }
    func recordGesture(){if isActive{gestures.append(ProcessInfo.processInfo.systemUptime-began)}}
    private func tick(){
        guard isActive else{return}
        let elapsed=ProcessInfo.processInfo.systemUptime-began
        let left=events.filter{$0.predicted==0}.count,other=events.filter{$0.predicted==1}.count
        status.stringValue="\(max(0,60-Int(elapsed))) seconds left · \(edits) edits\n\(gestureMode ? "False gestures: \(gestures.count) · Left candidates: \(left)" : "False left: \(left)") · Not-left impacts: \(other) · Unknown: \(events.count-left-other)\n\(gestureMode ? "Model bank" : "Frozen model"): \(modelID.prefix(12))"
        if elapsed>=60{end(reason:"completed")}
    }
    @objc func finishNow(){end(reason:"finished early")}
    @objc func closing(){end(reason:"window closed");editor.string=""}
    func end(reason:String){
        guard isActive else{return}
        let duration=ProcessInfo.processInfo.systemUptime-began
        isActive=false;timer?.invalidate();timer=nil;editor.isEditable=false;start.isEnabled=true;finish.isEnabled=false
        let result=TypingResult(modelID:modelID,startedAt:wall,duration:duration,editEvents:edits,effectiveThreshold:threshold,reason:reason,impacts:events,gestureTimes:gestures,editTimes:editTimes)
        onFinish?(result)
        status.stringValue="Saved \(Int(duration))-second session (\(reason)) · \(edits) edits\n\(gestureMode ? "False gestures: \(gestures.count) · Left candidates: \(result.falseLeft)" : "False left: \(result.falseLeft)") · Impact candidates: \(events.count)\n\(edits==0 ? "No typing recorded; this is not a typing validation." : "Text was not saved. Short sessions are not a full 60-second test.")"
    }
}
