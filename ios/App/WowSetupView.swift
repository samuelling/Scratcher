import SwiftUI
import UniformTypeIdentifiers

/// One-switch WOW setup: pick the WOW's drive once in Files, then flip between Normal and LiveSkratch.
final class WowSetup: ObservableObject {
    @Published var driveName: String? = nil
    @Published var mode: WowDrive.Mode? = nil
    @Published var values: [String: String] = [:]
    @Published var message: String? = nil
    @Published var ok = true
    @Published var busy = false
    @Published var park = true
    private var url: URL? = nil
    private let bookmarkKey = "LiveSkratchWowBookmark"

    init() { restore() }

    private func restore() {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return }
        var stale = false
        guard let u = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale) else { return }
        url = u
        if stale, let fresh = withAccess(u, { try? u.bookmarkData() }) { UserDefaults.standard.set(fresh, forKey: bookmarkKey) }
        refresh()
    }

    /// The user picked a folder: the WOW drive itself, or any folder on it.
    func choose(_ picked: URL) {
        guard picked.startAccessingSecurityScopedResource() else { fail("Couldn't open that folder."); return }
        defer { picked.stopAccessingSecurityScopedResource() }
        do {
            _ = try WowDrive(root: picked)
            UserDefaults.standard.set(try picked.bookmarkData(), forKey: bookmarkKey)
            url = picked
            message = nil; ok = true
            refresh()
        } catch { fail(error.localizedDescription) }
    }

    func refresh() {
        guard let url else { driveName = nil; mode = nil; return }
        withAccess(url) {
            if let d = try? WowDrive(root: url) {
                driveName = url.lastPathComponent; mode = d.mode; values = d.currentValues()
            } else {
                driveName = url.lastPathComponent; mode = nil; values = [:]
                message = "Can't see the WOW right now. Is it plugged in and showing in Files?"; ok = false
            }
        }
    }

    func setLiveSkratch(_ on: Bool) {
        guard let url else { return }
        let control = Bundle.main.url(forResource: "00-liveskratch-control", withExtension: "wav")
        let pilot = Bundle.main.url(forResource: "00-liveskratch-pilot", withExtension: "wav")
        busy = true
        let park = self.park
        DispatchQueue.global(qos: .userInitiated).async {
            var msg = "", good = true
            self.withAccess(url) {
                do {
                    let d = try WowDrive(root: url)
                    if on {
                        guard let control, let pilot else { throw WowDrive.WowError.missingBundleFile("the tone files") }
                        msg = try d.switchToLiveSkratch(control: control, pilot: pilot, park: park)
                        msg += " Eject the WOW in Files, then restart it."
                    } else {
                        msg = try d.switchToNormal() + " Eject the WOW in Files, then restart it."
                    }
                } catch { msg = error.localizedDescription; good = false }
            }
            DispatchQueue.main.async {
                self.busy = false; self.message = msg; self.ok = good
                self.refresh()
                if good { self.message = msg }
            }
        }
    }

    private func fail(_ m: String) { message = m; ok = false }

    @discardableResult
    private func withAccess<T>(_ u: URL, _ body: () -> T) -> T {
        let s = u.startAccessingSecurityScopedResource()
        defer { if s { u.stopAccessingSecurityScopedResource() } }
        return body()
    }
}

struct WowSetupSection: View {
    @StateObject private var wow = WowSetup()
    @State private var picking = false

    var body: some View {
        Section {
            if wow.driveName == nil {
                Button { picking = true } label: { Label("Choose the WOW drive…", systemImage: "externaldrive.badge.plus") }
            } else {
                LabeledContent {
                    Text(wow.driveName ?? "").lineLimit(1).truncationMode(.middle)
                } label: {
                    Label("WOW", systemImage: "externaldrive.fill")
                }
                if let mode = wow.mode {
                    let on = mode != .normal
                    Picker("Mode", selection: Binding(get: { on }, set: { wow.setLiveSkratch($0) })) {
                        Text("Normal").tag(false); Text("LiveSkratch").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .disabled(wow.busy)
                    if !on { Toggle("Put my beats & samples aside", isOn: $wow.park) }
                }
                HStack {
                    Button("Check again") { wow.refresh() }.buttonStyle(.borderless)
                    Spacer()
                    Button("Change drive…") { picking = true }.buttonStyle(.borderless)
                }
            }
            if wow.busy { ProgressView() }
            if let m = wow.message {
                Text(m).font(.footnote).foregroundStyle(wow.ok ? .green : .orange)
            }
            if let u = Bundle.main.url(forResource: "00-liveskratch-control", withExtension: "wav") {
                ShareLink(item: u) { Label("Share the control tone", systemImage: "waveform") }
            }
            if let u = Bundle.main.url(forResource: "00-liveskratch-pilot", withExtension: "wav") {
                ShareLink(item: u) { Label("Share the pilot beat", systemImage: "waveform") }
            }
            if let u = Bundle.main.url(forResource: "00-liveskratch-timecode", withExtension: "wav") {
                ShareLink(item: u) { Label("Share the stereo timecode (SC-1000 / SC-500)", systemImage: "waveform.path") }
            }
        } header: {
            Text("WOW setup")
        } footer: {
            Text(wow.driveName == nil
                 ? "Plug the WOW in with USB-C so it shows up in Files, then choose its drive. You only do this once."
                 : wow.mode == .normal
                    ? "Normal: your own beats, samples and settings. Switching puts them aside in a LiveSkratch folder on the WOW and puts them back when you switch back. Eject the WOW in Files and restart it after switching."
                    : "LiveSkratch: control tone as the sample, pilot as the beat, fader cuts the beat, effects off. Eject the WOW in Files and restart it after switching.")
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { r in
            if case .success(let url) = r { wow.choose(url) }
        }
    }
}
