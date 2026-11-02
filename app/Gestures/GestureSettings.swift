import AppKit

final class TapMacView:NSView {
    struct Pulse{let location:CalibrationLocation;let time:Double;let peak:Double}
    var pulses=[Pulse]()
    var target:CalibrationLocation?{didSet{if oldValue != target{needsDisplay=true}}}
    var checking=false{didSet{needsDisplay=true}}
    private var outcomeAt=0.0
    var outcome:Bool?{didSet{if oldValue != outcome{outcomeAt=ProcessInfo.processInfo.systemUptime;needsDisplay=true}}}
    var progress=0.0{didSet{if oldValue != progress{needsDisplay=true}}}
    var connected=false{didSet{plug.isActive=connected;needsLayout=true;needsDisplay=true}}
    private let plug=MenuConnectorView()
    override var isFlipped:Bool{true}
    override init(frame:NSRect){super.init(frame:frame);plug.rotation = -.pi/2}
    required init?(coder:NSCoder){fatalError()}
    var body:NSRect{NSRect(x:(bounds.width-252)/2,y:16,width:252,height:134)}
    func point(_ location:CalibrationLocation)->NSPoint{
        let b=body
        switch location{case .connector:return NSPoint(x:connectorFrame.midX,y:connectorFrame.midY);case .backLeft:return NSPoint(x:b.minX+5,y:b.minY+5);case .backRight:return NSPoint(x:b.maxX-5,y:b.minY+5);case .frontLeft:return NSPoint(x:b.minX+41,y:b.minY+107);case .frontRight:return NSPoint(x:b.maxX-41,y:b.minY+107);case .handling:return NSPoint(x:b.midX,y:b.midY)}
    }
    var connectorFrame:NSRect{NSRect(x:body.minX-(connected ? 14:30),y:body.minY+2,width:24,height:24)}
    override func layout(){super.layout();plug.frame=connectorFrame}
    func beginTap(_ id:Double,_ peak:Double){guard let target,target != .handling else{return};pulses.append(Pulse(location:target,time:ProcessInfo.processInfo.systemUptime,peak:peak));pulses=Array(pulses.suffix(8));needsDisplay=true}
    func resolveTap(_ id:Double,_ side:Int?,_ peak:Double){guard target==nil,side==0 else{return};pulses.append(Pulse(location:.connector,time:ProcessInfo.processInfo.systemUptime,peak:peak));pulses=Array(pulses.suffix(8));needsDisplay=true}
    func box(_ r:NSRect,_ color:NSColor,_ radius:CGFloat){color.setFill();NSBezierPath(roundedRect:r,xRadius:radius,yRadius:radius).fill()}
    override func draw(_ dirty:NSRect){
        let b=body
        let cableStart=NSPoint(x:connectorFrame.minX+6,y:connectorFrame.midY)
        let cable=NSBezierPath();cable.move(to:cableStart);cable.curve(to:NSPoint(x:cableStart.x-46,y:cableStart.y+18),controlPoint1:NSPoint(x:cableStart.x-28,y:cableStart.y),controlPoint2:NSPoint(x:cableStart.x-35,y:cableStart.y+9));NSColor(white:0.6,alpha:1).setStroke();cable.lineWidth=3;cable.lineCapStyle = .round;cable.stroke()
        NSGraphicsContext.saveGraphicsState();let connectorTransform=NSAffineTransform();connectorTransform.translateX(by:connectorFrame.minX,yBy:connectorFrame.minY);connectorTransform.concat();plug.draw(plug.bounds);NSGraphicsContext.restoreGraphicsState()
        box(b,NSColor(srgbRed:0.61,green:0.62,blue:0.64,alpha:1),11);NSColor(white:0.42,alpha:1).setStroke();NSBezierPath(roundedRect:b,xRadius:11,yRadius:11).stroke()
        box(NSRect(x:b.minX+18,y:b.minY+5,width:b.width-36,height:2),.tertiaryLabelColor,1)
        let deck=NSRect(x:b.minX+12,y:b.minY+8,width:b.width-24,height:74)
        let keyFill=NSColor(white:0.11,alpha:1)
        let rows:[[CGFloat]]=[[1.5]+Array(repeating:1,count:12)+[1.2],Array(repeating:1,count:13)+[1.8],[1.5]+Array(repeating:1,count:12)+[1.3],[1.8]+Array(repeating:1,count:11)+[2],[2.3]+Array(repeating:1,count:10)+[2.5]]
        for (row,weights) in rows.enumerated(){
            let unit=(deck.width-CGFloat(weights.count-1)*2)/weights.reduce(0,+);var x=deck.minX
            for weight in weights{let w=unit*weight;box(NSRect(x:x,y:deck.minY+CGFloat(row)*12.5,width:w,height:10.5),keyFill,1.8);x+=w+2}
        }
        let bottom:[CGFloat]=[1,1,1,1.3,5,1.3,1];let width=deck.width-37,unit=(width-12)/bottom.reduce(0,+);var x=deck.minX
        for weight in bottom{let w=unit*weight;box(NSRect(x:x,y:deck.minY+62.5,width:w,height:10.5),keyFill,1.8);x+=w+2}
        let arrowTop=deck.minY+62.5,arrowHeight:CGFloat=(10.5-0.75)/2
        for i in 0..<3{box(NSRect(x:deck.maxX-33+CGFloat(i)*11,y:arrowTop+arrowHeight+0.75,width:9,height:arrowHeight),keyFill,1)}
        box(NSRect(x:deck.maxX-22,y:arrowTop,width:9,height:arrowHeight),keyFill,1)
        for side in [b.minX+4,b.maxX-7]{for row in 0..<17{box(NSRect(x:side,y:b.minY+16+CGFloat(row)*3.6,width:3,height:1),.tertiaryLabelColor,0.5)}}
        let trackpad=NSRect(x:b.midX-44,y:b.minY+90,width:88,height:34)
        box(trackpad,NSColor(white:0.56,alpha:1),5);NSColor(white:0.4,alpha:1).setStroke();NSBezierPath(roundedRect:trackpad,xRadius:5,yRadius:5).stroke()
        let now=ProcessInfo.processInfo.systemUptime;pulses.removeAll{now-$0.time>0.65}
        let locations:[CalibrationLocation] = checking || outcome != nil ? CalibrationLocation.targets:(target.flatMap{$0 == .handling ? nil:[$0]} ?? [])
        for active in locations{
            let p=point(active)
            let value=checking ? 0.45+0.25*sin(now*5):outcome != nil ? 1:max(0,min(1,progress))
            let reveal=outcome != nil ? min(1,max(0,(now-outcomeAt)/0.35)):1
            let r=CGFloat(11+value*8)*(0.35+0.65*reveal)
            let color:NSColor=checking ? .systemOrange:outcome==true ? .systemGreen:outcome==false ? .systemOrange:.controlAccentColor
            let circle=NSBezierPath(ovalIn:NSRect(x:p.x-r,y:p.y-r,width:r*2,height:r*2))
            NSGraphicsContext.saveGraphicsState();circle.addClip();color.withAlphaComponent(0.55).setFill();NSRect(x:p.x-r,y:p.y+r-r*2*CGFloat(value),width:r*2,height:r*2*CGFloat(value)).fill();NSGraphicsContext.restoreGraphicsState();color.setStroke();circle.lineWidth=2;circle.stroke()
        }
        for pulse in pulses where !checking && outcome==nil && (target==nil || pulse.location==target){
            let p=point(pulse.location),age=now-pulse.time,r=CGFloat(13+age*25+sqrt(min(pulse.peak,0.2))*14)
            (target==nil ? NSColor.systemGreen:NSColor.controlAccentColor).withAlphaComponent(max(0,0.8-age*1.2)).setStroke();let ring=NSBezierPath(ovalIn:NSRect(x:p.x-r,y:p.y-r,width:r*2,height:r*2));ring.lineWidth=1.5;ring.stroke()
        }
    }
}
final class GestureSettingsView:NSView {
    override var isFlipped:Bool{true}
    let service:MagSafeGestureService,mac=TapMacView()
    let enabled=NSSwitch(),defaultProfile=NSSwitch(),permission=NSButton(title:"Allow…",target:nil,action:nil),calibrate=NSButton(title:"Start calibration",target:nil,action:nil),reset=NSButton()
    private let paceText=NSTextField(labelWithString:"")
    private var paceBadge:NSView?
    let hint=NSTextField(wrappingLabelWithString:""),sensitivity=NSSlider(value:0.5,minValue:0,maxValue:1,target:nil,action:nil)
    private var labelColors=[NSTextField:NSColor]()
    var timer:Timer?,lastUI=0.0,lastConnection=0.0,introUntil=ProcessInfo.processInfo.systemUptime+7,lastState="",calibrationButtonY=0.0
    init(service:MagSafeGestureService){self.service=service;super.init(frame:NSRect(x:0,y:0,width:592,height:700));service.onOnset={ [weak self] id,peak in self?.mac.beginTap(id,peak) };service.onImpact={ [weak self] id,side,peak in guard let self,self.service.preferences.enabled,self.mac.connected else{return};self.mac.resolveTap(id,side,peak) };rebuild();timer=Timer(timeInterval:1/60,repeats:true){[weak self] _ in self?.update()};timer?.tolerance=0.001;RunLoop.main.add(timer!,forMode:.common)}
    required init?(coder:NSCoder){fatalError()}
    deinit{timer?.invalidate()}
    func label(_ text:String,_ frame:NSRect,secondary:Bool=false)->NSTextField{let v=settingsLabel(text,frame,secondary:secondary);addSubview(v);return v}
    func card(_ y:CGFloat,_ height:CGFloat){addSubview(settingsCard(NSRect(x:0,y:y,width:592,height:height)))}
    func divider(_ y:CGFloat){let v=NSBox(frame:NSRect(x:16,y:y,width:560,height:1));v.boxType = .separator;addSubview(v)}
    var guidance:Bool{service.visibleCalibrationOutcome != nil || service.calibration != nil || (!service.preferences.useDefault && service.personal==nil && ProcessInfo.processInfo.systemUptime<introUntil)}
    var state:String{"\(service.preferences.enabled)-\(service.allowed)-\(service.preferences.useDefault)-\(service.personal?.id ?? "none")-\(guidance)"}
    func rebuild(){
        subviews.forEach{$0.removeFromSuperview()};labelColors.removeAll();lastState=state
        mac.frame=NSRect(x:0,y:0,width:592,height:168);addSubview(mac)
        let badgeFrame=NSRect(x:250,y:0,width:92,height:26)
        paceText.frame=NSRect(x:8,y:4,width:76,height:18);paceText.font = .systemFont(ofSize:13,weight:.semibold);paceText.alignment = .center;paceText.textColor = .labelColor
        if #available(macOS 26.0,*){let glass=NSGlassEffectView(frame:badgeFrame);glass.style = .regular;glass.cornerRadius=13;let inner=NSView(frame:NSRect(origin:.zero,size:badgeFrame.size));inner.addSubview(paceText);glass.contentView=inner;paceBadge=glass}
        else{let glass=NSVisualEffectView(frame:badgeFrame);glass.material = .popover;glass.blendingMode = .withinWindow;glass.state = .active;glass.wantsLayer=true;glass.layer?.cornerRadius=13;glass.layer?.masksToBounds=true;glass.addSubview(paceText);paceBadge=glass}
        addSubview(paceBadge!);paceBadge?.isHidden=true
        hint.frame=NSRect(x:16,y:182,width:560,height:44);hint.font = .systemFont(ofSize:17,weight:.semibold);hint.alignment = .center;hint.textColor = .labelColor;addSubview(hint)
        let showDescription = !service.preferences.useDefault && service.personal==nil
        if showDescription{let text=label("Double-tap MagSafe to open your agent when it’s done or needs your input.",NSRect(x:16,y:guidance ? 238:182,width:560,height:30),secondary:true);text.font = .systemFont(ofSize:12);text.alignment = .center}
        var y:CGFloat=showDescription ? (guidance ? 280:222):(guidance ? 240:182)
        card(y,54);_ = label("Activate",NSRect(x:16,y:y+17,width:460,height:22));enabled.frame=NSRect(x:536,y:y+15,width:40,height:24);enabled.state=service.preferences.enabled ? .on:.off;enabled.target=self;enabled.action = #selector(toggleEnabled);enabled.setAccessibilityLabel("Activate double-tap MagSafe");addSubview(enabled);y+=64
        if service.preferences.enabled{
            card(y,48);_ = label("Input Monitoring",NSRect(x:16,y:y+15,width:350,height:22))
            if service.allowed{let allowed=label("Allowed",NSRect(x:418,y:y+15,width:158,height:22));allowed.alignment = .right;allowed.textColor = .systemGreen}
            else{permission.frame=NSRect(x:466,y:y+7,width:110,height:32);permission.bezelStyle = .rounded;permission.target=self;permission.action = #selector(allow);addSubview(permission)}
            y+=60
            if service.allowed{
                let groupY=y,missing=service.personal==nil,custom = !service.preferences.useDefault,showSensitivity=service.preferences.useDefault || !missing
                let legacy=custom && service.personal != nil && service.personal?.gestureVersion != 2
                let height:CGFloat=48+((missing || legacy) ? 36:0)+(custom ? 55:0)+(showSensitivity ? 105:0)
                card(groupY,height)
                _ = label("Use default profile",NSRect(x:16,y:y+15,width:460,height:22));defaultProfile.frame=NSRect(x:536,y:y+13,width:40,height:24);defaultProfile.state=service.preferences.useDefault ? .on:.off;defaultProfile.target=self;defaultProfile.action = #selector(changeProfile);defaultProfile.setAccessibilityLabel("Use default profile");addSubview(defaultProfile);y+=48
                if missing || legacy{let notice=label(legacy ? "Recalibrate with free tapping":"Currently default profile. Please calibrate",NSRect(x:16,y:y,width:560,height:30));notice.textColor = .systemRed;y+=36}
                if custom{divider(y);y+=1;_ = label("Custom profile",NSRect(x:16,y:y+16,width:330,height:22));calibrationButtonY=y+11;calibrate.bezelStyle = .rounded;calibrate.target=self;calibrate.action = #selector(calibrateTaps);addSubview(calibrate);y+=54}
                if showSensitivity{
                    divider(y);y+=1
                    let title=label("Sensitivity",NSRect(x:16,y:y+12,width:180,height:22));title.sizeToFit();reset.image=NSImage(systemSymbolName:"arrow.counterclockwise",accessibilityDescription:"Reset sensitivity");reset.isBordered=false;reset.target=self;reset.action = #selector(resetSensitivity);reset.frame=NSRect(x:title.frame.maxX+8,y:title.frame.midY-12,width:22,height:24);reset.toolTip="Reset sensitivity to default";reset.setAccessibilityLabel("Reset sensitivity");addSubview(reset)
                    sensitivity.frame=NSRect(x:16,y:y+44,width:560,height:24);sensitivity.doubleValue=service.preferences.sensitivity;sensitivity.isContinuous=true;sensitivity.target=self;sensitivity.action = #selector(changeSensitivity);sensitivity.setAccessibilityLabel("Double-tap sensitivity");sensitivity.toolTip="Controls impact detection and the MagSafe confidence range. Strong corner matches stay rejected; recorded corner checks limit unsafe expansion.";addSubview(sensitivity)
                    _ = label("Firm taps",NSRect(x:16,y:y+76,width:120,height:18),secondary:true);let gentle=label("Gentle taps",NSRect(x:470,y:y+76,width:106,height:18),secondary:true);gentle.alignment = .right;y+=104
                }
            }
        }
        setFrameSize(NSSize(width:592,height:max(514,y+20)));update(force:true)
    }
    func update(force:Bool=false){
        if !mac.pulses.isEmpty || mac.checking || mac.outcome != nil{mac.needsDisplay=true}
        let now=ProcessInfo.processInfo.systemUptime;guard force || now-lastUI>=0.1 else{return};lastUI=now
        if state != lastState{rebuild();return}
        if force || now-lastConnection>=0.5{lastConnection=now;mac.connected=magSafeConnection()==true;if !mac.connected && service.calibration != nil{service.cancelCalibration()}}
        enabled.isEnabled=mac.connected;permission.isEnabled=mac.connected;defaultProfile.isEnabled=mac.connected
        for case let label as NSTextField in subviews{
            if labelColors[label]==nil{labelColors[label]=label.textColor ?? .labelColor}
            label.textColor=mac.connected ? labelColors[label]:.disabledControlTextColor
        }
        for case let label as NSTextField in enclosingScrollView?.superview?.subviews ?? []{label.textColor=(label.font?.pointSize ?? 0)>20 ? .labelColor:.secondaryLabelColor}
        let pace=service.inputBlocked ? "":service.calibration?.paceHint ?? ""
        paceText.stringValue=pace;paceBadge?.isHidden=pace.isEmpty
        mac.setFrameOrigin(.zero)
        let keyboardCenter=convert(NSPoint(x:mac.body.midX,y:mac.body.minY+45),from:mac)
        paceBadge?.setFrameOrigin(NSPoint(x:keyboardCenter.x-46,y:keyboardCenter.y-13))
        mac.target=service.calibration?.displayLocation;mac.progress=service.calibration?.progress ?? 0;mac.checking=service.calibration?.checking==true;mac.outcome=service.visibleCalibrationOutcome
        if service.calibration != nil{hint.stringValue=service.calibrationCue;hint.alphaValue=1}
        else if !service.preferences.useDefault && service.personal==nil && now<introUntil{hint.stringValue="Keep tapping the highlighted spot at your own pace. Vary the strength.";hint.alphaValue=min(1,max(0,(introUntil-now)/0.8))}
        else{hint.stringValue="";hint.alphaValue=1}
        hint.isHidden = !guidance

        let active=service.calibration != nil;calibrate.title=active ? "Cancel":"Start calibration";let w:CGFloat=active ? 90:150;calibrate.frame=NSRect(x:576-w,y:calibrationButtonY,width:w,height:32);calibrate.isEnabled=mac.connected && (active || (service.running && service.detector.ready));calibrate.toolTip=service.status
        sensitivity.isEnabled = mac.connected && !active;reset.isEnabled = mac.connected && !active;reset.isHidden=abs(service.preferences.sensitivity-TapPreferences.defaultSensitivity)<0.000001
    }
    @objc func toggleEnabled(){service.setEnabled(enabled.state == .on);rebuild()}
    @objc func allow(){service.requestPermission();rebuild()}
    @objc func changeProfile(){service.setUseDefault(defaultProfile.state == .on);introUntil=ProcessInfo.processInfo.systemUptime+7;rebuild();if !service.preferences.useDefault{scrollToVisible(NSRect(x:0,y:calibrationButtonY-16,width:592,height:70))}}
    @objc func calibrateTaps(){if service.calibration == nil{service.beginCalibration();if let scroll=enclosingScrollView{scroll.contentView.scroll(to:.zero);scroll.reflectScrolledClipView(scroll.contentView)}}else{service.cancelCalibration();introUntil=0};update(force:true)}
    @objc func changeSensitivity(){service.setSensitivity(sensitivity.doubleValue);reset.isHidden=abs(sensitivity.doubleValue-TapPreferences.defaultSensitivity)<0.000001}
    @objc func resetSensitivity(){sensitivity.doubleValue=TapPreferences.defaultSensitivity;service.setSensitivity(sensitivity.doubleValue);service.preferences.flush();update(force:true)}
}
