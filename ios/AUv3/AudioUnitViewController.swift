import CoreAudioKit
import SwiftUI

public final class AudioUnitViewController: AUViewController, AUAudioUnitFactory {
    private var audioUnit: LiveSkratchAudioUnit?
    private var hosting: UIHostingController<PluginRootView>?

    public override func viewDidLoad() {
        super.viewDidLoad()
        preferredContentSize = CGSize(width: 900, height: 640)
        connectUI()
    }

    nonisolated public func createAudioUnit(with componentDescription: AudioComponentDescription) throws -> AUAudioUnit {
        let au = try LiveSkratchAudioUnit(componentDescription: componentDescription, options: [])
        nonisolated(unsafe) let unit = au
        Task { @MainActor in self.attach(unit) }
        return au
    }

    private func attach(_ au: LiveSkratchAudioUnit) {
        audioUnit = au
        connectUI()
    }

    private func connectUI() {
        guard isViewLoaded, hosting == nil, let au = audioUnit else { return }
        let hc = UIHostingController(rootView: PluginRootView(model: ScratcherModel(host: au)))
        addChild(hc)
        hc.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hc.view)
        NSLayoutConstraint.activate([
            hc.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hc.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hc.view.topAnchor.constraint(equalTo: view.topAnchor),
            hc.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        hc.didMove(toParent: self)
        hosting = hc
    }
}

struct PluginRootView: View {
    @StateObject var model: ScratcherModel
    init(model: ScratcherModel) { _model = StateObject(wrappedValue: model) }

    var body: some View {
        ScratcherTabs(model: model) {
            Section {
                Picker("WOW tone on", selection: model.binding(\.ctrlChannel)) {
                    Text("Left input").tag(0); Text("Right input").tag(1)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Inputs")
            } footer: {
                Text("In AUM, make a stereo channel from two interface inputs, one the WOW and one the live audio, and insert LiveSkratch. The other side is what you scratch.")
            }
        }
    }
}
