import AVFoundation
import AudioToolbox

/// LiveSkratch as an AUv3 effect (e.g. in AUM): a stereo insert whose LEFT input is the WOW and RIGHT input
/// is the live audio (swap with the "WOW on" setting). Output is the scratched live audio, in stereo.
public final class LiveSkratchAudioUnit: AUAudioUnit, ScratcherHost {
    private(set) var processor: Processor
    let isPlugin = true
    static let settingsKey = "LiveSkratchAUSettings"

    var settings: ScratcherSettings {
        didSet {
            settings.apply(to: processor)
            settings.save(key: LiveSkratchAudioUnit.settingsKey)
            ctrlRight = settings.ctrlChannel == 1
            syncParameters()
        }
    }
    var inputChannelNames: [String] { ["Left", "Right"] }
    var outputPairNames: [String] { ["Plugin output"] }
    var routeDescription: String { "Running inside a host: input and output routing is set there." }
    private(set) var loopName = ""

    private var inBus: AUAudioUnitBus!
    private var outBus: AUAudioUnitBus!
    private var _inputBusses: AUAudioUnitBusArray!
    private var _outputBusses: AUAudioUnitBusArray!
    private let loops = LoopSlot()
    private var inPCM: AVAudioPCMBuffer?
    private var inL: UnsafeMutablePointer<Float>?, inR: UnsafeMutablePointer<Float>?
    private var outL: UnsafeMutablePointer<Float>?, outR: UnsafeMutablePointer<Float>?
    private var frameCap = 0
    private var ctrlRight = false
    private var jumpHeld = false

    enum Param: AUParameterAddress { case crossfader = 0, cut, freeze, jump, outGain, source }

    public override init(componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions = []) throws {
        settings = ScratcherSettings.load(key: LiveSkratchAudioUnit.settingsKey)
        processor = Processor(sr: 48000)
        try super.init(componentDescription: componentDescription, options: options)
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        inBus = try AUAudioUnitBus(format: fmt); inBus.maximumChannelCount = 2
        outBus = try AUAudioUnitBus(format: fmt); outBus.maximumChannelCount = 2
        _inputBusses = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [inBus])
        _outputBusses = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outBus])
        maximumFramesToRender = 4096
        ctrlRight = settings.ctrlChannel == 1
        settings.apply(to: processor)
        loops.loadDefault(fileName: settings.loopFile, into: processor)
        loopName = loops.current?.name ?? ""
        parameterTree = makeParameterTree()
    }
    deinit { freeBuffers() }

    public override var inputBusses: AUAudioUnitBusArray { _inputBusses }
    public override var outputBusses: AUAudioUnitBusArray { _outputBusses }
    public override var channelCapabilities: [NSNumber]? { [2, 2] }
    public override var canProcessInPlace: Bool { false }
    public override var latency: TimeInterval { 0.0025 }   // the needle sits 2.5 ms behind live

    // MARK: state saved with the host's session

    public override var fullState: [String: Any]? {
        get {
            var s = super.fullState ?? [:]
            if let d = try? JSONEncoder().encode(settings) { s["liveskratch"] = d }
            return s
        }
        set {
            super.fullState = newValue
            if let d = newValue?["liveskratch"] as? Data, let st = ScratcherSettings.decodeLenient(d) { settings = st }
        }
    }

    // MARK: render resources

    public override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        let sr = outBus.format.sampleRate
        if abs(sr - processor.sr) > 1 {
            processor = Processor(sr: sr)
            settings.apply(to: processor)
            loops.loadDefault(fileName: settings.loopFile, into: processor)
        }
        freeBuffers()
        frameCap = Int(maximumFramesToRender)
        guard let f = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2),
              let pcm = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: AVAudioFrameCount(frameCap)),
              let ch = pcm.floatChannelData else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_FailedInitialization)) }
        inPCM = pcm; inL = ch[0]; inR = ch[1]
        outL = .allocate(capacity: frameCap); outL!.initialize(repeating: 0, count: frameCap)
        outR = .allocate(capacity: frameCap); outR!.initialize(repeating: 0, count: frameCap)
    }
    public override func deallocateRenderResources() {
        super.deallocateRenderResources()
        freeBuffers()
    }
    private func freeBuffers() {
        outL?.deallocate(); outR?.deallocate(); outL = nil; outR = nil
        inPCM = nil; inL = nil; inR = nil
    }

    public override var internalRenderBlock: AUInternalRenderBlock {
        return { [unowned self] flags, ts, frames, _, outputData, _, pullInput in
            guard let pullInput, let pcm = self.inPCM, let inL = self.inL, let inR = self.inR,
                  let outL = self.outL, let outR = self.outR else { return kAudioUnitErr_NoConnection }
            let n = min(Int(frames), self.frameCap)
            let abl = pcm.mutableAudioBufferList
            let list = UnsafeMutableAudioBufferListPointer(abl)
            if list.count >= 2 {
                list[0].mData = UnsafeMutableRawPointer(inL); list[0].mDataByteSize = UInt32(n * 4)
                list[1].mData = UnsafeMutableRawPointer(inR); list[1].mDataByteSize = UInt32(n * 4)
            }
            var pf = AudioUnitRenderActionFlags()
            let st = pullInput(&pf, ts, AUAudioFrameCount(n), 0, abl)
            if st != noErr { return st }
            // the host may hand back its own buffers
            let srcL = list[0].mData?.assumingMemoryBound(to: Float.self) ?? inL
            let srcR = list.count > 1 ? (list[1].mData?.assumingMemoryBound(to: Float.self) ?? inR) : srcL
            let ctrl = self.ctrlRight ? srcR : srcL, live = self.ctrlRight ? srcL : srcR
            self.processor.render(frames: n, ctrl: ctrl, liveL: live, liveR: live, outL: outL, outR: outR)
            let out = UnsafeMutableAudioBufferListPointer(outputData)
            for i in 0..<out.count {
                let src = i == 0 ? outL : outR
                if out[i].mData == nil { out[i].mData = UnsafeMutableRawPointer(src) }
                else { out[i].mData!.assumingMemoryBound(to: Float.self).update(from: src, count: n) }
                out[i].mDataByteSize = UInt32(n * 4)
            }
            return noErr
        }
    }

    // MARK: loop

    func setLoop(file: URL?) {
        if let file, let name = LoopLoader.importFile(file),
           let l = LoopLoader.load(url: LoopLoader.storeDir.appendingPathComponent(name), sampleRate: processor.sr) {
            loops.install(l, into: processor); settings.loopFile = name
        } else if file == nil {
            loops.install(TestLoop.synthetic(sampleRate: processor.sr), into: processor); settings.loopFile = nil
        }
        loopName = loops.current?.name ?? ""
    }

    // MARK: parameters (mappable to MIDI in the host)

    private func makeParameterTree() -> AUParameterTree {
        let rw: AudioUnitParameterOptions = [.flag_IsReadable, .flag_IsWritable]
        func p(_ id: String, _ name: String, _ a: Param, _ lo: Float, _ hi: Float, _ unit: AudioUnitParameterUnit,
               _ strings: [String]? = nil) -> AUParameter {
            AUParameterTree.createParameter(withIdentifier: id, name: name, address: a.rawValue, min: lo, max: hi,
                                            unit: unit, unitName: nil, flags: rw, valueStrings: strings, dependentParameters: nil)
        }
        let tree = AUParameterTree.createTree(withChildren: [
            p("crossfader", "Crossfader", .crossfader, 0, 1, .generic),
            p("cut", "Cut", .cut, 0, 1, .boolean),
            p("freeze", "Freeze", .freeze, 0, 1, .boolean),
            p("jump", "Jump to live", .jump, 0, 1, .boolean),
            p("gain", "Output gain", .outGain, 0, 2, .linearGain),
            p("source", "Source", .source, 0, 1, .indexed, ["Live input", "Loop"]),
        ])
        tree.implementorValueObserver = { [weak self] param, value in
            guard let self, let a = Param(rawValue: param.address) else { return }
            switch a {
            case .crossfader: if abs(self.settings.vfX - Double(value)) > 1e-4 { self.settings.vfX = Double(value) }
            case .cut: self.processor.softCut = value > 0.5
            case .freeze: self.processor.freezeTarget = value > 0.5
            case .jump:
                let on = value > 0.5
                if on && !self.jumpHeld { self.processor.jumpRequests += 1 }
                self.jumpHeld = on
            case .outGain: if abs(self.settings.outGain - Double(value)) > 1e-4 { self.settings.outGain = Double(value) }
            case .source: let loop = value > 0.5; if self.settings.testLoop != loop { self.settings.testLoop = loop }
            }
        }
        tree.implementorValueProvider = { [weak self] param in
            guard let self, let a = Param(rawValue: param.address) else { return 0 }
            switch a {
            case .crossfader: return Float(self.settings.vfX)
            case .cut: return self.processor.softCut ? 1 : 0
            case .freeze: return self.processor.freezeTarget ? 1 : 0
            case .jump: return self.jumpHeld ? 1 : 0
            case .outGain: return Float(self.settings.outGain)
            case .source: return self.settings.testLoop ? 1 : 0
            }
        }
        return tree
    }

    /// Keep host-visible parameter values in step with changes made in the plugin's own UI.
    private func syncParameters() {
        guard let tree = parameterTree else { return }
        let pairs: [(Param, Float)] = [(.crossfader, Float(settings.vfX)), (.outGain, Float(settings.outGain)),
                                       (.source, settings.testLoop ? 1 : 0)]
        for (a, v) in pairs {
            if let prm = tree.parameter(withAddress: a.rawValue), abs(prm.value - v) > 1e-4 {
                prm.setValue(v, originator: nil)
            }
        }
    }
}
