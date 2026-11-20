import Foundation
import Testing
@testable import WatchDogCore

/// Cleaning secrets and personal details out of page addresses.
struct LinkScrubberTests {
    let r = LinkScrubber.placeholder

    func clean(_ url: String) -> String { LinkScrubber.clean(url) }

    // MARK: Removed

    @Test func aPasswordBeforeTheHostIsRemoved() {
        #expect(clean("https://bob:hunter2@example.com/files") == "https://example.com/files")
    }

    @Test func parametersNamedLikeSecretsLoseTheirValues() {
        #expect(clean("https://example.com/cb?code=4/0AX4Xf&state=xyz&access_token=ya29.a0Af&lang=en")
                == "https://example.com/cb?code=\(r)&state=xyz&access_token=\(r)&lang=en")
        #expect(clean("https://s3.amazonaws.com/b/f.pdf?X-Amz-Credential=AKIA%2F2026&X-Amz-Signature=9a8b&X-Amz-Expires=300")
                == "https://s3.amazonaws.com/b/f.pdf?X-Amz-Credential=\(r)&X-Amz-Signature=\(r)&X-Amz-Expires=300")
        #expect(clean("https://example.com/?apiKey=abc&PHPSESSID=def&login_hint=me&password=p")
                == "https://example.com/?apiKey=\(r)&PHPSESSID=\(r)&login_hint=\(r)&password=\(r)")
    }

    @Test func namesThatOnlyLookSimilarAreKept() {
        let url = "https://example.com/books?author=tolkien&keyword=ring&passage=3&monkey=1"
        #expect(clean(url) == url)
    }

    @Test func tokensInTheFragmentAreRemoved() {
        #expect(clean("https://app.example.com/callback#access_token=abc&expires_in=3600")
                == "https://app.example.com/callback#access_token=\(r)&expires_in=3600")
        #expect(clean("https://app.example.com/#/reset?token=abc").hasSuffix("token=\(r)"))
    }

    @Test func emailAddressesAreRemovedWherever() {
        #expect(clean("https://example.com/users/jane.doe@example.org/settings")
                == "https://example.com/users/\(r)/settings")
        #expect(clean("https://example.com/share?to=jane%40example.org&from=x")
                == "https://example.com/share?to=\(r)&from=x")
    }

    @Test func webTokensCardNumbersAndGeneratedKeysAreRemoved() {
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"
        #expect(clean("https://example.com/verify/\(jwt)") == "https://example.com/verify/\(r)")
        #expect(clean("https://shop.example.com/pay?q=4111%201111%201111%201111") == "https://shop.example.com/pay?q=\(r)")
        #expect(clean("https://example.com/reset/9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08")
                == "https://example.com/reset/\(r)")
        #expect(clean("https://docs.google.com/document/d/1BxiMVs0XRA5nFMdKvBdBZjgmUUqptlbs74OgvE2upms/edit")
                == "https://docs.google.com/document/d/\(r)/edit")
        #expect(clean("https://api.example.com/x?redirect=a&t=sk_live_51HqLyjWDarjtT1zdp7dc") == "https://api.example.com/x?redirect=a&t=\(r)")
    }

    @Test func sessionIDsInThePathAreRemoved() {
        #expect(clean("https://shop.example.com/cart;jsessionid=A1B2C3?item=7")
                == "https://shop.example.com/cart;jsessionid=\(r)?item=7")
    }

    @Test func oddAddressesNeitherCrashNorGrow() {
        for url in [
            "https://[::1]:8080/a%20b?x=1", "https://example.com/%E2%9C%93?x=%ZZ", "https://example.com/?=&&=x&a==b",
            "https://example.com/#", "https://example.com/?", "mailto:jane@example.org", "javascript:alert(1)",
            "data:text/html,hi", "https://example.com/a;b;=;c=", "https://exa mple.com/?token=x", "", "://", "?token=abc",
            "https://example.com/" + String(repeating: "aB3", count: 2_000),
        ] {
            let once = clean(url)
            #expect(clean(once) == once, "\(url)")
            #expect(Sample.domain(of: once) == Sample.domain(of: url), "\(url)")
        }
    }

    @Test func aLinkInsideALinkIsCleanedToo() {
        let cleaned = clean("https://example.com/login?next=https%3A%2F%2Fapp.example.com%2Freset%3Ftoken%3Dabc123")
        #expect(!cleaned.contains("abc123"))
        #expect(cleaned.hasPrefix("https://example.com/login?next="))
        #expect(URLComponents(string: cleaned) != nil)
    }

    // MARK: Kept

    @Test func ordinaryPagesAreLeftAlone() {
        for url in [
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42",
            "https://en.wikipedia.org/wiki/Albert_Einstein_1879_Birth",
            "https://www.google.com/search?q=swift+concurrency+tutorial&hl=en",
            "https://blog.example.com/2024/05/how-to-bake-sourdough-bread-at-home-2024",
            "https://github.com/apple/swift/pull/71234/files",
            "https://www.amazon.com/dp/B0CHX1W1XY?th=1",
            "https://example.com/SomeVeryLongCamelCaseName",
            "https://news.ycombinator.com/item?id=41234567",
            "https://example.com/",
            "brave://newtab",
        ] {
            #expect(clean(url) == url, "\(url)")
        }
    }

    @Test func theSiteNeverChangesSoRulesSeeTheSameDomain() {
        for url in [
            "https://bob:pw@www.youtube.com:8443/watch?v=x&token=y",
            "https://mail.google.com/mail/u/0/#inbox/FMfcgzQXJWDsKmhqlwBknlxXyzrpBMDZ",
            "http://localhost:8080/admin?session=abc",
        ] {
            #expect(Sample.domain(of: clean(url)) == Sample.domain(of: url))
            #expect(Sample.siteAddress(of: clean(url)) == Sample.siteAddress(of: url.replacingOccurrences(of: "bob:pw@", with: "")))
        }
    }

    @Test func cleaningTwiceChangesNothing() {
        for url in [
            "https://bob:pw@example.com/users/jane@example.org/reset/9f86d081884c7d659a2feaa0c55ad015a3bf4f1b?token=x#id_token=y",
            "https://example.com/login?next=https%3A%2F%2Fapp.example.com%2Freset%3Ftoken%3Dabc123",
            "not a url, mail me at jane@example.org",
        ] {
            let once = clean(url)
            #expect(clean(once) == once)
        }
    }

    @Test func textThatIsNotAnAddressIsStillScrubbed() {
        #expect(clean("not a url, mail me at jane@example.org") == "not a url, mail me at \(r)")
    }

    // MARK: Setting

    @Test func eachSettingKeepsWhatItSays() {
        let url = "https://www.example.com/reset?token=abc&page=2"
        #expect(AddressDetail.site.apply(to: url) == "https://www.example.com")
        #expect(AddressDetail.cleaned.apply(to: url) == "https://www.example.com/reset?token=\(r)&page=2")
        #expect(AddressDetail.full.apply(to: url) == url)
        #expect(AddressDetail.site.apply(to: "file:///Users/me/Secret.pdf") == nil)
        #expect(AddressDetail.cleaned.apply(to: nil) == nil)
    }

    @Test func choosingLessDetailCleansWhatHistoryAlreadyHolds() throws {
        let store = try UsageStore()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let pages = ["https://www.example.com/reset?token=abc", "https://www.example.com/about", "file:///Users/me/Secret.pdf"]
        for (i, url) in pages.enumerated() {
            try store.record(Sample(time: t0.addingTimeInterval(Double(i) * 10), bundleID: "com.brave.Browser",
                                    appName: "Brave", windowTitle: "\(i)", url: url))
        }
        func urls() throws -> [String?] { try store.recentSpans().sorted { $0.startedAt < $1.startedAt }.map(\.url) }

        #expect(try store.applyAddressDetail(.full) == 0)
        #expect(try store.applyAddressDetail(.cleaned) == 1)
        #expect(try urls() == ["https://www.example.com/reset?token=\(r)", "https://www.example.com/about", pages[2]])
        #expect(try store.applyAddressDetail(.cleaned) == 0)

        #expect(try store.applyAddressDetail(.site) == 3)
        #expect(try urls() == ["https://www.example.com", "https://www.example.com", nil])
        #expect(try store.recentSpans().allSatisfy { $0.url == nil || $0.domain == "example.com" })
    }
}
