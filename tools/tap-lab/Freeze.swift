import Foundation
import CryptoKit

struct FrozenMotion:Codable {
    let id:String
    let version:String
    let threshold:Double
    let model:LocationModel
    let source:String
    static func make(model:LocationModel,threshold:Double,source:String)throws->FrozenMotion {
        let encoder=JSONEncoder();encoder.outputFormatting = .sortedKeys
        let data=try encoder.encode(model)+encoder.encode(threshold)
        let id=SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()
        return FrozenMotion(id:id,version:classifierVersion,threshold:threshold,model:model,source:source)
    }
}
struct TypingImpact:Codable {let elapsed:Double;let predicted:Int?;let peak:Double;var impact:Impact? = nil}
struct TypingResult:Codable {
    let modelID:String
    let startedAt:Date
    let duration:Double
    let editEvents:Int
    let effectiveThreshold:Double
    let reason:String
    let impacts:[TypingImpact]
    var gestureTimes:[Double]? = nil
    var editTimes:[Double]? = nil
    var falseLeft:Int {impacts.filter{$0.predicted==0}.count}
}
func freezeSelfTest(){
    let a=LocationModel()
    let f=try! FrozenMotion.make(model:a,threshold:0.01,source:"fixture")
    precondition(f.id == (try! FrozenMotion.make(model:a,threshold:0.01,source:"fixture")).id)
    precondition(f.id != (try! FrozenMotion.make(model:a,threshold:0.02,source:"fixture")).id)
    let row=TypingResult(modelID:f.id,startedAt:Date(),duration:60,editEvents:100,effectiveThreshold:0.01,reason:"completed",impacts:[TypingImpact(elapsed:1,predicted:0,peak:0.1),TypingImpact(elapsed:2,predicted:1,peak:0.1),TypingImpact(elapsed:3,predicted:nil,peak:0.1)])
    precondition(row.falseLeft==1)
    let restored=try! JSONDecoder().decode(TypingResult.self,from:JSONEncoder().encode(row))
    precondition(restored.editEvents==100 && restored.modelID==f.id && restored.impacts.count==3)
    print("PASS: frozen model fingerprints and typing-result counts/persistence; no typed text in result schema")
}
