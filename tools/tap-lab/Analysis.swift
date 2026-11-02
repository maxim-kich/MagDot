import Foundation

// Diagnostic analysis only. Historical test outcomes never become training rows.
func analyzeProfile(_ url:URL)throws {
    let source=try JSONDecoder().decode(CalibrationProfile.self,from:Data(contentsOf:url))
    var model=LocationModel()
    for (zone,rows) in source.model.samples {for row in rows{model.add(row,zone:binaryZone(zone))}}
    var validation=[[String:Any]]()
    for zone in model.samples.keys.sorted() {
        let rows=model.samples[zone]!
        var correct=0,wrong=0,unknown=0
        for i in rows.indices {
            var fold=model;fold.samples[zone]!.remove(at:i)
            if let predicted=fold.estimate(rows[i].feature)?.0 {if predicted==zone{correct+=1}else{wrong+=1}}else{unknown+=1}
        }
        validation.append(["class":zone==0 ? "left" : "not-left","recordings":rows.count,"correct":correct,"wrong":wrong,"unknown":unknown])
    }
    let historical=(source.legacyTrials ?? [])+source.trials
    var old=[[String:Any]]()
    for zone in [0,1] {
        let rows=historical.filter{binaryZone($0.expected)==zone}
        old.append(["class":zone==0 ? "left" : "not-left","trials":rows.count,
                    "correct":rows.filter{!$0.missed && $0.predicted.map(binaryZone)==zone}.count,
                    "wrong":rows.filter{!$0.missed && $0.predicted != nil && $0.predicted.map(binaryZone) != zone}.count,
                    "unknown":rows.filter{!$0.missed && $0.predicted==nil}.count,
                    "missed":rows.filter(\.missed).count,
                    "replayable":rows.filter{$0.impact != nil}.count])
    }
    let report:[String:Any]=["hardware":source.hardware,"sourceProfile":source.size,
        "trainingOnlyLeaveOneOut":validation,"historicalTests":old,
        "proposedThresholdG":learnedThreshold(model),
        "limitations":["Leave-one-out uses a single small training session; it is not independent validation.","Historical test outcomes without waveforms cannot be replayed.","Right-edge examples do not establish rejection of center taps, typing, or desk bumps.","New detection threshold requires fresh physical tests and noise tests."]]
    let data=try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
    print(String(data:data,encoding:.utf8)!)
}
