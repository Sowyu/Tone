// Offline self-check for release parsing and version ordering. Run: make check
import Foundation

@main
struct CheckUpdates {
    static func payload(tag: String = "v1.10.0", draft: Bool = false, prerelease: Bool = false,
                        url: String? = nil, assets: Bool = true) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "tag_name": tag, "draft": draft, "prerelease": prerelease,
            "assets": assets ? [["name": "Tone.dmg", "size": 123, "digest": "sha256:" + String(repeating: "a", count: 64),
                                  "browser_download_url": url ?? "https://github.com/Sowyu/Tone/releases/download/\(tag)/Tone.dmg"]] : []
        ])
    }

    static func rejects(_ body: Data, status: Int = 200) {
        do {
            _ = try AppUpdate.parse(body, statusCode: status, installedVersion: "1.2.0")
            fatalError("Expected invalid response to be rejected")
        } catch { }
    }

    static func main() throws {
        let suite = "Tone.update-check-test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date()
        assert(AppUpdate.automaticCheckDelay(defaults: defaults, now: now) == 0)
        assert(AppUpdate.beginAutomaticCheck(defaults: defaults, now: now))
        let relaunchedDefaults = UserDefaults(suiteName: suite)!
        assert(!AppUpdate.beginAutomaticCheck(defaults: relaunchedDefaults, now: now.addingTimeInterval(60)))
        assert(AppUpdate.automaticCheckDelay(defaults: relaunchedDefaults, now: now.addingTimeInterval(60)) == 86340)
        assert(AppUpdate.beginAutomaticCheck(defaults: relaunchedDefaults, now: now.addingTimeInterval(86400)))
        print("PASS: automatic checks persist across launches and wait a full day")

        let newer = try payload()
        let update = try AppUpdate.parse(newer, statusCode: 200, installedVersion: "1.2.0")
        assert(update?.version == "v1.10.0")
        assert(update?.downloadURL.absoluteString == "https://github.com/Sowyu/Tone/releases/download/v1.10.0/Tone.dmg")
        let same = try AppUpdate.parse(newer, statusCode: 200, installedVersion: "1.10.0")
        let older = try AppUpdate.parse(newer, statusCode: 200, installedVersion: "2.0.0")
        assert(same == nil && older == nil)
        assert(AppUpdate.versionNumbers("1.0") == [1, 0, 0])
        for invalid in ["", "1..0", "1.2.0-beta", "1.2.0.1", "1.-2.0", "1.2/evil", "1.2.999999999999999999999999"] {
            assert(AppUpdate.versionNumbers(invalid) == nil)
        }
        rejects(newer, status: 403)
        rejects(newer, status: 429)
        rejects(newer, status: 500)
        rejects(Data("not JSON".utf8))
        var malformed = try JSONSerialization.jsonObject(with: newer) as! [String: Any]
        var assets = malformed["assets"] as! [[String: Any]]
        for digest in [NSNull(), "sha256:123", "sha256:" + String(repeating: "g", count: 64)] as [Any] {
            assets[0]["digest"] = digest
            malformed["assets"] = assets
            rejects(try JSONSerialization.data(withJSONObject: malformed))
        }
        rejects(try payload(draft: true))
        rejects(try payload(prerelease: true))
        rejects(try payload(assets: false))
        rejects(try payload(url: "https://example.com/Tone.dmg"))
        rejects(try payload(url: "http://github.com/Sowyu/Tone/releases/download/v1.10.0/Tone.dmg"))
        rejects(try payload(url: "https://github.com/other/repo/releases/download/v1.10.0/Tone.dmg"))
        print("PASS: version ordering, equal/older releases, invalid versions, HTTP errors, malformed releases, and download URL validation")
    }
}
