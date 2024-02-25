import Foundation
import Beethoven
import Pitchy
import Accelerate

@objc public class PitchWithTime : NSObject {
    @objc public var pitch:Pitch
    @objc public var time:UInt32
    
    init(pitch:Pitch, time:UInt32) {
        self.pitch = pitch
        self.time = time
    }
}

@objc public class Pitch : NSObject {
    @objc public var note:String
    @objc public var frequency:Double
    @objc public var percentage:Double
    @objc public var cents:Double
    @objc public var db: Double
    
    init(note: String, frequeny: Double, percentage: Double, cents: Double, db: Double) {
        self.note = note
        self.frequency = frequeny
        self.percentage = percentage
        self.cents = cents
        self.db = db
    }
    
    public override var description: String {
        return "note: \(self.note)"
    }
}

class SignalProcessing {
    static func rms(data: UnsafeMutablePointer<Float>, frameLength: UInt) -> Float {
        var val : Float = 0
        vDSP_rmsqv(data, 1, &val, frameLength)
        return val
    }
    
    static func rms(buffer: AVAudioPCMBuffer) -> Float? {
        guard let channelData = buffer.floatChannelData?[0] else {return nil}
        let frames = buffer.frameLength
        
        return SignalProcessing.rms(data: channelData, frameLength: UInt(frames))
    }
    
    
    static func calcDbValue(_ buffer: AVAudioPCMBuffer) -> Double {
        let channelData = buffer.floatChannelData![0]
        let scale: Float = 32767.0
        guard let rms = SignalProcessing.rms(buffer:buffer) else { return 0; }
        let ref_pressure = 51805.5336
        let p = Double(rms * scale) / ref_pressure
        let p0 = 0.0002
        let l = log10(p / p0)
        
        let db = 20.0 * l
        //print("rms:\(rms), db:\(db)")
        return db
    }
}

@objc public class PitchDetector : NSObject, PitchEngineDelegate {
    public func pitchEngine(_ pitchEngine: Beethoven.PitchEngine, didReceivePitch pitch: Pitchy.Pitch) {
        //print("did receive pitch: \(pitch.note.string) \(pitch.note.octave) \(pitch.closestOffset.frequency) \(pitch.closestOffset.percentage)")
        if (detectedOrder == dbBuffer.count) { return }
        let ts = detectDuration - (UInt32(dbBuffer.count) - detectedOrder - 1) * timeSlicePerDetection
        //print("ts \(ts) \(dbBuffer[Int(detectedOrder)])")
        self.pitch.append((pitch, ts, dbBuffer[Int(detectedOrder)]))
        detectedOrder = detectedOrder + 1
    }
    
    public func pitchEngine(_ pitchEngine: Beethoven.PitchEngine, didReceiveError error: Error) {
        
    }
    
    public func pitchEngineWentBelowLevelThreshold(_ pitchEngine: Beethoven.PitchEngine) {
        
    }
    
    let engine : PitchEngine
    let tracker : SignalTracker
    var pitch:[(Pitchy.Pitch, UInt32, Double)] = []
    
    var lastDetectTime:AVAudioTime?
    var detectDuration:UInt32 = 0
    var targetDetectionRate : UInt32 = 100
    var timeSlicePerDetection : UInt32 = 0
    var detectedOrder : UInt32 = 0
    var dbBuffer:[Double] = []
    
    public override init() {
        tracker = Tracker(bufferSize: 4096)
        engine = PitchEngine(config:Config(bufferSize: 4096))
        
        super.init()
        
        engine.delegate = self
    }
    private func calculateRMSValue(_ buffer: AVAudioPCMBuffer) -> Double {
        let channelData = buffer.floatChannelData![0]
        let frameLength = buffer.frameLength
        
        var rms: Float = 0.0
        
        // Calculate the sum of squares of each sample
        for i in 0..<Int(frameLength) {
            let sample = channelData[i]
            rms += sample * sample
        }
        
        // Divide by the number of samples and take the square root to get the RMS value
        rms /= Float(frameLength)
        rms = sqrt(rms)
        
        return Double(rms)
    }
    
    private func segment(of buffer: AVAudioPCMBuffer, from startFrame: AVAudioFramePosition, to endFrame: AVAudioFramePosition) -> AVAudioPCMBuffer {
        let framesToCopy = AVAudioFrameCount(endFrame - startFrame)
        
        let sampleSize = buffer.format.streamDescription.pointee.mBytesPerFrame
        
        let channelData = buffer.floatChannelData![0]
        let audioBuffer = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(framesToCopy * sampleSize), mData: channelData.advanced(by: Int(startFrame)))
        var bufferList = AudioBufferList(mNumberBuffers: 1, mBuffers: audioBuffer)
        let outputAudioBuffer = AVAudioPCMBuffer(pcmFormat: buffer.format, bufferListNoCopy: &bufferList)!
        
        return outputAudioBuffer
    }
    
    @objc public func detect(buffer:AVAudioPCMBuffer, atTime:AVAudioTime, duration:NSNumber) {
        lastDetectTime = atTime
        detectDuration = duration.uint32Value
        detectedOrder = 0
        
        let bufferSegmentParts = UInt32(ceil(Double(targetDetectionRate) / (atTime.sampleRate / Double(buffer.frameLength))))
        timeSlicePerDetection = UInt32((Double(buffer.frameLength) / atTime.sampleRate) * 1000 / Double(bufferSegmentParts))
        dbBuffer.removeAll()
        
        //print("detect() \(detectDuration)")
        let framesPerPart:UInt32 = buffer.frameLength / bufferSegmentParts
        //let refFrameTime:UInt32 = 20 // ms
        //let refFrameCount:UInt32 = refFrameTime * (UInt32(atTime.sampleRate) / 1000)
        let refFrameCount = UInt32(Double(framesPerPart) * 1.5)
        
        for i in 0..<bufferSegmentParts {
            let segment = self.segment(of: buffer,
                                       from: AVAudioFramePosition(max(0, Int(i * framesPerPart) - Int(refFrameCount))),
                                       to: AVAudioFramePosition(min(buffer.frameLength, (i+1) * framesPerPart + refFrameCount))
            )
            dbBuffer.append(SignalProcessing.calcDbValue(segment))
            engine.signalTracker(tracker, didReceiveBuffer: segment, atTime: atTime)
        }
    }
    
    @objc public var currentPitch : PitchWithTime? {
        if !self.pitch.isEmpty {
            let p = self.pitch.removeFirst()
            let pitch = p.0
            return PitchWithTime(pitch:Pitch(
                note: pitch.note.string,
                frequeny: pitch.note.frequency + pitch.closestOffset.frequency,
                percentage: pitch.closestOffset.percentage,
                cents: pitch.closestOffset.cents,
                db: p.2
            ), time: p.1)
        }
        
        return nil
    }
}

public class Tracker : SignalTracker {
    public var mode: SignalTrackerMode {
        return .record
    }
    public var levelThreshold: Float?
    
    public var peakLevel: Float?
    
    public var averageLevel: Float?
    
    public weak var delegate: Beethoven.SignalTrackerDelegate?
    private let bufferSize: AVAudioFrameCount
    
    required init(bufferSize: AVAudioFrameCount = 2048,
                  delegate: SignalTrackerDelegate? = nil) {
        self.bufferSize = bufferSize
        self.delegate = delegate
        //setupAudio()
    }
    
    public func start() {
        
    }
    
    public func stop() {
        
    }
}
