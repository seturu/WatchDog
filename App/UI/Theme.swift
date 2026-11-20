import SwiftUI
import WatchDogCore

/// Shared visual vocabulary, so every screen uses the same radii, spacing and
/// colours. System colours and materials only: the app follows light/dark
/// mode, accent colour and accessibility settings without extra work.
enum Theme {
    static let cornerRadius: CGFloat = 14
    static let gap: CGFloat = 16

    static let focus = Color.indigo
    static let onBreak = Color.green
    static let away = Color.gray
    static let warning = Color.orange

    /// Colours for chart series, busiest first.
    private static let seriesColors: [Color] = [.blue, .purple, .pink, .orange, .teal, .mint]

    static func seriesColor(_ index: Int, name: String) -> Color {
        name == DaySummary.otherSeries ? Color.gray.opacity(0.45) : seriesColors[index % seriesColors.count]
    }

    static func color(for state: TimerState) -> Color {
        switch state {
        case .focus: focus
        case .onBreak: onBreak
        case .none: .secondary
        }
    }
}

/// A titled surface. Content sits on a quiet filled shape rather than on
/// glass: Liquid Glass is for the navigation layer (sidebar, toolbar,
/// popover), not for the content itself.
struct Card<Content: View, Accessory: View>: View {
    var title: String?
    var systemImage: String?
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                HStack(alignment: .firstTextBaseline) {
                    Label {
                        Text(title)
                    } icon: {
                        if let systemImage { Image(systemName: systemImage).foregroundStyle(.secondary) }
                    }
                    .font(.headline)
                    Spacer(minLength: 8)
                    accessory
                }
            }
            content
        }
        .padding(Theme.gap)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .strokeBorder(.separator.opacity(0.5), lineWidth: 0.5)
        }
    }
}

extension Card where Accessory == EmptyView {
    init(_ title: String? = nil, systemImage: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, systemImage: systemImage, accessory: { EmptyView() }, content: content)
    }
}

/// One headline number.
struct StatTile: View {
    let title: String
    let value: String
    let systemImage: String
    var tint: Color = .accentColor
    var caption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(title).foregroundStyle(.secondary)
            } icon: {
                Image(systemName: systemImage).foregroundStyle(tint)
            }
            .font(.subheadline.weight(.medium))

            Text(value)
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Text(caption ?? " ")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(Theme.gap)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .strokeBorder(.separator.opacity(0.5), lineWidth: 0.5)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The real icon of an installed app, looked up by bundle ID.
struct AppIcon: View {
    let bundleID: String
    var size: CGFloat = 24

    var body: some View {
        if let image = IconCache.icon(for: bundleID) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "app.dashed")
                .font(.system(size: size * 0.75))
                .foregroundStyle(.tertiary)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }
}

@MainActor
private enum IconCache {
    private static var cache: [String: NSImage?] = [:]

    static func icon(for bundleID: String) -> NSImage? {
        if let cached = cache[bundleID] { return cached }
        let image = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        cache[bundleID] = image
        return image
    }
}

/// A site has no local icon (fetching one would mean a network request), so it
/// gets a monogram on a colour that is always the same for the same domain.
struct SiteIcon: View {
    let domain: String
    var size: CGFloat = 24

    private static let colors: [Color] = [.red, .orange, .green, .teal, .blue, .indigo, .purple, .pink, .brown]

    var body: some View {
        let seed = domain.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(Self.colors[seed % Self.colors.count].gradient)
            .frame(width: size, height: size)
            .overlay {
                Text(String(domain.prefix(1)).uppercased())
                    .font(.system(size: size * 0.52, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

/// "Focus", "Break" or nothing, as a small coloured capsule.
struct TimerBadge: View {
    let state: TimerState

    var body: some View {
        if state != .none {
            Text(state == .focus ? "Focus" : "Break")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .foregroundStyle(Theme.color(for: state))
                .background(Theme.color(for: state).opacity(0.15), in: Capsule())
        }
    }
}

/// A row with an icon, a name, a proportional bar and a duration.
struct UsageRow<Icon: View>: View {
    let label: String
    let seconds: TimeInterval
    /// The largest value in the list; this row's bar is drawn relative to it.
    let maximum: TimeInterval
    var tint: Color = .accentColor
    @ViewBuilder var icon: Icon

    var body: some View {
        HStack(spacing: 10) {
            icon
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(label).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(Format.short(seconds))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
                GeometryReader { proxy in
                    Capsule()
                        .fill(tint.gradient)
                        .frame(width: max(4, proxy.size.width * (maximum > 0 ? seconds / maximum : 0)))
                }
                .frame(height: 4)
                .background(.quaternary.opacity(0.5), in: Capsule())
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(Format.short(seconds))")
    }
}

/// Text describing a pomodoro timer reading.
enum TimerText {
    /// Seconds left in the running interval; nil when unknown or already over.
    static func remaining(_ reading: TimerReading, now: Date = Date()) -> TimeInterval? {
        // The built-in timer knows (it leaves pauses out); Session gives a start and a length.
        if let left = reading.remainingSeconds { return left > 0 ? left : nil }
        guard let start = reading.startedAt, let length = reading.durationSeconds else { return nil }
        let left = TimeInterval(length) - now.timeIntervalSince(start)
        return left > 0 ? left : nil
    }

    static func headline(_ reading: TimerReading) -> String {
        if reading.isPaused { return reading.shownInterval == .onBreak ? "Break paused" : "Focus paused" }
        switch reading.state {
        case .focus: return "Focus session"
        case .onBreak: return "On a break"
        case .none: return "No timer running"
        }
    }

    static func detail(_ reading: TimerReading, now: Date = Date()) -> String? {
        guard reading.state != .none || reading.isPaused else { return nil }
        let name = reading.title ?? reading.project
        let left = remaining(reading, now: now).map { "\(Format.short($0)) left" } ?? "over time"
        return [name, left].compactMap { $0 }.joined(separator: " · ")
    }

    static func symbol(_ reading: TimerReading) -> String {
        if reading.isPaused { return "pause.circle" }
        return reading.state == .onBreak ? "cup.and.saucer.fill" : "timer"
    }
}

// MARK: Pomodoro

extension CategoryColor {
    var color: Color {
        switch self {
        case .blue: .blue
        case .indigo: .indigo
        case .purple: .purple
        case .pink: .pink
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .mint: .mint
        case .teal: .teal
        case .cyan: .cyan
        case .brown: .brown
        case .gray: .gray
        }
    }

    var name: String { rawValue.capitalized }
}

extension SessionRating {
    var title: String {
        switch self {
        case .neutral: "Neutral"
        case .focused: "Focused"
        case .distracted: "Distracted"
        }
    }

    var symbol: String {
        switch self {
        case .neutral: "minus.circle.fill"
        case .focused: "checkmark.circle.fill"
        case .distracted: "exclamationmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .neutral: .gray
        case .focused: .green
        case .distracted: .orange
        }
    }

    /// Order on screen: the two judgements either side of the default.
    static let shown: [SessionRating] = [.focused, .neutral, .distracted]
}

extension PomodoroPhase {
    var title: String {
        switch self {
        case .focus: "Focus"
        case .shortBreak: "Short break"
        case .longBreak: "Long break"
        }
    }

    var tint: Color { isBreak ? Theme.onBreak : Theme.focus }
}

/// A category's colour as a small dot.
struct CategoryDot: View {
    let color: CategoryColor?
    var size: CGFloat = 10

    var body: some View {
        Circle()
            .fill(color?.color ?? Color.secondary.opacity(0.4))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
