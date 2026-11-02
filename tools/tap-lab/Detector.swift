import Foundation

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
final class Detector {
    var threshold = 0.012
    var onImpact: ((Impact)->Void)?
    private var gravity = [Double](), history = [MotionSample](), capture = [MotionSample]()
    private var noise = [Double](), lastTime = -1.0, began = -1.0, blockedUntil = 0.0, peak = 0.0
    private(set) var noiseFloor = 0.0
    private(set) var magnitude = 0.0
    var effectiveThreshold: Double { max(threshold,noiseFloor*3) }
    var ready: Bool { noise.count >= 800 }
    func reset() { gravity=[]; history=[]; capture=[]; noise=[]; lastTime = -1; began = -1; blockedUntil=0; magnitude=0; noiseFloor=0 }
    func ingest(_ t: Double,_ xyz:[Double]) {
        guard t.isFinite,xyz.count==3,xyz.allSatisfy({$0.isFinite}) else {return}
        if lastTime >= 0 && (t<=lastTime || t-lastTime>0.05) {reset()}
        lastTime=t
        if gravity.isEmpty {gravity=xyz}
        let delta=zip(xyz,gravity).map(-)
        magnitude=sqrt(delta.reduce(0){$0+$1*$1})
        for i in 0..<3 {gravity[i] += 0.015*delta[i]}
        let sample=MotionSample(t:t,xyz:delta)
        history.append(sample); history.removeAll{t-$0.t>0.04}
        if !ready {
            noise.append(magnitude)
            if ready {
                let sorted=noise.sorted(), median=sorted[sorted.count/2]
                let deviations=noise.map{abs($0-median)}.sorted()
                noiseFloor=median+6*deviations[deviations.count/2]
            }
            return
        }
        if began<0,t>=blockedUntil,magnitude>effectiveThreshold {
            began=t; peak=magnitude; capture=history
        } else if began>=0 {capture.append(sample); peak=max(peak,magnitude)}
        if began>=0,t-began>=0.14 {
            let event=Impact(onset:began,peak:peak,feature:features(capture),waveform:capture)
            began = -1; blockedUntil=t+0.22; capture=[]
            onImpact?(event)
        }
    }
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
func selfTest() {
    var tests=0
    func check(_ b:Bool,_ message:String){precondition(b,message);tests+=1}
    let d=Detector();var impacts=[Impact]();d.onImpact={impacts.append($0)}
    var t=0.0
    func feed(_ x:Double,count:Int){for _ in 0..<count{t+=0.00125;d.ingest(t,[x,0,-1])}}
    feed(0,count:850);check(d.ready && impacts.isEmpty,"quiet calibration")
    feed(0.12,count:2);feed(0,count:400);check(impacts.count==1,"ringing must not double count")
    feed(0.30,count:2);feed(0,count:400);check(impacts.count==2 && impacts[1].peak>impacts[0].peak,"strength")
    check(impacts[0].waveform.count>100 && impacts[0].feature.count==42,"long waveform and spectral features")
    let f=features(impacts[0].waveform), scaled=features(impacts[0].waveform.map{MotionSample(t:$0.t,xyz:$0.xyz.map{$0*3})})
    check(zip(f,scaled).allSatisfy{abs($0-$1)<1e-6},"amplitude invariance")
    d.ingest(t-1,[0,0,-1]);check(!d.ready,"timestamp discontinuity resets")
    d.reset();check(!d.ready && d.noiseFloor==0,"reset")
    var model=LocationModel()
    for _ in 0..<20 {
        model.add(Impact(onset:0,peak:0.1,feature:[1,0,0],waveform:[]),zone:0)
        model.add(Impact(onset:0,peak:0.1,feature:[0,1,0],waveform:[]),zone:1)
    }
    check(model.estimate([1,0,0])?.0==0,"region match")
    check(model.estimate([0.5,0.5,0])==nil,"ambiguous rejection")
    check(model.estimate([0,0,10])==nil,"out of distribution rejection")
    let decoded=try! JSONDecoder().decode(LocationModel.self,from:JSONEncoder().encode(model))
    check(decoded.samples[0]!.count==20,"profile round trip")
    let oldCount=model.samples[0]!.count;_ = model.estimate([1,0,0]);check(model.samples[0]!.count==oldCount,"testing cannot train")
    let startup=Detector();var startupT=0.0
    for i in 0..<850 {startupT+=0.00125;startup.ingest(startupT,[i==300 ? 0.5 : 0,0,-1])}
    check(startup.ready && startup.effectiveThreshold<0.02,"one startup bump must not poison noise threshold")
    var small=LocationModel()
    for _ in 0..<4 { small.add(Impact(onset:0,peak:0.1,feature:[1,0,0],waveform:[]),zone:0);small.add(Impact(onset:0,peak:0.1,feature:[0,1,0],waveform:[]),zone:1) }
    check(small.estimate([1,0,0])==nil,"four taps are insufficient")
    func tone(_ hz:Double,_ phase:Double,_ amplitude:Double)->Impact {
        let wave=(0..<144).map{i -> MotionSample in
            let t=Double(i)/800
            return MotionSample(t:t,xyz:[sin(2*Double.pi*hz*t+phase)*exp(-t*12)*amplitude,0,0])
        }
        return Impact(onset:0,peak:amplitude,feature:features(wave),waveform:wave)
    }
    var spectral=LocationModel()
    for i in 0..<20 {spectral.add(tone(25,Double(i)*0.005,0.1),zone:0);spectral.add(tone(115,Double(i)*0.005,0.1),zone:1)}
    check(spectral.estimate(tone(25,0.035,0.3).feature)?.0==0,"unseen stronger low frequency waveform")
    check(spectral.estimate(tone(115,0.065,0.04).feature)?.0==1,"unseen softer high frequency waveform")
    var paired=LocationModel()
    let audio=[Double](repeating:0.2,count:12)
    for _ in 0..<12 {paired.add(Impact(onset:0,peak:0.1,feature:[1,0,0],waveform:[],audio:audio),zone:0);paired.add(Impact(onset:0,peak:0.1,feature:[0,1,0],waveform:[],audio:audio),zone:1)}
    check(paired.pairedMotionModel.samples[0]?.count==paired.pairedModel.samples[0]?.count,"comparison uses identical training examples")
    check(paired.pairedModel.samples[0]?.first?.feature.count==15,"paired feature dimensions")
    check(model.pairedModel.trained.isEmpty,"unpaired historical rows cannot train audio model")
    check(paired.pairedModel.estimate([1,0,0]+audio)?.0==0,"paired classifier")
    print("PASS: \(tests) detector/classifier checks")
}
