import SwiftUI
import WatchDogCore

/// Shown instead of the main window when the app could not open its usage
/// database. Without tracking the app cannot judge anything, and if rules are
/// being enforced the daemon will notice the silence and block their sites.
/// So this screen must still offer the way back to dry run, which otherwise
/// lives in a window that cannot open.
struct StartupFailureView: View {
    let message: String
    @State private var status: String?

    var body: some View {
        ContentUnavailableView {
            Label("WatchDog could not start", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
            if let status { Text(status) }
        } actions: {
            Button("Switch to Dry Run") {
                Task {
                    guard let daemon = await DaemonClient.status(), let config = daemon.config else {
                        status = "The background service did not answer."
                        return
                    }
                    let answer = await DaemonClient.propose(
                        DaemonConfig(rules: config.rules, isEnforcing: false, usePacketFilter: config.packetFilterOn))
                    status = answer?.message ?? "The background service did not answer."
                }
            }
        }
        .frame(minWidth: 520, minHeight: 320)
    }
}
