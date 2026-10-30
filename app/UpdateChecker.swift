// SPDX-License-Identifier: GPL-3.0-only
// Adapted from the author's DragTwoZero updater.
import Foundation

struct ReleaseVersion: Comparable {
    let major: Int
    let minor: Int
    let patch: Int
    init?(_ value: String) {
        let raw = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let components = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3,
              components.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }),
              let major = Int(components[0]), let minor = Int(components[1]), let patch = Int(components[2]) else { return nil }
        self.major = major; self.minor = minor; self.patch = patch
    }
    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

struct PublishedRelease: Decodable {
    let tag_name: String
    let draft: Bool
    let prerelease: Bool
    let html_url: URL
    let assets: [Asset]
    struct Asset: Decodable {
        let name: String
        let browser_download_url: URL
        let size: Int
        let state: String
    }
    func update(current: String) -> ReleaseUpdate? {
        guard !draft, !prerelease,
              let version = ReleaseVersion(tag_name), let installed = ReleaseVersion(current), version > installed,
              Self.trusted(html_url, path: "/maxim-kich/MagDot/releases/tag/\(tag_name)") else { return nil }
        let name = "MagDot-\(tag_name)-macOS-arm64.zip"
        func asset(_ name: String) -> Asset? {
            assets.first { $0.name == name && $0.size > 0 && $0.state == "uploaded"
                && Self.trusted($0.browser_download_url,
                    path: "/maxim-kich/MagDot/releases/download/\(tag_name)/\(name)") }
        }
        guard let archive = asset(name), let feed = asset("appcast.xml") else { return nil }
        return ReleaseUpdate(version: String(tag_name.dropFirst(tag_name.hasPrefix("v") ? 1 : 0)),
                             archive: archive.browser_download_url, length: UInt64(archive.size),
                             feed: feed.browser_download_url)
    }
    private static func trusted(_ url: URL, path: String) -> Bool {
        url.scheme == "https" && url.host == "github.com" && url.path == path
            && url.user == nil && url.password == nil && url.port == nil && url.query == nil && url.fragment == nil
    }
}

/// Limits accumulated decoded response bytes, even when Content-Length is absent or misleading.
enum BoundedReleaseBody {
    static let limit = 1_000_000
    enum Failure: Error { case tooLarge }
    static func read<Bytes: AsyncSequence>(_ bytes: Bytes, expectedLength: Int64 = -1) async throws -> Data where Bytes.Element == UInt8 {
        guard expectedLength <= Int64(limit) else { throw Failure.tooLarge }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < limit else { throw Failure.tooLarge }
            data.append(byte)
        }
        return data
    }
}
