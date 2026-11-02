// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import SQLite3

func magSafeGestureSelfTest(){
    precondition(magdot_touch_decoder_selftest()==1)
    precondition(InteractionGuard.blocked(keyboardAge:0.1,pointerAge:10))
    precondition(InteractionGuard.blocked(keyboardAge:10,pointerAge:0.1))
    precondition(InteractionGuard.blocked(keyboardAge:10,pointerAge:0.6))
    precondition(!InteractionGuard.blocked(keyboardAge:1,pointerAge:1))
    precondition(!GesturePolicy.canNavigate(enabled:true,allowed:true,hasTarget:false))
    precondition(!GesturePolicy.canNavigate(enabled:false,allowed:true,hasTarget:true))
    precondition(!GesturePolicy.canNavigate(enabled:true,allowed:false,hasTarget:true))
    precondition(GesturePolicy.canNavigate(enabled:true,allowed:true,hasTarget:true))
    var unreadLight=UnreadDoneLight()
    precondition(unreadLight.update(["old-chat":5],now:100,duration:60),"Marking an old completed chat unread must light Done without a new provider turn")
    precondition(!unreadLight.update(["old-chat":5],now:160,duration:60))
    precondition(!unreadLight.update([:],now:161,duration:60))
    precondition(unreadLight.update(["old-chat":5],now:162,duration:60),"Re-mark unread must rearm Done")
    precondition(UnreadDoneLight.mode(tracked:"working",unread:true)=="finished")
    precondition(UnreadDoneLight.mode(tracked:"attention",unread:true)=="attention")
    precondition(UnreadDoneLight.mode(tracked:"working",unread:false)=="working")
    precondition(UnreadDoneLight.mode(tracked:"finished",unread:false)=="idle","A stale tracked completion must clear when no unread Done remains")
    precondition(UnreadDoneLight.mode(tracked:"finished",unread:false,working:true)=="working")
    let lowered=BurstDetector();lowered.sensitivity=1
    precondition(abs(lowered.threshold-0.00075)<1e-10,"Full sensitivity onset floor is lowered")
    let capture=BurstDetector();capture.calibrationCapture=true;capture.sensitivity=1
    var ambientCaptures=0;capture.onImpact={_ in ambientCaptures+=1}
    for i in 0..<3200{capture.ingest(Double(i)/800,[i%2==0 ? 0.002:-0.002,0,-1])}
    precondition(capture.threshold>0.004 && ambientCaptures==0,"Calibration must reject continuous background vibration even at full runtime sensitivity")
    // Increasing ambient vibration must update a baseline which began quiet.
    let driftingCapture=BurstDetector();driftingCapture.calibrationCapture=true
    for i in 0..<800{driftingCapture.ingest(Double(i)/800,[0,0,-1])}
    for i in 800..<3200{driftingCapture.ingest(Double(i)/800,[i%2==0 ? 0.004:-0.004,0,-1])}
    precondition(driftingCapture.threshold>0.008,"Calibration noise adaptation must not freeze below the ambient signal")
    var confidenceFixture=LocationModel()
    for _ in 0..<12{confidenceFixture.add(Impact(onset:0,peak:1,feature:[1,0],waveform:[]),zone:0);confidenceFixture.add(Impact(onset:0,peak:1,feature:[0,1],waveform:[]),zone:1)}
    let confidenceBank=PreparedContextBank(ContextBank(experts:[.init(source:"confidence",model:confidenceFixture)]))
    precondition(confidenceBank.evidence([0.85,0.15],vetoNegativeNeighbor:true,sensitivity:0.5).side==nil)
    precondition(confidenceBank.evidence([0.85,0.15],vetoNegativeNeighbor:true,sensitivity:1).side==0,"Higher sensitivity must admit a borderline MagSafe-shaped impact")
    for value in [0.0,0.5,1.0]{precondition(confidenceBank.evidence([0,1],vetoNegativeNeighbor:true,sensitivity:value).side==1,"Sensitivity must not turn a strong other-location match into MagSafe")}
    gestureRecordingSelfTest()
    let domain="magdot.gesture-test."+UUID().uuidString
    let d=UserDefaults(suiteName:domain)!;defer{d.removePersistentDomain(forName:domain)}
    let prefs=TapPreferences(d)
    precondition(!prefs.enabled && prefs.useDefault && prefs.sensitivity==0.5)
    prefs.enabled=true;prefs.sensitivity=0.8
    precondition(prefs.enabled && prefs.sensitivity==0.8)
    prefs.flush()
    let probe=Process(),pipe=Pipe();probe.executableURL=URL(fileURLWithPath:CommandLine.arguments[0]);probe.arguments=["--gesture-preference-probe",domain];probe.standardOutput=pipe
    try! probe.run();let persisted=pipe.fileHandleForReading.readDataToEndOfFile();probe.waitUntilExit()
    let values=try! JSONSerialization.jsonObject(with:persisted) as! [String:Any]
    precondition(probe.terminationStatus==0 && values["enabled"] as? Bool==true && values["sensitivity"] as? Double==0.8,"gesture choice must survive a new process before permission relaunch")
    d.set(Double.nan,forKey:"gesture.sensitivity");precondition(prefs.sensitivity==0.5)
    precondition(!GesturePolicy.shouldListen(enabled:true,allowed:false,suspended:false,lidOpen:true,preview:true,modelReady:true,hasTarget:true))
    precondition(!GesturePolicy.shouldListen(enabled:true,allowed:true,suspended:false,lidOpen:false,preview:true,modelReady:true,hasTarget:true))
    precondition(!GesturePolicy.shouldListen(enabled:true,allowed:true,suspended:true,lidOpen:true,preview:true,modelReady:true,hasTarget:true))
    precondition(GesturePolicy.shouldListen(enabled:true,allowed:true,suspended:false,lidOpen:true,preview:false,modelReady:true,hasTarget:false))
    precondition(GesturePolicy.shouldListen(enabled:true,allowed:true,suspended:false,lidOpen:true,preview:false,modelReady:true,hasTarget:true))
    precondition(GesturePolicy.shouldListen(enabled:false,allowed:true,suspended:false,lidOpen:true,preview:true,modelReady:false,hasTarget:false))
    precondition(!GesturePolicy.shouldListen(enabled:false,allowed:true,suspended:false,lidOpen:true,preview:false,modelReady:true,hasTarget:true))
    func c(_ t:Double,_ side:Int?,_ f:[Double]=[1,0])->GestureCandidate{GestureCandidate(impact:Impact(onset:t,peak:0.1,feature:f,waveform:[]),evidence:SideEvidence(side:side,leftDistance:0.5,contradiction:false))}
    let m=DoubleTapMatcher()
    _=m.ingest(c(1,nil),armed:true);precondition(m.ingest(c(1.2,0),armed:true)?.accepted==true)
    m.reset();_=m.ingest(c(1,0),armed:true);precondition(m.ingest(c(1.2,nil),armed:true)?.accepted==true)
    m.reset();_=m.ingest(c(1,nil),armed:true);precondition(m.ingest(c(1.2,nil),armed:true)?.accepted==false)
    m.reset();_=m.ingest(c(1,1),armed:true);precondition(m.ingest(c(1.2,0),armed:true)?.accepted==false)
    m.reset();_=m.ingest(c(1,0),armed:false);precondition(m.ingest(c(1.2,0),armed:false)==nil)
    m.reset();_=m.ingest(c(1,0),armed:true);precondition(m.ingest(c(1.2,0,[0,1]),armed:true)?.accepted==false)
    m.reset();_=m.ingest(c(1,0),armed:true,requireTwoAnchors:true);precondition(m.ingest(c(1.2,nil),armed:true,requireTwoAnchors:true)?.accepted==false)
    m.reset();_=m.ingest(c(1,0),armed:true,requireTwoAnchors:true);precondition(m.ingest(c(1.2,0),armed:true,requireTwoAnchors:true)?.accepted==true)
    var delivered=[String:Double]()
    let doneThreads=["new":200.0,"old":100.0]
    precondition(nextGestureDone(doneThreads,delivered:delivered)=="new")
    delivered["new"]=200;precondition(nextGestureDone(doneThreads,delivered:delivered)=="old")
    delivered["old"]=100;precondition(nextGestureDone(doneThreads,delivered:delivered)==nil)
    precondition(nextGestureDone(["new":201],delivered:delivered)=="new")
    let adapting=BurstDetector()
    for i in 0..<800{adapting.ingest(Double(i)/800,[i%2==0 ? 0.01:-0.01,0,-1])}
    let noisy=adapting.threshold
    for i in 800..<3000{adapting.ingest(Double(i)/800,[0,0,-1])}
    precondition(adapting.threshold<noisy*0.6,"Startup handling must not latch the threshold")
    let path=NSTemporaryDirectory()+"magdot-done-"+UUID().uuidString+".sqlite"
    defer{try? FileManager.default.removeItem(atPath:path)}
    var db:OpaquePointer?;precondition(sqlite3_open(path,&db)==SQLITE_OK)
    let sql="""
    CREATE TABLE orchestration_v2_projection_threads(thread_id TEXT,archived_at TEXT,deleted_at TEXT,payload_json TEXT);
    CREATE TABLE orchestration_v2_projection_runs(thread_id TEXT,ordinal INTEGER,status TEXT,completed_at TEXT);
    INSERT INTO orchestration_v2_projection_threads VALUES('unread',NULL,NULL,'{"lastVisitedAt":"2020-01-01T00:00:00Z"}'),('seen',NULL,NULL,'{"lastVisitedAt":"2020-01-03T00:00:00Z"}'),('working',NULL,NULL,'{"lastVisitedAt":"2020-01-01T00:00:00Z"}'),('archived','2020-01-01',NULL,'{"lastVisitedAt":"2020-01-01T00:00:00Z"}');
    INSERT INTO orchestration_v2_projection_runs VALUES('unread',1,'completed','2020-01-02T00:00:00Z'),('seen',1,'completed','2020-01-02T00:00:00Z'),('working',1,'completed','2020-01-02T00:00:00Z'),('working',2,'running',NULL),('archived',1,'completed','2020-01-02T00:00:00Z');
    """
    precondition(sqlite3_exec(db,sql,nil,nil,nil)==SQLITE_OK);sqlite3_close(db)
    let unread=try! pendingDoneThreads(path:path)
    precondition(Set(unread.keys)==Set(["unread"]),"Done navigation must survive restart and LED expiry, skip seen/newly running/archived chats")
    precondition(sqlite3_open(path,&db)==SQLITE_OK)
    precondition(sqlite3_exec(db,"UPDATE orchestration_v2_projection_threads SET payload_json=json_set(payload_json,'$.settledOverride','settled') WHERE thread_id='unread'",nil,nil,nil)==SQLITE_OK)
    precondition(try! pendingDoneThreads(path:path).isEmpty,"Manually settling a thread must clear Done for both LED and navigation")
    precondition(sqlite3_exec(db,"UPDATE orchestration_v2_projection_threads SET payload_json=json_set(payload_json,'$.settledOverride','active') WHERE thread_id='unread'",nil,nil,nil)==SQLITE_OK)
    precondition(Set(try! pendingDoneThreads(path:path).keys)==Set(["unread"]),"Manually returning to Done must restore eligibility")
    sqlite3_close(db)
    func uncertain(_ ratio:Double)->GestureCandidate{GestureCandidate(impact:c(1.2,nil).impact,evidence:SideEvidence(side:nil,leftDistance:0.5,contradiction:false,leftVsOther:ratio))}
    m.reset();_=m.ingest(c(1,0),armed:true);precondition(m.ingest(uncertain(1.1),armed:true)?.accepted==false)
    m.reset();_=m.ingest(c(1,0),armed:true);precondition(m.ingest(uncertain(0.85),armed:true)?.accepted==true)
    let calibratedDetector=BurstDetector();calibratedDetector.sensitivity=1;calibratedDetector.learnedTapFloor=0.004
    precondition(calibratedDetector.threshold==0.004,"Full sensitivity must respect calibrated onset floor")
    let detector=BurstDetector();var taps=[Impact](),onsets=[Double](),onsetDeliveredBeforeWaveform=true
    detector.onImpact={taps.append($0)}
    detector.onOnset={t,_ in onsets.append(t);onsetDeliveredBeforeWaveform = onsetDeliveredBeforeWaveform && taps.count<onsets.count}
    for i in 0..<1400{let x=(i==900 || i==1000) ? 0.2:0;detector.ingest(Double(i)/800,[x,0,-1])}
    precondition(taps.count==2 && abs(taps[1].onset-taps[0].onset-0.125)<0.002)
    precondition(onsets.count==2 && onsetDeliveredBeforeWaveform && onsets==taps.map(\.onset),"visual onset must arrive immediately before 140-ms waveform completion")
    var model=LocationModel()
    for side in 0...1 {for i in 0..<12 {var f=Array(repeating:0.0,count:42);f[side]=1+Double(i)*0.001;model.add(Impact(onset:0,peak:0.1,feature:f,waveform:[]),zone:side)}}
    let reference=ContextBank(experts:[ContextBank.Expert(source:"fixture",model:model)]),prepared=PreparedContextBank(reference)
    for f in model.samples.values.flatMap({$0}).map(\.feature)+[Array(repeating:1.0,count:42)] {
        let a=reference.evidence(f),b=prepared.evidence(f)
        precondition(a.side==b.side && a.contradiction==b.contradiction && abs(a.leftDistance-b.leftDistance)<1e-9,"cached classifier must preserve decisions")
    }
    struct Models:Decodable{let experts:[ContextBank.Expert]}
    if let url=Bundle.main.url(forResource:"MagSafeTapModels",withExtension:"json") {
        let models=try! JSONDecoder().decode(Models.self,from:Data(contentsOf:url))
        let original=ContextBank(experts:models.experts),fast=PreparedContextBank(original)
        for f in models.experts.flatMap({$0.model.samples.values.flatMap{$0}}).map(\.feature) {
            let a=original.evidence(f),b=fast.evidence(f)
            precondition(a.side==b.side && a.contradiction==b.contradiction && abs(a.leftDistance-b.leftDistance)<1e-8,"bundled dataset decisions must stay identical")
        }
        print("Bundled-model cached classifier parity passed")
    }
    let base=detector.threshold;detector.sensitivity=1;precondition(detector.threshold<base);detector.sensitivity=0;precondition(detector.threshold>base)
    precondition(gestureThreadURL("abc-123_def",environment:"local-123")?.absoluteString=="t3code://threads/local-123/abc-123_def")
    precondition(gestureThreadURL("../settings",environment:"local")==nil && gestureThreadURL("abc?x=1",environment:"local")==nil)
    print("Experimental gesture checks passed: opt-in defaults, cross-process preference persistence, pair matching, disarmed rejection, sensitivity, immediate visual onsets, cached classifier parity and safe thread URLs")
}
