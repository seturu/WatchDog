import SwiftUI
import WatchDogCore

/// Rules: the list on the left, the selected rule's editor on the right.
struct RulesView: View {
    @Bindable var runner: RuleRunner
    let tracker: Tracker

    @State private var selection: String?
    @State private var recentApps: [UsageTotal] = []

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) { DaemonNotices(runner: runner) }
                .padding(.horizontal, 16)
                .padding(.vertical, runner.pending == nil && runner.notice == nil && runner.penaltyDomains.isEmpty && runner.daemonReachable ? 0 : 10)
            content
        }
        .navigationTitle("Rules")
        .navigationSubtitle("\(runner.effective.rules.filter(\.isEnabled).count) active")
        .toolbar {
            ToolbarItemGroup {
                Button("New Rule", systemImage: "plus", action: add)
                    .help("Add a rule")
                Button("Delete Rule", systemImage: "trash", action: removeSelected)
                    .disabled(selection == nil)
                    .help("Delete the selected rule")
            }
            ModeSwitch(runner: runner)
        }
        .onAppear {
            if selection == nil { selection = runner.rules.first?.id }
            recentApps = (try? tracker.store.summary().apps) ?? []
        }
        .onChange(of: runner.rules) { runner.save() }
    }

    private var content: some View {
        HStack(spacing: 0) {
            List(selection: $selection) {
                ForEach($runner.rules) { $rule in
                    RuleRow(rule: $rule, status: statusLine(rule)).tag(rule.id)
                }
            }
            .listStyle(.inset)
            .frame(width: 300)

            Divider()

            if let index = runner.rules.firstIndex(where: { $0.id == selection }) {
                RuleEditor(rule: $runner.rules[index], runner: runner, recentApps: recentApps)
                    .id(runner.rules[index].id)   // fresh editor state per rule
            } else {
                ContentUnavailableView {
                    Label(runner.rules.isEmpty ? "No rules yet" : "No rule selected", systemImage: "checklist")
                } description: {
                    Text("A rule says what counts as a distraction, when, and how much of it is fine.")
                } actions: {
                    Button("New Rule", action: add)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func statusLine(_ rule: Rule) -> String {
        guard rule.isEnabled else { return "Off" }
        guard rule.schedule.contains(Date()) else { return "Outside its hours" }
        if let budget = runner.budgets[rule.id] {
            return "\(Format.short(budget.remaining)) of break budget left"
        }
        if rule.limitSeconds == 0 { return "Watching" }
        return "\(Format.short(runner.progress[rule.id] ?? 0)) of \(Format.short(TimeInterval(rule.limitSeconds)))"
    }

    private func add() {
        let rule = Rule(name: "New rule", isEnabled: false)
        runner.rules.append(rule)
        selection = rule.id
    }

    private func removeSelected() {
        runner.rules.removeAll { $0.id == selection }
        selection = runner.rules.first?.id
    }
}

private struct RuleRow: View {
    @Binding var rule: Rule
    let status: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: RuleText.symbol(rule))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background((rule.isEnabled ? RuleText.tint(rule) : Color.gray).gradient,
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.name.isEmpty ? "Untitled rule" : rule.name).lineLimit(1)
                Text(status).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
            Spacer(minLength: 4)
            Toggle("Enabled", isOn: $rule.isEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        .padding(.vertical, 4)
    }
}

private struct RuleEditor: View {
    @Binding var rule: Rule
    let runner: RuleRunner
    let recentApps: [UsageTotal]

    // Free text while typing; parsed into the rule's lists on every change.
    @State private var sites = ""
    @State private var apps = ""
    @State private var keywords = ""

    private static let weekdays = [(2, "Mon"), (3, "Tue"), (4, "Wed"), (5, "Thu"), (6, "Fri"), (7, "Sat"), (1, "Sun")]
    private static let windows = [(3600, "the last hour"), (7200, "the last 2 hours"), (14_400, "the last 4 hours"), (86_400, "the last 24 hours")]

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $rule.name)
                VStack(alignment: .leading, spacing: 8) {
                    Text(RuleText.sentence(rule))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    liveStatus
                }
                .padding(.vertical, 2)
            }

            Section("Applies to any of") {
                TextField("Sites", text: $sites, prompt: Text("youtube.com, reddit.com"))
                    .onChange(of: sites) { rule.domains = Self.parse(sites).map { $0.lowercased() } }
                LabeledContent("Apps") {
                    VStack(alignment: .trailing, spacing: 6) {
                        if rule.apps.isEmpty {
                            Text("None").foregroundStyle(.tertiary)
                        }
                        ForEach(rule.apps, id: \.self) { bundleID in
                            HStack(spacing: 6) {
                                AppIcon(bundleID: bundleID, size: 18)
                                Text(appName(bundleID))
                                Button("Remove", systemImage: "xmark.circle.fill") {
                                    apps = rule.apps.filter { $0 != bundleID }.joined(separator: ", ")
                                }
                                .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.tertiary)
                            }
                        }
                        Menu("Add App") {
                            ForEach(recentApps.filter { !rule.apps.contains($0.key) }) { app in
                                Button(app.label) { apps = (rule.apps + [app.key]).joined(separator: ", ") }
                            }
                        }
                        .fixedSize()
                        .disabled(recentApps.isEmpty)
                    }
                }
                .onChange(of: apps) { rule.apps = Self.parse(apps) }
                TextField("Window title contains", text: $keywords, prompt: Text("netflix, twitch"))
                    .onChange(of: keywords) { rule.titleKeywords = Self.parse(keywords) }
            }

            Section("When") {
                Picker("Active", selection: $rule.schedule.isAlways) {
                    Text("Always").tag(true)
                    Text("On a schedule").tag(false)
                }
                if !rule.schedule.isAlways {
                    LabeledContent("Days") {
                        HStack(spacing: 4) {
                            ForEach(Self.weekdays, id: \.0) { day, label in
                                let isOn = rule.schedule.weekdays.contains(day)
                                Button(label) {
                                    if isOn { rule.schedule.weekdays.remove(day) } else { rule.schedule.weekdays.insert(day) }
                                }
                                .buttonStyle(.plain)
                                .font(.callout.weight(isOn ? .semibold : .regular))
                                .foregroundStyle(isOn ? Color.white : Color.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary),
                                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .accessibilityAddTraits(isOn ? .isSelected : [])
                            }
                        }
                    }
                    DatePicker("From", selection: time(\.startMinute), displayedComponents: .hourAndMinute)
                    DatePicker("Until", selection: time(\.endMinute), displayedComponents: .hourAndMinute)
                }
                // "Pomodoro it" decides by the timer itself, so the extra condition is hidden.
                if rule.mode != .pomodoro {
                    Picker("Pomodoro timer", selection: $rule.timerCondition) {
                        Text("Any time").tag(Rule.TimerCondition?.none)
                        Text("Except during a break").tag(Rule.TimerCondition?.some(.exceptDuringBreak))
                        Text("Only during a focus session").tag(Rule.TimerCondition?.some(.duringFocus))
                        Text("Only during a break").tag(Rule.TimerCondition?.some(.duringBreak))
                    }
                }
            }

            Section("Limit") {
                Picker("Count time", selection: $rule.mode) {
                    Text("In one sitting").tag(Rule.Mode.continuous)
                    Text("In total").tag(Rule.Mode.cumulative)
                    Text("Pomodoro it").tag(Rule.Mode.pomodoro)
                }
                if rule.mode == .pomodoro {
                    Stepper("Focus interval: \(pomodoro.focusMinutes.wrappedValue) min", value: pomodoro.focusMinutes, in: 5...120, step: 5)
                    Stepper("Short break: \(pomodoro.shortBreakMinutes.wrappedValue) min", value: pomodoro.shortBreakMinutes, in: 1...30)
                    Stepper("Long break: \(pomodoro.longBreakMinutes.wrappedValue) min", value: pomodoro.longBreakMinutes, in: 5...60, step: 5)
                    Stepper("Long break every \(pomodoro.longBreakEvery.wrappedValue) intervals", value: pomodoro.longBreakEvery, in: 1...8)
                } else {
                    Stepper(rule.limitSeconds == 0 ? "Not allowed at all" : "Allow \(rule.limitSeconds / 60) min",
                            value: minutes(\.limitSeconds), in: 0...240)
                }
                if rule.mode == .cumulative {
                    Picker("Within", selection: $rule.windowSeconds) {
                        ForEach(Self.windows, id: \.0) { seconds, label in Text(label).tag(seconds) }
                    }
                }
            }

            Section("Then") {
                Picker("Response", selection: $rule.action) {
                    Text("Warn me").tag(Rule.Action.warn)
                    Text("Close it").tag(Rule.Action.close)
                    Text("Block it").tag(Rule.Action.block)
                }
                if rule.action == .block {
                    Stepper("Block for \(rule.blockMinutes) min", value: $rule.blockMinutes, in: 5...240, step: 5)
                }
                Stepper("Then stay quiet for \(rule.cooldownSeconds / 60) min", value: minutes(\.cooldownSeconds), in: 1...120)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            sites = rule.domains.joined(separator: ", ")
            apps = rule.apps.joined(separator: ", ")
            keywords = rule.titleKeywords.joined(separator: ", ")
        }
    }

    /// The rule's live state: a break-budget gauge, or progress toward a limit.
    @ViewBuilder private var liveStatus: some View {
        if !rule.isEnabled {
            Label("This rule is off", systemImage: "pause.circle").foregroundStyle(.secondary)
        } else if !rule.schedule.contains(Date()) {
            Label("Outside its hours right now", systemImage: "moon").foregroundStyle(.secondary)
        } else if let budget = runner.budgets[rule.id] {
            Gauge(value: budget.remaining, in: 0...max(budget.earned, 1)) {
                Text("Break budget")
            } currentValueLabel: {
                Text("\(Format.short(budget.remaining)) left")
            }
            .tint(Theme.onBreak)
            Text("\(Format.short(budget.earned)) earned · \(Format.short(budget.used)) used · now: \(budget.denial?.rawValue ?? "allowed")")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        } else if rule.limitSeconds > 0 {
            let done = runner.progress[rule.id] ?? 0
            ProgressView(value: min(done, TimeInterval(rule.limitSeconds)), total: TimeInterval(rule.limitSeconds)) {
                Text("\(Format.short(done)) of \(Format.short(TimeInterval(rule.limitSeconds)))")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            .tint(done >= TimeInterval(rule.limitSeconds) ? .red : .accentColor)
        }
    }

    private func appName(_ bundleID: String) -> String {
        recentApps.first { $0.key == bundleID }?.label
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?
                .deletingPathExtension().lastPathComponent
            ?? bundleID
    }

    /// The rule's pomodoro numbers, falling back to the classic rhythm.
    private var pomodoro: Binding<PomodoroSettings> {
        Binding(get: { rule.pomodoro ?? .classic }, set: { rule.pomodoro = $0 })
    }

    private static func parse(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// A seconds field shown and edited as whole minutes.
    private func minutes(_ field: WritableKeyPath<Rule, Int>) -> Binding<Int> {
        Binding(get: { rule[keyPath: field] / 60 }, set: { rule[keyPath: field] = $0 * 60 })
    }

    /// A minutes-after-midnight field shown and edited as a time of day.
    private func time(_ field: WritableKeyPath<Schedule, Int>) -> Binding<Date> {
        let midnight = Calendar.current.startOfDay(for: Date())
        return Binding(
            get: { midnight.addingTimeInterval(TimeInterval(rule.schedule[keyPath: field] * 60)) },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                rule.schedule[keyPath: field] = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            })
    }
}

/// Rules described in words.
enum RuleText {
    static func symbol(_ rule: Rule) -> String {
        switch rule.mode {
        case .pomodoro: "cup.and.saucer.fill"
        case .cumulative: "sum"
        case .continuous: rule.limitSeconds == 0 ? "nosign" : "hourglass"
        }
    }

    static func tint(_ rule: Rule) -> Color {
        switch rule.mode {
        case .pomodoro: Theme.onBreak
        case .cumulative: .purple
        case .continuous: rule.limitSeconds == 0 ? .red : .orange
        }
    }

    static func targets(_ rule: Rule) -> String {
        let apps = rule.apps.map {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)?
                .deletingPathExtension().lastPathComponent ?? $0
        }
        let titles = rule.titleKeywords.map { "windows titled “\($0)”" }
        let all = rule.domains + apps + titles
        return all.isEmpty ? "nothing yet" : all.formatted(.list(type: .or))
    }

    static func when(_ schedule: Schedule) -> String {
        if schedule.isAlways { return "At any time" }
        let days: String
        switch schedule.weekdays {
        case [2, 3, 4, 5, 6]: days = "On weekdays"
        case [1, 7]: days = "On weekends"
        case [1, 2, 3, 4, 5, 6, 7]: days = "Every day"
        case []: days = "On no day"
        default:
            let names = Calendar.current.shortWeekdaySymbols
            let ordered = [2, 3, 4, 5, 6, 7, 1].filter(schedule.weekdays.contains)
            days = "On " + ordered.map { names[$0 - 1] }.formatted(.list(type: .and))
        }
        return "\(days) from \(Format.timeOfDay(minutes: schedule.startMinute)) to \(Format.timeOfDay(minutes: schedule.endMinute))"
    }

    static func response(_ rule: Rule) -> String {
        switch rule.action {
        case .warn: "warn you"
        case .close: "close it"
        case .block: "block it for \(rule.blockMinutes) minutes"
        }
    }

    /// One readable sentence for the whole rule.
    static func sentence(_ rule: Rule) -> String {
        let what = targets(rule)
        let then = response(rule)
        let prefix = when(rule.schedule)
        switch rule.mode {
        case .pomodoro:
            let settings = rule.pomodoro ?? .classic
            let perHour = Int((settings.earnRatio * 60).rounded())
            return "\(prefix), \(what) is for breaks only. Each hour of focus earns \(perHour) minutes, "
                + "one break tops out at \(settings.longBreakMinutes), and the budget starts empty each day. "
                + "Otherwise WatchDog will \(then)."
        case .continuous, .cumulative:
            var condition = ""
            switch rule.timerCondition {
            case .exceptDuringBreak: condition = ", except during a break"
            case .duringFocus: condition = ", during a focus session"
            case .duringBreak: condition = ", during a break"
            case nil: break
            }
            if rule.limitSeconds == 0 {
                return "\(prefix)\(condition), \(what) is not allowed. WatchDog will \(then) straight away."
            }
            let amount = "\(rule.limitSeconds / 60) minutes"
            let scope = rule.mode == .continuous
                ? "in one sitting"
                : "within " + (rule.windowSeconds >= 86_400 ? "24 hours" : "\(rule.windowSeconds / 3600) hour\(rule.windowSeconds == 3600 ? "" : "s")")
            return "\(prefix)\(condition), \(what) is fine for \(amount) \(scope). After that WatchDog will \(then)."
        }
    }
}
