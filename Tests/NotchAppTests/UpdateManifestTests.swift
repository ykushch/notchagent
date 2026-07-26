import Foundation
import Testing
@testable import NotchApp

@Suite("UpdateManifest")
struct UpdateManifestTests {
    /// The exact shape `.github/workflows/release.yml` writes.
    static func json(
        version: String = "1.3.0",
        minimum: String? = "14.0",
        download: String = "https://github.com/ykushch/notchagent/releases/download/v1.3.0/NotchApp-1.3.0.zip",
        notes: String = "https://github.com/ykushch/notchagent/releases/tag/v1.3.0",
        sha256: String = String(repeating: "a", count: 64),
        extra: String = ""
    ) -> Data {
        let minimumField = minimum.map { "\"minimumSystemVersion\": \"\($0)\"," } ?? ""
        return Data("""
        {
          "schemaVersion": 1,
          "version": "\(version)",
          "publishedAt": "2026-07-24T12:00:00Z",
          \(minimumField)
          "downloadURL": "\(download)",
          "sha256": "\(sha256)",
          "releaseNotesURL": "\(notes)"\(extra)
        }
        """.utf8)
    }

    static func decode(_ data: Data) throws -> UpdateManifest {
        try JSONDecoder().decode(UpdateManifest.self, from: data)
    }

    @Test("Decodes the published shape")
    func decodesPublishedShape() throws {
        let manifest = try Self.decode(Self.json())
        #expect(manifest.version == AppVersion("1.3.0")!)
        #expect(manifest.minimumSystemVersion == AppVersion("14.0")!)
        #expect(manifest.archiveName == "NotchApp-1.3.0.zip")
        #expect(manifest.sha256 == String(repeating: "a", count: 64))
        #expect(manifest.publishedAt != nil)
    }

    @Test("Unknown fields are ignored, optional fields may be absent")
    func toleratesUnknownFields() throws {
        let manifest = try Self.decode(
            Self.json(minimum: nil, extra: ",\n  \"channel\": \"beta\", \"delta\": {\"from\": \"1.2.0\"}"))
        #expect(manifest.minimumSystemVersion == nil)
        #expect(manifest.version == AppVersion("1.3.0")!)
    }

    @Test("Fractional-second timestamps parse too")
    func fractionalTimestamp() throws {
        let data = Data("""
        {"version":"1.3.0","publishedAt":"2026-07-24T12:00:00.500Z",
         "downloadURL":"https://github.com/ykushch/notchagent/releases/download/v1.3.0/NotchApp-1.3.0.zip",
         "sha256":"\(String(repeating: "b", count: 64))",
         "releaseNotesURL":"https://github.com/ykushch/notchagent/releases/tag/v1.3.0"}
        """.utf8)
        #expect(try Self.decode(data).publishedAt != nil)
    }

    @Test(
        "URLs off the GitHub allowlist are rejected",
        arguments: [
            "http://github.com/ykushch/notchagent/releases/download/v1.3.0/NotchApp-1.3.0.zip",
            "https://evil.example.com/NotchApp-1.3.0.zip",
            "https://github.com.evil.example.com/NotchApp-1.3.0.zip",
            "https://user:pass@github.com/NotchApp-1.3.0.zip",
            "file:///tmp/NotchApp-1.3.0.zip",
            "not a url at all",
        ])
    func rejectsUntrustedDownloadURL(url: String) {
        #expect(throws: (any Error).self) { try Self.decode(Self.json(download: url)) }
    }

    @Test("Release notes are held to the same allowlist")
    func rejectsUntrustedNotesURL() {
        #expect(throws: (any Error).self) {
            try Self.decode(Self.json(notes: "https://evil.example.com/notes"))
        }
    }

    @Test("GitHub's release asset redirect host is trusted")
    func trustsGitHubReleaseAssetRedirect() {
        let redirect = """
            https://release-assets.githubusercontent.com/github-production-release-asset/archive\
            ?response-content-disposition=attachment
            """
        #expect(UpdateManifest.trustedURL(redirect) != nil)
    }

    @Test("Malformed versions and digests reject")
    func rejectsMalformedFields() {
        #expect(throws: (any Error).self) { try Self.decode(Self.json(version: "1.3.0-beta")) }
        #expect(throws: (any Error).self) { try Self.decode(Self.json(minimum: "sequoia")) }
        #expect(throws: (any Error).self) { try Self.decode(Self.json(sha256: "abc123")) }
        #expect(throws: (any Error).self) {
            try Self.decode(Self.json(sha256: String(repeating: "z", count: 64)))
        }
    }

    @Test("Uppercase digests normalize to lowercase")
    func normalizesDigest() throws {
        let manifest = try Self.decode(Self.json(sha256: String(repeating: "AB", count: 32)))
        #expect(manifest.sha256 == String(repeating: "ab", count: 32))
    }
}
