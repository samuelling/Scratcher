import AVFoundation
import AudioToolbox
import Combine

/// The standalone app's audio: RemoteIO with every input and output channel of the interface,
/// the WOW on one input, live audio on one or two others, the result on a chosen output pair.
final class AppHost: ObservableObject, ScratcherHost {
    private(set) var processor: Processor
    let isPlugin = false
    static let settingsKey = "LiveSkratchSettings"

    var settings: ScratcherSettings {
        didSet {
            settings.apply(to: processor)
            settings.save(key: AppHost.settingsKey)
            updateRouting()
        }
    }
    @Published private(set) var inputChannelNames: [String] = []
    @Published private(set) var outputPairNames: [String] = ["Outputs 1–2"]
    @Published private(set) var routeDescription = "Starting audio…"
    @Published private(set) var running = false
    @Published private(set) var loopName = ""
    @Published var problem: String? = nil

    private let loops = LoopSlot()
    private var au: AUAudioUnit?
    private var pull: AURenderBlock?
    private var inBuf: AVAudioPCMBuffer?
    private let maxFrames = 4096
    private let outL: UnsafeMutablePointer<Float>, outR: UnsafeMutablePointer<Float>
    // render-thread copies of the routing (plain Ints)
    private var inCh = 0, outCh = 2, rCtrl = 0, rLiveL = 1, rLiveR = 1, rPair = 0
    private var observers: [NSObjectProtocol] = []

    init() {
        settings = ScratcherSettings.load(key: AppHost.settingsKey)
        processor = Processor(sr: 48000)
        outL = .allocate(capacity: maxFrames); outL.initialize(repeating: 0, count: maxFrames)
        outR = .allocate(capacity: maxFrames); outR.initialize(repeating: 0, count: maxFrames)
        settings.apply(to: processor)
        loadLoop()
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] n in
            guard let self, let raw = n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
            if reason == .newDeviceAvailable || reason == .oldDeviceUnavailable || reason == .override { self.restart() }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            guard let self, let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            if type == .ended { self.restart() }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            self?.restart()
        })
    }
    deinit { stop(); outL.deallocate(); outR.deallocate() }

    // MARK: loop

    private func loadLoop() {
        if !loops.loadDefault(fileName: settings.loopFile, into: processor) {
            problem = "Couldn't open your saved loop, so the built-in loop is playing."
        }
        loopName = loops.current?.name ?? ""
    }
    func setLoop(file: URL?) {
        if let file {
            guard let name = LoopLoader.importFile(file),
                  let l = LoopLoader.load(url: LoopLoader.storeDir.appendingPathComponent(name), sampleRate: processor.sr) else {
                problem = "That file couldn't be read as audio."; return
            }
            loops.install(l, into: processor)
            settings.loopFile = name
        } else {
            settings.loopFile = nil
            loops.install(TestLoop.synthetic(sampleRate: processor.sr), into: processor)
        }
        loopName = loops.current?.name ?? ""
    }

    // MARK: start / stop

    func start() {
        if AVAudioApplication.shared.recordPermission == .undetermined {
            AVAudioApplication.requestRecordPermission { [weak self] _ in DispatchQueue.main.async { self?.start() } }
            return
        }
        let micOK = AVAudioApplication.shared.recordPermission == .granted
        let s = AVAudioSession.sharedInstance()
        do {
            try s.setCategory(micOK ? .playAndRecord : .playback, mode: .measurement,
                              options: micOK ? [.defaultToSpeaker, .allowBluetoothA2DP] : [])
            try? s.setPreferredSampleRate(48000)
            try? s.setPreferredIOBufferDuration(0.0025)     // ~120 frames: as low as the hardware allows
            try s.setActive(true)
            if micOK { try? s.setPreferredInputNumberOfChannels(s.maximumInputNumberOfChannels) }
            try? s.setPreferredOutputNumberOfChannels(s.maximumOutputNumberOfChannels)
        } catch {
            problem = "Audio session: \(error.localizedDescription)"; return
        }
        let sr = s.sampleRate
        if abs(sr - processor.sr) > 1 {
            processor = Processor(sr: sr)
            settings.apply(to: processor)
            loadLoop()
        }
        inCh = micOK ? s.inputNumberOfChannels : 0
        outCh = max(1, s.outputNumberOfChannels)
        do {
            let desc = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_RemoteIO,
                                                 componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
            let unit = try AUAudioUnit(componentDescription: desc)
            if inCh > 0, let f = AppHost.format(sr, inCh) {
                try unit.outputBusses[1].setFormat(f)          // bus 1 out = audio from the inputs, to us
                unit.isInputEnabled = true
                inBuf = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: AVAudioFrameCount(maxFrames))
            } else { unit.isInputEnabled = false; inBuf = nil }
            if let f = AppHost.format(sr, outCh) { try unit.inputBusses[0].setFormat(f) }   // bus 0 in = our audio, to the outputs
            unit.isOutputEnabled = true
            unit.maximumFramesToRender = AUAudioFrameCount(maxFrames)
            unit.outputProvider = { [unowned self] flags, ts, frames, _, data in
                self.render(flags, ts, frames, data)
            }
            try unit.allocateRenderResources()
            pull = unit.renderBlock
            try unit.startHardware()
            au = unit
            running = true
            problem = nil
        } catch {
            problem = "Couldn't start audio: \(error.localizedDescription)"
            running = false
        }
        describeRoute(micOK: micOK)
        updateRouting()
    }

    func stop() {
        au?.stopHardware()
        au?.deallocateRenderResources()
        au = nil; pull = nil
        running = false
    }
    func restart() { stop(); start() }

    static func format(_ sr: Double, _ ch: Int) -> AVAudioFormat? {
        guard let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(ch)) else { return nil }
        return AVAudioFormat(standardFormatWithSampleRate: sr, channelLayout: layout)
    }

    private func describeRoute(micOK: Bool) {
        let r = AVAudioSession.sharedInstance().currentRoute
        var names: [String] = []
        for port in r.inputs { for c in port.channels ?? [] { names.append(c.channelName) } }
        while names.count < inCh { names.append("Input \(names.count + 1)") }
        inputChannelNames = Array(names.prefix(inCh))
        var outs: [String] = []
        for port in r.outputs { for c in port.channels ?? [] { outs.append(c.channelName) } }
        while outs.count < outCh { outs.append("Output \(outs.count + 1)") }
        var pairs: [String] = []
        var i = 0
        while i < outCh {
            pairs.append(i + 1 < outCh ? "\(i + 1)–\(i + 2): \(outs[i]) / \(outs[i + 1])" : "\(i + 1): \(outs[i])"); i += 2
        }
        outputPairNames = pairs
        let ins = r.inputs.map(\.portName).joined(separator: ", "), outn = r.outputs.map(\.portName).joined(separator: ", ")
        let s = AVAudioSession.sharedInstance()
        routeDescription = String(format: "In: %@ (%ld ch) · Out: %@ (%ld ch) · %.0f kHz · %.1f ms buffer",
                                  micOK ? (ins.isEmpty ? "none" : ins) : "microphone access off", inCh,
                                  outn, outCh, s.sampleRate / 1000, s.ioBufferDuration * 1000)
    }

    private func updateRouting() {
        let last = max(0, inCh - 1)
        rCtrl = min(settings.ctrlChannel, last)
        rLiveL = min(settings.liveLeft, last)
        rLiveR = min(settings.liveRight, last)
        rPair = min(settings.outPair, max(0, (outCh - 1) / 2))
    }

    // MARK: render (audio thread)

    private func render(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, _ ts: UnsafePointer<AudioTimeStamp>,
                        _ frames: AUAudioFrameCount, _ data: UnsafeMutablePointer<AudioBufferList>) -> AUAudioUnitStatus {
        let n = min(Int(frames), maxFrames)
        var ctrl: UnsafePointer<Float>? = nil, liveL: UnsafePointer<Float>? = nil, liveR: UnsafePointer<Float>? = nil
        if inCh > 0, let ib = inBuf, let pull, let ch = ib.floatChannelData {
            let list = UnsafeMutableAudioBufferListPointer(ib.mutableAudioBufferList)
            for i in 0..<list.count {
                list[i].mData = UnsafeMutableRawPointer(ch[i])
                list[i].mDataByteSize = UInt32(n * MemoryLayout<Float>.size)
            }
            var pf = AudioUnitRenderActionFlags()
            if pull(&pf, ts, AUAudioFrameCount(n), 1, ib.mutableAudioBufferList, nil) == noErr {
                ctrl = UnsafePointer(ch[rCtrl]); liveL = UnsafePointer(ch[rLiveL]); liveR = UnsafePointer(ch[rLiveR])
            }
        }
        processor.render(frames: n, ctrl: ctrl, liveL: liveL, liveR: liveR, outL: outL, outR: outR)
        let out = UnsafeMutableAudioBufferListPointer(data)
        for i in 0..<out.count {
            guard let p = out[i].mData?.assumingMemoryBound(to: Float.self) else { continue }
            if i == 2 * rPair { p.update(from: outL, count: n) }
            else if i == 2 * rPair + 1 { p.update(from: outR, count: n) }
            else { p.update(repeating: 0, count: n) }
        }
        return noErr
    }
}
