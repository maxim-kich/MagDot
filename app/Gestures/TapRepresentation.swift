import Foundation

// Candidate representations are benchmarked by recording window, keeping
// neighboring impacts and their decay out of the corresponding training fold.
enum TapRepresentation:String,CaseIterable {
    case legacy,fullEnvelope,direction,attack,spectrum,hybrid
    func extract(_ impact:Impact)->[Double]{
        if self == .legacy{return GestureRecording.tapShape(impact)}
        let rows=impact.waveform.filter{$0.t>=impact.onset-0.025 && $0.t<=impact.onset+0.135}
        guard rows.count>=16 else{return []}
        if self == .fullEnvelope{return features(rows)}
        let count=128,duration=0.13
        var axes=Array(repeating:[Double](),count:3),cursor=0
        for i in 0..<count{
            let t=impact.onset+Double(i)*duration/Double(count-1)
            while cursor+1<rows.count-1 && rows[cursor+1].t<t{cursor+=1}
            let a=rows[cursor],b=rows[min(cursor+1,rows.count-1)]
            let fraction=min(1,max(0,(t-a.t)/max(1e-9,b.t-a.t)))
            for axis in 0..<3{axes[axis].append(a.xyz[axis]+fraction*(b.xyz[axis]-a.xyz[axis]))}
        }
        let total=max(1e-12,axes.flatMap{$0}.reduce(0){$0+$1*$1})
        let localEnergy=axes.reduce(0){$0+$1.prefix(40).reduce(0){$0+$1*$1}}
        let rms=self == .attack ? sqrt(max(1e-12,localEnergy)/40):sqrt(total/Double(count))
        var signed=[Double]()
        for axis in axes{
            // Preserve the initial direction and signed attack, rather than
            // mapping a waveform and its sign reversal to the same signature.
            for bin in 0..<8{let lo=bin*5,hi=lo+5;signed.append(axis[lo..<hi].reduce(0,+)/(5*rms))}
            signed.append((axis.prefix(40).max() ?? 0)/rms)
            signed.append((axis.prefix(40).min() ?? 0)/rms)
        }
        if self == .direction || self == .attack{return signed}
        var spectral=[Double]()
        for axis in axes{
            for frequency in stride(from:10.0,through:390.0,by:10){
                var re=0.0,im=0.0
                for i in 0..<count{
                    let phase=2*Double.pi*frequency*Double(i)*duration/Double(count-1)
                    let window=0.5-0.5*cos(2*Double.pi*Double(i)/Double(count-1))
                    re+=axis[i]*window*cos(phase);im+=axis[i]*window*sin(phase)
                }
                spectral.append(sqrt((re*re+im*im)/(total*Double(count))))
            }
        }
        return self == .spectrum ? spectral:features(rows)+signed+spectral
    }
}
