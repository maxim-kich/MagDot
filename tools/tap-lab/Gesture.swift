import Foundation
import CryptoKit

struct SideEvidence:Codable {
    let side:Int?
    let leftDistance:Double
    let contradiction:Bool
}
struct GestureCandidate:Codable {let impact:Impact;let evidence:SideEvidence}
struct GestureDecision:Codable {
    let first:Double;let second:Double;let accepted:Bool
    let reason:String;let similarity:Double
}
// Sample timestamps, rather than wall-clock timers, drive every decision.
final class DoubleTapMatcher {
    private var recent=[GestureCandidate](),lastTime = -1.0,lastFire = -1.0
    private(set) var status="Waiting for a pair"
    func reset(){recent=[];lastTime = -1;lastFire = -1;status="Waiting for a pair"}
    func advance(_ t:Double){
        recent.removeAll{t-$0.impact.onset>0.65}
        if recent.isEmpty && (status.hasPrefix("Target anchor") || status.hasPrefix("Candidate retained")){status="Pair window expired · waiting"}
    }
    static func similarity(_ a:[Double],_ b:[Double])->Double {
        guard !a.isEmpty,a.count==b.count else{return 0}
        let dot=zip(a,b).reduce(0){$0+$1.0*$1.1}
        let norm=sqrt(a.reduce(0){$0+$1*$1}*b.reduce(0){$0+$1*$1})
        return norm>1e-12 ? max(-1,min(1,dot/norm)) : 0
    }
    func ingest(_ next:GestureCandidate,armed:Bool)->GestureDecision? {
        let t=next.impact.onset
        guard t.isFinite,next.impact.peak.isFinite,next.impact.peak>0 else{return nil}
        if lastTime>=0 && (t<=lastTime || t-lastTime>2) {reset()}
        lastTime=t
        guard armed else{recent=[];status="Disarmed · agent not requesting attention";return nil}
        recent.removeAll{t-$0.impact.onset>0.65}
        guard lastFire<0 || t-lastFire>0.8 else{status="Gesture cooldown";return nil}
        // A burst of many candidates is more consistent with typing/handling.
        if recent.count>=3 {recent.append(next);status="Rejected busy burst";return nil}
        var rejection:GestureDecision?
        for previous in recent.reversed() {
            let dt=t-previous.impact.onset
            guard dt>=0.09,dt<=0.60 else{continue}
            let s=Self.similarity(previous.impact.feature,next.impact.feature)
            let a=previous.evidence,b=next.evidence
            var reason=""
            if recent.contains(where:{$0.impact.onset>=previous.impact.onset && ($0.evidence.side==1 || $0.evidence.contradiction)}) || a.contradiction || b.contradiction || a.side==1 || b.side==1 {reason="Non-target contradiction"}
            else if a.side != 0 && b.side != 0 {reason="No learned target anchor"}
            else if max(a.leftDistance,b.leftDistance)>3 {reason="Unknown impact too far from learned target signatures"}
            else if max(previous.impact.peak,next.impact.peak)/min(previous.impact.peak,next.impact.peak)>5 {reason="Impact strengths too different"}
            else if s < (a.side==0 && b.side==0 ? 0.85 : 0.92) {reason="Pair signatures differ"}
            else {
                lastFire=t;recent=[];status="Double-tap confirmed"
                return GestureDecision(first:previous.impact.onset,second:t,accepted:true,reason:a.side==0 && b.side==0 ? "Two target anchors" : "Learned target anchor matched an unknown neighbor",similarity:s)
            }
            rejection=GestureDecision(first:previous.impact.onset,second:t,accepted:false,reason:reason,similarity:s)
        }
        recent.append(next)
        status=next.evidence.side==0 ? "Target anchor · checking past and waiting up to 600 ms" : "Candidate retained · waiting for a learned target anchor"
        return rejection
    }
}

// Overlapping capture windows preserve a second onset even when the first
// impact's 140-ms waveform window is still being assembled.
final class BurstDetector {
    private struct Pending {let start:Double;var peak:Double;var frames:[MotionSample]}
    var onImpact:((Impact)->Void)?
    var onOnset:((Double,Double)->Void)?
    private var gravity=[Double](),history=[MotionSample](),pending=[Pending](),noise=[Double]()
    private var last = -1.0,lastOnset = -1.0,lastQuiet = -1.0,previousMagnitude=0.0
    private(set) var magnitude=0.0
    private(set) var noiseFloor=0.0
    var ready:Bool{noise.count>=800}
    var sensitivity=0.5
    var threshold:Double{max(0.006,min(0.03,noiseFloor*2.5))*pow(2,(0.5-sensitivity)*2)}
    func reset(){gravity=[];history=[];pending=[];noise=[];last = -1;lastOnset = -1;lastQuiet = -1;previousMagnitude=0;magnitude=0;noiseFloor=0}
    func ingest(_ t:Double,_ xyz:[Double]) {
        guard t.isFinite,xyz.count==3,xyz.allSatisfy(\.isFinite) else{return}
        if last>=0 && (t<=last || t-last>0.05){reset()}
        last=t
        if gravity.isEmpty{gravity=xyz}
        let delta=zip(xyz,gravity).map(-)
        for i in 0..<3 {gravity[i]+=0.015*delta[i]}
        magnitude=sqrt(delta.reduce(0){$0+$1*$1})
        defer{previousMagnitude=magnitude}
        let frame=MotionSample(t:t,xyz:delta)
        history.append(frame);history.removeAll{t-$0.t>0.04}
        if !ready {
            noise.append(magnitude)
            if ready {let median=noise.sorted()[400];let mad=noise.map{abs($0-median)}.sorted()[400];noiseFloor=median+6*mad}
            return
        }
        for i in pending.indices {pending[i].frames.append(frame);pending[i].peak=max(pending[i].peak,magnitude)}
        if magnitude<threshold*0.65 {lastQuiet=t}
        let sharpRise=magnitude>max(threshold,previousMagnitude*1.7)
        if (lastOnset<0 || t-lastOnset>=0.085),magnitude>threshold,
           sharpRise || (lastQuiet>=0 && t-lastQuiet<0.025 && previousMagnitude<=threshold) {
            pending.append(Pending(start:t,peak:magnitude,frames:history));lastOnset=t;lastQuiet = -1
            onOnset?(t,magnitude)
        }
        let complete=pending.filter{t-$0.start>=0.14}
        pending.removeAll{t-$0.start>=0.14}
        for p in complete {onImpact?(Impact(onset:p.start,peak:p.peak,feature:features(p.frames),waveform:p.frames))}
    }
}

struct ContextBank {
    struct Expert:Codable {let source:String;let model:LocationModel}
    var experts=[Expert]()
    var id:String {
        let e=JSONEncoder();e.outputFormatting = .sortedKeys
        return SHA256.hash(data:(try? e.encode(experts)) ?? Data()).map{String(format:"%02x",$0)}.joined()
    }
    var examples:Int{experts.reduce(0){$0+$1.model.samples.values.reduce(0){$0+$1.count}}}
    func evidence(_ f:[Double])->SideEvidence {
        var left=false,other=false,best=Double.greatestFiniteMagnitude
        for expert in experts {
            guard expert.model.trained.count==2 else{continue}
            let all=expert.model.samples.values.flatMap{$0}.map(\.feature)
            guard !f.isEmpty,all.allSatisfy({$0.count==f.count}) else{continue}
            let scales=f.indices.map{i -> Double in
                let mean=all.reduce(0){$0+$1[i]}/Double(all.count)
                return max(0.06,sqrt(all.reduce(0){$0+pow($1[i]-mean,2)}/Double(all.count)))
            }
            func distance(_ a:[Double],_ b:[Double])->Double{zip(zip(a,b),scales).reduce(0){$0+pow(($1.0.0-$1.0.1)/$1.1,2)}/Double(f.count)}
            func score(_ f:[Double],_ rows:[Impact])->Double{let v=rows.map{distance(f,$0.feature)}.sorted().prefix(3);return v.reduce(0,+)/Double(v.count)}
            let rows=expert.model.samples[0]!
            let own=rows.indices.map{i in score(rows[i].feature,rows.enumerated().filter{$0.offset != i}.map(\.element))}.sorted()
            let radius=max(0.08,own[Int(Double(own.count-1)*0.95)]*2)
            best=min(best,score(f,rows)/radius)
            if let side=expert.model.estimate(f)?.0 {if side==0{left=true}else{other=true}}
        }
        return SideEvidence(side:left && !other ? 0 : other ? 1 : nil,leftDistance:best.isFinite ? min(best,1000) : 1000,contradiction:left && other)
    }
    static func load(hardware:String,root:URL)->ContextBank {
        var result=ContextBank()
        let paths=(try? FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil)) ?? []
        for path in paths.sorted(by:{$0.lastPathComponent<$1.lastPathComponent}) where path.lastPathComponent.hasPrefix("v3-") && path.pathExtension=="json" {
            guard let p=try? JSONDecoder().decode(CalibrationProfile.self,from:Data(contentsOf:path)),p.hardware==hardware else{continue}
            let model=p.frozen?.model ?? p.model
            guard model.trained.count==2 else{continue}
            result.experts.append(Expert(source:p.size+"/"+p.surface,model:model))
        }
        return result
    }
}

func gestureSelfTest(){
    var count=0
    func check(_ v:Bool,_ text:String){precondition(v,text);count+=1}
    func candidate(_ t:Double,_ side:Int?,_ f:[Double]=[1,0],_ distance:Double=0.5)->GestureCandidate {
        GestureCandidate(impact:Impact(onset:t,peak:0.1,feature:f,waveform:[]),evidence:SideEvidence(side:side,leftDistance:distance,contradiction:false))
    }
    let m=DoubleTapMatcher()
    check(m.ingest(candidate(1,nil),armed:true)==nil,"unknown first waits")
    check(m.ingest(candidate(1.22,0),armed:true)?.accepted==true,"look behind unknown then clean")
    m.reset();_ = m.ingest(candidate(1,0),armed:true)
    check(m.ingest(candidate(1.2,nil),armed:true)?.accepted==true,"look ahead clean then unknown")
    m.reset();_ = m.ingest(candidate(1,nil),armed:true)
    check(m.ingest(candidate(1.2,nil),armed:true)?.accepted==false,"two unknowns never trigger")
    m.reset();_ = m.ingest(candidate(1,1),armed:true)
    check(m.ingest(candidate(1.2,0),armed:true)?.accepted==false,"right contradiction")
    m.reset();_ = m.ingest(candidate(1,0),armed:true)
    check(m.ingest(candidate(1.2,nil,[0,1]),armed:true)?.accepted==false,"different signatures rejected")
    m.reset();_ = m.ingest(candidate(1,0),armed:false)
    check(m.ingest(candidate(1.2,0),armed:false)==nil,"disarmed")
    m.reset();_ = m.ingest(candidate(1,0),armed:true)
    check(m.ingest(candidate(2,0),armed:true)==nil,"late second tap")
    m.reset();_ = m.ingest(candidate(1,0),armed:true)
    check(m.ingest(candidate(1.02,0),armed:true)==nil,"ringing is not a second tap")
    m.reset();_ = m.ingest(candidate(1,0),armed:true);_ = m.ingest(candidate(1.2,0),armed:true)
    check(m.ingest(candidate(1.4,0),armed:true)==nil,"no overlapping duplicate gesture")
    m.reset();_ = m.ingest(candidate(1,0),armed:true)
    check(m.ingest(candidate(1.2,nil,[1,0],10),armed:true)?.accepted==false,"gross outlier rejected")
    m.reset();_ = m.ingest(candidate(1,nil),armed:true);_ = m.ingest(candidate(1.12,1),armed:true)
    check(m.ingest(candidate(1.3,0),armed:true)?.accepted != true,"cannot skip an intervening right contradiction")
    m.reset();_ = m.ingest(candidate(1,nil),armed:true);_ = m.ingest(candidate(1.13,nil),armed:true)
    check(m.ingest(candidate(1.28,0),armed:true)?.accepted==true,"a later clean anchor can resolve the most recent unknown")
    m.reset();_ = m.ingest(candidate(1,nil),armed:true);m.advance(2)
    check(m.status.hasPrefix("Pair window expired"),"candidate waiting state expires")
    let detector=BurstDetector();var taps=[Impact]();detector.onImpact={taps.append($0)}
    for i in 0..<1400 {let t=Double(i)/800;let x=(i==900 || i==1000) ? 0.2 : 0;detector.ingest(t,[x,0,-1])}
    check(taps.count==2,"125 ms pair preserved by overlapping windows")
    check(abs(taps[1].onset-taps[0].onset-0.125)<0.002,"onsets remain distinct")
    print("PASS: \(count) gesture checks: look-behind/ahead, contradictions, similarity, timing, arming, cooldown and rapid-impact capture")
}
