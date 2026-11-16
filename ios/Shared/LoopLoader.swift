import AVFoundation

/// Loads any audio file (wav, aiff, mp3, m4a…) as the loop source, resampled to the engine rate, stereo.
enum LoopLoader {
    static let maxSeconds = 30.0

    static func load(url: URL, sampleRate sr: Double) -> TestLoop? {
        guard let f = try? AVAudioFile(forReading: url) else { return nil }
        let inFmt = f.processingFormat
        let inFrames = AVAudioFrameCount(min(Double(f.length), maxSeconds * inFmt.sampleRate))
        guard inFrames > 0, let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: inFrames) else { return nil }
        do { try f.read(into: inBuf, frameCount: inFrames) } catch { return nil }
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr, channels: 2, interleaved: false),
              let conv = AVAudioConverter(from: inFmt, to: target) else { return nil }
        if inFmt.channelCount == 1 { conv.channelMap = [0, 0] }    // mono → both sides
        let cap = AVAudioFrameCount(Double(inBuf.frameLength) * sr / inFmt.sampleRate) + 4096
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return nil }
        var fed = false
        var err: NSError?
        let status = conv.convert(to: outBuf, error: &err) { _, st in
            if fed { st.pointee = .endOfStream; return nil }
            fed = true; st.pointee = .haveData; return inBuf
        }
        guard status != .error, outBuf.frameLength > 0, let ch = outBuf.floatChannelData else { return nil }
        let n = Int(outBuf.frameLength)
        let data = UnsafeMutablePointer<Float>.allocate(capacity: n * 2)
        let r = target.channelCount > 1 ? ch[1] : ch[0]
        for i in 0..<n { data[2 * i] = ch[0][i]; data[2 * i + 1] = r[i] }
        return TestLoop(frames: n, data: data, name: url.deletingPathExtension().lastPathComponent)
    }

    /// Where the user's chosen loop is kept (a copy inside the app, so it loads on every launch).
    static var storeDir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LiveSkratch")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Copy a picked file into the app and return the stored copy's file name.
    static func importFile(_ url: URL) -> String? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let name = "loop-" + url.lastPathComponent
        let dst = storeDir.appendingPathComponent(name)
        // remove older imports
        for f in (try? FileManager.default.contentsOfDirectory(at: storeDir, includingPropertiesForKeys: nil)) ?? []
        where f.lastPathComponent.hasPrefix("loop-") { try? FileManager.default.removeItem(at: f) }
        do { try FileManager.default.copyItem(at: url, to: dst); return name } catch { return nil }
    }
}
