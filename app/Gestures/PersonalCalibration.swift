import Foundation
import CoreGraphics

enum InteractionGuard {
    static func blocked(keyboardAge:Double,pointerAge:Double)->Bool{keyboardAge<0.75 || pointerAge<0.75}
    static var active:Bool {
        let keys:[CGEventType]=[.keyDown,.keyUp,.flagsChanged]
        let pointer:[CGEventType]=[.mouseMoved,.leftMouseDown,.leftMouseUp,.rightMouseDown,.rightMouseUp,.otherMouseDown,.otherMouseUp,.leftMouseDragged,.rightMouseDragged,.otherMouseDragged,.scrollWheel,.tabletPointer]
        func age(_ types:[CGEventType])->Double{types.map{CGEventSource.secondsSinceLastEventType(.combinedSessionState,eventType:$0)}.min() ?? 0}
        return blocked(keyboardAge:age(keys),pointerAge:min(age(pointer),magdot_touch_age()))
    }
}
enum CalibrationLocation:String,Codable,CaseIterable {
    case connector="MagSafe connector",backLeft="Back-left corner",backRight="Back-right corner",frontLeft="Front-left corner",frontRight="Front-right corner",handling="Normal handling"
    static let targets:[CalibrationLocation]=[.connector,.backRight,.frontLeft,.frontRight]
    var displayName:String{switch self{case .connector:return "MagSafe";case .backLeft:return "top-left corner";case .backRight:return "top-right corner";case .frontLeft:return "left palm rest";case .frontRight:return "right palm rest";case .handling:return "normal handling"}}
    var label:Int{self == .connector ? 0:1}
}
struct PersonalExample:Codable {let location:CalibrationLocation;let intensity:String;let impact:Impact}
struct PersonalValidation:Codable {let location:CalibrationLocation;let predicted:Int?;var samples:[Impact]? = nil}
struct PersonalCalibration:Codable {
    let hardware:String
    let id:String
    let date:Date
    var examples:[PersonalExample]
    var validation:[PersonalValidation]
    var gestures:[GestureExample]? = nil
    var gestureChecks:[GestureValidation]? = nil
    var gestureVersion:Int? = nil
    var targetLayout:String? = nil
    var hasGestureData:Bool{gestures != nil}
    var valid:Bool {
        if let gestures{
            if gestureVersion==2{
                return CalibrationLocation.targets.allSatisfy{target in gestures.filter{$0.location==target}.count>=3} && gestures.allSatisfy{$0.recording.valid} && PersonalTapModel(gestures).ready
            }
            return gestureVersion==1 && (CalibrationLocation.targets+[.handling]).allSatisfy{target in gestures.filter{$0.location==target}.count>=8} && gestures.allSatisfy{$0.recording.valid} && PersonalGestureModel(gestures).ready
        }
        return examples.count>=CalibrationLocation.targets.count*12 && CalibrationLocation.targets.allSatisfy{location in examples.filter{$0.location==location}.count>=12} && examples.allSatisfy{$0.impact.feature.count==42 && $0.impact.feature.allSatisfy(\.isFinite) && $0.impact.peak.isFinite && $0.impact.peak>0}
    }
    var validated:Bool{
        if hasGestureData{guard valid,let checks=gestureChecks else{return false};let targets=gestureVersion==2 ? CalibrationLocation.targets:CalibrationLocation.targets+[.handling];return checks.count==targets.count && Set(checks.map(\.location))==Set(targets) && checks.allSatisfy{!$0.samples.isEmpty && $0.samples.allSatisfy(\.valid) && $0.passed}}
        return valid && validation.count>=CalibrationLocation.targets.count && Set(validation.map(\.location)).count==validation.count && Set(CalibrationLocation.targets).isSubset(of:Set(validation.map(\.location))) && validation.allSatisfy{$0.predicted==$0.location.label}}
    var suggestedDetectionFloor:Double?{
        let peaks=examples.filter{$0.location == .connector}.map{$0.impact.peak}.sorted()
        guard !peaks.isEmpty else{return nil}
        return max(0.00075,min(0.005,peaks[Int(Double(peaks.count-1)*0.1)]*0.1))
    }
    var bank:ContextBank{
        var model=LocationModel();for e in examples{model.add(e.impact,zone:e.location.label)}
        return ContextBank(experts:[ContextBank.Expert(source:"personal/"+id,model:model)])
    }
    func evidence(_ f:[Double])->SideEvidence{PreparedContextBank(bank).evidence(f)}
    static func root()->URL{
#if TESTING
        if let path=ProcessInfo.processInfo.environment["MAGDOT_TEST_PERSONAL_ROOT"]{return URL(fileURLWithPath:path)}
#endif
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MagDot/PersonalCalibration")
    }
    static func load(_ hardware:String)->PersonalCalibration?{
        let path=root().appendingPathComponent(hardware.replacingOccurrences(of:",",with:"_")+".json")
        guard let data=try? Data(contentsOf:path),let p=try? JSONDecoder().decode(Self.self,from:data),p.hardware==hardware,p.validated else{return nil};return p
    }
    func save(activate:Bool)throws{
        let root=Self.root();try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let data=try JSONEncoder().encode(self)
        try data.write(to:root.appendingPathComponent("attempt-"+id+".json"),options:.atomic)
        if activate && validated{try data.write(to:root.appendingPathComponent(hardware.replacingOccurrences(of:",",with:"_")+".json"),options:.atomic)}
    }
}
enum CalibrationReadiness {
    static func enough(_ rows:[Impact])->Bool {
        guard rows.count>=12 else{return false}
        let recent=Array(rows.suffix(12)).map(\.feature)
        func mean(_ rows:[[Double]])->[Double]{(0..<42).map{i in rows.reduce(0){$0+$1[i]}/Double(rows.count)}}
        let earlier=mean(Array(recent.prefix(6))),later=mean(Array(recent.suffix(6)))
        let stability=DoubleTapMatcher.similarity(earlier,later)
        let center=mean(recent)
        let consistency=recent.map{DoubleTapMatcher.similarity($0,center)}.sorted()[2]
        // A minimum sample base plus stable recent shape; pairwise separation
        // is checked using reserved taps after all locations are collected.
        return stability>=0.985 && consistency>=0.9
    }
}
final class CalibrationSession {
    static let steps=CalibrationLocation.targets
    var profile:PersonalCalibration
    private(set) var cueAt:Double
    private(set) var stage=0
    private var completedUntil=0.0,checkAt=Double.greatestFiniteMagnitude
    private var completedLocation:CalibrationLocation?
    private var heldOut=[GestureExample]()
    private var retryTargets=[CalibrationLocation]()
    private var pace=CalibrationPace()
    var paceHint:String{checking || finished ? "":pace.hint(at:ProcessInfo.processInfo.systemUptime)}
    func observeTap(_ impact:Impact,at time:Double){if time>=cueAt && !checking && !finished{pace.observe(impact,at:time)}}
    private(set) var finished=false
    var checking:Bool{stage==Self.steps.count && retryTargets.isEmpty && !finished}
    var validating:Bool{checking}
    var location:CalibrationLocation{retryTargets.first ?? Self.steps[min(Self.steps.count-1,stage)]}
    var displayLocation:CalibrationLocation{ProcessInfo.processInfo.systemUptime<completedUntil ? completedLocation ?? location:location}
    var instruction:String{checking ? "Checking…":"Keep tapping \(displayLocation.displayName)"}
    var progress:Double{
        if ProcessInfo.processInfo.systemUptime<completedUntil{return 1}
        let train=trainingCount(location)
        let checks=heldOut.filter{$0.location==location}.count
        return min(0.95,0.75*Double(min(location == .handling ? 8:12,train))/Double(location == .handling ? 8:12)+0.25*Double(min(3,checks))/3)
    }
    private func trainingCount(_ target:CalibrationLocation)->Int{
        let rows=(profile.gestures ?? []).filter{$0.location==target}
        return target == .handling ? rows.count:rows.reduce(0){$0+$1.recording.impacts.count}
    }
    init(hardware:String,now:Double){profile=PersonalCalibration(hardware:hardware,id:UUID().uuidString,date:Date(),examples:[],validation:[],gestures:[],gestureChecks:[],gestureVersion:2,targetLayout:"palm-rests-v1");cueAt=now+0.8}
    func update(now:Double){
        guard checking,now>=checkAt else{return}
        let inputs=Self.steps.map{target in GestureValidation(location:target,samples:heldOut.filter{$0.location==target}.map(\.recording),detected:[])}
        let model=PersonalTapModel(profile.gestures ?? [],checks:inputs)
        profile.gestureChecks=inputs.map{model.validate($0.location,$0.samples)}
        let failed=(profile.gestureChecks ?? []).filter{!$0.passed}.map(\.location)
        if failed.isEmpty{finished=true}
        else{pace.reset();retryTargets=failed;profile.gestureChecks=[];heldOut.removeAll{failed.contains($0.location)};completedUntil=0;completedLocation=nil;cueAt=now+0.8}
    }
    @discardableResult func accept(_ recording:GestureRecording,onset:Double,now:Double)->Bool{
        guard !finished,!checking,recording.valid else{return false}
        let target=location
        pace.observeRecording(recording,at:now)
        if recording.inputActive || recording.impacts.isEmpty{
            if (!recording.impacts.isEmpty || !(recording.decays ?? []).isEmpty) && (profile.gestures?.filter{$0.location == .handling}.count ?? 0)<12{profile.gestures?.append(GestureExample(location:.handling,recording:recording))}
            return false
        }
        guard onset+(recording.impacts.first?.onset ?? 0)>=cueAt else{return false}
        let row=GestureExample(location:target,recording:recording)
        let train=profile.gestures?.filter{$0.location==target}.count ?? 0
        let total=train+heldOut.filter{$0.location==target}.count
        if total%4==3{heldOut.append(row)}else{
            profile.gestures?.append(row)
            for impact in recording.impacts{profile.examples.append(PersonalExample(location:target,intensity:"free-tap",impact:Impact(onset:impact.onset,peak:impact.peak,feature:impact.feature,waveform:[])))}
        }
        let enough=trainingCount(target)>=(target == .handling ? 8:12) && heldOut.filter{$0.location==target}.count>=3 && (target != .connector || heldOut.filter{$0.location==target}.reduce(0){$0+$1.recording.impacts.count}>=4)
        if enough{
            pace.reset()
            if retryTargets.isEmpty{stage+=1}else{retryTargets.removeFirst()}
            completedLocation=target;completedUntil=now+0.8;cueAt=now+0.8
            if checking{checkAt=now+1.4}
        }
        return true
    }
}
