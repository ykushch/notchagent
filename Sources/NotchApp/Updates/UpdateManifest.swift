import Foundation

/// The `appcast.json` asset published by the release workflow and fetched from
/// `https://github.com/ykushch/notchagent/releases/latest/download/appcast.json`.
///
/// Decoding is tolerant of unknown fields (per the project convention) but
/// strict about the fields it does use: a manifest that fails validation is
/// treated as "no update available", never as something to act on. Every URL is
/// checked against a GitHub allowlist here so nothing downstream — the release
/// notes link, a future download step — can be pointed at an arbitrary host by
/// whatever the feed happened to return.
struct UpdateManifest: Sendable, Equatable, Decodable {
    let version: AppVersion
    let publishedAt: Date?
    let minimumSystemVersion: AppVersion?
    let downloadURL: URL
    let sha256: String
    let releaseNotesURL: URL

    /// `NotchApp-1.3.0.zip` — used in the "Download …" affordance.
    var archiveName: String { downloadURL.lastPathComponent }

    static let allowedHosts: Set<String> = [
        "github.com",
        "www.github.com",
        "objects.githubusercontent.com",
        "release-assets.githubusercontent.com",
    ]

    enum ValidationError: Error, Equatable {
        case invalidVersion(String)
        case invalidMinimumSystemVersion(String)
        case untrustedURL(field: String)
        case invalidDigest
    }

    private enum CodingKeys: String, CodingKey {
        case version, publishedAt, minimumSystemVersion, downloadURL, sha256, releaseNotesURL
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let rawVersion = try container.decode(String.self, forKey: .version)
        guard let version = AppVersion(rawVersion) else {
            throw ValidationError.invalidVersion(rawVersion)
        }
        self.version = version

        if let rawMinimum = try container.decodeIfPresent(String.self, forKey: .minimumSystemVersion) {
            guard let minimum = AppVersion(rawMinimum) else {
                throw ValidationError.invalidMinimumSystemVersion(rawMinimum)
            }
            minimumSystemVersion = minimum
        } else {
            minimumSystemVersion = nil
        }

        publishedAt = try container.decodeIfPresent(String.self, forKey: .publishedAt)
            .flatMap(Self.parseTimestamp)

        let rawDownload = try container.decode(String.self, forKey: .downloadURL)
        guard let downloadURL = Self.trustedURL(rawDownload) else {
            throw ValidationError.untrustedURL(field: "downloadURL")
        }
        self.downloadURL = downloadURL

        let rawNotes = try container.decode(String.self, forKey: .releaseNotesURL)
        guard let releaseNotesURL = Self.trustedURL(rawNotes) else {
            throw ValidationError.untrustedURL(field: "releaseNotesURL")
        }
        self.releaseNotesURL = releaseNotesURL

        let rawDigest = try container.decode(String.self, forKey: .sha256)
        guard let digest = Self.normalizedDigest(rawDigest) else {
            throw ValidationError.invalidDigest
        }
        sha256 = digest
    }

    /// Memberwise init for tests and previews; bypasses no validation that
    /// matters because every field is already typed.
    init(
        version: AppVersion,
        publishedAt: Date? = nil,
        minimumSystemVersion: AppVersion? = nil,
        downloadURL: URL,
        sha256: String,
        releaseNotesURL: URL
    ) {
        self.version = version
        self.publishedAt = publishedAt
        self.minimumSystemVersion = minimumSystemVersion
        self.downloadURL = downloadURL
        self.sha256 = sha256
        self.releaseNotesURL = releaseNotesURL
    }

    /// HTTPS on a GitHub host, with no embedded credentials.
    static func trustedURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw),
              url.scheme?.lowercased() == "https",
              url.user == nil, url.password == nil,
              let host = url.host?.lowercased(),
              allowedHosts.contains(host)
        else { return nil }
        return url
    }

    static func normalizedDigest(_ raw: String) -> String? {
        let digest = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard digest.count == 64,
              digest.allSatisfy({ $0.isASCII && ($0.isNumber || ("a"..."f").contains($0)) })
        else { return nil }
        return digest
    }

    private static func parseTimestamp(_ raw: String) -> Date? {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: raw) { return date }
        return ISO8601DateFormatter().date(from: raw)
    }
}
