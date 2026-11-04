import Foundation
import Testing
@testable import CoolReaderKit

/// What the Mac app's updater reads of GitHub's latest release.
struct AppReleaseTests {
    @Test func readsTheLatestRelease() throws {
        let json = #"""
            {"tag_name": "v0.2.0", "draft": false, "prerelease": false, "html_url": "https://github.com/ExoGroupe-fr/cool-reader-server/releases/tag/v0.2.0",
             "assets": [{"name": "CoolReaderServer-0.2.0-mac-arm64.zip", "browser_download_url": "https://github.com/x/arm64.zip"},
                        {"name": "CoolReaderServer-0.2.0-mac-universal.zip", "browser_download_url": "https://github.com/x/universal.zip"},
                        {"name": "notes.txt", "browser_download_url": "https://github.com/x/notes.txt"}]}
            """#
        let release = try #require(AppRelease.parse(Data(json.utf8)))
        #expect(release.version == "0.2.0" && release.download.absoluteString == "https://github.com/x/universal.zip")
        #expect(AppRelease.parse(Data(#"{"tag_name": "v0.3.0", "prerelease": true, "assets": []}"#.utf8)) == nil)
        #expect(AppRelease.parse(Data(#"{"tag_name": "v0.3.0", "assets": [{"name": "server.tar.gz", "browser_download_url": "https://x/y"}]}"#.utf8)) == nil)
    }

    @Test func comparesVersions() {
        #expect(AppRelease.isNewer("0.2.0", than: "0.1.0"))
        #expect(AppRelease.isNewer("0.10.0", than: "0.9.2"))
        #expect(AppRelease.isNewer("0.2", than: "0.1.9"))
        #expect(!AppRelease.isNewer("0.1.0", than: "0.1.0"))
        #expect(!AppRelease.isNewer("0.1.0", than: "0.1.1"))
    }
}
