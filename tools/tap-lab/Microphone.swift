import AVFoundation
import Foundation
import Darwin

// Keeps at most five seconds in RAM; only derived features are persisted.
final class Microphone {
    private struct Chunk {let start:Double;let rate:Double;let data:[Float]}
    private let lock=NSLock()
    private var chunks=[Chunk]()
    private var engine:AVAudioEngine?
    private(set) var status="Microphone off"
    private(set) var source=""
    var enabled:Bool {engine != nil}
    func start()throws {
        stop()
        let e=AVAudioEngine(),node=e.inputNode,format=e.inputNode.outputFormat(forBus:0)
        guard format.sampleRate>0,format.channelCount>0 else{throw CocoaError(.featureUnsupported)}
        let clockOffset=ProcessInfo.processInfo.systemUptime-AVAudioTime.seconds(forHostTime:mach_absolute_time())
        node.installTap(onBus:0,bufferSize:1024,format:nil){[weak self] buffer,time in
            guard let self,let channels=buffer.floatChannelData,time.isHostTimeValid else{return}
            let frames=Int(buffer.frameLength),count=Int(buffer.format.channelCount),rate=buffer.format.sampleRate
            var data=[Float](repeating:0,count:frames)
            for c in 0..<count {for i in 0..<frames{data[i]+=channels[c][i]/Float(count)}}
            let start=AVAudioTime.seconds(forHostTime:time.hostTime)+clockOffset
            self.lock.lock()
            self.chunks.append(Chunk(start:start,rate:rate,data:data))
            self.chunks.removeAll{$0.start+Double($0.data.count)/$0.rate<start-5}
            self.lock.unlock()
        }
        do {try e.start();engine=e;source="\(AVCaptureDevice.default(for:.audio)?.localizedName ?? "Default input") · \(Int(format.sampleRate)) Hz · \(format.channelCount) channels";status="Mic on · \(Int(format.sampleRate)) Hz · local features"}
        catch {node.removeTap(onBus:0);throw error}
    }
    func stop(){if let e=engine{e.inputNode.removeTap(onBus:0);e.stop()};engine=nil;lock.lock();chunks=[];lock.unlock();status="Microphone off"}
    func features(at onset:Double)->[Double]? {
        lock.lock();let copy=chunks;lock.unlock()
        let lo=onset-0.02,hi=onset+0.10
        var values=[Double](),times=[Double]()
        for chunk in copy {
            guard chunk.start<hi,chunk.start+Double(chunk.data.count)/chunk.rate>lo else{continue}
            for i in chunk.data.indices {
                let t=chunk.start+Double(i)/chunk.rate
                if t>=lo,t<=hi {values.append(Double(chunk.data[i]));times.append(t-lo)}
            }
        }
        return Self.summarize(values:values,times:times)
    }
    static func summarize(values:[Double],times:[Double])->[Double]? {
        guard values.count==times.count,values.count>100,let first=times.first,let last=times.last,last-first>0.10,
              values.allSatisfy(\.isFinite) else{return nil}
        let mean=values.reduce(0,+)/Double(values.count)
        let centered=values.map{$0-mean},energy=centered.reduce(0){$0+$1*$1}
        guard energy>1e-10 else{return nil}
        var bands=[Double]()
        for f in [150.0,300,600,1200,2400,4800,8000,12000] {
            var re=0.0,im=0.0
            for i in centered.indices {
                let window=0.5-0.5*cos(2*Double.pi*Double(i)/Double(centered.count-1))
                let phase=2*Double.pi*f*times[i]
                re+=centered[i]*window*cos(phase);im+=centered[i]*window*sin(phase)
            }
            bands.append(sqrt((re*re+im*im)/(energy*Double(centered.count))))
        }
        for part in 0..<4 {
            let a=part*centered.count/4,b=(part+1)*centered.count/4
            bands.append(sqrt(centered[a..<b].reduce(0){$0+$1*$1}/energy))
        }
        return bands
    }
}

func microphoneSelfTest(){
    let t=(0..<5760).map{Double($0)/48000}
    let a=t.map{sin(2*Double.pi*1200*$0)*0.2}
    let feature=Microphone.summarize(values:a,times:t)!
    precondition(feature.count==12 && feature.allSatisfy(\.isFinite))
    precondition(feature[3]>feature[0] && feature[3]>feature[5])
    let scaled=Microphone.summarize(values:a.map{$0*2},times:t)!
    precondition(zip(feature,scaled).allSatisfy{abs($0-$1)<1e-8})
    precondition(Microphone.summarize(values:[Double](repeating:0,count:5760),times:t)==nil)
    precondition(Microphone.summarize(values:[1,2],times:[0,0.1])==nil)
    print("PASS: audio features, spectral separation, amplitude normalization, silence and short-window rejection; no microphone opened")
}
