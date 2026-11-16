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

struct WowSetupCard: View {
    @StateObject private var wow = WowSetup()
    @State private var picking = false

    var body: some View {
        Card(title: "WOW setup") {
            if wow.driveName == nil {
                Text("Plug the WOW into the iPad with USB-C so it shows up in Files, then choose its drive. You only do this once.")
                    .font(.callout)
                Button("Choose the WOW drive…") { picking = true }.buttonStyle(.borderedProminent).tint(accent)
            } else {
                HStack {
                    Image(systemName: "externaldrive.fill")
                    Text(wow.driveName ?? "").font(.headline)
                    Spacer()
                    Button("Check again") { wow.refresh() }
                    Button("Change…") { picking = true }
                }
                if let mode = wow.mode {
                    let on = mode != .normal
                    Picker("Mode", selection: Binding(get: { on }, set: { wow.setLiveSkratch($0) })) {
                        Text("Normal").tag(false); Text("LiveSkratch").tag(true)
                    }
                    .pickerStyle(.segmented).disabled(wow.busy)
                    Text(on ? "Sample = the control tone, beat = the fader pilot, fader cuts the beat, effects off."
                            : "Your own beats, samples and settings.")
                        .font(.caption).foregroundStyle(.secondary)
                    if !on { Toggle("Park my beats and samples while in LiveSkratch mode (recommended)", isOn: $wow.park) }
                    if !wow.values.isEmpty {
                        Text(wow.values.sorted { $0.key < $1.key }.map { "\($0.key) = \($0.value)" }.joined(separator: "   "))
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
            }
            if wow.busy { ProgressView() }
            if let m = wow.message {
                Text(m).font(.callout).foregroundStyle(wow.ok ? .green : .orange)
            }
            DisclosureGroup("Set it up by hand instead") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Put the control tone in the WOW's samples folder and the pilot in beats, then set fader_left and fader_right to beat and delay/reverb strength to 0 in wow_settings.txt.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        if let u = Bundle.main.url(forResource: "00-liveskratch-control", withExtension: "wav") {
                            ShareLink(item: u) { Label("Control tone", systemImage: "waveform") }
                        }
                        if let u = Bundle.main.url(forResource: "00-liveskratch-pilot", withExtension: "wav") {
                            ShareLink(item: u) { Label("Pilot beat", systemImage: "waveform") }
                        }
                    }
                }
            }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { r in
            if case .success(let url) = r { wow.choose(url) }
        }
    }
}
