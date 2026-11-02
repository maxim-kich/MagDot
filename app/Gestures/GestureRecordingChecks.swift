import Foundation

@discardableResult func gestureRecordingSelfTest()->PersonalCalibration{
    func tap(_ t:Double,_ axis:Int,_ amp:Double=0.03)->Impact{
        let rows=(0..<140).map{i -> MotionSample in
            let dt=Double(i)/800-0.035
            var xyz=[0.0,0.0,0.0]
            if dt>=0{xyz[axis]=amp*exp(-dt*35)*cos(dt*2*Double.pi*65)}
            return MotionSample(t:t+dt,xyz:xyz)
        }
        return Impact(onset:t,peak:amp,feature:features(rows),waveform:rows)
    }
    func recording(_ axis:Int,input:Bool=false,starts:[Double]=[0.05,0.23])->GestureRecording{
        let taps=starts.map{tap($0,axis)}
        let rows=(0..<600).map{i -> MotionSample in
            let t=Double(i)/800;var xyz=[0.0,0.0,0.0]
            for start in starts where t>=start{xyz[axis]+=0.03*exp(-(t-start)*35)*cos((t-start)*2*Double.pi*65)}
            return MotionSample(t:t,xyz:xyz)
        }
        return GestureRecording(startedAt:0,frames:rows,impacts:taps,inputActive:input,rawCandidates:2)
    }
    var pace=CalibrationPace()
    for t in [1.0,1.12,1.24,1.36]{pace.observe(tap(t,0),at:t)}
    precondition(pace.hint(at:1.4)=="Slower" && pace.hint(at:4).isEmpty)
    precondition(pace.hint(at:2.2).isEmpty,"Hands-off must clear the pace warning promptly")
    pace.observeRecording(recording(0,starts:[0.05,0.15,0.25,0.35]),at:5)
    precondition(pace.hint(at:5).isEmpty,"Delayed captures must not revive Slower after tapping stops")
    pace.reset();for t in [1.0,2.5,4,5.5]{pace.observe(tap(t,0),at:t)}
    precondition(pace.hint(at:5.6).isEmpty)
    pace.reset();for t in [1.0,1.5,2,2.5]{pace.observe(tap(t,0),at:t)}
    precondition(pace.hint(at:2.6).isEmpty)
    let positive=recording(0),negative=recording(1)
    precondition(positive.valid && positive.pairSignature?.count==86)
    let session=CalibrationSession(hardware:"fixture",now:0)
    var clock=4.0
    for _ in CalibrationSession.steps{
        for _ in 0..<12{
            let row=session.location == .connector ? positive:negative
            precondition(session.accept(row,onset:clock,now:clock))
            clock+=4
        }
    }
    precondition(session.checking && !session.finished)
    session.update(now:clock-3.5);precondition(!session.finished)
    session.update(now:clock+2)
    precondition(session.finished && session.profile.validated)
    precondition(session.profile.gestures?.count==36 && session.profile.gestureChecks?.count==4)
    precondition(session.profile.gestureChecks?.allSatisfy{$0.samples.count==3}==true)
    precondition((try! JSONDecoder().decode(PersonalCalibration.self,from:JSONEncoder().encode(session.profile))).validated)
    let model=PersonalGestureModel(session.profile.gestures ?? [])
    precondition(model.evaluate(positive).accepted && !model.evaluate(negative).accepted)
    precondition(!model.evaluate(recording(0,input:true)).accepted)
    let single=GestureRecording(startedAt:0,frames:positive.frames,impacts:[positive.impacts[0]],inputActive:false,rawCandidates:1)
    precondition(!model.evaluate(single).accepted)
    let triple=GestureRecording(startedAt:0,frames:positive.frames,impacts:positive.impacts+[tap(0.4,0)],inputActive:false,rawCandidates:3)
    precondition(!model.evaluate(triple).accepted)
    let collecting=CalibrationSession(hardware:"fixture",now:0)
    precondition(collecting.accept(single,onset:4,now:4) && collecting.profile.gestures?.count==1,"Free calibration must accept single taps without pair timing")
    precondition(!collecting.accept(recording(0,input:true),onset:5,now:5),"Input-active positive captures must be ignored")
    precondition(collecting.profile.gestures?.contains{$0.location == .handling}==true,"Incidental input is captured as negative without a manual task")
    precondition(CalibrationSession.steps==CalibrationLocation.targets,"Setup must not ask users to perform keyboard/trackpad/handling exercises")
    let freeModel=PersonalTapModel(session.profile.gestures ?? [])
    precondition(freeModel.ready && freeModel.evidence(positive.impacts[0]).side==0 && freeModel.evidence(negative.impacts[0]).side==1)
    let flipped=GestureRecording(startedAt:positive.startedAt,frames:positive.frames.map{MotionSample(t:$0.t,xyz:$0.xyz.map{-$0})},impacts:positive.impacts.map{tap in Impact(onset:tap.onset,peak:tap.peak,feature:tap.feature,waveform:tap.waveform.map{MotionSample(t:$0.t,xyz:$0.xyz.map{-$0})})},inputActive:false,rawCandidates:2)
    let originalShape=TapRepresentation.direction.extract(positive.impacts[0]),reversedShape=TapRepresentation.direction.extract(flipped.impacts[0])
    precondition(zip(originalShape,reversedShape).contains{abs($0-$1)>0.1},"The new representation must preserve initial motion direction")
    let oldA=GestureRecording.tapShape(positive.impacts[0]),oldB=GestureRecording.tapShape(flipped.impacts[0])
    precondition(zip(oldA,oldB).allSatisfy{abs($0-$1)<1e-10},"This fixture must exercise the old sign ambiguity")
    let stronger=Impact(onset:positive.impacts[0].onset,peak:0.09,feature:positive.impacts[0].feature,waveform:positive.impacts[0].waveform.map{MotionSample(t:$0.t,xyz:$0.xyz.map{$0*3})})
    precondition(zip(originalShape,TapRepresentation.direction.extract(stronger)).allSatisfy{abs($0-$1)<1e-9},"Signed features must retain strength normalization")
    let guarded=PersonalTapModel(session.profile.gestures ?? [],checks:[GestureValidation(location:.connector,samples:[flipped,flipped,flipped],detected:[true,true,true])])
    precondition(!guarded.usesSignedAlgorithm && guarded.evidence(flipped.impacts[0]).side==0,"A regression on an existing reserved recording must retain the legacy classifier")
    let irregular=recording(0,starts:[0.08,0.33,0.61])
    precondition(collecting.accept(irregular,onset:6,now:6),"Three freely timed taps must be accepted as a recording, not rejected for missing a double-tap pattern")
    precondition(irregular.impacts.allSatisfy{freeModel.evidence($0).side==0})
    var pairedCompatibility=session.profile;pairedCompatibility.gestureVersion=1
    let handlingRows=(pairedCompatibility.gestures ?? []).filter{$0.location == .frontRight}.map{GestureExample(location:.handling,recording:$0.recording)}
    pairedCompatibility.gestures?.append(contentsOf:handlingRows)
    pairedCompatibility.gestureChecks?.append(GestureValidation(location:.handling,samples:[negative,negative,negative],detected:[false,false,false]))
    precondition(pairedCompatibility.validated,"Existing complete-pair profiles must remain readable")
    var failed=session.profile
    failed.gestureChecks?[1]=GestureValidation(location:.backRight,samples:[negative,negative,negative],detected:[true,false,false])
    precondition(!failed.validated,"A corner false activation cannot pass automatic checks")
    let grouper=ImpactGrouper()
    precondition(grouper.ingest(tap(1,0)) != nil)
    let decayRows=(0..<100).map{i -> MotionSample in
        let dt=Double(i)/800-0.035
        return MotionSample(t:1.12+dt,xyz:[0.01*exp(-dt*10),0,0])
    }
    let decay=Impact(onset:1.12,peak:0.01,feature:features(decayRows),waveform:decayRows)
    precondition(grouper.ingest(decay)==nil && grouper.grouped==1 && grouper.confidentDecay)
    precondition(grouper.ingest(tap(1.24,0,0.02)) != nil,"A fresh second attack must survive a preceding ringing candidate")
    let tail=Impact(onset:0.38,peak:decay.peak,feature:decay.feature,waveform:decay.waveform.map{MotionSample(t:$0.t-1.12+0.38,xyz:$0.xyz)})
    let augmented=(session.profile.gestures ?? []).map{row -> GestureExample in
        var recording=row.recording;recording.decays=[tail]
        return GestureExample(location:row.location,recording:recording)
    }
    let vibrationModel=PersonalTapModel(augmented)
    precondition(vibrationModel.evidence(tail).side==1,"Confident between-tap decay must train as a negative")
    var withTail=positive;withTail.decays=[tail]
    precondition(vibrationModel.validate(.connector,[withTail,withTail,withTail]).passed)
    grouper.reset();precondition(grouper.ingest(tap(2,0)) != nil)
    precondition(grouper.ingest(tap(2.105,0,0.02)) != nil,"Grouping must not add a long dead interval")
    let recorder=GestureRecorder()
    for i in 0..<600{
        let t=Double(i)/800
        recorder.sample(positive.frames[i],inputActive:false)
        if i==40{recorder.onset(t)}
        if i==184{recorder.onset(t)}
        if i==160{recorder.impact(positive.impacts[0])}
        if i==304{recorder.impact(positive.impacts[1])}
    }
    recorder.vibration(tail)
    let captured=recorder.take(now:0.75,handling:false)!
    precondition(captured.impacts.count==2 && captured.pairSignature != nil && captured.frames.count>400 && captured.decays?.count==1)
    precondition(recorder.take(now:0.8,handling:false)==nil,"A gesture window can be delivered only once")
    let handling=GestureRecorder()
    for i in 0..<1400{handling.sample(MotionSample(t:Double(i)/800,xyz:[0,0,-1]),inputActive:i<500)}
    let activity=handling.take(now:1.75,handling:true)!
    precondition(activity.inputActive && activity.impacts.isEmpty && !model.evaluate(activity).accepted)
    let continuous=GestureRecorder();var freeWindows=[GestureRecording]()
    let starts=[0.05,0.31,0.76,1.16,1.69,2.1]
    for i in 0..<2400{
        let t=Double(i)/800
        continuous.sample(MotionSample(t:t,xyz:[0,0,-1]),inputActive:false)
        for start in starts{
            if abs(t-start)<0.0001{continuous.onset(t)}
            if abs(t-(start+0.14))<0.0001{continuous.impact(tap(start,0))}
        }
        if let window=continuous.take(now:t,handling:false,continuous:true){freeWindows.append(window)}
    }
    precondition(freeWindows.count>=3 && freeWindows.reduce(0){$0+$1.impacts.count}==starts.count,"Continuous capture must retain freely timed attacks without waiting for a pause")
    precondition(freeWindows.allSatisfy(\.valid))
    // Exercise the real sampling pipeline with a resonant decay and a second
    // attack. Raw candidate spacing must not hide the second tap behind a ring.
    for frequency in [25.0,60,115]{for gap in [0.105,0.14,0.24,0.40]{for secondStrength in [0.0,0.018,0.03,0.05]{
        let detector=BurstDetector(),grouped=ImpactGrouper(),windows=GestureRecorder()
        detector.minimumCandidateGap=0.025;detector.sensitivity=1
        var rawCount=0,fresh=[Impact](),episodes=[GestureRecording]()
        detector.onOnset={t,_ in rawCount+=1;windows.onset(t)}
        detector.onImpact={impact in if let attack=grouped.ingest(impact){fresh.append(attack);windows.impact(attack)}}
        for i in 0..<3200{
            let t=Double(i)/800;var x=0.0
            for (start,amplitude) in [(1.25,0.03),(1.25+gap,secondStrength)] where t>=start{x+=amplitude*exp(-(t-start)*12)*cos((t-start)*2*Double.pi*frequency)}
            windows.sample(MotionSample(t:t,xyz:[x,0,-1]),inputActive:false);detector.ingest(t,[x,0,-1])
            if let episode=windows.take(now:t,handling:false){episodes.append(episode)}
        }
        let expected=secondStrength==0 ? 1:2
        precondition(rawCount>=expected)
        precondition(fresh.count==expected,"Decay grouping at \(frequency) Hz / \(gap) sec: raw=\(rawCount), fresh=\(fresh.map(\.onset)), second=\(secondStrength)")
        precondition(episodes.count==1 && episodes[0].impacts.count==expected && (episodes[0].pairSignature != nil)==(expected==2),"Runtime/calibration window mismatch at \(frequency)/\(gap)")
    }}}
    print("Free-tap continuous capture, profile compatibility and 48 sampled ringing/attack fixtures passed")
    return session.profile
}
