import Foundation

/// Switches a connected WOW between Normal and LiveSkratch mode by editing its card directly:
/// the same job as wow/scratcher-mode.command, but everything it keeps (the settings backup and your
/// parked beats/samples) lives on the WOW itself in a `LiveSkratch/` folder, so it travels with the device.
struct WowDrive {
    enum Mode: Equatable { case normal, liveSkratch, liveSkratchFromMacScript }
    enum WowError: LocalizedError {
        case notAWow, missingFolders, missingBundleFile(String), noBackup
        var errorDescription: String? {
            switch self {
            case .notAWow: return "That folder doesn't look like a WOW (no wow_settings.txt with fader settings)."
            case .missingFolders: return "Found the WOW settings, but no samples/ and beats/ folders next to them."
            case .missingBundleFile(let f): return "The app is missing \(f)."
            case .noBackup: return "No saved Normal settings were found on the WOW."
            }
        }
    }

    static let controlName = "00-liveskratch-control.wav"
    static let pilotName = "00-liveskratch-pilot.wav"
    static let legacyNames = ["00-scratcher-control.wav", "00-scratcher-pilot.wav"]
    static let marker = ".liveskratch-mode"
    static let legacyMarker = ".scratcher-mode"
    static let keepDir = "LiveSkratch"
    /// The four lines LiveSkratch changes. Normal values are restored from the backup.
    static let liveSkratchValues: [(String, String)] = [
        ("fader_left", "beat"), ("fader_right", "beat"), ("delay_strength", "0"), ("reverb_strength", "0")]

    let root: URL
    let settingsName: String
    private var fm: FileManager { .default }

    init(root: URL) throws {
        self.root = root
        guard let s = WowDrive.findSettings(in: root) else { throw WowError.notAWow }
        settingsName = s
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("samples").path, isDirectory: &isDir), isDir.boolValue,
              FileManager.default.fileExists(atPath: root.appendingPathComponent("beats").path, isDirectory: &isDir), isDir.boolValue
        else { throw WowError.missingFolders }
    }

    static func findSettings(in root: URL) -> String? {
        for name in ["wow_settings.txt", "settings.txt", "scsettings.txt"] {
            let u = root.appendingPathComponent(name)
            if let t = (try? String(contentsOf: u, encoding: .utf8)) ?? (try? String(contentsOf: u, encoding: .isoLatin1)),
               t.range(of: "wowmachine", options: .caseInsensitive) != nil || t.range(of: "fader_left") != nil { return name }
        }
        return nil
    }

    var settingsURL: URL { root.appendingPathComponent(settingsName) }
    var keepURL: URL { root.appendingPathComponent(WowDrive.keepDir) }
    var backupURL: URL { keepURL.appendingPathComponent("settings-normal.txt") }

    var mode: Mode {
        if fm.fileExists(atPath: root.appendingPathComponent(WowDrive.marker).path) { return .liveSkratch }
        if fm.fileExists(atPath: root.appendingPathComponent(WowDrive.legacyMarker).path) { return .liveSkratchFromMacScript }
        return .normal
    }

    /// Current values of the lines LiveSkratch touches (for display).
    func currentValues() -> [String: String] {
        guard let t = try? readSettings() else { return [:] }
        var out: [String: String] = [:]
        for (k, _) in WowDrive.liveSkratchValues {
            if let r = t.range(of: "(?m)^\(k)\\s*=\\s*([^\\r\\n]*)", options: .regularExpression) {
                let line = String(t[r]); out[k] = line.split(separator: "=", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) }
            }
        }
        return out
    }

    // MARK: switching

    /// Normal → LiveSkratch. Returns a short summary for the UI.
    @discardableResult
    func switchToLiveSkratch(control: URL, pilot: URL, park: Bool = true) throws -> String {
        guard fm.fileExists(atPath: control.path) else { throw WowError.missingBundleFile(WowDrive.controlName) }
        guard fm.fileExists(atPath: pilot.path) else { throw WowError.missingBundleFile(WowDrive.pilotName) }
        try fm.createDirectory(at: keepURL, withIntermediateDirectories: true)
        if mode == .normal { try copyReplacing(settingsURL, to: backupURL) }   // never overwrite a Normal backup with LiveSkratch values
        var parked = 0
        if park {
            for sub in ["samples", "beats"] {
                let dst = keepURL.appendingPathComponent("parked").appendingPathComponent(sub)
                try fm.createDirectory(at: dst, withIntermediateDirectories: true)
                for f in try audioFiles(in: root.appendingPathComponent(sub)) where !WowDrive.isOurs(f.lastPathComponent) {
                    try moveReplacing(f, to: dst.appendingPathComponent(f.lastPathComponent)); parked += 1
                }
            }
        }
        for legacy in WowDrive.legacyNames {   // tone files from the Mac script era
            try? fm.removeItem(at: root.appendingPathComponent("samples").appendingPathComponent(legacy))
            try? fm.removeItem(at: root.appendingPathComponent("beats").appendingPathComponent(legacy))
        }
        try copyReplacing(control, to: root.appendingPathComponent("samples").appendingPathComponent(WowDrive.controlName))
        try copyReplacing(pilot, to: root.appendingPathComponent("beats").appendingPathComponent(WowDrive.pilotName))
        var t = try readSettings()
        for (k, v) in WowDrive.liveSkratchValues { t = WowDrive.setKey(t, k, v) }
        try writeSettings(t)
        try? fm.removeItem(at: root.appendingPathComponent(WowDrive.legacyMarker))
        try Data(ISO8601DateFormatter().string(from: Date()).utf8).write(to: root.appendingPathComponent(WowDrive.marker))
        cleanDotFiles()
        return parked > 0 ? "LiveSkratch mode. Parked \(parked) file\(parked == 1 ? "" : "s") in LiveSkratch/parked on the WOW." : "LiveSkratch mode."
    }

    /// LiveSkratch → Normal. Restores the saved settings and every parked file.
    @discardableResult
    func switchToNormal() throws -> String {
        var note = ""
        if fm.fileExists(atPath: backupURL.path) {
            try copyReplacing(backupURL, to: settingsURL)
        } else {
            // switched by the Mac script, whose backup lives on that Mac: put the fader back on the sample at least
            var t = try readSettings()
            t = WowDrive.setKey(t, "fader_left", "sample"); t = WowDrive.setKey(t, "fader_right", "sample")
            try writeSettings(t)
            note = " The original settings backup is on the Mac that ran the script, so delay and reverb stay at 0."
        }
        for name in [WowDrive.controlName] + WowDrive.legacyNames {
            try? fm.removeItem(at: root.appendingPathComponent("samples").appendingPathComponent(name))
        }
        for name in [WowDrive.pilotName] + WowDrive.legacyNames {
            try? fm.removeItem(at: root.appendingPathComponent("beats").appendingPathComponent(name))
        }
        var restored = 0
        for sub in ["samples", "beats"] {
            let src = keepURL.appendingPathComponent("parked").appendingPathComponent(sub)
            for f in (try? fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil)) ?? [] where !f.lastPathComponent.hasPrefix(".") {
                try moveReplacing(f, to: root.appendingPathComponent(sub).appendingPathComponent(f.lastPathComponent)); restored += 1
            }
        }
        try? fm.removeItem(at: root.appendingPathComponent(WowDrive.marker))
        try? fm.removeItem(at: root.appendingPathComponent(WowDrive.legacyMarker))
        cleanDotFiles()
        return "Normal mode. Restored your settings" + (restored > 0 ? " and \(restored) file\(restored == 1 ? "" : "s")." : ".") + note
    }

    // MARK: helpers

    static func isOurs(_ name: String) -> Bool { name == controlName || name == pilotName || legacyNames.contains(name) }

    /// Set "key = value", keeping column alignment and the line ending.
    static func setKey(_ text: String, _ key: String, _ value: String) -> String {
        let esc = NSRegularExpression.escapedPattern(for: key)
        guard let re = try? NSRegularExpression(pattern: "(?m)^(\(esc)\\s*=\\s*)[^\\r\\n]*") else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return re.stringByReplacingMatches(in: text, range: range, withTemplate: "$1" + NSRegularExpression.escapedTemplate(for: value))
    }

    private func audioFiles(in dir: URL) throws -> [URL] {
        try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { !$0.lastPathComponent.hasPrefix(".") && ["wav", "mp3"].contains($0.pathExtension.lowercased()) }
    }
    private func readSettings() throws -> String {
        if let t = try? String(contentsOf: settingsURL, encoding: .utf8) { return t }
        return try String(contentsOf: settingsURL, encoding: .isoLatin1)
    }
    private func writeSettings(_ t: String) throws { try Data(t.utf8).write(to: settingsURL) }
    private func copyReplacing(_ src: URL, to dst: URL) throws {
        if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
        try fm.copyItem(at: src, to: dst)
    }
    private func moveReplacing(_ src: URL, to dst: URL) throws {
        if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
        try fm.moveItem(at: src, to: dst)
    }
    /// Remove macOS/iPadOS "._" metadata files the WOW might try to load as audio.
    private func cleanDotFiles() {
        for sub in ["samples", "beats", ""] {
            let dir = sub.isEmpty ? root : root.appendingPathComponent(sub)
            for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where f.lastPathComponent.hasPrefix("._") {
                try? fm.removeItem(at: f)
            }
        }
    }
}
