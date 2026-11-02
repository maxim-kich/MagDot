// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import IOKit

struct TapPreferences {
    static let defaultSensitivity=0.5
    let defaults:UserDefaults
    init(_ defaults:UserDefaults = .standard){self.defaults=defaults}
    var enabled:Bool {get{defaults.bool(forKey:"gesture.enabled")} nonmutating set{defaults.set(newValue,forKey:"gesture.enabled");defaults.synchronize()}}
    var useDefault:Bool {get{defaults.object(forKey:"gesture.useDefault") as? Bool ?? true} nonmutating set{defaults.set(newValue,forKey:"gesture.useDefault");defaults.synchronize()}}
    func flush(){defaults.synchronize()}
    var sensitivity:Double {get{let v=defaults.object(forKey:"gesture.sensitivity") as? Double ?? Self.defaultSensitivity;return v.isFinite ? min(1,max(0,v)) : Self.defaultSensitivity} nonmutating set{defaults.set(min(1,max(0,newValue)),forKey:"gesture.sensitivity")}}
}
enum GesturePolicy {
    static func canNavigate(enabled:Bool,allowed:Bool,hasTarget:Bool)->Bool{enabled && allowed && hasTarget}

    static func shouldListen(enabled:Bool,allowed:Bool,suspended:Bool,lidOpen:Bool,preview:Bool,modelReady:Bool,hasTarget:Bool)->Bool {
        allowed && !suspended && lidOpen && (preview || (enabled && modelReady))
    }
}
func gestureHardware()->String {
    var size=0;guard sysctlbyname("hw.model",nil,&size,nil,0)==0,size>0 else{return "unknown"}
    var bytes=[CChar](repeating:0,count:size);guard sysctlbyname("hw.model",&bytes,&size,nil,0)==0 else{return "unknown"};return String(cString:bytes)
}
func gestureLidOpen()->Bool {
#if TESTING
    if let value=ProcessInfo.processInfo.environment["MAGDOT_TEST_GESTURE_LID_OPEN"]{return value=="1"}
#endif
    let entry=IOServiceGetMatchingService(kIOMainPortDefault,IOServiceMatching("IOPMrootDomain"))
    guard entry != 0 else{return false};defer{IOObjectRelease(entry)}
    guard let closed=IORegistryEntryCreateCFProperty(entry,"AppleClamshellState" as CFString,kCFAllocatorDefault,0)?.takeRetainedValue() as? Bool else{return false};return !closed
}
private var currentGestureService:MagSafeGestureService?
private func gestureSample(_ t:Double,_ x:Double,_ y:Double,_ z:Double){currentGestureService?.sample(t,[x,y,z])}

final class MagSafeGestureService {
    let preferences=TapPreferences(),hardware=gestureHardware()
    let detector=BurstDetector(),matcher=DoubleTapMatcher()
    private let grouper=ImpactGrouper(),recorder=GestureRecorder()
    private var pairModel:PersonalGestureModel?
    private var tapModel:PersonalTapModel?
    private var lastGestureAt = -Double.greatestFiniteMagnitude
    var whenEnabled:(()->Void)?
    var target:(()->String?)?
    var navigate:((String)->Bool)?
    var onOnset:((Double,Double)->Void)?
    var onImpact:((Double,Int?,Double)->Void)?
    var preview=false {didSet{if !preview{cancelCalibration()};reconcile()}}
    var suspended=false {didSet{failedStart=false;resetStream();reconcile()}}
    private(set) var personal:PersonalCalibration?
    private(set) var calibration:CalibrationSession?
    private(set) var calibrationMessage="Keep tapping the highlighted spot with varied strength until Enough appears. Then follow the fresh-tap checks."
    private var personalClassifier=PreparedContextBank()
    private(set) var calibrationOutcome:Bool?
    private var outcomeUntil=0.0
    var visibleCalibrationOutcome:Bool?{ProcessInfo.processInfo.systemUptime<outcomeUntil ? calibrationOutcome:nil}
    private var sensorOffset=0.0
    private(set) var allowed=false,running=false
    private(set) var status="Enable double-tap to preview."
    private var bank=ContextBank(),classifier=PreparedContextBank(),timer:Timer?,currentTarget:String?,lastSample=0.0,started=0.0
    private var failedStart=false,recognizedUntil=0.0
    private var observedConnection:Bool?,observedLid:Bool?
    private var recentImpacts=[[String:Any]]()
    private var recentTraces=[GestureTrace]()
    private var lastNavigationAt:Double?
    private var impactCount=0,onsetCount=0,lastDecision="No impacts yet",lastNavigation="Not attempted",loadedModelID="bundled"
    private var connectorStamp:Date?
    private(set) var usesConnectorModel=false
    init(){
        detector.minimumCandidateGap=0.025
        struct BundleModels:Decodable{let schema:Int;let hardware:String;let experts:[ContextBank.Expert]}
        if let url=Bundle.main.url(forResource:"MagSafeTapModels",withExtension:"json"),let data=try? Data(contentsOf:url),let bundled=try? JSONDecoder().decode(BundleModels.self,from:data),bundled.schema==1,bundled.hardware==hardware {bank.experts=bundled.experts}
        personal=PersonalCalibration.load(hardware)
        personalClassifier=PreparedContextBank(personal?.bank ?? ContextBank())
        if let rows=personal?.gestures{if personal?.gestureVersion==2{tapModel=PersonalTapModel(rows,checks:personal?.gestureChecks ?? [])}else{pairModel=PersonalGestureModel(rows)}}
        classifier=PreparedContextBank(bank)
        reloadConnectorModel()
        detector.onOnset={ [weak self] t,_ in self?.onsetCount+=1;self?.recorder.onset(t) }
        detector.onImpact={ [weak self] in self?.impact($0) }
    }
    // Compile-time test seam: native QA can inspect permission states without
    // granting macOS access or starting the physical sensor.
    private var fixturePermission:Bool? {
#if TESTING
        guard let path=ProcessInfo.processInfo.environment["MAGDOT_TEST_GESTURE_PERMISSION_FILE"] else{return false}
        return (try? String(contentsOfFile:path,encoding:.utf8))?.trimmingCharacters(in:.whitespacesAndNewlines)=="allowed"
#else
        return nil
#endif
    }
    private var permissionGranted:Bool{fixturePermission ?? (magdot_sensor_access()==0)}
    var usesPersonalProfile:Bool{!preferences.useDefault && personal != nil}
    var usesPairProfile:Bool{usesPersonalProfile && personal?.gestureVersion==1 && pairModel != nil}
    var usesFreeTapProfile:Bool{usesPersonalProfile && personal?.gestureVersion==2 && tapModel != nil}
    var modelReady:Bool{usesPersonalProfile ? true:!classifier.experts.isEmpty}
    private var inputPollAt = -1.0,cachedInput=false
    var inputBlocked:Bool{
        guard fixturePermission==nil else{return false}
        let now=ProcessInfo.processInfo.systemUptime
        if now-inputPollAt>=0.02{inputPollAt=now;cachedInput=InteractionGuard.active}
        return cachedInput
    }
    func start(){
        timer=Timer(timeInterval:0.5,repeats:true){[weak self] _ in self?.tick()};RunLoop.main.add(timer!,forMode:.common);tick()
    }
    func stop(){cancelCalibration();preferences.flush();timer?.invalidate();timer=nil;resetStream();currentGestureService=nil}
    func setEnabled(_ enabled:Bool){if enabled && !preferences.enabled{whenEnabled?()};preferences.enabled=enabled;if !enabled{cancelCalibration()};failedStart=false;matcher.reset();if enabled{requestPermission()}else{reconcile()}}
    func requestPermission(){
        // Persist intent before macOS can terminate the app for a TCC relaunch.
        preferences.flush()
        if fixturePermission != nil{tick();return}
        if magdot_sensor_access() != 0 {
            let wasDenied=magdot_sensor_access()==1
            _ = magdot_sensor_request()
            if wasDenied,let url=URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"){NSWorkspace.shared.open(url)}
        }
        failedStart=false;tick()
    }
    func setUseDefault(_ value:Bool){cancelCalibration();preferences.useDefault=value;configureDetector();matcher.reset();reconcile()}
    func beginCalibration(){
        guard magSafeConnection()==true,running,detector.ready,preview,!preferences.useDefault else{calibrationMessage="Enable the sensor and wait for baseline readiness.";return}
        calibrationOutcome=nil;calibration=CalibrationSession(hardware:hardware,now:ProcessInfo.processInfo.systemUptime);recorder.reset();grouper.reset();configureDetector();matcher.reset()
    }
    func cancelCalibration(){if let session=calibration{try? session.profile.save(activate:false);calibrationMessage=""};calibration=nil;recorder.reset();grouper.reset();configureDetector();matcher.reset()}
    var calibrationCue:String{guard let s=calibration else{return ""};return inputBlocked && s.location != .handling ? "Hands off keyboard/trackpad":s.instruction}
    private func configureDetector(){
        detector.calibrationCapture=calibration != nil
        detector.sensitivity=calibration != nil ? 0.75:preferences.sensitivity
        detector.learnedTapFloor=calibration==nil && usesPersonalProfile ? personal?.suggestedDetectionFloor:nil
    }
    func setSensitivity(_ value:Double){preferences.sensitivity=value;recorder.reset();grouper.reset();matcher.reset();configureDetector()}
    func resetStream(){recognizedUntil=0;lastGestureAt = -Double.greatestFiniteMagnitude;calibrationOutcome=nil;outcomeUntil=0;recentImpacts=[];recentTraces=[];lastDecision="Waiting for a fresh tap";lastNavigation="Not attempted";lastNavigationAt=nil;magdot_touch_stop();cancelCalibration();if running && fixturePermission == nil{magdot_sensor_stop()};running=false;detector.reset();recorder.reset();grouper.reset();matcher.reset();lastSample=0}
    private func reloadConnectorModel(){
        let path=ConnectorModel.path(hardware:hardware)
        guard let stamp=(try? FileManager.default.attributesOfItem(atPath:path.path)[.modificationDate]) as? Date,stamp != connectorStamp else{return}
        guard let asset=ConnectorModel.load(hardware:hardware) else{return}
        loadedModelID=asset.id;connectorStamp=stamp;bank=asset.bank;classifier=PreparedContextBank(bank);usesConnectorModel=true;matcher.reset()
    }
    private func finishCalibration(_ session:CalibrationSession){
        let valid=session.profile.validated
        do{
            try session.profile.save(activate:valid)
            if valid{personal=session.profile;personalClassifier=PreparedContextBank(session.profile.bank);tapModel=PersonalTapModel(session.profile.gestures ?? [],checks:session.profile.gestureChecks ?? []);pairModel=nil}
            calibrationOutcome=valid;outcomeUntil=ProcessInfo.processInfo.systemUptime+3
        }catch{calibrationOutcome=false;outcomeUntil=ProcessInfo.processInfo.systemUptime+3}
        calibration=nil;recorder.reset();grouper.reset();configureDetector();matcher.reset()
    }
    private func tick(){
        if let session=calibration{session.update(now:ProcessInfo.processInfo.systemUptime);if session.finished{finishCalibration(session)}}
        reloadConnectorModel()
        if inputBlocked{matcher.reset();lastDecision="Suppressed: recent keyboard or pointer activity"}
        let permission=permissionGranted
        if permission != allowed {allowed=permission;failedStart=false;resetStream();}
        let nextTarget=preferences.enabled && !suspended ? target?():nil
        if nextTarget != currentTarget{matcher.reset()}
        currentTarget=nextTarget
        reconcile()
        let now=ProcessInfo.processInfo.systemUptime
        if fixturePermission != nil && running{lastSample=now}
        if running,now-(lastSample>0 ? lastSample:started)>2 {
            status="No sensor stream. If permission was just granted, quit and reopen MagDot."
            failedStart=true;resetStream()
        }
        let diagnostic:[String:Any] = ["appPath":Bundle.main.bundleURL.path,"build":Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "unknown","sourceDigest":Bundle.main.object(forInfoDictionaryKey:"MagDotSourceDigest") as? String ?? "unknown","updatedAt":Date().timeIntervalSince1970,"enabled":preferences.enabled,"allowed":allowed,"lidOpen":gestureLidOpen(),"running":running,"ready":detector.ready,"hasEligibleAgent":currentTarget != nil,"settingsPreview":preview,"modelID":usesPersonalProfile ? (personal?.id ?? "personal-unconfigured"):loadedModelID,"useDefaultProfile":preferences.useDefault,"calibrating":calibration != nil,"inputSuppressed":inputBlocked,"rawTouchDevices":magdot_touch_available(),"rawTouchFrames":magdot_touch_frames(),"onsets":onsetCount,"impacts":impactCount,"lastDecision":lastDecision,"lastNavigation":lastNavigation,"lastNavigationAt":lastNavigationAt ?? 0,"status":status,"threshold":detector.threshold,"calibratedDetectionFloor":detector.learnedTapFloor ?? 0,"recentImpacts":recentImpacts,"locationSensitivity":usesFreeTapProfile ? min(preferences.sensitivity,tapModel?.maximumValidatedSensitivity ?? 1):preferences.sensitivity,"locationSensitivityLimit":tapModel?.maximumValidatedSensitivity ?? 1,"classifier":usesFreeTapProfile ? (tapModel?.usesSignedAlgorithm==true ? "signed-attack-logistic-v1":"legacy-envelope-fallback"):"legacy","profileCapture":usesFreeTapProfile ? "continuous-free-taps-v2":usesPairProfile ? "complete-gestures-v1":"legacy-single-taps","groupedVibrations":grouper.grouped,"calibrationLocation":calibration?.location.rawValue ?? "","calibrationGestures":calibration?.profile.gestures?.count ?? 0]
        #if TESTING
        let directory=ProcessInfo.processInfo.environment["MAGDOT_TEST_DIR"].map{URL(fileURLWithPath:$0)} ?? FileManager.default.temporaryDirectory.appendingPathComponent("MagDot-gesture-qa")
#else
        let directory=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MagDot")
#endif
        if let data=try? JSONSerialization.data(withJSONObject:diagnostic){try? data.write(to:directory.appendingPathComponent("gesture-status.json"),options:.atomic)}
    }
    private func reconcile(){
        let connected=magSafeConnection()==true,lid=gestureLidOpen()
        if observedConnection != connected || observedLid != lid{
            observedConnection=connected;observedLid=lid;failedStart=false;resetStream()
        }
        let open=(preferences.enabled || preview) && lid && connected
        let want=GesturePolicy.shouldListen(enabled:preferences.enabled,allowed:allowed,suspended:suspended,lidOpen:open,preview:preview,modelReady:modelReady,hasTarget:currentTarget != nil)
        if !want {if running{resetStream()}}
        if want && !running && !failedStart {
            detector.reset();recorder.reset();grouper.reset();matcher.reset();configureDetector()
            currentGestureService=self
            if fixturePermission == nil{_ = magdot_touch_start()}
            #if TESTING
            let fixtureResult:Int32=ProcessInfo.processInfo.environment["MAGDOT_TEST_SENSOR_RESULT_FILE"].flatMap{try? String(contentsOfFile:$0,encoding:.utf8)}.flatMap{Int32($0.trimmingCharacters(in:.whitespacesAndNewlines))} ?? 0
#else
            let fixtureResult:Int32=0
#endif
            let result=fixturePermission != nil ? fixtureResult:magdot_sensor_start(gestureSample)
            if fixturePermission != nil{for i in 0..<900{detector.ingest(Double(i)/800,[0,0,-1])}}
            running=result==0;started=ProcessInfo.processInfo.systemUptime;lastSample=0
            if !running{failedStart=true;status=result==2 ? "This Mac does not expose a supported accelerometer." : "Could not start the sensor. Check permission, then reopen MagDot."}
        }
        if recognizedUntil>ProcessInfo.processInfo.systemUptime && running && preferences.enabled && allowed {status="Double-tap recognized";return}
        if !preferences.enabled{status=running ? "Live preview · double-tap feature is off":"Enable double-tap to preview."}
        else if !allowed{status="Allow Input Monitoring to use the accelerometer."}
        else if suspended{status="Paused while your Mac is asleep or locked."}
        else if !connected{status="Connect MagSafe to use double-tap."}
        else if !open{status="Open your MacBook to use double-tap."}
        else if failedStart{return}
        else if !modelReady{status=preferences.useDefault ? "The experimental gesture model is not available for this Mac yet.":""}
        else if inputBlocked{status="Taps paused · keyboard or pointer activity"}
        else if running{status=detector.ready ? (preview ? (usesConnectorModel ? "Live preview · MagSafe connector model":"Live preview · estimated area (orange = uncertain)"):"Listening for a double-tap") : "Hold still for a moment…"}
        else{status="Ready · listening when an agent is done or needs input."}
    }
    fileprivate func sample(_ t:Double,_ xyz:[Double]){
        let now=ProcessInfo.processInfo.systemUptime
        guard running,allowed,!suspended else{return}
        if lastSample==0{sensorOffset=now-t}
        lastSample=now
        recorder.sample(MotionSample(t:t,xyz:xyz),inputActive:inputBlocked)
        let wasReady=detector.ready;detector.ingest(t,xyz)
        if wasReady && !detector.ready{cancelCalibration();matcher.reset();status="Sensor restarted · hold still for a moment…"}
        matcher.advance(t-0.14)
        if let recording=recorder.take(now:t,handling:calibration?.location == .handling && calibration?.checking==false,continuous:calibration != nil && calibration?.checking==false){
            complete(recording)
        }
    }
    private func impact(_ raw:Impact){
        impactCount+=1
        guard magSafeConnection()==true else{return}
        guard let impact=grouper.ingest(raw) else{if grouper.confidentDecay{recorder.vibration(raw)};lastDecision=grouper.reason;return}
        recorder.impact(impact)
        if let calibration{if !inputBlocked{calibration.observeTap(impact,at:impact.onset+sensorOffset);onOnset?(impact.onset,impact.peak)};return}
        guard !inputBlocked else{matcher.reset();lastDecision="Suppressed: recent keyboard or pointer activity";return}
        let evidence=usesFreeTapProfile ? tapModel!.evidence(impact,sensitivity:preferences.sensitivity):usesPersonalProfile ? personalClassifier.evidence(impact.feature,vetoNegativeNeighbor:true,sensitivity:preferences.sensitivity):classifier.evidence(impact.feature,sensitivity:preferences.sensitivity)
        onImpact?(impact.onset,evidence.side,impact.peak)
        guard !usesPairProfile else{return}
        guard modelReady,allowed,preferences.enabled,!suspended,gestureLidOpen() else{matcher.reset();return}
        let decision=matcher.ingest(GestureCandidate(impact:impact,evidence:evidence),armed:GesturePolicy.canNavigate(enabled:preferences.enabled,allowed:allowed,hasTarget:currentTarget != nil))
        lastDecision=decision?.reason ?? matcher.status
        logGesture(peak:impact.peak,count:1,reason:lastDecision)
        if decision?.accepted==true{confirmGesture()}
    }
    private func complete(_ recording:GestureRecording){
        if let session=calibration{
            let location=session.location
            _ = session.accept(recording,onset:recording.startedAt+sensorOffset,now:ProcessInfo.processInfo.systemUptime)
            if location != session.location || session.checking{recorder.reset();grouper.reset()}
            return
        }
        if preview && preferences.enabled && !recording.inputActive{
            let evidence=recording.impacts.map{impact in usesFreeTapProfile ? tapModel!.evidence(impact,sensitivity:preferences.sensitivity):usesPersonalProfile ? personalClassifier.evidence(impact.feature,vetoNegativeNeighbor:true,sensitivity:preferences.sensitivity):classifier.evidence(impact.feature,sensitivity:preferences.sensitivity)}
            recentTraces.append(GestureTrace(capturedAt:Date(),hardware:hardware,modelID:usesPersonalProfile ? personal!.id:loadedModelID,recording:recording,evidence:evidence,lastNavigationAt:lastNavigationAt))
            recentTraces=Array(recentTraces.suffix(6))
#if !TESTING
            let path=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MagDot/gesture-recent.json")
            if let data=try? JSONEncoder().encode(recentTraces){try? data.write(to:path,options:.atomic)}
#endif
        }
        guard usesPairProfile,let pairModel else{return}
        let result=pairModel.evaluate(recording,sensitivity:preferences.sensitivity);lastDecision=result.reason
        logGesture(peak:recording.impacts.map(\.peak).max() ?? 0,count:recording.impacts.count,reason:result.reason)
        if result.accepted{onImpact?(recording.startedAt,0,recording.impacts.map(\.peak).max() ?? 0);confirmGesture()}
    }
    private func logGesture(peak:Double,count:Int,reason:String){
        recentImpacts.append(["time":Date().timeIntervalSince1970,"peak":peak,"freshImpacts":count,"decision":reason])
        recentImpacts=Array(recentImpacts.suffix(12))
    }
    private func confirmGesture(){
        guard modelReady,allowed,preferences.enabled,!suspended,gestureLidOpen(),magSafeConnection()==true,!inputBlocked else{return}
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier != "local.magdot.taplab" else{lastDecision="Paused while Tap Lab is frontmost";return}
        guard GesturePolicy.canNavigate(enabled:preferences.enabled,allowed:allowed,hasTarget:currentTarget != nil),let fresh=target?(),fresh==currentTarget else{lastDecision="Visualization only · no Done/Input agent";return}
        let now=ProcessInfo.processInfo.systemUptime
        guard now-lastGestureAt>0.8 else{return};lastGestureAt=now
        recognizedUntil=now+2
        let opened=navigate?(fresh)==true
        lastNavigation=opened ? "T3 chat URL accepted by macOS":"T3 chat URL open failed"
        if opened{lastNavigationAt=Date().timeIntervalSince1970;status="Opened your agent."}
    }
}
