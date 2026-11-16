import SwiftUI

// MARK: - Help content

enum HelpTopic: String, Identifiable {
    case scratch, setup, feel
    var id: String { rawValue }
}

struct HelpSection: Identifiable {
    let title: String
    let items: [HelpItem]
    var id: String { title }
    init(_ title: String, _ items: [HelpItem]) { self.title = title; self.items = items }
}

struct HelpItem: Identifiable {
    let icon: String, title: String, text: String
    var id: String { title }
}

enum HelpText {
    static func title(_ t: HelpTopic) -> String {
        switch t { case .scratch: return "The Scratch screen"; case .setup: return "Setup"; case .feel: return "Feel" }
    }

    static func sections(_ t: HelpTopic, plugin: Bool) -> [HelpSection] {
        switch t {
        case .scratch:
            return [
                HelpSection("Watching", [
                    HelpItem(icon: "opticaldisc", title: "Platter",
                             text: "Turns with your WOW's platter. With Virtual platter on (Setup tab), drag it with your finger to scratch."),
                    HelpItem(icon: "gauge.with.dots.needle.33percent", title: "Speed, direction, behind live",
                             text: "Speed is in multiples of normal (1× = motor speed). Behind live is how far the needle sits behind the audio coming in right now."),
                    HelpItem(icon: "waveform", title: "Tape strip",
                             text: "The last 11 seconds of incoming audio. The orange line is the needle; when frozen, the blue area is the loop you're scratching."),
                    HelpItem(icon: "checkmark.circle", title: "Status badges",
                             text: "Tone: the WOW's control tone is coming in. 1×: the platter is at normal speed, so playback locks to live. Calibrated: the app has measured your WOW."),
                ]),
                HelpSection("Playing", [
                    HelpItem(icon: "slider.horizontal.below.rectangle", title: "Crossfader",
                             text: "An on-screen fader. By default it works together with the WOW's own fader: sound plays only when both are open. Change this in Feel."),
                    HelpItem(icon: "scissors", title: "Cut",
                             text: "Silent while you hold it, like slamming the fader shut."),
                    HelpItem(icon: "snowflake", title: "Freeze",
                             text: "Stops taking in new audio, so the last few seconds become a fixed loop you can scratch over and over. Tap again to go back to live."),
                    HelpItem(icon: "forward.end.fill", title: "Live",
                             text: "Jumps the needle back to right now. After a scratch it also snaps back by itself once the platter is back at 1× (Feel tab)."),
                ]),
            ]
        case .setup:
            var sections: [HelpSection] = []
            if plugin {
                sections.append(HelpSection("In AUM or another host", [
                    HelpItem(icon: "cable.connector", title: "Inputs",
                             text: "Make a stereo channel from two interface inputs: one carries the WOW, the other the audio you want to scratch. Insert LiveSkratch on it and choose which side the WOW is on."),
                    HelpItem(icon: "pianokeys", title: "MIDI",
                             text: "Crossfader, Cut, Freeze, Jump to live, Output gain and Source are plugin parameters: map them to MIDI in your host."),
                ]))
            } else {
                sections.append(HelpSection("Audio routing", [
                    HelpItem(icon: "cable.connector", title: "Inputs",
                             text: "Plug the WOW into one input of your audio interface and the audio you want to scratch into another. Then pick them here: WOW input, and Live input L and R (the same channel twice for a mono source)."),
                    HelpItem(icon: "speaker.wave.2", title: "Output",
                             text: "Pick an output your interface doesn't mix with its own direct monitoring, or turn direct monitoring off, so you hear only the scratch and not the raw tone."),
                ]))
                sections.append(HelpSection("WOW setup", [
                    HelpItem(icon: "externaldrive", title: "Choose the WOW drive (once)",
                             text: "Plug the WOW into this device with USB-C so it shows up in Files. Tap Choose the WOW drive, then Browse → Locations → the WOW, and tap Open while you're inside it."),
                    HelpItem(icon: "arrow.left.arrow.right", title: "Normal ↔ LiveSkratch",
                             text: "LiveSkratch mode puts your own beats and samples aside on the WOW, loads the control tone and pilot beat, and sets the fader to cut the beat. Normal puts everything back exactly as it was."),
                    HelpItem(icon: "eject", title: "Then eject and restart",
                             text: "After switching, eject the WOW in Files and turn it off and on: it only reads its files when it starts."),
                ]))
            }
            sections.append(HelpSection("Getting ready", [
                HelpItem(icon: "repeat", title: "What you scratch",
                         text: "Loop plays a built-in “ahhh / fresh” loop, or any audio file you load, so you can practise without other gear. Live input scratches whatever comes in from your interface."),
                HelpItem(icon: "hand.draw", title: "Virtual platter",
                         text: "Scratch by dragging the on-screen platter. No WOW needed."),
                HelpItem(icon: "scope", title: "Calibrate",
                         text: "Do this once per session: WOW in LiveSkratch mode, motor on, hands off, fader open, then tap Calibrate. It measures the WOW's exact speed and levels."),
                HelpItem(icon: "waveform.badge.magnifyingglass", title: "Diagnostics",
                         text: "Records 10 seconds of what the app hears and plays. Share it if something doesn't sound right."),
            ]))
            return sections
        case .feel:
            return [
                HelpSection("WOW fader", [
                    HelpItem(icon: "dial.medium", title: "Fader",
                             text: "Which faders control the sound: the WOW's own fader, the on-screen one, both, or neither."),
                    HelpItem(icon: "dot.radiowaves.right", title: "Read WOW fader by",
                             text: "Pilot tone (recommended): the WOW's fader cuts a high pilot beat, so the platter keeps being tracked through every cut. Tone level is for a WOW set up without the pilot."),
                    HelpItem(icon: "line.diagonal", title: "Cut point, Fully open",
                             text: "Where along the WOW fader's travel the sound starts and reaches full volume."),
                    HelpItem(icon: "waveform.path.badge.minus", title: "Tone gate",
                             text: "Below this level the platter counts as stopped. Raise it if a stopped record slowly drifts."),
                ]),
                HelpSection("On-screen crossfader", [
                    HelpItem(icon: "slider.horizontal.3", title: "Cut-in, Curve, Hamster",
                             text: "Cut-in is how far you move before sound starts; Curve is how quickly it reaches full volume; Hamster flips the direction."),
                ]),
                HelpSection("Feel", [
                    HelpItem(icon: "waveform.path", title: "Smoothing",
                             text: "Lower is tighter and more immediate; higher is smoother but slightly laggy."),
                    HelpItem(icon: "arrow.uturn.forward", title: "After a scratch",
                             text: "Snap back returns to live audio once the platter is back at normal speed (after the snap delay). Stay behind keeps playing from where you left the needle."),
                    HelpItem(icon: "lock", title: "Lock to exactly 1×",
                             text: "When the platter runs at motor speed, play exactly in time with live audio so it never drifts."),
                    HelpItem(icon: "snowflake", title: "Freeze loop",
                             text: "How many seconds Freeze holds on to."),
                ]),
            ]
        }
    }
}

// MARK: - Help sheet

struct HelpSheet: View {
    let topic: HelpTopic
    let plugin: Bool
    var onWalkthrough: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(HelpText.sections(topic, plugin: plugin)) { section in
                    Section(section.title) {
                        ForEach(section.items) { item in
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: item.icon).foregroundStyle(accent).frame(width: 26)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.title).font(.subheadline.weight(.semibold))
                                    Text(item.text).font(.footnote).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                if let onWalkthrough, !plugin {
                    Section {
                        Button { onWalkthrough() } label: { Label("Show the first-time walkthrough", systemImage: "play.rectangle") }
                    }
                }
            }
            .navigationTitle(HelpText.title(topic))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
    }
}

struct HelpButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: "questionmark.circle").font(.title3) }
            .accessibilityLabel("Help")
    }
}

// MARK: - First-time walkthrough

struct WalkthroughPage: Identifiable {
    let icon: String, title: String
    let steps: [String]
    var id: String { title }
}

struct WalkthroughView: View {
    @ObservedObject var model: ScratcherModel
    var onDone: () -> Void
    @State private var page = 0

    private let pages: [WalkthroughPage] = [
        WalkthroughPage(icon: "opticaldisc", title: "Scratch anything, live", steps: [
            "Your WOW plays a control tone instead of music.",
            "LiveSkratch reads the platter's every move from that tone and scratches whatever audio is coming in right now: a synth, a mic, a drum machine.",
            "No gear yet? Try the built-in loop with the on-screen platter.",
        ]),
        WalkthroughPage(icon: "externaldrive.fill", title: "1 · Put the WOW in LiveSkratch mode", steps: [
            "Plug the WOW into this device with USB-C.",
            "Setup tab → WOW setup → Choose the WOW drive. In Files: Browse → Locations → the WOW, then Open.",
            "Flip the switch to LiveSkratch.",
            "Eject the WOW in Files and restart it. Switch back to Normal the same way whenever you like: your beats and samples come back exactly as they were.",
        ]),
        WalkthroughPage(icon: "cable.connector", title: "2 · Plug in", steps: [
            "Connect your audio interface.",
            "WOW output → one input. The audio you want to scratch → another input.",
            "Setup tab → Audio routing: pick the WOW input, the live inputs, and an output.",
            "What you scratch → Live input.",
        ]),
        WalkthroughPage(icon: "scope", title: "3 · Calibrate", steps: [
            "Start the WOW's motor and let it spin.",
            "Hands off the platter, fader open.",
            "Setup tab → Calibrate. It takes 1.5 seconds and measures your WOW's exact speed and levels.",
        ]),
        WalkthroughPage(icon: "hand.draw.fill", title: "4 · Scratch", steps: [
            "Scratch tab: move the record and the live audio moves with it.",
            "The WOW's fader and the on-screen crossfader both cut the sound. Hold Cut to silence, Freeze to hold a loop, Live to jump back to now.",
            "Fine-tune the fader and feel in the Feel tab.",
            "Tap ? on any screen for help.",
        ]),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Skip") { onDone() }.foregroundStyle(.secondary)
            }
            .padding()
            TabView(selection: $page) {
                ForEach(Array(pages.enumerated()), id: \.offset) { i, p in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            Image(systemName: p.icon).font(.system(size: 44)).foregroundStyle(accent)
                            Text(p.title).font(.title2.weight(.bold))
                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(p.steps, id: \.self) { s in
                                    HStack(alignment: .top, spacing: 10) {
                                        Circle().fill(accent).frame(width: 6, height: 6).padding(.top, 7)
                                        Text(s).fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                            if i == 0 {
                                Button {
                                    var s = model.settings
                                    s.virtualPlatter = true; s.testLoop = true
                                    model.settings = s
                                    onDone()
                                } label: {
                                    Label("Try it now with the on-screen platter", systemImage: "hand.draw")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                                .padding(.top, 8)
                            }
                        }
                        .padding(.horizontal, 28)
                        .frame(maxWidth: 520, alignment: .leading)
                        .frame(maxWidth: .infinity)
                    }
                    .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
            Button {
                if page < pages.count - 1 { withAnimation { page += 1 } } else { onDone() }
            } label: {
                Text(page < pages.count - 1 ? "Next" : "Start scratching")
                    .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .padding()
        }
        .background(Color(white: 0.06))
        .tint(accent)
        .preferredColorScheme(.dark)
    }
}
