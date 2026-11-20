import SwiftUI
import WatchDogCore

/// Every time a rule reached its limit, newest first, grouped by day.
struct HistoryView: View {
    let runner: RuleRunner

    var body: some View {
        Group {
            if runner.verdicts.isEmpty {
                ContentUnavailableView("No rule has fired", systemImage: "checkmark.seal",
                                       description: Text("When a rule reaches its limit, it is listed here."))
            } else {
                List {
                    ForEach(days, id: \.day) { group in
                        Section(group.day.formatted(.dateTime.weekday(.wide).day().month(.wide))) {
                            ForEach(group.rows) { row in VerdictRow(row: row) }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("History")
        .navigationSubtitle("What the rules did")
        .toolbar { ModeSwitch(runner: runner) }
    }

    private var days: [(day: Date, rows: [VerdictRecord])] {
        Dictionary(grouping: runner.verdicts) { Calendar.current.startOfDay(for: $0.at) }
            .map { (day: $0.key, rows: $0.value) }
            .sorted { $0.day > $1.day }
    }
}

private struct VerdictRow: View {
    let row: VerdictRecord

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(row.ruleName)
                Text("\(verb) \(row.subject)").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(Format.clock(row.at)).monospacedDigit()
                Text("after \(Format.short(row.matchedSeconds))").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch row.action {
        case "close": "xmark"
        case "block": "lock.fill"
        default: "bell.fill"
        }
    }

    private var tint: Color {
        switch row.action {
        case "close": .orange
        case "block": .red
        default: .blue
        }
    }

    private var verb: String {
        let dry = row.dryRun
        switch row.action {
        case "close": return dry ? "Would have closed" : "Closed"
        case "block": return dry ? "Would have blocked" : "Blocked"
        default: return "Warned about"
        }
    }
}
