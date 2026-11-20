import Foundation

/// Editing /etc/hosts safely. Pure text in, text out: the daemon does the
/// reading and writing, this decides what the file should contain.
///
/// WatchDog owns exactly one marked section at the end of the file. Every line
/// outside the markers is passed through untouched, byte for byte.
public enum HostsFile {
    public static let begin = "# >>> \(WD.tag) (managed block list; edits here are reverted)"
    public static let end = "# <<< \(WD.tag)"

    /// A blocked name is pointed at an address that goes nowhere, for both
    /// IPv4 and IPv6. `www.` is added because hosts has no wildcards.
    public static func lines(for domains: [String]) -> [String] {
        var names: [String] = []
        for domain in domains.sorted() {
            names.append(domain)
            if !domain.hasPrefix("www.") { names.append("www." + domain) }
        }
        return names.flatMap { ["0.0.0.0 \($0)", ":: \($0)"] }
    }

    /// The file with our section removed. Idempotent.
    public static func strip(_ content: String) -> String {
        var kept: [Substring] = []
        var inside = false
        for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
            if line == begin { inside = true; continue }
            if inside {
                if line == end { inside = false; continue }
                // Inside the section only our own kind of line is removed. The
                // first foreign line ends the section, so if the end marker
                // has been deleted, whatever follows is kept, not swallowed.
                if isBlockLine(line) { continue }
                inside = false
            }
            kept.append(line)
        }
        return kept.joined(separator: "\n")
    }

    /// The exact shape of the lines `lines(for:)` produces.
    private static func isBlockLine(_ line: Substring) -> Bool {
        line.hasPrefix("0.0.0.0 ") || line.hasPrefix(":: ")
    }

    /// The file as it should be for this block list. An empty list means "no
    /// section at all". Whatever is outside the section is preserved.
    public static func render(_ content: String, blocking domains: [String]) -> String {
        var base = strip(content)
        guard !domains.isEmpty else { return base }
        if !base.hasSuffix("\n") { base += "\n" }
        return base + ([begin] + lines(for: domains) + [end]).joined(separator: "\n") + "\n"
    }

    /// Guard for the writer: true only if `new` differs from `old` in our
    /// section alone and the file still has its localhost entry.
    public static func isSafeReplacement(old: String, new: String) -> Bool {
        let before = strip(old)
        let after = strip(new)
        let sameOutside = before == after || before + "\n" == after
        return sameOutside && after.contains("localhost")
    }
}
