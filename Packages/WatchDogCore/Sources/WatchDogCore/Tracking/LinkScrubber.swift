import Foundation

/// How much of a browser page's address history keeps.
public enum AddressDetail: String, Codable, Sendable, CaseIterable {
    /// The site only: "https://www.youtube.com".
    case site
    /// The whole address, minus the parts that look like secrets or
    /// personal details (see `LinkScrubber`).
    case cleaned
    /// The address exactly as the browser reported it.
    case full

    /// What history stores for `url` under this setting.
    public func apply(to url: String?) -> String? {
        switch self {
        case .site: Sample.siteAddress(of: url)
        case .cleaned: url.map(LinkScrubber.clean)
        case .full: url
        }
    }
}

/// Removes the parts of a page address that most often carry secrets or
/// personal details, so a full address can be kept without them.
///
/// Best effort, by pattern; it cannot know what a site means by its own
/// parameters. It removes:
/// - a user name and password written before the host;
/// - the values of parameters whose names suggest a secret or an identity
///   (token, key, password, session, signature, code, email, phone...);
/// - anywhere in the path, parameters or fragment: email addresses, JSON web
///   tokens, card numbers (checked with the Luhn sum), and long random-looking
///   strings (hex of 32+ characters, or 24+ characters with digits that keep
///   switching between upper case, lower case and digits like a generated
///   key does). A generated key with fewer than two digits gets through.
///
/// The scheme, host and port are never changed, so rules (which match on the
/// site) see the same domain. Cleaning a cleaned address changes nothing.
public enum LinkScrubber {
    /// What a removed part is replaced with.
    public static let placeholder = "redacted"

    public static func clean(_ url: String) -> String { clean(url, depth: 0) }

    private static func clean(_ url: String, depth: Int) -> String {
        guard depth < 3, var parts = URLComponents(string: url), parts.scheme != nil else {
            return scrubText(url)
        }
        parts.user = nil
        parts.password = nil

        let path = parts.percentEncodedPath
        if !path.isEmpty {
            parts.percentEncodedPath = path.split(separator: "/", omittingEmptySubsequences: false)
                .map { cleanSegment(String($0)) }
                .joined(separator: "/")
        }
        if let query = parts.percentEncodedQuery {
            parts.percentEncodedQuery = cleanParameters(query, allowed: queryValueAllowed, depth: depth)
        }
        if let fragment = parts.percentEncodedFragment {
            // "#access_token=...&expires_in=3600" or "#/route?token=..." are
            // parameters; "#inbox/FMfcgz..." is a path.
            parts.percentEncodedFragment = fragment.contains("=")
                ? cleanParameters(fragment, allowed: fragmentValueAllowed, depth: depth)
                : fragment.split(separator: "/", omittingEmptySubsequences: false)
                    .map { scrubPiece(String($0), allowed: fragmentPieceAllowed) }
                    .joined(separator: "/")
        }
        return parts.string ?? scrubText(url)
    }

    // MARK: Parameters

    /// `a=1&token=xyz` -> `a=1&token=redacted`. Works on the percent-encoded
    /// text and re-encodes only what it changes, so everything else keeps its
    /// exact spelling.
    private static func cleanParameters(_ encoded: String, allowed: CharacterSet, depth: Int) -> String {
        encoded.split(separator: "&", omittingEmptySubsequences: false).map { pair -> String in
            guard let equals = pair.firstIndex(of: "=") else {
                return scrubPiece(String(pair), allowed: allowed)
            }
            let key = String(pair[..<equals])
            let value = String(pair[pair.index(after: equals)...])
            if value.isEmpty { return String(pair) }
            if isSensitiveName(key) { return "\(key)=\(placeholder)" }
            let decoded = value.removingPercentEncoding ?? value
            let lowered = decoded.lowercased()
            // A link inside a link (?next=https://...): clean that one too.
            let cleaned = lowered.hasPrefix("http://") || lowered.hasPrefix("https://")
                ? clean(decoded, depth: depth + 1)
                : scrubText(decoded)
            guard cleaned != decoded else { return String(pair) }
            return "\(key)=\(cleaned.addingPercentEncoding(withAllowedCharacters: allowed) ?? placeholder)"
        }.joined(separator: "&")
    }

    /// Parameter names whose values are secrets or identify you.
    static func isSensitiveName(_ encodedName: String) -> Bool {
        let name = encodedName.removingPercentEncoding ?? encodedName
        // Words: split on punctuation and on camelCase ("X-Amz-Signature",
        // "access_token", "apiKey" -> x amz signature / access token / api key).
        var words: [String] = []
        var word = ""
        var previous: Character?
        for character in name {
            if character.isLetter || character.isNumber {
                if let previous, previous.isLowercase, character.isUppercase, !word.isEmpty {
                    words.append(word)
                    word = ""
                }
                word.append(character)
            } else if !word.isEmpty {
                words.append(word)
                word = ""
            }
            previous = character
        }
        if !word.isEmpty { words.append(word) }
        words = words.map { $0.lowercased() }
        if words.contains(where: sensitiveWords.contains) { return true }
        let joined = words.joined()
        return sensitiveFragments.contains { joined.contains($0) }
    }

    /// Whole words that mark a parameter as sensitive.
    private static let sensitiveWords: Set<String> = [
        "token", "secret", "password", "passwd", "pwd", "pass", "passcode", "key", "apikey",
        "sig", "signature", "credential", "credentials", "auth", "authorization", "oauth",
        "session", "sessionid", "sid", "otp", "nonce", "code", "pin", "jwt", "bearer",
        "email", "mail", "phone", "tel", "mobile", "ssn", "cvv", "cvc", "iban", "ticket",
        "login", "user", "username",
    ]

    /// Parts of run-together names ("PHPSESSID", "accesstoken").
    private static let sensitiveFragments = [
        "token", "secret", "password", "passwd", "apikey", "sessid", "sessionid", "signature",
        "credential", "email", "phone",
    ]

    /// A path segment, including the `;name=value` parameters some servers
    /// put there (`/cart;jsessionid=...`).
    private static func cleanSegment(_ encoded: String) -> String {
        let pieces = encoded.split(separator: ";", omittingEmptySubsequences: false)
        guard pieces.count > 1 else { return scrubPiece(encoded, allowed: pathPieceAllowed) }
        return pieces.map { piece -> String in
            if let equals = piece.firstIndex(of: "="), piece.index(after: equals) < piece.endIndex,
               isSensitiveName(String(piece[..<equals])) {
                return "\(piece[..<equals])=\(placeholder)"
            }
            return scrubPiece(String(piece), allowed: pathPieceAllowed)
        }.joined(separator: ";")
    }

    // MARK: Text

    /// One percent-encoded path segment or fragment piece. Unchanged pieces
    /// are returned as they were.
    private static func scrubPiece(_ encoded: String, allowed: CharacterSet) -> String {
        let decoded = encoded.removingPercentEncoding ?? encoded
        let cleaned = scrubText(decoded)
        guard cleaned != decoded else { return encoded }
        return cleaned.addingPercentEncoding(withAllowedCharacters: allowed) ?? placeholder
    }

    /// Replaces secrets and personal details found anywhere in plain text.
    static func scrubText(_ text: String) -> String {
        var text = text
        // Each pattern only runs where it could match, and every repeat is
        // bounded, so a very long address costs time in proportion to its length.
        if text.contains("eyJ") { text = text.replacing(jsonWebToken, with: placeholder) }
        if text.contains("@") { text = text.replacing(emailAddress, with: placeholder) }
        text = text.replacing(cardLike) { match in
            isCardNumber(match.output) ? placeholder : String(match.output)
        }
        text = text.replacing(tokenLike) { match in
            looksGenerated(match.output) ? placeholder : String(match.output)
        }
        return text
    }

    nonisolated(unsafe) private static let jsonWebToken = /eyJ[A-Za-z0-9_\-]{4,}\.[A-Za-z0-9_\-]{4,}\.[A-Za-z0-9_\-]*/
    nonisolated(unsafe) private static let emailAddress = /[A-Za-z0-9._%+\-]{1,64}@[A-Za-z0-9\-]{1,63}(?:\.[A-Za-z0-9\-]{1,63}){0,8}\.[A-Za-z]{2,24}/
    nonisolated(unsafe) private static let cardLike = /\d(?:[ \-]?\d){12,18}/
    nonisolated(unsafe) private static let tokenLike = /[A-Za-z0-9_\-+\/=~]{20,}/

    /// 13 to 19 digits that pass the Luhn check every payment card number passes.
    private static func isCardNumber(_ text: Substring) -> Bool {
        let digits = text.compactMap(\.wholeNumberValue)
        guard (13...19).contains(digits.count) else { return false }
        let sum = digits.reversed().enumerated().reduce(0) { total, item in
            let (index, digit) = item
            guard index % 2 == 1 else { return total + digit }
            let doubled = digit * 2
            return total + (doubled > 9 ? doubled - 9 : doubled)
        }
        return sum % 10 == 0
    }

    /// Does this run of letters and digits look machine-made? Hex of 32+
    /// characters (hashes, reset links), or 24+ characters with digits that
    /// keep switching between upper case, lower case and digits (keys,
    /// session IDs). Words, slugs, titles and camelCase names are kept.
    static func looksGenerated(_ run: Substring) -> Bool {
        enum Kind { case upper, lower, digit }
        var kinds: [Kind] = []
        var hex = true
        for scalar in run.unicodeScalars {
            switch scalar.value {
            case 0x30...0x39: kinds.append(.digit)
            case 0x41...0x5A: kinds.append(.upper); hex = hex && scalar.value <= 0x46   // A-F
            case 0x61...0x7A: kinds.append(.lower); hex = hex && scalar.value <= 0x66   // a-f
            default: continue
            }
        }
        if hex, kinds.count >= 32, kinds.contains(.digit), kinds.contains(where: { $0 != .digit }) { return true }

        // Digits too: a camelCase name switches case often but has none,
        // while a generated key of this length almost always has several.
        guard kinds.count >= 24, kinds.filter({ $0 == .digit }).count >= 2,
              kinds.contains(where: { $0 != .digit }) else { return false }
        let switches = zip(kinds, kinds.dropFirst()).filter { $0 != $1 }.count
        return Double(switches) / Double(kinds.count - 1) >= 0.35
    }

    // MARK: Encoding

    private static let pathPieceAllowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/;"))
    private static let queryValueAllowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+#"))
    private static let fragmentValueAllowed = CharacterSet.urlFragmentAllowed.subtracting(CharacterSet(charactersIn: "&=+#"))
    private static let fragmentPieceAllowed = CharacterSet.urlFragmentAllowed.subtracting(CharacterSet(charactersIn: "/#"))
}
