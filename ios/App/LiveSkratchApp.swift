import SwiftUI

@main
struct LiveSkratchApp: App {
    @StateObject private var host = AppHost()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            ContentView(host: host)
                .onAppear { if !host.running { host.start() } }
        }
        .onChange(of: phase) { _, p in
            if p == .active && !host.running { host.start() }
        }
    }
}

struct ContentView: View {
    @ObservedObject var host: AppHost
    @StateObject private var model: ScratcherModel

    init(host: AppHost) {
        _host = ObservedObject(wrappedValue: host)
        _model = StateObject(wrappedValue: ScratcherModel(host: host))
    }

    var body: some View {
        ScratcherTabs(model: model, problem: host.problem) {
            RoutingSection(host: host, model: model)
            WowSetupSection()
        }
    }
}

struct RoutingSection: View {
    @ObservedObject var host: AppHost
    @ObservedObject var model: ScratcherModel

    var body: some View {
        Section {
            if host.inputChannelNames.isEmpty {
                Text("No inputs yet. Plug in an audio interface, and allow microphone access in Settings, to use the WOW and live audio.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                if model.settings.controlSignal == .timecode {
                    channelPicker("Timecode L", \.ctrlChannel)
                    channelPicker("Timecode R", \.ctrlChannelR)
                } else {
                    channelPicker("WOW input", \.ctrlChannel)
                }
                channelPicker("Live input L", \.liveLeft)
                channelPicker("Live input R", \.liveRight)
            }
            Picker("Output", selection: clamped(\.outPair, host.outputPairNames.count)) {
                ForEach(Array(host.outputPairNames.enumerated()), id: \.offset) { i, n in Text(n).tag(i) }
            }
            Button("Restart audio") { host.restart() }
        } header: {
            Text("Audio routing")
        } footer: {
            Text(host.routeDescription + "\nPick an output your interface doesn't mix with its direct monitoring, so you hear only the scratch.")
        }
    }

    /// A picker selection that always names an existing row (saved choices can outnumber the current device's channels).
    private func clamped(_ kp: WritableKeyPath<ScratcherSettings, Int>, _ count: Int) -> Binding<Int> {
        let b = model.binding(kp)
        return Binding(get: { min(b.wrappedValue, max(0, count - 1)) }, set: { b.wrappedValue = $0 })
    }

    private func channelPicker(_ label: String, _ kp: WritableKeyPath<ScratcherSettings, Int>) -> some View {
        Picker(label, selection: clamped(kp, host.inputChannelNames.count)) {
            ForEach(Array(host.inputChannelNames.enumerated()), id: \.offset) { i, n in Text("\(i + 1) · \(n)").tag(i) }
        }
    }
}

#Preview {
    ContentView(host: AppHost())
}
