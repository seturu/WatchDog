import SwiftUI
import WatchDogCore

// Building blocks for the built-in pomodoro timer, shared by the Focus screen
// and the menu-bar popover. In the popover the buttons use Liquid Glass (the
// navigation layer); in the main window they are ordinary buttons on content.

/// What the built-in timer is doing, in words.
enum PomodoroText {
    static func headline(_ machine: PomodoroMachine) -> String {
        switch machine.status {
        case .idle:
            switch machine.phase {
            case .focus: return "Ready to focus"
            case .shortBreak: return "Time for a short break"
            case .longBreak: return "Time for a long break"
            }
        case .running:
            return machine.phase.title
        case .paused:
            return machine.phase.isBreak ? "Break paused" : "Focus paused"
        }
    }

    static func symbol(_ machine: PomodoroMachine) -> String {
        if machine.isPaused { return "pause.circle" }
        return machine.phase.isBreak ? "cup.and.saucer.fill" : "timer"
    }

    /// "Session 2 of 4", or where the round stands during a break.
    static func round(_ machine: PomodoroMachine, settings: BuiltInTimerSettings) -> String {
        let length = settings.roundLength
        if machine.phase == .longBreak { return "Round of \(length) done" }
        if machine.phase.isBreak { return "\(machine.completedInRound) of \(length) done" }
        return "Session \(min(machine.completedInRound + 1, length)) of \(length)"
    }
}

/// Start, pause, resume, skip and stop, as the moment allows.
struct PomodoroControls: View {
    let timer: PomodoroTimer
    /// Glass buttons, with skip and stop as icons.
    var inPopover = false

    var body: some View {
        let machine = timer.machine
        HStack(spacing: 8) {
            switch machine.status {
            case .idle:
                primary(machine.phase.isBreak ? "Start Break" : "Start Focus", "play.fill") { timer.startOrResume() }
                if machine.phase.isBreak {
                    secondary("Skip Break", "forward.end.fill", help: "Go straight to the next focus session") { timer.skip() }
                }
            case .running:
                primary("Pause", "pause.fill") { timer.pause() }
                skipAndStop(machine)
            case .paused:
                primary("Resume", "play.fill") { timer.resume() }
                skipAndStop(machine)
            }
        }
        .controlSize(inPopover ? .regular : .large)
    }

    @ViewBuilder private func skipAndStop(_ machine: PomodoroMachine) -> some View {
        secondary("Skip", "forward.end.fill",
                  help: machine.phase.isBreak ? "End the break now" : "End this session now; it does not count toward the long break") {
            timer.skip()
        }
        secondary("Stop", "stop.fill", help: "End the session and the round") { timer.stop() }
    }

    @ViewBuilder private func primary(_ title: String, _ symbol: String, action: @escaping @MainActor () -> Void) -> some View {
        let button = Button(action: action) {
            Label(title, systemImage: symbol).frame(maxWidth: inPopover ? .infinity : nil)
        }
        if inPopover { button.buttonStyle(.glassProminent) } else { button.buttonStyle(.borderedProminent) }
    }

    @ViewBuilder private func secondary(_ title: String, _ symbol: String, help: String,
                                        action: @escaping @MainActor () -> Void) -> some View {
        if inPopover {
            Button(title, systemImage: symbol, action: action)
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .help(help)
        } else {
            Button(title, systemImage: symbol, action: action)
                .buttonStyle(.bordered)
                .help(help)
        }
    }
}

/// Chooses the category of the running focus session, or of the next one.
struct CategoryPicker: View {
    let timer: PomodoroTimer

    var body: some View {
        HStack(spacing: 8) {
            CategoryDot(color: timer.selectedCategory?.color)
            Picker("Category", selection: Binding(get: { timer.machine.categoryID }, set: { timer.setCategory($0) })) {
                Text("No category").tag(Int64?.none)
                if !timer.categories.isEmpty { Divider() }
                ForEach(timer.categories) { category in
                    Text(category.name).tag(category.id)
                }
            }
            .labelsHidden()
            .fixedSize()
            .help("Category of this focus session")
        }
    }
}

/// One dot per focus session in a round: done, current, to come.
struct RoundDots: View {
    let machine: PomodoroMachine
    let settings: BuiltInTimerSettings

    var body: some View {
        let length = settings.roundLength
        let done = machine.phase == .longBreak ? length : min(machine.completedInRound, length)
        HStack(spacing: 5) {
            ForEach(0..<length, id: \.self) { index in
                Circle()
                    .fill(index < done ? AnyShapeStyle(Theme.focus)
                          : index == done && machine.phase == .focus && !machine.isIdle ? AnyShapeStyle(Theme.focus.opacity(0.4))
                          : AnyShapeStyle(.quaternary))
                    .frame(width: 7, height: 7)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(PomodoroText.round(machine, settings: settings))
    }
}

/// The ring and countdown on the Focus screen.
struct PomodoroDial: View {
    let timer: PomodoroTimer
    var diameter: CGFloat = 168

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let machine = timer.machine
            let planned = machine.isIdle ? timer.settings.seconds(for: machine.phase) : machine.plannedSeconds
            let left = machine.isIdle ? planned : timer.remaining()
            let progress = planned > 0 ? 1 - left / planned : 0
            ZStack {
                Circle().stroke(.quaternary, lineWidth: 10)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(machine.phase.tint.opacity(machine.isPaused ? 0.5 : 1),
                            style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: progress)
                VStack(spacing: 2) {
                    Text(Format.countdown(left))
                        .font(.system(size: diameter * 0.2, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText(countsDown: true))
                    Text(machine.phase.title)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: diameter, height: diameter)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(PomodoroText.headline(machine)), \(Format.short(left)) left")
        }
    }
}

/// "How did it go?": the rating and an optional note for the session that
/// just ended. Both save as soon as they change and can be edited later.
struct ReviewPanel: View {
    let timer: PomodoroTimer
    let session: FocusSession
    var inPopover = false

    @State private var rating: SessionRating
    @State private var note: String

    init(timer: PomodoroTimer, session: FocusSession, inPopover: Bool = false) {
        self.timer = timer
        self.session = session
        self.inPopover = inPopover
        _rating = State(initialValue: session.rating)
        _note = State(initialValue: session.note ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("How did it go?").font(inPopover ? .subheadline.weight(.semibold) : .headline)
                Spacer()
                Text(summary).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Picker("Rating", selection: $rating) {
                ForEach(SessionRating.shown, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: rating) { save() }
            // The same session may be rated in the popover and the main window.
            .onChange(of: session.rating) { rating = session.rating }
            HStack(spacing: 8) {
                TextField("Add a note (optional)", text: $note, axis: .vertical)
                    .lineLimit(1...3)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                if inPopover {
                    Button("Done") { finish() }.buttonStyle(.glass)
                } else {
                    Button("Done") { finish() }
                }
            }
        }
        .onDisappear(perform: save)
    }

    private var summary: String {
        let name = session.categoryID.flatMap { timer.categoryByID[$0]?.name }
        return [name, Format.short(session.focusedSeconds)].compactMap { $0 }.joined(separator: " · ")
    }

    /// Saves straight to the session, so a note typed but not submitted is
    /// kept even when the next focus session has already taken the panel away.
    private func save() {
        guard let id = session.id else { return }
        timer.rate(id, rating: rating, note: note)
    }

    private func finish() {
        save()
        timer.dismissReview()
    }
}

/// One past session in the history.
struct SessionRow: View {
    let session: FocusSession
    let category: SessionCategory?

    var body: some View {
        HStack(spacing: 10) {
            CategoryDot(color: category?.color)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(category?.name ?? "No category")
                        .foregroundStyle(category == nil ? .secondary : .primary)
                    if !session.completed {
                        Text("ended early").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                if let note = session.note {
                    Text(note).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            Image(systemName: session.rating.symbol)
                .foregroundStyle(session.rating.tint)
                .help(session.rating.title)
            VStack(alignment: .trailing, spacing: 1) {
                Text(Format.short(session.focusedSeconds)).monospacedDigit()
                Text(Format.clock(session.startedAt)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            .frame(minWidth: 54, alignment: .trailing)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(category?.name ?? "No category"), \(session.rating.title), \(Format.short(session.focusedSeconds))"
                            + (session.note.map { ", \($0)" } ?? ""))
    }
}

/// Edits a past session: rating, note, category.
struct SessionEditor: View {
    let timer: PomodoroTimer
    let session: FocusSession

    @Environment(\.dismiss) private var dismiss
    @State private var rating: SessionRating
    @State private var note: String
    @State private var categoryID: Int64?
    @State private var confirmingDelete = false

    init(timer: PomodoroTimer, session: FocusSession) {
        self.timer = timer
        self.session = session
        _rating = State(initialValue: session.rating)
        _note = State(initialValue: session.note ?? "")
        _categoryID = State(initialValue: session.categoryID)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    LabeledContent("Started", value: session.startedAt.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("Length", value: length)
                }
                Section {
                    Picker("Category", selection: $categoryID) {
                        Text("No category").tag(Int64?.none)
                        ForEach(choices) { category in
                            Text(category.isArchived ? "\(category.name) (removed)" : category.name).tag(category.id)
                        }
                    }
                    Picker("Rating", selection: $rating) {
                        ForEach(SessionRating.shown, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    TextField("Note", text: $note, prompt: Text("Optional"), axis: .vertical)
                        .lineLimit(3...6)
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Delete Session…", role: .destructive) { confirmingDelete = true }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    if let id = session.id { timer.update(id: id, rating: rating, note: note, categoryID: categoryID) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
        // A grouped form scrolls, so give the sheet a size of its own.
        .frame(width: 440, height: 420)
        .confirmationDialog("Delete this session from the history?", isPresented: $confirmingDelete) {
            Button("Delete Session", role: .destructive) {
                timer.delete(session)
                dismiss()
            }
        }
    }

    /// Categories on offer, plus the session's own if it has since been removed.
    private var choices: [SessionCategory] {
        var list = timer.categories
        if let id = session.categoryID, !list.contains(where: { $0.id == id }), let removed = timer.categoryByID[id] {
            list.append(removed)
        }
        return list
    }

    private var length: String {
        let ran = Format.short(session.focusedSeconds)
        return session.completed ? ran : "\(ran) of \(Format.short(session.plannedSeconds)), ended early"
    }
}

/// A grid of category colours, shown in a popover.
struct ColorGrid: View {
    let selection: CategoryColor
    let choose: @MainActor (CategoryColor) -> Void

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(26), spacing: 6), count: 7), spacing: 6) {
            ForEach(CategoryColor.allCases, id: \.self) { color in
                Button { choose(color) } label: {
                    Circle()
                        .fill(color.color)
                        .frame(width: 18, height: 18)
                        .padding(4)
                        // A ring around the chosen one, visible on every colour and in both modes.
                        .overlay {
                            if color == selection { Circle().strokeBorder(.primary.opacity(0.75), lineWidth: 2) }
                        }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(color.name)
                .accessibilityLabel(color.name)
                .accessibilityAddTraits(color == selection ? .isSelected : [])
            }
        }
        .padding(12)
    }
}
