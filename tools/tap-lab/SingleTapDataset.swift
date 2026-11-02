import Foundation

struct SingleTapRecord:Codable {
    let id:String
    let hardware:String
    let label:Int // 0 = attached connector, 1 = everything else
    let split:String // Train or Test; Test never fits the model
    let source:String
    let date:Date
    let impact:Impact
    let predicted:Int?
    var threshold:Double? = nil
    var valid:Bool{[0,1].contains(label) && ["Train","Test"].contains(split) && impact.feature.count==42 && impact.feature.allSatisfy(\.isFinite) && impact.peak.isFinite && impact.peak>0}
}
struct SingleTapStore {
    let root:URL
    init(root:URL=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Tap Lab/connector-singles-v1")){self.root=root}
    func save(_ r:SingleTapRecord)throws{
        guard r.valid else{throw CocoaError(.fileWriteInvalidFileName)}
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        try JSONEncoder().encode(r).write(to:root.appendingPathComponent(r.id+".json"),options:.atomic)
    }
    func load(_ hardware:String)->[SingleTapRecord]{
        ((try? FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil)) ?? []).filter{$0.pathExtension=="json"}.compactMap{try? JSONDecoder().decode(SingleTapRecord.self,from:Data(contentsOf:$0))}.filter{$0.hardware==hardware && $0.valid}.sorted{$0.date<$1.date}
    }
    func model(_ records:[SingleTapRecord])->LocationModel{
        var model=LocationModel()
        for r in records where r.split=="Train"{model.add(r.impact,zone:r.label)}
        return model
    }
    // Recover only complete, explicitly labelled training pairs. Deduplicate
    // impacts shared by candidate pairs and deterministic IDs across launches.
    func recover(_ hardware:String,legacy:GestureDataStore)throws->Int {
        var added=0
        for row in legacy.load() where row.completed && row.split=="Train" && row.hardware==hardware && [legacy.target.positive,legacy.target.negative].contains(row.category) {
            let label=row.category==legacy.target.positive ? 0:1
            var indices=Set<Int>()
            for i in row.candidates.indices {for j in row.candidates.indices where j>i {
                let a=row.candidates[i].impact,b=row.candidates[j].impact,dt=b.onset-a.onset
                if (0.09...0.60).contains(dt) && DoubleTapMatcher.similarity(a.feature,b.feature)>=0.85 && max(a.peak,b.peak)/min(a.peak,b.peak)<=5 {indices.insert(i);indices.insert(j)}
            }}
            for i in indices.sorted(){
                let id="recovered-"+row.id+"-"+String(i)
                if FileManager.default.fileExists(atPath:root.appendingPathComponent(id+".json").path){continue}
                let r=SingleTapRecord(id:id,hardware:hardware,label:label,split:"Train",source:"recovered/"+row.id,date:row.date,impact:row.candidates[i].impact,predicted:nil,threshold:row.threshold)
                try save(r);added+=1
            }
        }
        return added
    }
    // The original frozen datasets were collected on the chassis, before the
    // connector experiment. Both their old left/right labels are now negative.
    func recoverChassis(_ hardware:String,legacyRoot:URL=ProfileStore().root)throws->Int {
        var added=0
        let paths=(try? FileManager.default.contentsOfDirectory(at:legacyRoot,includingPropertiesForKeys:nil)) ?? []
        for path in paths where path.lastPathComponent.hasPrefix("v3-") && path.pathExtension=="json" {
            guard let p=try? JSONDecoder().decode(CalibrationProfile.self,from:Data(contentsOf:path)),p.hardware==hardware,let frozen=p.frozen else{continue}
            for label in frozen.model.samples.keys.sorted(){for (i,event) in frozen.model.samples[label]!.enumerated(){
                let id="chassis-"+frozen.id+"-"+String(label)+"-"+String(i)
                if FileManager.default.fileExists(atPath:root.appendingPathComponent(id+".json").path){continue}
                let row=SingleTapRecord(id:id,hardware:hardware,label:1,split:"Train",source:"legacy-chassis/"+path.lastPathComponent,date:Date(timeIntervalSince1970:0),impact:Impact(onset:event.onset,peak:event.peak,feature:event.feature,waveform:event.waveform),predicted:nil,threshold:frozen.threshold)
                guard row.valid else{continue};try save(row);added+=1
            }}
        }
        return added
    }
    func asset(hardware:String,records:[SingleTapRecord])->ConnectorModel? {
        let fitted=model(records)
        guard fitted.trained==[0,1] else{return nil}
        var compact=LocationModel()
        for (label,rows) in fitted.samples {for r in rows {compact.add(Impact(onset:0,peak:r.peak,feature:r.feature,waveform:[]),zone:label)}}
        let tests=records.filter{$0.split=="Test"}
        return ConnectorModel(schema:1,target:"MagSafe connector",hardware:hardware,id:UUID().uuidString,createdAt:Date(),model:compact,positiveTests:tests.filter{$0.label==0}.count,negativeTests:tests.filter{$0.label==1}.count)
    }
}
func singleTapSelfTest(){
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("single-tap-"+UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
    let store=SingleTapStore(root:root.appendingPathComponent("singles")),legacy=GestureDataStore(root:root.appendingPathComponent("legacy"),target:.connector)
    func impact(_ t:Double,_ side:Int)->Impact{var f=Array(repeating:0.0,count:42);f[side]=1;return Impact(onset:t,peak:0.05,feature:f,waveform:[])}
    let cs=[1.0,1.2,2.0,2.2].map{GestureCandidate(impact:impact($0,0),evidence:SideEvidence(side:nil,leftDistance:1000,contradiction:false))}
    let row=GestureTrial(id:UUID().uuidString,hardware:"fixture",machineName:"MacBook",conditionTag:"desk",split:"Train",category:GestureTarget.connector.positive,attention:true,modelBankID:"none",date:Date(),duration:4,threshold:0.01,completed:true,raw:[],candidates:cs,decisions:[],target:GestureTarget.connector.rawValue)
    try! legacy.save(row);precondition(try! store.recover("fixture",legacy:legacy)==4);precondition(try! store.recover("fixture",legacy:legacy)==0)
    for label in 0...1 {for _ in 0..<12 {try! store.save(SingleTapRecord(id:UUID().uuidString,hardware:"fixture",label:label,split:"Train",source:"live",date:Date(),impact:impact(1,label),predicted:nil))}}
    var rows=store.load("fixture");let m=store.model(rows);precondition(m.samples[0]!.count==16 && m.samples[1]!.count==12)
    try! store.save(SingleTapRecord(id:UUID().uuidString,hardware:"fixture",label:1,split:"Test",source:"live",date:Date(),impact:impact(1,1),predicted:1))
    rows=store.load("fixture");precondition(store.model(rows).samples[1]!.count==12 && store.load("other").isEmpty)
    let asset=store.asset(hardware:"fixture",records:rows)!;precondition(asset.valid && asset.negativeTests==1 && asset.model.samples.values.flatMap{$0}.allSatisfy{$0.waveform.isEmpty})
    let shared=root.appendingPathComponent("MagDot-models");try! asset.save(root:shared)
    let loaded=ConnectorModel.load(hardware:"fixture",root:shared)!;precondition(loaded.id==asset.id && ConnectorModel.load(hardware:"other",root:shared)==nil)
    precondition(PreparedContextBank(loaded.bank).evidence(impact(1,0).feature).side==0)
    let profiles=root.appendingPathComponent("profiles");try! FileManager.default.createDirectory(at:profiles,withIntermediateDirectories:true)
    let frozen=try! FrozenMotion.make(model:m,threshold:0.01,source:"fixture")
    let profile=CalibrationProfile(schema:3,hardware:"fixture",size:"Small",surface:"desk",threshold:0.01,model:m,trials:[],noiseRuns:[],frozen:frozen)
    try! JSONEncoder().encode(profile).write(to:profiles.appendingPathComponent("v3-fixture-Small-desk.json"))
    precondition(try! store.recoverChassis("fixture",legacyRoot:profiles)==28)
    precondition(try! store.recoverChassis("fixture",legacyRoot:profiles)==0)
    precondition(store.load("fixture").filter{$0.source.hasPrefix("legacy-chassis") && $0.label==1}.count==28)
    print("PASS: single-tap labels, recovered-pair reuse/deduplication, Test exclusion, hardware isolation and MagDot model handoff")
}
