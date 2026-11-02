import Foundation

// A complete sensor episode, not an isolated threshold crossing. Coordinates
// are accelerometer axes only; no keyboard contents or touch paths are stored.
struct GestureRecording:Codable {
    let startedAt:Double
    let frames:[MotionSample]
    let impacts:[Impact]
    let inputActive:Bool
    let rawCandidates:Int
    var decays:[Impact]?=nil
    var valid:Bool{
        frames.count>=8 && frames.count<=2400 && frames.allSatisfy{$0.t.isFinite && $0.xyz.count==3 && $0.xyz.allSatisfy(\.isFinite)} && impacts.count<=24 && (decays?.count ?? 0)<=24 && (impacts+(decays ?? [])).allSatisfy{$0.onset.isFinite && $0.peak.isFinite && $0.peak>0 && $0.feature.count==42 && $0.feature.allSatisfy(\.isFinite) && $0.waveform.count>=8 && $0.waveform.count<=240 && $0.waveform.allSatisfy{$0.t.isFinite && $0.xyz.count==3 && $0.xyz.allSatisfy(\.isFinite)}}
    }
    var pairSignature:[Double]?{
        guard valid,impacts.count==2 else{return nil}
        let a=impacts[0],b=impacts[1],gap=b.onset-a.onset
        guard gap>=0.09,gap<=0.60,max(a.peak,b.peak)/min(a.peak,b.peak)<=6 else{return nil}
        let first=Self.tapShape(a),second=Self.tapShape(b)
        guard first.count==42,second.count==42 else{return nil}
        let averages:[Double]=zip(first,second).map{($0+$1)/2}
        let differences:[Double]=zip(first,second).map{abs($0-$1)}
        let peakRatio:Double=max(a.peak,b.peak)/min(a.peak,b.peak)
        let timingAndAmplitude:[Double]=[gap*0.5,0.2*log(peakRatio)]
        return averages+differences+timingAndAmplitude
    }
    static func tapShape(_ impact:Impact)->[Double]{
        let local=impact.waveform.filter{$0.t>=impact.onset-0.025 && $0.t<=impact.onset+0.070}
        return local.count>8 ? features(local):impact.feature
    }

}
struct GestureExample:Codable {let location:CalibrationLocation;let recording:GestureRecording}
struct GestureValidation:Codable {let location:CalibrationLocation;let samples:[GestureRecording];let detected:[Bool]
    var correctTaps:Int?=nil
    var totalTaps:Int?=nil
    var falseVibrations:Int?=nil
    var passed:Bool{
        if let correct=correctTaps,let total=totalTaps{
            let handling=location != .handling || samples.contains{!$0.inputActive && !$0.impacts.isEmpty}
            return samples.count>=3 && samples.count==detected.count && handling && (falseVibrations ?? 0)==0 && (location == .connector ? total>=4 && correct*3>=total*2:!detected.contains(true))
        }
        return samples.count>=3 && samples.count==detected.count && (location != .handling || samples.contains{!$0.inputActive && !$0.impacts.isEmpty}) && (location == .connector ? detected.filter{$0}.count*3>=samples.count*2:!detected.contains(true))}
}

// Inspect attack energy around a raw candidate, instead of treating every
// oscillation in its decay as a new physical impact. There is no long blind
// interval: a new attack can be accepted after 90 ms, even with a ringing tail.
final class ImpactGrouper {
    private var previous:Impact?
    private(set) var grouped=0
    private(set) var reason="Waiting for an attack"
    private(set) var confidentDecay=false
    func reset(){previous=nil;grouped=0;confidentDecay=false;reason="Waiting for an attack"}
    // Predict a short continuation of a stable ringing waveform. A weaker
    // second impact can cancel the old vibration and have little energy rise;
    // prediction error still exposes the new attack. Unstable fits are ignored.
    private func innovation(_ impact:Impact)->Double?{
        let old=impact.waveform.filter{$0.t>=impact.onset-0.04 && $0.t<impact.onset-0.005}
        let future=impact.waveform.filter{$0.t>=impact.onset && $0.t<impact.onset+0.015}
        guard old.count>=20,future.count>=6 else{return nil}
        let dt=(old.last!.t-old.first!.t)/Double(old.count-1)
        guard dt>0 else{return nil}
        func fit(_ values:[Double])->[Double]?{
            let order=4;guard values.count>=order+8 else{return nil}
            var a=Array(repeating:Array(repeating:0.0,count:order+1),count:order)
            for i in order..<values.count{
                let x=(1...order).map{values[i-$0]}
                for r in 0..<order{for c in 0..<order{a[r][c]+=x[r]*x[c]};a[r][order]+=x[r]*values[i]}
            }
            let ridge=max(1e-14,values.reduce(0){$0+$1*$1}*1e-7)
            for i in 0..<order{a[i][i]+=ridge}
            for col in 0..<order{
                let pivot=(col..<order).max{abs(a[$0][col])<abs(a[$1][col])}!
                guard abs(a[pivot][col])>1e-18 else{return nil};a.swapAt(col,pivot)
                let divisor=a[col][col];for c in col...order{a[col][c]/=divisor}
                for r in 0..<order where r != col{let v=a[r][col];for c in col...order{a[r][c]-=v*a[col][c]}}
            }
            let result=a.map{$0[order]};return result.allSatisfy(\.isFinite) ? result:nil
        }
        func predict(_ values:[Double],_ coefficients:[Double],_ count:Int)->[Double]{
            var state=values,result=[Double]()
            for _ in 0..<count{let next=(0..<4).reduce(0){$0+coefficients[$1]*state[state.count-1-$1]};state.append(next);result.append(next)}
            return result
        }
        var error=0.0,reference=0.0
        for axis in 0..<3{
            let values=old.map{$0.xyz[axis]},energy=values.reduce(0){$0+$1*$1}/Double(values.count)
            if energy<1e-14{continue}
            let training=Array(values.dropLast(5))
            guard let trial=fit(training) else{return nil}
            let check=predict(training,trial,5),known=Array(values.suffix(5))
            let checkError=zip(check,known).reduce(0){$0+pow($1.0-$1.1,2)}/5
            guard checkError<=energy*0.025,let coefficients=fit(values) else{return nil}
            let gap=max(0,Int(((future.first!.t-old.last!.t)/dt).rounded())-1)
            guard gap<=12 else{return nil}
            let predicted=Array(predict(values,coefficients,gap+future.count).suffix(future.count))
            guard predicted.allSatisfy({$0.isFinite && abs($0)<=sqrt(energy)*5}) else{return nil}
            error+=zip(predicted,future).reduce(0){$0+pow($1.0-$1.1.xyz[axis],2)}/Double(future.count)
            reference+=energy
        }
        return reference>0 ? sqrt(error):nil
    }
    func ingest(_ impact:Impact)->Impact?{
        confidentDecay=false
        guard impact.feature.count==42,impact.feature.allSatisfy(\.isFinite),impact.peak.isFinite,impact.peak>0 else{return nil}
        let local=impact.waveform.filter{$0.t>=impact.onset && $0.t<=impact.onset+0.035}
        let peak=local.map{sqrt($0.xyz.reduce(0){$0+$1*$1})}.max() ?? impact.peak
        let localized=Impact(onset:impact.onset,peak:max(peak,1e-9),feature:impact.feature,waveform:impact.waveform)
        if let previous,impact.onset-previous.onset<=0.70{
            let gap=impact.onset-previous.onset
            func rms(_ lo:Double,_ hi:Double)->Double{
                let rows=impact.waveform.filter{$0.t>=impact.onset+lo && $0.t<impact.onset+hi}
                return rows.isEmpty ? 0:sqrt(rows.reduce(0){$0+$1.xyz.reduce(0){$0+$1*$1}}/Double(rows.count))
            }
            let before=rms(-0.035,-0.005),after=rms(0,0.020)
            let predictionError=innovation(impact)
            let newAttack=(predictionError ?? 0)>=max(before*0.55,previous.peak*0.10)
            let fresh=before<1e-9 || after>=before*1.6 || peak>=previous.peak*1.35 || newAttack
            guard gap>=0.09,fresh else{confidentDecay=gap>=0.09 && predictionError != nil && predictionError!<max(before*0.2,previous.peak*0.03) && after<=before*1.05 && peak<previous.peak*0.8;grouped+=1;reason="Grouped decay vibration with preceding tap";return nil}
        }
        previous=localized;reason="Fresh impact attack";return localized
    }
}

final class GestureRecorder {
    private var frames=[MotionSample](),impacts=[Impact](),decays=[Impact]()
    private var inputTimes=[Double](),rawTimes=[Double]()
    private var anchor:Double?,closedThrough = -Double.greatestFiniteMagnitude
    func reset(){frames=[];impacts=[];decays=[];inputTimes=[];rawTimes=[];anchor=nil;closedThrough = -Double.greatestFiniteMagnitude}
    func onset(_ t:Double){rawTimes.append(t)}
    func vibration(_ impact:Impact){if impact.onset>closedThrough{decays.append(impact)}}
    func impact(_ impact:Impact){if impact.onset>closedThrough{impacts.append(impact)}}
    func sample(_ frame:MotionSample,inputActive:Bool){
        if anchor==nil{anchor=frame.t}
        frames.append(frame);if inputActive{inputTimes.append(frame.t)}
        frames.removeAll{frame.t-$0.t>3};inputTimes.removeAll{frame.t-$0>3};rawTimes.removeAll{frame.t-$0>3}
    }
    func take(now:Double,handling:Bool,continuous:Bool=false)->GestureRecording?{
        guard let anchor else{return nil}
        let start:Double,end:Double
        if handling || continuous{
            guard now-anchor>=(continuous ? 0.95:1.6) else{return nil};start=anchor;end=now-0.16
        }else{
            guard let first=impacts.first,let last=impacts.last else{return nil}
            let quiet=now-last.onset>=(impacts.count==1 ? 0.76:0.38) && now-(rawTimes.last ?? last.onset)>=0.16
            guard quiet || now-first.onset>=1.6 else{return nil}
            start=first.onset-0.04;end=now-0.001
        }
        let rows=frames.filter{$0.t>=start && $0.t<=end}
        let taps=impacts.filter{$0.onset>=start && $0.onset<=end}
        guard rows.count>=8 else{return nil}
        func shift(_ row:MotionSample)->MotionSample{MotionSample(t:row.t-start,xyz:row.xyz)}
        func normalized(_ impact:Impact)->Impact{Impact(onset:impact.onset-start,peak:impact.peak,feature:impact.feature,waveform:impact.waveform.map(shift))}
        let tails=Array(decays.filter{$0.onset>=start && $0.onset<=end}.prefix(2)).map(normalized)
        let result=GestureRecording(startedAt:start,frames:rows.map(shift),impacts:taps.map(normalized),inputActive:inputTimes.contains{$0>=start && $0<=end},rawCandidates:rawTimes.filter{$0>=start && $0<=end}.count,decays:tails)
        impacts.removeAll{$0.onset<=end};decays.removeAll{$0.onset<=end};frames.removeAll{$0.t<end-0.04};inputTimes.removeAll{$0<=end};rawTimes.removeAll{$0<=end};self.anchor=end;closedThrough=end
        return result
    }
}

// Complete-pair personal classification. This retains the existing custom
// profile choice; it does not introduce pretrained/personal model fusion.
struct PersonalGestureModel {
    private let classifier:PreparedContextBank
    let ready:Bool
    init(_ examples:[GestureExample]){
        var model=LocationModel()
        for row in examples{
            guard let f=row.recording.pairSignature else{continue}
            model.add(Impact(onset:0,peak:1,feature:f,waveform:[]),zone:row.location.label)
        }
        ready=(model.samples[0]?.count ?? 0)>=8 && (model.samples[1]?.count ?? 0)>=16
        classifier=PreparedContextBank(ContextBank(experts:[ContextBank.Expert(source:"personal-pairs",model:model)]),minimumSamples:8)
    }
    func evaluate(_ recording:GestureRecording,sensitivity:Double=0.5)->(accepted:Bool,reason:String){
        guard recording.valid else{return(false,"Invalid gesture recording")}
        guard !recording.inputActive else{return(false,"Keyboard/trackpad activity in gesture window")}
        guard let f=recording.pairSignature else{return(false,recording.impacts.count>2 ? "More than two fresh impacts":"No complete double-tap")}
        guard ready else{return(false,"Personal double-tap model is not ready")}
        let e=classifier.evidence(f,vetoNegativeNeighbor:true,sensitivity:sensitivity)
        return(e.side==0,e.side==0 ? "Complete MagSafe double-tap":e.side==1 ? "Gesture matches corner/handling examples":"Uncertain complete gesture")
    }
}

// Free-tap calibration learns local attack/decay signatures from continuously
// recorded windows. Pair timing remains a runtime concern, not a setup task.
struct PersonalTapModel {
    private let legacy:PreparedContextBank
    private let signedSupport:PreparedContextBank
    private let discriminative:DiscriminativeTapModel
    let ready:Bool
    let usesSignedAlgorithm:Bool
    private(set) var maximumValidatedSensitivity=1.0
    init(_ examples:[GestureExample],checks:[GestureValidation]=[]){
        var old=LocationModel(),support=LocationModel(),features=[[Double]](),labels=[Int]()
        for row in examples where row.recording.valid{
            for (label,impacts) in [(row.location.label,row.recording.impacts),(1,Array((row.recording.decays ?? []).prefix(2))) ]{
                for impact in impacts{
                    let previous=GestureRecording.tapShape(impact),signed=TapRepresentation.direction.extract(impact)
                    if previous.count==42 && previous.allSatisfy(\.isFinite){old.add(Impact(onset:0,peak:impact.peak,feature:previous,waveform:[]),zone:label)}
                    if signed.count==30 && signed.allSatisfy(\.isFinite){
                        features.append(signed);labels.append(label)
                        support.add(Impact(onset:0,peak:impact.peak,feature:signed,waveform:[]),zone:label)
                    }
                }
            }
        }
        legacy=PreparedContextBank(ContextBank(experts:[ContextBank.Expert(source:"personal-free-taps",model:old)]))
        signedSupport=PreparedContextBank(ContextBank(experts:[ContextBank.Expert(source:"signed-attack-support",model:support)]))
        discriminative=DiscriminativeTapModel(features:features,labels:labels)
        ready=(old.samples[0]?.count ?? 0)>=12 && (old.samples[1]?.count ?? 0)>=24
        var allowed=ready && discriminative.ready
        // Existing reserved windows are a non-regression guard, never training
        // data. Do not demand new input or rewrite the user's saved dataset.
        for check in checks{
            var oldCorrect=0,newCorrect=0,oldFalse=0,newFalse=0
            for row in check.samples{
                for tap in row.impacts{
                    let oldPositive = !row.inputActive && legacy.evidence(GestureRecording.tapShape(tap),vetoNegativeNeighbor:true).side==0
                    let newPositive = !row.inputActive && (discriminative.probability(TapRepresentation.direction.extract(tap)) ?? 0)>=0.8
                    if check.location == .connector{oldCorrect+=oldPositive ? 1:0;newCorrect+=newPositive ? 1:0}
                    else{oldFalse+=oldPositive ? 1:0;newFalse+=newPositive ? 1:0}
                }
                for tap in row.decays ?? []{
                    oldFalse+=legacy.evidence(GestureRecording.tapShape(tap),vetoNegativeNeighbor:true).side==0 ? 1:0
                    newFalse+=(discriminative.probability(TapRepresentation.direction.extract(tap)) ?? 0)>=0.8 ? 1:0
                }
            }
            if newCorrect<oldCorrect || newFalse>oldFalse{allowed=false}
        }
        usesSignedAlgorithm=allowed
        if !checks.isEmpty{
            for step in 11...20{
                let candidate=Double(step)/20
                var unsafe=false
                for check in checks{for row in check.samples{
                    let negatives=(check.location == .connector ? []:row.impacts)+(row.decays ?? [])
                    for tap in negatives where rawEvidence(tap,sensitivity:0.5).side != 0{
                        if rawEvidence(tap,sensitivity:candidate).side==0{unsafe=true}
                    }
                }}
                if unsafe{maximumValidatedSensitivity=Double(step-1)/20;break}
            }
        }
    }
    func evidence(_ impact:Impact,sensitivity:Double=0.5)->SideEvidence{rawEvidence(impact,sensitivity:min(LocationSensitivity(sensitivity).value,maximumValidatedSensitivity))}
    private func rawEvidence(_ impact:Impact,sensitivity:Double)->SideEvidence{
        guard usesSignedAlgorithm else{return legacy.evidence(GestureRecording.tapShape(impact),vetoNegativeNeighbor:true,sensitivity:sensitivity)}
        let f=TapRepresentation.direction.extract(impact)
        guard let probability=discriminative.probability(f) else{return SideEvidence(side:nil,leftDistance:1000,contradiction:false,leftVsOther:1)}
        let support=signedSupport.evidence(f)
        return SideEvidence(side:probability>=LocationSensitivity(sensitivity).positiveScore ? 0:probability<=0.2 ? 1:nil,leftDistance:support.leftDistance,contradiction:false,leftVsOther:(1-probability)/max(probability,1e-9))
    }
    func validate(_ location:CalibrationLocation,_ recordings:[GestureRecording])->GestureValidation{
        let results=recordings.map{row -> [Bool] in
            row.impacts.map{!row.inputActive && evidence($0).side==0}
        }
        let all=results.flatMap{$0}
        let falseDecay=recordings.flatMap{$0.decays ?? []}.filter{evidence($0).side==0}.count
        return GestureValidation(location:location,samples:recordings,detected:results.map{$0.contains(true)},correctTaps:location == .connector ? all.filter{$0}.count:all.filter{!$0}.count,totalTaps:all.count,falseVibrations:falseDecay)
    }
}
