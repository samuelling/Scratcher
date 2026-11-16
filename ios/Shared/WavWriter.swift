import Foundation

enum WavWriter {
    /// 32-bit float WAV (format 3) to a temp file; returns its URL.
    static func writeFloat(interleaved: UnsafePointer<Float>, frames: Int, channels: Int, sampleRate: Double, name: String) -> URL? {
        let dataBytes = frames * channels * 4
        var d = Data(capacity: 44 + dataBytes)
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + dataBytes)); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(3); u16(UInt16(channels)); u32(UInt32(sampleRate))
        u32(UInt32(sampleRate) * UInt32(channels * 4)); u16(UInt16(channels * 4)); u16(32)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(dataBytes))
        d.append(UnsafeBufferPointer(start: interleaved, count: frames * channels))
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(stamp).wav")
        do { try d.write(to: url); return url } catch { return nil }
    }
}
