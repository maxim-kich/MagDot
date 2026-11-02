import Foundation

// Precompute training statistics once. Classification stays linear in the
// number of examples instead of recomputing leave-one-out radii per tap on UI.
struct PreparedContextBank {
    struct Expert {
        let groups:[[Impact]]
        let scales:[Double]
        let radii:[Double]
    }
    var experts=[Expert]()
    init(_ bank:ContextBank=ContextBank(),minimumSamples:Int=12){
        for expert in bank.experts {
            let m=expert.model
            guard let left=m.samples[0],let other=m.samples[1],left.count>=minimumSamples,other.count>=minimumSamples,let n=left.first?.feature.count,n>0 else{continue}
            let all=left+other
            guard all.allSatisfy({$0.feature.count==n}) else{continue}
            let scales=(0..<n).map{i -> Double in
                let mean=all.reduce(0){$0+$1.feature[i]}/Double(all.count)
                return max(0.06,sqrt(all.reduce(0){$0+pow($1.feature[i]-mean,2)}/Double(all.count)))
            }
            let groups=[left,other]
            let radii=groups.map{rows -> Double in
                let own=rows.indices.map{i in Self.score(rows[i].feature,rows.enumerated().filter{$0.offset != i}.map(\.element),scales)}.sorted()
                return max(0.08,own[Int(Double(own.count-1)*0.95)]*2)
            }
            experts.append(Expert(groups:groups,scales:scales,radii:radii))
        }
    }
    private static func score(_ f:[Double],_ rows:[Impact],_ scales:[Double])->Double{
        let values=rows.map{row in zip(zip(f,row.feature),scales).reduce(0){$0+pow(($1.0.0-$1.0.1)/$1.1,2)}/Double(f.count)}.sorted().prefix(3)
        return values.reduce(0,+)/Double(values.count)
    }
    func evidence(_ f:[Double],vetoNegativeNeighbor:Bool=false,sensitivity:Double=0.5)->SideEvidence {
        let policy=LocationSensitivity(sensitivity)
        var left=false,other=false,best=Double.greatestFiniteMagnitude,relative=Double.greatestFiniteMagnitude
        for e in experts where f.count==e.scales.count {
            let scores=e.groups.map{Self.score(f,$0,e.scales)}
            best=min(best,scores[0]/e.radii[0]);relative=min(relative,scores[0]/max(scores[1],1e-9))
            let winner=scores[0]<=scores[1] ? 0:1,loser=1-winner
            let margin=(scores[loser]-scores[winner])/max(scores[loser],1e-9)
            if scores[winner]<=e.radii[winner]*(winner==0 ? policy.radiusScale:1) && margin>(winner==0 ? policy.minimumMargin:0.25) {
                if winner==0 && vetoNegativeNeighbor {
                    func nearest(_ rows:[Impact])->Double{rows.map{row in zip(zip(f,row.feature),e.scales).reduce(0){$0+pow(($1.0.0-$1.0.1)/$1.1,2)}/Double(f.count)}.min() ?? .greatestFiniteMagnitude}
                    if nearest(e.groups[1])<=nearest(e.groups[0])*1.1{other=true}else{left=true}
                }else if winner==0{left=true}else{other=true}
            }
        }
        return SideEvidence(side:left && !other ? 0:other ? 1:nil,leftDistance:best.isFinite ? min(best,1000):1000,contradiction:left && other,leftVsOther:relative.isFinite ? relative:nil)
    }
}
