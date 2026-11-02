// SPDX-License-Identifier: GPL-3.0-only
// Motion-only signal processing and conservative pair matching, adapted from Tap Lab.
import Foundation
import CryptoKit

struct MotionSample: Codable { let t: Double; let xyz: [Double] }
struct Impact: Codable { let onset: Double; let peak: Double; let feature: [Double]; let waveform: [MotionSample]; var audio: [Double]? = nil; var audioSource:String? = nil }

// Retain waveform shape, decay, axis coupling and spectral energy; normalize
// amplitude so hitting harder does not by itself become a different location.
func features(_ samples: [MotionSample]) -> [Double] {
    guard samples.count > 8, let first = samples.first, let last = samples.last, last.t > first.t else { return [] }
    let n = 128, duration = last.t-first.t
    var axis = Array(repeating:[Double](),count:3), cursor = 0
    for i in 0..<n {
        let t = first.t + Double(i)*duration/Double(n-1)
        while cursor+1 < samples.count-1 && samples[cursor+1].t < t { cursor += 1 }
        let a = samples[cursor], b = samples[min(cursor+1,samples.count-1)]
        let mix = min(1,max(0,(t-a.t)/max(b.t-a.t,1e-9)))
        for j in 0..<3 { axis[j].append(a.xyz[j]+mix*(b.xyz[j]-a.xyz[j])) }
    }
    let energy = axis.map { $0.reduce(0){$0+$1*$1} }, total = max(energy.reduce(0,+),1e-12)
    var f = energy.map { sqrt($0/total) }
    // Six time slices per axis retain the onset and decay envelope.
    for a in axis { for slice in 0..<6 {
        let lo = slice*n/6, hi = (slice+1)*n/6
        f.append(sqrt(a[lo..<hi].reduce(0){$0+$1*$1}/total))
    } }
    for a in axis { for frequency in [12.0,25,45,75,115,165] {
        var re = 0.0, im = 0.0
        for i in 0..<n {
            let phase = 2*Double.pi*frequency*Double(i)*duration/Double(n-1)
            let window = 0.5-0.5*cos(2*Double.pi*Double(i)/Double(n-1))
            re += a[i]*window*cos(phase); im += a[i]*window*sin(phase)
        }
        f.append(sqrt((re*re+im*im)/(total*Double(n))))
    } }
    for (a,b) in [(0,1),(0,2),(1,2)] {
        f.append(zip(axis[a],axis[b]).reduce(0){$0+$1.0*$1.1}/max(sqrt(energy[a]*energy[b]),1e-9)*0.4)
    }
    return f
}
struct LocationModel: Codable {
    var samples = [Int:[Impact]]()
    var trained: [Int] { samples.keys.filter{samples[$0]!.count>=12}.sorted() }
    mutating func add(_ event:Impact,zone:Int) {guard !event.feature.isEmpty else{return}; samples[zone,default:[]].append(event)}
    var pairedMotionModel:LocationModel {
        var result=LocationModel()
        for (zone,rows) in samples {for row in rows where row.audio?.count==12 && row.audio!.allSatisfy(\.isFinite) {result.add(row,zone:zone)}}
        return result
    }
    var pairedModel:LocationModel {
        var result=LocationModel()
        for (zone,rows) in samples {for row in rows {
            guard let audio=row.audio,audio.count==12,audio.allSatisfy(\.isFinite) else{continue}
            result.add(Impact(onset:row.onset,peak:row.peak,feature:row.feature+audio,waveform:[]),zone:zone)
        }}
        return result
    }
    func estimate(_ feature:[Double])->(Int,Double)? {
        let zones=trained
        guard zones.count>=2,!feature.isEmpty else{return nil}
        let all=zones.flatMap{samples[$0]!}.map(\.feature)
        guard all.allSatisfy({$0.count==feature.count}) else{return nil}
        let scales=(0..<feature.count).map{i -> Double in
            let mean=all.reduce(0){$0+$1[i]}/Double(all.count)
            return max(0.06,sqrt(all.reduce(0){$0+pow($1[i]-mean,2)}/Double(all.count)))
        }
        func distance(_ a:[Double],_ b:[Double])->Double {
            zip(zip(a,b),scales).reduce(0){$0+pow(($1.0.0-$1.0.1)/$1.1,2)}/Double(scales.count)
        }
        func score(_ value:[Double],_ examples:[[Double]])->Double {
            let near=examples.map{distance(value,$0)}.sorted().prefix(3)
            return near.reduce(0,+)/Double(near.count)
        }
        let ranked=zones.map{($0,score(feature,samples[$0]!.map(\.feature)))}.sorted{$0.1<$1.1}
        let best=ranked[0], examples=samples[best.0]!.map(\.feature)
        let own=examples.indices.map{i in score(examples[i],examples.enumerated().filter{$0.offset != i}.map(\.element))}.sorted()
        let radius=max(0.08,own[Int(Double(own.count-1)*0.95)]*2)
        let margin=(ranked[1].1-best.1)/max(ranked[1].1,1e-9)
        guard best.1<=radius,margin>0.25 else{return nil}
        return(best.0,margin)
    }
}
struct SideEvidence:Codable {
    let side:Int?
    let leftDistance:Double
    let contradiction:Bool
    var leftVsOther:Double?=nil
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
        if recent.isEmpty && (status.hasPrefix("Left anchor") || status.hasPrefix("Candidate retained")){status="Pair window expired · waiting"}
    }
    static func similarity(_ a:[Double],_ b:[Double])->Double {
        guard !a.isEmpty,a.count==b.count else{return 0}
        let dot=zip(a,b).reduce(0){$0+$1.0*$1.1}
        let norm=sqrt(a.reduce(0){$0+$1*$1}*b.reduce(0){$0+$1*$1})
        return norm>1e-12 ? max(-1,min(1,dot/norm)) : 0
    }
    func ingest(_ next:GestureCandidate,armed:Bool,requireTwoAnchors:Bool=false)->GestureDecision? {
        let t=next.impact.onset
        guard t.isFinite,next.impact.peak.isFinite,next.impact.peak>0 else{return nil}
        if lastTime>=0 && (t<=lastTime || t-lastTime>2) {reset()}
        lastTime=t
        guard armed else{recent=[];status="Disarmed · agent not requesting attention";return nil}
        recent.removeAll{t-$0.impact.onset>0.65}
        guard lastFire<0 || t-lastFire>0.8 else{status="Gesture cooldown";return nil}
        // These are grouped fresh impacts in MagDot; raw ringing never reaches
        // this guard. A stream of genuine attacks is still not a double-tap.
        if recent.count>=3 {recent.append(next);status="Rejected multiple fresh impacts";return nil}
        var rejection:GestureDecision?
        for previous in recent.reversed() {
            let dt=t-previous.impact.onset
            guard dt>=0.09,dt<=0.60 else{continue}
            let s=Self.similarity(previous.impact.feature,next.impact.feature)
            let a=previous.evidence,b=next.evidence
            var reason=""
            if recent.contains(where:{$0.impact.onset>=previous.impact.onset && ($0.evidence.side==1 || $0.evidence.contradiction)}) || a.contradiction || b.contradiction || a.side==1 || b.side==1 {reason="Not-left contradiction"}
            else if a.side != 0 && b.side != 0 {reason="No clear left anchor"}
            else if requireTwoAnchors && (a.side != 0 || b.side != 0){reason="Personal profile requires two clear MagSafe taps"}
            else if (a.side==nil && (a.leftVsOther ?? 0)>=0.9) || (b.side==nil && (b.leftVsOther ?? 0)>=0.9){reason="Corner-like uncertain neighbor"}
            else if max(a.leftDistance,b.leftDistance)>3 {reason="Unknown impact too far from learned left signatures"}
            else if max(previous.impact.peak,next.impact.peak)/min(previous.impact.peak,next.impact.peak)>5 {reason="Impact strengths too different"}
            else if s < (a.side==0 && b.side==0 ? 0.85 : 0.92) {reason="Pair signatures differ"}
            else {
                lastFire=t;recent=[];status="Double-tap confirmed"
                return GestureDecision(first:previous.impact.onset,second:t,accepted:true,reason:a.side==0 && b.side==0 ? "Two left anchors" : "Clear left anchor matched an unknown neighbor",similarity:s)
            }
            rejection=GestureDecision(first:previous.impact.onset,second:t,accepted:false,reason:reason,similarity:s)
        }
        recent.append(next)
        status=next.evidence.side==0 ? "Left anchor · checking past and waiting up to 600 ms" : "Candidate retained · waiting for a clear left anchor"
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
    private var quietSamples=0
    var sensitivity=0.5
    var minimumCandidateGap=0.085
    var learnedTapFloor:Double?
    var calibrationCapture=false
    var threshold:Double{
        // Capture must stay above ambient vibration independently of the user's
        // permissive runtime slider. Do not cap this noise-relative threshold.
        if calibrationCapture{return max(0.003,noiseFloor*2.5)}
        return max(learnedTapFloor ?? 0,max(0.003,min(0.015,noiseFloor*1.25))*pow(2,(0.5-sensitivity)*4))
    }
    func reset(){gravity=[];history=[];pending=[];noise=[];last = -1;lastOnset = -1;lastQuiet = -1;previousMagnitude=0;magnitude=0;noiseFloor=0;quietSamples=0}
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
        // Re-estimate from quiet samples so startup handling does not latch a
        // high threshold for the entire session. Impact windows never fit noise.
        // During calibration, use a robust rolling baseline even if ambient
        // movement exceeds the old threshold; otherwise it can stay latched low.
        if calibrationCapture || (pending.isEmpty && magnitude<threshold*0.65) {
            noise.append(magnitude);if noise.count>800{noise.removeFirst()};quietSamples+=1
            if quietSamples>=200{let sorted=noise.sorted(),median=sorted[sorted.count/2];let mad=noise.map{abs($0-median)}.sorted()[noise.count/2];noiseFloor=median+6*mad;quietSamples=0}
        }
        for i in pending.indices {pending[i].frames.append(frame);pending[i].peak=max(pending[i].peak,magnitude)}
        if magnitude<threshold*0.65 {lastQuiet=t}
        let sharpRise=magnitude>max(threshold,previousMagnitude*1.7)
        if (lastOnset<0 || t-lastOnset>=minimumCandidateGap),magnitude>threshold,
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
}
