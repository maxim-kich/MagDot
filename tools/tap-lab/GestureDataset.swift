import Foundation

enum GestureTarget:String,CaseIterable {
    case chassis="Chassis near MagSafe",connector="MagSafe connector"
    var categories:[String]{self == .connector ? ["Connector double-tap","Chassis double-tap","Single connector tap","Cable movement / handling","Agent busy: connector double-tap"] : ["MagSafe double-tap","Other-side double-tap","Single MagSafe tap","Handling / desk bumps","Agent busy: MagSafe double-tap"]}
    var positive:String{categories[0]}
    var negative:String{categories[1]}
    var single:String{categories[2]}
}
struct GestureTrial:Codable {
    let id:String
    let hardware:String
    let machineName:String
    let conditionTag:String
    let split:String
    let category:String
    let attention:Bool
    let modelBankID:String
    let date:Date
    let duration:Double
    let threshold:Double
    let completed:Bool
    let raw:[MotionSample]
    var detectorVersion:String = "burst-v1 / pair-v1"
    let candidates:[GestureCandidate]
    let decisions:[GestureDecision]
    var target:String? = nil
    var targetKind:GestureTarget{GestureTarget(rawValue:target ?? "") ?? .chassis}
    var expected:Int { attention && category == targetKind.positive ? 1 : 0 }
}
struct GestureDataStore {
    let root:URL
    let target:GestureTarget
    init(root:URL?=nil,target:GestureTarget = .chassis){
        self.target=target
        self.root=root ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Tap Lab/"+(target == .connector ? "gesture-connector-v1":"gesture-v1"))
    }
    func save(_ row:GestureTrial)throws {
        guard row.targetKind==target else{throw CocoaError(.fileWriteInvalidFileName)}
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let data=try JSONEncoder().encode(row)
        try data.write(to:root.appendingPathComponent(row.id+".json"),options:.atomic)
    }
    func load()->[GestureTrial] {
        ((try? FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil)) ?? [])
            .filter{$0.pathExtension=="json"}.compactMap{try? JSONDecoder().decode(GestureTrial.self,from:Data(contentsOf:$0))}
            .filter{$0.targetKind==target}.sorted{$0.date<$1.date}
    }
    // Only explicitly labelled training trials contribute anchors. Validation
    // and typing recordings are never used for fitting.
    func bank(hardware:String,legacyRoot:URL)->ContextBank {
        var result=target == .chassis ? ContextBank.load(hardware:hardware,root:legacyRoot):ContextBank()
        var models=[String:LocationModel]()
        for row in load() where row.hardware==hardware && row.split=="Train" && row.completed {
            let label:Int
            if row.category==target.positive,row.candidates.count==2 {label=0}
            else if row.category==target.negative,row.candidates.count==2 {label=1}
            else if row.category==target.single,row.candidates.count==1 {label=0}
            else {continue}
            for candidate in row.candidates {models[row.conditionTag,default:LocationModel()].add(candidate.impact,zone:label)}
        }
        for key in models.keys.sorted() where models[key]!.trained.count==2 {
            result.experts.append(ContextBank.Expert(source:"gesture-training/"+key,model:models[key]!))
        }
        return result
    }
}
func datasetSelfTest(){
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer{try? FileManager.default.removeItem(at:root)}
    let store=GestureDataStore(root:root)
    let row=GestureTrial(id:UUID().uuidString,hardware:"fixture",machineName:"MacBook",conditionTag:"lap",split:"Validation",category:"MagSafe double-tap",attention:true,modelBankID:"fixed",date:Date(),duration:4,threshold:0.01,completed:true,raw:[],candidates:[],decisions:[])
    try! store.save(row)
    precondition(store.load().count==1 && store.load()[0].expected==1)
    precondition(store.bank(hardware:"fixture",legacyRoot:root).experts.isEmpty)
    precondition(store.bank(hardware:"other",legacyRoot:root).experts.isEmpty)
    func pair(_ label:Int)->[GestureCandidate]{
        var f=[Double](repeating:0,count:42);f[label]=1
        return [1.0,1.2].map{GestureCandidate(impact:Impact(onset:$0,peak:0.1,feature:f,waveform:[]),evidence:SideEvidence(side:nil,leftDistance:1,contradiction:false))}
    }
    for hardware in ["fixture","other"] {for label in [0,1] {for _ in 0..<6 {
        let r=GestureTrial(id:UUID().uuidString,hardware:hardware,machineName:"MacBook",conditionTag:"lap",split:"Train",category:label==0 ? "MagSafe double-tap" : "Other-side double-tap",attention:true,modelBankID:"fixed",date:Date(),duration:4,threshold:0.01,completed:true,raw:[],candidates:pair(label),decisions:[])
        try! store.save(r)
    }}}
    let bank=store.bank(hardware:"fixture",legacyRoot:root)
    precondition(bank.experts.count==1 && bank.examples==24)
    precondition(bank.evidence(pair(0)[0].impact.feature).side==0)
    precondition(bank.evidence(pair(1)[0].impact.feature).side==1)
    let heldout=GestureTrial(id:UUID().uuidString,hardware:"fixture",machineName:"MacBook",conditionTag:"lap",split:"Validation",category:"MagSafe double-tap",attention:true,modelBankID:bank.id,date:Date(),duration:4,threshold:0.01,completed:true,raw:[],candidates:pair(0),decisions:[])
    try! store.save(heldout)
    precondition(store.bank(hardware:"fixture",legacyRoot:root).id==bank.id)
    let connector=GestureDataStore(root:root,target:.connector)
    precondition(connector.load().isEmpty && connector.bank(hardware:"fixture",legacyRoot:root).experts.isEmpty,"connector cannot inherit chassis anchors")
    for label in [0,1] {for _ in 0..<6 {
        let r=GestureTrial(id:UUID().uuidString,hardware:"fixture",machineName:"MacBook",conditionTag:"lap",split:"Train",category:label==0 ? GestureTarget.connector.positive:GestureTarget.connector.negative,attention:true,modelBankID:"fixed",date:Date(),duration:4,threshold:0.01,completed:true,raw:[],candidates:pair(label),decisions:[],target:GestureTarget.connector.rawValue)
        try! connector.save(r)
        precondition(r.expected == (label==0 ? 1:0))
    }}
    precondition(connector.load().count==12 && connector.bank(hardware:"fixture",legacyRoot:root).examples==24)
    precondition(store.bank(hardware:"fixture",legacyRoot:root).id==bank.id,"connector data must not change chassis bank")
    print("PASS: connector/chassis dataset and model isolation")
    print("PASS: gesture dataset round trip; validation and other-machine data excluded from training")
}
