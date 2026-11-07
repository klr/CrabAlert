//
//  CrabAlertTests.swift
//  CrabAlertTests
//
//  Created by Karl Roos on 2023-10-21.
//

import XCTest
@testable import CrabAlert

final class EndpointTests: XCTestCase {

    func testParseAddsSchemeAndStripsTrailingSlash() {
        XCTAssertEqual(Endpoint.parse("localhost:1081")?.absoluteString, "http://localhost:1081")
        XCTAssertEqual(Endpoint.parse("  http://mail.test:1080/  ")?.absoluteString, "http://mail.test:1080")
        XCTAssertEqual(Endpoint.parse("HTTPS://staging.example.com/mailcrab/")?.absoluteString, "https://staging.example.com/mailcrab")
    }

    func testParseRejectsInvalidInput() {
        XCTAssertNil(Endpoint.parse(""))
        XCTAssertNil(Endpoint.parse("   "))
        XCTAssertNil(Endpoint.parse("ftp://localhost:1080"))
        XCTAssertNil(Endpoint.parse("http://"))
    }

    func testDefaultEndpointURLs() {
        let endpoint = Endpoint.default
        XCTAssertEqual(endpoint.inboxURL.absoluteString, "http://localhost:1080/")
        XCTAssertEqual(endpoint.webSocketURL.absoluteString, "ws://localhost:1080/ws")
        XCTAssertEqual(endpoint.bodyURL(for: "abc").absoluteString, "http://localhost:1080/api/message/abc/body")
        XCTAssertEqual(endpoint.displayAddress, "localhost:1080")
    }

    func testHTTPSEndpointUsesSecureWebSocketAndKeepsBasePath() {
        let endpoint = Endpoint(name: "Staging", baseURL: Endpoint.parse("https://staging.example.com/mailcrab")!)
        XCTAssertEqual(endpoint.inboxURL.absoluteString, "https://staging.example.com/mailcrab/")
        XCTAssertEqual(endpoint.webSocketURL.absoluteString, "wss://staging.example.com/mailcrab/ws")
        XCTAssertEqual(endpoint.bodyURL(for: "42").absoluteString, "https://staging.example.com/mailcrab/api/message/42/body")
    }
}

final class EndpointStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "CrabAlertTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testDefaultIsAlwaysFirst() {
        let store = EndpointStore(defaults: defaults)
        XCTAssertEqual(store.all, [.default])

        XCTAssertNil(store.add(name: "Second", urlString: "localhost:1081"))
        XCTAssertEqual(store.all.first, .default)
        XCTAssertEqual(store.all.count, 2)
    }

    func testAddAndRemovePersist() {
        let store = EndpointStore(defaults: defaults)
        XCTAssertNil(store.add(name: "Second", urlString: "localhost:1081"))

        let reloaded = EndpointStore(defaults: defaults)
        XCTAssertEqual(reloaded.custom.map(\.name), ["Second"])
        XCTAssertEqual(reloaded.custom.first?.baseURL.absoluteString, "http://localhost:1081")

        reloaded.remove(ids: [reloaded.custom[0].id])
        XCTAssertTrue(EndpointStore(defaults: defaults).custom.isEmpty)
    }

    func testAddValidation() {
        let store = EndpointStore(defaults: defaults)
        XCTAssertNotNil(store.add(name: "", urlString: "localhost:1081"))
        XCTAssertNotNil(store.add(name: "Bad", urlString: "ftp://nope"))
        XCTAssertNotNil(store.add(name: "Dup of default", urlString: "http://localhost:1080/"))

        XCTAssertNil(store.add(name: "Second", urlString: "localhost:1081"))
        XCTAssertNotNil(store.add(name: "Dup", urlString: "http://localhost:1081"))
        XCTAssertEqual(store.custom.count, 1)
    }

    func testDefaultCannotBeRemoved() {
        let store = EndpointStore(defaults: defaults)
        store.remove(ids: [Endpoint.defaultID])
        XCTAssertEqual(store.all, [.default])
    }
}
