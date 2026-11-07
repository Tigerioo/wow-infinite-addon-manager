import XCTest
@testable import AddonCore

final class GitHubReleaseClientTests: XCTestCase {
    func testRepositoryValidation() throws {
        XCTAssertEqual(try GitHubReleaseClient.parseRepository("https://github.com/owner/addon.git"), "owner/addon")
        XCTAssertEqual(try GitHubReleaseClient.parseRepository("oUF-wow/oUF"), "oUF-wow/oUF")
        XCTAssertThrowsError(try GitHubReleaseClient.parseRepository("https://example.com/owner/addon"))
        XCTAssertThrowsError(try GitHubReleaseClient.parseRepository("owner/../addon"))
    }
    func testAssetRuleRequiresExactlyOneMatchingZIP() throws {
        let data = Data("""
        {"id":1,"tag_name":"v1", "assets":[
        {"id":10,"name":"MyAddon-1.zip","size":100,"browser_download_url":"https://github.com/a/b/releases/download/v1/MyAddon-1.zip"},
        {"id":11,"name":"MyAddon-debug.zip","size":100,"browser_download_url":"https://github.com/a/b/releases/download/v1/MyAddon-debug.zip"}]}
        """.utf8)
        let release = try JSONDecoder().decode(Release.self, from: data)
        let client = GitHubReleaseClient()
        XCTAssertEqual(try client.asset(named: "MyAddon-1.zip", in: release).id, 10)
        XCTAssertThrowsError(try client.asset(named: "MyAddon-*.zip", in: release))
        XCTAssertThrowsError(try client.asset(named: "Missing-*.zip", in: release))
    }
}
