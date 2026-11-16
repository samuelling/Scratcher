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
    /// Input buffers owned by us (AVAudioPCMBuffer's buffer-list getter resets the byte sizes, which made every pull fail).
    private var inABL: UnsafeMutableAudioBufferListPointer?
    private var inStore: UnsafeMutablePointer<Float>?
    private var inChans: [UnsafeMutablePointer<Float>] = []
    private let audioQueue = DispatchQueue(label: "liveskratch.audio-setup", qos: .userInitiated)
    private let maxFrames = 4096
    private let outL: UnsafeMutablePointer<Float>, outR: UnsafeMutablePointer<Float>
    // render-thread copies of the routing (plain Ints)
    private var inCh = 0, outCh = 2, rCtrl = 0, rCtrlR = 1, rLiveL = 1, rLiveR = 1, rPair = 0
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
    deinit { au?.stopHardware(); au?.deallocateRenderResources(); freeInput(); outL.deallocate(); outR.deallocate() }

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

    /// Audio session and unit setup can block for a while, so it runs on its own queue, never the main thread.
    func start() {
        if AVAudioApplication.shared.recordPermission == .undetermined {
            AVAudioApplication.requestRecordPermission { [weak self] _ in DispatchQueue.main.async { self?.start() } }
            return
        }
        let micOK = AVAudioApplication.shared.recordPermission == .granted
        audioQueue.async { [weak self] in self?.startOnQueue(micOK: micOK) }
    }
    func stop() { audioQueue.async { [weak self] in self?.stopOnQueue() } }
    func restart() {
        let micOK = AVAudioApplication.shared.recordPermission == .granted
        audioQueue.async { [weak self] in self?.stopOnQueue(); self?.startOnQueue(micOK: micOK) }
    }
    private func onMain(_ f: @escaping () -> Void) { DispatchQueue.main.async(execute: f) }

    private func startOnQueue(micOK: Bool) {
        if au != nil { return }
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
            let m = "Audio session: \(error.localizedDescription)"
            onMain { self.problem = m }; return
        }
        let sr = s.sampleRate
        DispatchQueue.main.sync {        // the UI reads the processor, so it is only ever swapped on the main thread
            if abs(sr - self.processor.sr) > 1 {
                self.processor = Processor(sr: sr)
                self.settings.apply(to: self.processor)
                self.loadLoop()
            }
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
                allocateInput(channels: inCh)
            } else { unit.isInputEnabled = false; freeInput() }
            if let f = AppHost.format(sr, outCh) { try unit.inputBusses[0].setFormat(f) }   // bus 0 in = our audio, to the outputs
            unit.isOutputEnabled = true
            unit.maximumFramesToRender = AUAudioFrameCount(maxFrames)
            unit.outputProvider = { [unowned self] flags, ts, frames, _, data in
                self.render(flags, ts, frames, data)
            }
            try unit.allocateRenderResources()
            pull = unit.renderBlock
            let settingsNow = DispatchQueue.main.sync { self.settings }
            updateRouting(settingsNow)
            try unit.startHardware()
            au = unit
            onMain { self.running = true; self.problem = nil }
        } catch {
            let m = "Couldn't start audio: \(error.localizedDescription)"
            onMain { self.problem = m; self.running = false }
        }
        let route = describeRoute(micOK: micOK)
        onMain {
            self.inputChannelNames = route.ins; self.outputPairNames = route.outs; self.routeDescription = route.text
        }
    }

    private func stopOnQueue() {
        au?.stopHardware()
        au?.deallocateRenderResources()
        au = nil; pull = nil
        onMain { self.running = false }
    }

    private func allocateInput(channels n: Int) {
        freeInput()
        let store = UnsafeMutablePointer<Float>.allocate(capacity: n * maxFrames)
        store.initialize(repeating: 0, count: n * maxFrames)
        inStore = store
        inChans = (0..<n).map { store + $0 * maxFrames }
        inABL = AudioBufferList.allocate(maximumBuffers: n)
    }
    private func freeInput() {
        inChans = []
        if let l = inABL { free(l.unsafeMutablePointer) }; inABL = nil
        inStore?.deallocate(); inStore = nil
    }

    static func format(_ sr: Double, _ ch: Int) -> AVAudioFormat? {
        guard let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(ch)) else { return nil }
        return AVAudioFormat(standardFormatWithSampleRate: sr, channelLayout: layout)
    }

    private func describeRoute(micOK: Bool) -> (ins: [String], outs: [String], text: String) {
        let r = AVAudioSession.sharedInstance().currentRoute
        var names: [String] = []
        for port in r.inputs { for c in port.channels ?? [] { names.append(c.channelName) } }
        while names.count < inCh { names.append("Input \(names.count + 1)") }
        let insOut = Array(names.prefix(inCh))
        var outs: [String] = []
        for port in r.outputs { for c in port.channels ?? [] { outs.append(c.channelName) } }
        while outs.count < outCh { outs.append("Output \(outs.count + 1)") }
        var pairs: [String] = []
        var i = 0
        while i < outCh {
            pairs.append(i + 1 < outCh ? "\(i + 1)–\(i + 2): \(outs[i]) / \(outs[i + 1])" : "\(i + 1): \(outs[i])"); i += 2
        }
        let ins = r.inputs.map(\.portName).joined(separator: ", "), outn = r.outputs.map(\.portName).joined(separator: ", ")
        let s = AVAudioSession.sharedInstance()
        let text = String(format: "In: %@ (%ld ch) · Out: %@ (%ld ch) · %.0f kHz · %.1f ms buffer",
                                  micOK ? (ins.isEmpty ? "none" : ins) : "microphone access off", inCh,
                                  outn, outCh, s.sampleRate / 1000, s.ioBufferDuration * 1000)
        return (insOut, pairs, text)
    }

    private func updateRouting(_ st: ScratcherSettings? = nil) {
        let st = st ?? settings
        let last = max(0, inCh - 1)
        rCtrl = min(st.ctrlChannel, last)
        rCtrlR = min(st.ctrlChannelR, last)
        rLiveL = min(st.liveLeft, last)
        rLiveR = min(st.liveRight, last)
        rPair = min(st.outPair, max(0, (outCh - 1) / 2))
    }

    // MARK: render (audio thread)

    private func render(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, _ ts: UnsafePointer<AudioTimeStamp>,
                        _ frames: AUAudioFrameCount, _ data: UnsafeMutablePointer<AudioBufferList>) -> AUAudioUnitStatus {
        let n = min(Int(frames), maxFrames)
        var ctrl: UnsafePointer<Float>? = nil, ctrlR: UnsafePointer<Float>? = nil
        var liveL: UnsafePointer<Float>? = nil, liveR: UnsafePointer<Float>? = nil
        if inCh > 0, let list = inABL, let pull, inChans.count == inCh {
            for i in 0..<inCh {
                list[i].mNumberChannels = 1
                list[i].mData = UnsafeMutableRawPointer(inChans[i])
                list[i].mDataByteSize = UInt32(n * MemoryLayout<Float>.size)
            }
            var pf = AudioUnitRenderActionFlags()
            if pull(&pf, ts, AUAudioFrameCount(n), 1, list.unsafeMutablePointer, nil) == noErr {
                // the unit may hand back its own buffers
                func ch(_ i: Int) -> UnsafePointer<Float> {
                    UnsafePointer(list[i].mData?.assumingMemoryBound(to: Float.self) ?? inChans[i])
                }
                ctrl = ch(rCtrl); ctrlR = ch(rCtrlR); liveL = ch(rLiveL); liveR = ch(rLiveR)
            }
        }
        processor.render(frames: n, ctrl: ctrl, ctrlR: ctrlR, liveL: liveL, liveR: liveR, outL: outL, outR: outR)
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
