import Foundation
import IOKit

struct Hardware {
    let model: String
    let name: String
    static func current() -> Hardware {
        let process=Process(), pipe=Pipe()
        process.executableURL=URL(fileURLWithPath:"/usr/sbin/system_profiler")
        process.arguments=["SPHardwareDataType","-json"];process.standardOutput=pipe;process.standardError=FileHandle.nullDevice
        do {
            try process.run()
            let data=pipe.fileHandleForReading.readDataToEndOfFile();process.waitUntilExit()
            let json=try JSONSerialization.jsonObject(with:data) as? [String:Any]
            let row=(json?["SPHardwareDataType"] as? [[String:Any]])?.first
            return Hardware(model:row?["machine_model"] as? String ?? "unknown",name:row?["machine_name"] as? String ?? "Unknown Mac")
        } catch {return Hardware(model:"unknown",name:"Unknown Mac")}
    }
    var isMacBook: Bool { name.hasPrefix("MacBook") && model != "unknown" }
}
func lidIsOpen() -> Bool {
    let root=IOServiceGetMatchingService(kIOMainPortDefault,IOServiceMatching("IOPMrootDomain"))
    guard root != 0 else{return false};defer{IOObjectRelease(root)}
    guard let closed=IORegistryEntryCreateCFProperty(root,"AppleClamshellState" as CFString,kCFAllocatorDefault,0)?.takeRetainedValue() as? Bool else{return false}
    return !closed
}
struct TestTrial: Codable {
    let expected:Int
    let predicted:Int?
    let missed:Bool
    var impact:Impact? = nil
    var diagnostic:[MotionSample]? = nil
    var classifierVersion:String? = nil
    var micPredicted:Int? = nil
    var pairedMotionPredicted:Int? = nil
    var micAvailable:Bool? = nil
    var pairedModelReady:Bool? = nil
}
let classifierVersion = "left-v3"
func binaryZone(_ zone:Int)->Int { zone == 0 || zone == 2 ? 0 : 1 }
func learnedThreshold(_ model:LocationModel)->Double {
    let weak=model.samples.values.compactMap { rows -> Double? in
        let peaks=rows.map(\.peak).filter{$0.isFinite && $0>0}.sorted()
        return peaks.count>=12 ? peaks[Int(Double(peaks.count-1)*0.1)] : nil
    }.min()
    return weak.map{max(0.003,min(0.012,$0*0.2))} ?? 0.012
}
struct CalibrationProfile: Codable {
    let schema:Int
    let hardware:String
    let size:String
    let surface:String
    var threshold:Double
    var model:LocationModel
    var trials:[TestTrial]
    var noiseRuns:[Int]
    var legacyTrials:[TestTrial]? = nil
    var frozen:FrozenMotion? = nil
    var typingTests:[TypingResult]? = nil
    var sourceSizeLabel:String? = nil
    var classifierVersion:String? = nil
}
struct ProfileStore {
    let root:URL
    init(root:URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Tap Lab")){self.root=root}
    func url(_ hardware:String,_ size:String,_ surface:String)->URL {
        let key="v3-\(hardware)-\(size)-\(surface)".map{$0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_"}
        return root.appendingPathComponent(String(key)+".json")
    }
    func load(_ hardware:String,_ size:String,_ surface:String)throws->CalibrationProfile? {
        let file=url(hardware,size,surface)
        guard FileManager.default.fileExists(atPath:file.path) else{return try migrate(hardware,size,surface)}
        let p=try JSONDecoder().decode(CalibrationProfile.self,from:Data(contentsOf:file))
        guard p.schema==3,p.hardware==hardware,p.size==size,p.surface==surface,p.threshold.isFinite,
              (0.003...0.12).contains(p.threshold),p.model.samples.keys.allSatisfy({(0..<2).contains($0)}),
              p.model.samples.values.flatMap({$0}).allSatisfy({$0.feature.count==42 && $0.feature.allSatisfy(\.isFinite)}) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        if let f=p.frozen {
            guard f.threshold.isFinite,(0.003...0.12).contains(f.threshold),
                  f.model.trained.count==2,
                  try FrozenMotion.make(model:f.model,threshold:f.threshold,source:f.source).id==f.id else{throw CocoaError(.fileReadCorruptFile)}
        }
        return p
    }
    private func migrate(_ hardware:String,_ size:String,_ surface:String)throws->CalibrationProfile? {
        guard ["Small","Big"].contains(size),FileManager.default.fileExists(atPath:root.path) else{return nil}
        let aliases=size == "Small" ? ["13-inch","14-inch"] : ["15-inch","16-inch"]
        var candidates=[CalibrationProfile]()
        for path in try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil) where path.lastPathComponent.hasPrefix("v2-") && path.pathExtension == "json" {
            guard let p=try? JSONDecoder().decode(CalibrationProfile.self,from:Data(contentsOf:path)),p.schema==2,p.hardware==hardware,p.surface==surface,aliases.contains(p.size) else{continue}
            candidates.append(p)
        }
        let populated=candidates.filter{!$0.model.samples.values.flatMap({$0}).isEmpty}
        guard populated.count<=1 else{throw CocoaError(.fileReadCorruptFile)} // Never silently merge different old profiles.
        guard let old=populated.first ?? candidates.first else{return nil}
        var binary=LocationModel()
        for (zone,rows) in old.model.samples {for event in rows {binary.add(event,zone:binaryZone(zone))}}
        let legacy=old.trials.map{TestTrial(expected:binaryZone($0.expected),predicted:$0.predicted.map(binaryZone),missed:$0.missed,impact:$0.impact,diagnostic:$0.diagnostic,classifierVersion:"legacy-v2")}
        let result=CalibrationProfile(schema:3,hardware:hardware,size:size,surface:surface,threshold:learnedThreshold(binary),model:binary,trials:[],noiseRuns:[],legacyTrials:legacy,sourceSizeLabel:old.size,classifierVersion:classifierVersion)
        try save(result) // Original v2 file is kept intact as the migration source.
        return result
    }
    func save(_ p:CalibrationProfile)throws {
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        try JSONEncoder().encode(p).write(to:url(p.hardware,p.size,p.surface),options:.atomic)
    }
}
func profileSelfTest() {
    let temp=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer{try? FileManager.default.removeItem(at:temp)}
    let store=ProfileStore(root:temp)
    let p=CalibrationProfile(schema:3,hardware:"MacTest",size:"Small",surface:"Desk",threshold:0.012,model:LocationModel(),trials:[],noiseRuns:[])
    try! store.save(p)
    precondition(try! store.load("MacTest","Small","Desk") != nil)
    precondition(try! store.load("MacTest","Big","Desk") == nil)
    precondition(try! store.load("OtherMac","Small","Desk") == nil)
    precondition(try! store.load("MacTest","Small","Lap") == nil)
    var legacy=p;legacy=CalibrationProfile(schema:2,hardware:"LegacyMac",size:"14-inch",surface:"Desk",threshold:0.012,model:LocationModel(),trials:[TestTrial(expected:2,predicted:1,missed:false)],noiseRuns:[])
    let legacyPath=temp.appendingPathComponent("v2-LegacyMac-14-inch-Desk.json")
    try! JSONEncoder().encode(legacy).write(to:legacyPath)
    let migrated=try! store.load("LegacyMac","Small","Desk")!
    precondition(migrated.schema==3 && migrated.legacyTrials?.first?.expected==0 && migrated.trials.isEmpty)
    precondition(FileManager.default.fileExists(atPath:legacyPath.path))
    precondition(try! store.load("LegacyMac","Big","Desk")==nil)
    var recorded=p
    recorded.trials=[TestTrial(expected:0,predicted:nil,missed:true,diagnostic:[MotionSample(t:0,xyz:[0,0,-1])],classifierVersion:classifierVersion)]
    try! store.save(recorded)
    let replay=try! store.load("MacTest","Small","Desk")!
    precondition(replay.trials.first?.diagnostic?.count==1 && replay.model.samples.isEmpty)
    precondition(replay.trials.first?.classifierVersion==classifierVersion)
    precondition(learnedThreshold(LocationModel())==0.012)
    var locked=p;var examples=LocationModel()
    for z in [0,1] {for _ in 0..<12 {var f=[Double](repeating:0,count:42);f[z]=1;examples.add(Impact(onset:0,peak:0.1,feature:f,waveform:[]),zone:z)}}
    locked.frozen=try! FrozenMotion.make(model:examples,threshold:locked.threshold,source:"fixture")
    try! store.save(locked)
    let reopened=try! store.load("MacTest","Small","Desk")!
    precondition(reopened.frozen?.id==locked.frozen?.id && reopened.frozen?.model.samples[0]?.count==12)
    print("PASS: profile persistence; hardware/Small/Big/surface isolation; migration preserves original and historical results")
}
