import Foundation
import XCTest
@testable import DokkuStatus

final class SSHConfigDefaultProviderTests: XCTestCase {
    func testParseProfilesReturnsAllConcreteAliases() {
        let config = """
        Host dokku-prod prod
          HostName 10.0.0.5
          User root
          Port 2222
        """

        let parsed = SSHConfigDefaultProvider.parseProfiles(contents: config, currentUser: "local")

        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed.map { $0.sshAlias }, ["dokku-prod", "prod"])
    }

    func testParsePrefersDokkuAliasWhenAvailable() {
        let config = """
        Host github
          HostName github.com
          User git

        Host dokku-prod
          HostName 10.0.0.5
          User root
          Port 2222
        """

        let parsed = SSHConfigDefaultProvider.parseDefaultConfig(contents: config, currentUser: "local")

        XCTAssertEqual(parsed?.host, "10.0.0.5")
        XCTAssertEqual(parsed?.user, "root")
        XCTAssertEqual(parsed?.port, 2222)
        XCTAssertEqual(parsed?.sshAlias, "dokku-prod")
    }

    func testParseFallsBackToFirstConcreteAlias() {
        let config = """
        Host staging
          HostName staging.example.com
          User deploy
        """

        let parsed = SSHConfigDefaultProvider.parseDefaultConfig(contents: config, currentUser: "local")

        XCTAssertEqual(parsed?.host, "staging.example.com")
        XCTAssertEqual(parsed?.user, "deploy")
        XCTAssertEqual(parsed?.port, 22)
        XCTAssertEqual(parsed?.sshAlias, "staging")
    }

    func testParseUsesGlobalDefaultsWhenEntryOmitsUserAndPort() {
        let config = """
        User global-user
        Port 2200

        Host dokku
          HostName dokku.example.com
        """

        let parsed = SSHConfigDefaultProvider.parseDefaultConfig(contents: config, currentUser: "local")

        XCTAssertEqual(parsed?.host, "dokku.example.com")
        XCTAssertEqual(parsed?.user, "global-user")
        XCTAssertEqual(parsed?.port, 2200)
        XCTAssertEqual(parsed?.sshAlias, "dokku")
    }

    func testParseIgnoresWildcardAliases() {
        let config = """
        Host *
          User wildcard

        Host app-?
          HostName ignored.example.com

        Host prod
          HostName prod.example.com
          User deploy
        """

        let parsed = SSHConfigDefaultProvider.parseDefaultConfig(contents: config, currentUser: "local")

        XCTAssertEqual(parsed?.host, "prod.example.com")
        XCTAssertEqual(parsed?.user, "deploy")
        XCTAssertEqual(parsed?.sshAlias, "prod")
    }

    func testParseReturnsNilWhenNoConcreteHostsExist() {
        let config = """
        Host *
          User default
        """

        let parsed = SSHConfigDefaultProvider.parseDefaultConfig(contents: config, currentUser: "local")

        XCTAssertNil(parsed)
    }
}
