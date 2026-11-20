import SwiftUI

/// Milestone 0 window: one section per thing that has to work on this Mac
/// before the real app is built on top of it. Throwaway UI.
struct SpikePanel: View {
    @State private var model = SpikeModel()

    var body: some View {
        Form {
            Section("Tracking") {
                LabeledContent("Front app", value: model.frontApp)
                LabeledContent("Idle", value: model.idle)
                LabeledContent("Window title", value: model.windowTitle)
                if !model.accessibilityGranted {
                    Button("Grant Accessibility…") { model.requestAccessibility() }
                }
                LabeledContent("Brave address", value: model.braveURL)
                Button("Read Brave address") { model.readBraveURL() }
            }

            Section("Media") {
                LabeledContent("Making sound now", value: model.playingNow)
                LabeledContent("Last Spotify / Music event", value: model.lastMediaNotification)
            }

            Section {
                LabeledContent("Status", value: model.daemonStatus)
                HStack {
                    Button("Register") { model.registerDaemon() }
                    Button("Open Login Items") { model.openLoginItems() }
                    Button("Ping") { model.pingDaemon() }
                    Button("Unregister") { model.unregisterDaemon() }
                }
                if !model.daemonLog.isEmpty {
                    Text(model.daemonLog)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } header: {
                Text("Root daemon")
            } footer: {
                Text("Success is a ping answer starting with uid=0. Needs a build signed with your Apple ID; an ad-hoc build is expected to fail here.")
            }
        }
        .formStyle(.grouped)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }
}
