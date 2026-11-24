import SwiftUI
import WatchDogCore

/// The compact layout: the pomodoro timer and nothing else, in a small window
/// that floats above other apps. Opened from the Focus screen; the button in
/// its corner goes back to the full window.
struct CompactTimerView: View {
    let pomodoro: PomodoroTimer
    let tracker: Tracker

    static let windowID = "compact"

    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(spacing: 12) {
            if pomodoro.usesBuiltIn {
                builtIn
            } else {
                external
            }
            if let error = pomodoro.error {
                Label(error, systemImage: "exclamationmark.octagon.fill")
                    .font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 264)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { DockPresence.enter() }
        .onDisappear { DockPresence.leave() }
    }

    @ViewBuilder private var builtIn: some View {
        let machine = pomodoro.machine
        header(PomodoroText.headline(machine), symbol: PomodoroText.symbol(machine),
               tint: machine.isIdle ? AnyShapeStyle(.primary) : AnyShapeStyle(machine.phase.tint))
        PomodoroDial(timer: pomodoro, diameter: 150)
        HStack(spacing: 8) {
            RoundDots(machine: machine, settings: pomodoro.settings)
            Text(PomodoroText.round(machine, settings: pomodoro.settings))
                .font(.callout).foregroundStyle(.secondary)
        }
        if machine.phase == .focus && !pomodoro.categories.isEmpty {
            CategoryPicker(timer: pomodoro)
        }
        PomodoroControls(timer: pomodoro, compact: true)
        if let review = pomodoro.review {
            Divider()
            ReviewPanel(timer: pomodoro, session: review)
                .id(review.id)
        }
    }

    /// An external timer app is only read, so there is nothing to control here.
    @ViewBuilder private var external: some View {
        let reading = tracker.focusTimer
        header(TimerText.headline(reading), symbol: TimerText.symbol(reading),
               tint: AnyShapeStyle(Theme.color(for: reading.state)))
        // Reading `revision` keeps the countdown current as the tracker ticks.
        let _ = tracker.revision
        Text(TimerText.remaining(reading).map(Format.countdown) ?? "--:--")
            .font(.system(size: 40, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .frame(maxWidth: .infinity)
        Text("Start, pause and skip in \(pomodoro.externalApp?.name ?? "the timer app").")
            .font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func header(_ title: String, symbol: String, tint: AnyShapeStyle) -> some View {
        HStack(spacing: 8) {
            Label(title, systemImage: symbol)
                .fontWeight(.medium)
                .foregroundStyle(tint)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button("Open WatchDog", systemImage: "arrow.up.left.and.arrow.down.right") {
                openWindow(id: "main")
                dismissWindow(id: Self.windowID)
                NSApp.activate(ignoringOtherApps: true)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Back to the full window")
        }
    }
}
