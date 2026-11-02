// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct ConnectorModel:Codable {
    let schema:Int
    let target:String
    let hardware:String
    let id:String
    let createdAt:Date
    let model:LocationModel
    let positiveTests:Int
    let negativeTests:Int
    var valid:Bool {
        schema==1 && target=="MagSafe connector" && !hardware.isEmpty && !id.isEmpty && model.trained==[0,1] && model.samples.keys.allSatisfy{[0,1].contains($0)} && model.samples.values.flatMap{$0}.allSatisfy{$0.feature.count==42 && $0.feature.allSatisfy(\.isFinite) && $0.peak.isFinite && $0.peak>0}
    }
    var bank:ContextBank{ContextBank(experts:[ContextBank.Expert(source:"connector/"+id,model:model)])}
    static func path(hardware:String,root:URL=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MagDot/Models"))->URL {
        root.appendingPathComponent("magsafe-connector-"+String(hardware.map{$0.isLetter || $0.isNumber ? $0:"_"})+".json")
    }
    static func load(hardware:String,root:URL=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MagDot/Models"))->ConnectorModel?{
        guard let data=try? Data(contentsOf:path(hardware:hardware,root:root)),let asset=try? JSONDecoder().decode(Self.self,from:data),asset.hardware==hardware,asset.valid else{return nil};return asset
    }
    func save(root:URL=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MagDot/Models"))throws{
        guard valid else{throw CocoaError(.fileWriteInvalidFileName)}
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try JSONEncoder().encode(self).write(to:Self.path(hardware:hardware,root:root),options:.atomic)
    }
}
