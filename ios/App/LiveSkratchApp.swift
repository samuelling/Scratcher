import SwiftUI

@main
struct LiveSkratchApp: App {
    @StateObject private var host = AppHost()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            ContentView(host: host)
                .preferredColorScheme(.dark)
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
        ScrollView {
            VStack(spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text("LiveSkratch").font(.largeTitle.weight(.heavy))
                    Text("scratch live audio with a WOW").foregroundStyle(.secondary)
                    Spacer()
                }
                if let p = host.problem {
                    Text(p).font(.callout).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading)
                }
                PerformView(model: model)
                RoutingCard(host: host, model: model)
                WowSetupCard()
                SettingsSections(model: model)
                Text("Also available as an Audio Unit (effect) in AUM and other hosts: insert “LiveSkratch” on a stereo channel with the WOW on the left input.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding()
        }
        .background(Color(white: 0.07))
    }
}

struct RoutingCard: View {
    @ObservedObject var host: AppHost
    @ObservedObject var model: ScratcherModel

    var body: some View {
        Card(title: "Audio routing") {
            Text(host.routeDescription).font(.caption).foregroundStyle(.secondary)
            if host.inputChannelNames.isEmpty {
                Text("No inputs. Plug in an audio interface (and allow microphone access in Settings) to use the WOW and live audio.")
                    .font(.callout)
            } else {
                channelPicker("WOW (control tone)", \.ctrlChannel)
                channelPicker("Live audio left", \.liveLeft)
                channelPicker("Live audio right", \.liveRight)
            }
            HStack {
                Text("Output to").frame(width: 150, alignment: .leading)
                Picker("Output to", selection: model.binding(\.outPair)) {
                    ForEach(Array(host.outputPairNames.enumerated()), id: \.offset) { i, n in Text(n).tag(i) }
                }.labelsHidden()
                Spacer()
                Button("Restart audio") { host.restart() }
            }
            Text("Tip: send the output to a pair your interface doesn't blend with its direct monitoring, so you hear only the scratch.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    func channelPicker(_ label: String, _ kp: WritableKeyPath<ScratcherSettings, Int>) -> some View {
        HStack {
            Text(label).frame(width: 150, alignment: .leading)
            Picker(label, selection: model.binding(kp)) {
                ForEach(Array(host.inputChannelNames.enumerated()), id: \.offset) { i, n in Text("\(i + 1): \(n)").tag(i) }
            }.labelsHidden()
            Spacer()
        }
    }
}
