import Foundation

struct CalibrationPace {
    private var last:Double?,gaps=[Double](),settles=[Double]()
    private var message="",expires=0.0
    mutating func reset(){self=CalibrationPace()}
    mutating func observe(_ impact:Impact,at time:Double){
        defer{last=time}
        guard let last else{return}
        let gap=time-last
        guard gap>0,gap<3 else{gaps=[];message="";return}
        gaps.append(gap);gaps=Array(gaps.suffix(3))
        guard gaps.count==3 else{return}
        let median=gaps.sorted()[1]
        let separation=settles.count<6 ? 0.35:max(0.30,settles.sorted()[Int(Double(settles.count-1)*0.9)]+0.05)
        message=median<separation ? "Slower":""
        expires=time+0.8
    }
    mutating func observeRecording(_ recording:GestureRecording,at time:Double){
        guard recording.valid,!recording.inputActive,let first=recording.impacts.first,let initial=recording.frames.first else{return}
        var gravity=initial.xyz,energy=[Double](),envelope=[(Double,Double)]()
        for frame in recording.frames{
            let delta=zip(frame.xyz,gravity).map(-)
            for i in 0..<3{gravity[i]+=0.015*delta[i]}
            energy.append(delta.reduce(0){$0+$1*$1});if energy.count>8{energy.removeFirst()}
            envelope.append((frame.t,sqrt(energy.reduce(0,+)/Double(energy.count))))
        }
        let before=envelope.filter{$0.0<first.onset-0.008}.map{$0.1}.sorted()
        guard before.count>=5 else{return}
        let baseline=before[before.count/2],mad=before.map{abs($0-baseline)}.sorted()[before.count/2]
        for (i,tap) in recording.impacts.enumerated(){
            let next=i+1<recording.impacts.count ? recording.impacts[i+1].onset:nil
            let end=next.map{$0-0.015} ?? envelope.last!.0
            let peak=envelope.filter{$0.0>=tap.onset && $0.0<tap.onset+0.035}.map{$0.1}.max() ?? 0
            let threshold=max(1e-5,max(baseline+4*mad,peak*0.05))
            var quiet:Double?,settled:Double?
            for (t,value) in envelope where t>=tap.onset+0.015 && t<=end{
                if value<=threshold{if quiet==nil{quiet=t};if t-quiet!>=0.03{settled=quiet!-tap.onset;break}}else{quiet=nil}
            }
            if let settled{settles.append(settled+0.03);settles=Array(settles.suffix(20))}
            // This recording arrives after the tap. Learn settling time here,
            // but never revive a pace warning from an old capture window.
        }
    }
    func hint(at time:Double)->String{time<expires ? message:""}
}
