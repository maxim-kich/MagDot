import Foundation

struct Score:Codable {
    var recognized=0,positives=0,falsePositives=0,negatives=0
    mutating func add(_ other:Score){recognized+=other.recognized;positives+=other.positives;falsePositives+=other.falsePositives;negatives+=other.negatives}
}
struct Model {
    let legacy:PreparedContextBank
    let updated:PersonalTapModel
    init(_ examples:[GestureExample],checks:[GestureValidation]=[]){
        var bank=LocationModel()
        for row in examples{
            for (label,taps) in [(row.location.label,row.recording.impacts),(1,Array((row.recording.decays ?? []).prefix(2)))]{
                for tap in taps{bank.add(Impact(onset:0,peak:tap.peak,feature:GestureRecording.tapShape(tap),waveform:[]),zone:label)}
            }
        }
        legacy=PreparedContextBank(ContextBank(experts:[.init(source:"baseline",model:bank)]))
        updated=PersonalTapModel(examples,checks:checks)
    }
    func evidence(_ tap:Impact,new:Bool)->SideEvidence{new ? updated.evidence(tap):legacy.evidence(GestureRecording.tapShape(tap),vetoNegativeNeighbor:true)}
    func impacts(_ examples:[GestureExample],new:Bool)->Score{
        var score=Score()
        for row in examples{
            for (positive,taps) in [(row.location == .connector,row.recording.impacts),(false,Array((row.recording.decays ?? []).prefix(2)))]{
                for tap in taps{
                    let accepted=evidence(tap,new:new).side==0
                    if positive{score.positives+=1;if accepted{score.recognized+=1}}
                    else{score.negatives+=1;if accepted{score.falsePositives+=1}}
                }
            }
        }
        return score
    }
    func pairs(_ examples:[GestureExample],new:Bool)->Score{
        var score=Score()
        for row in examples where !row.recording.inputActive{
            let taps=row.recording.impacts
            let positive=row.location == .connector
            if positive && (taps.count != 2 || taps[1].onset-taps[0].onset>0.60 || taps[1].onset-taps[0].onset<0.09){continue}
            let matcher=DoubleTapMatcher();var accepted=false
            for tap in taps{if matcher.ingest(GestureCandidate(impact:tap,evidence:evidence(tap,new:new)),armed:true)?.accepted==true{accepted=true}}
            if positive{score.positives+=1;if accepted{score.recognized+=1}}
            else{score.negatives+=1;if accepted{score.falsePositives+=1}}
        }
        return score
    }
}
func read<T:Decodable>(_ type:T.Type,_ path:String)throws->T{try JSONDecoder().decode(type,from:Data(contentsOf:URL(fileURLWithPath:path)))}
guard CommandLine.arguments.count==4 else{fputs("usage: gesture-benchmark PROFILE HISTORICAL_PROFILE LABELED_BOTTOM_RIGHT_TRACES\n",stderr);exit(2)}
let profile=try read(PersonalCalibration.self,CommandLine.arguments[1]),historical=try read(PersonalCalibration.self,CommandLine.arguments[2]),traces=try read([GestureTrace].self,CommandLine.arguments[3])
let training=profile.gestures ?? []
func checks(_ profile:PersonalCalibration)->[GestureExample]{(profile.gestureChecks ?? []).flatMap{check in check.samples.map{GestureExample(location:check.location,recording:$0)}}}
let reserved=checks(profile),oldSession=(historical.gestures ?? [])+checks(historical),external=traces.map{GestureExample(location:.frontRight,recording:$0.recording)}
var before=Score(),after=Score(),beforePairs=Score(),afterPairs=Score()
for i in training.indices{
    let model=Model(training.enumerated().filter{$0.offset != i}.map(\.element)),test=[training[i]]
    before.add(model.impacts(test,new:false));after.add(model.impacts(test,new:true))
    beforePairs.add(model.pairs(test,new:false));afterPairs.add(model.pairs(test,new:true))
}
let model=Model(training,checks:profile.gestureChecks ?? [])
let results:[String:Any]=[
    "profile":profile.id,"signedAlgorithmSelected":model.updated.usesSignedAlgorithm,
    "method":"Leave one entire training window out; reserved windows, older session, and separately labeled bottom-right test are never training data. Impact scores include input-active negatives conservatively; pair scores apply the existing input guard.",
    "currentCrossValidation":[before,after],"currentPairsCrossValidation":[beforePairs,afterPairs],
    "reserved":[model.impacts(reserved,new:false),model.impacts(reserved,new:true)],
    "olderSession":[model.impacts(oldSession,new:false),model.impacts(oldSession,new:true)],
    "olderPairs":[model.pairs(oldSession,new:false),model.pairs(oldSession,new:true)],
    "bottomRight":[model.impacts(external,new:false),model.impacts(external,new:true)],
    "bottomRightPairs":[model.pairs(external,new:false),model.pairs(external,new:true)]
]
var output=[String:Any]()
let encoder=JSONEncoder()
for (key,value) in results{if let value=value as? [Score]{output[key]=try JSONSerialization.jsonObject(with:encoder.encode(value))}else{output[key]=value}}
let data=try JSONSerialization.data(withJSONObject:output,options:[.prettyPrinted,.sortedKeys]);FileHandle.standardOutput.write(data)
