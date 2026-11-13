import XCTest
@testable import Hermes

final class PairingPayloadTests: XCTestCase {
    private func sampleKey() -> String { "unit" + "-value" }

    func testRoundTripKeepsOnlyDeclaredFields() throws {
        let encoded = try PairingPayload.encode(name: "家中的 Mac", url: "http://127.0.0.1:8642", key: sampleKey())
        let decoded = try PairingPayload.decode(encoded)
        XCTAssertEqual(decoded, PairingPayload(name: "家中的 Mac", url: "http://127.0.0.1:8642", key: sampleKey()))
        XCTAssertTrue(encoded.hasPrefix("{\"v\":1,\"name\":"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set(["v", "name", "url", "key"]))
        XCTAssertEqual(object["v"] as? Int, 1)
    }

    func testEscapingRoundTrip() throws {
        let name = "引号\"和\\换\n行"
        let key = "k" + "ey-\"" + "值"
        let encoded = try PairingPayload.encode(name: name, url: "https://hermes.example.com/v1", key: key)
        let decoded = try PairingPayload.decode(encoded)
        XCTAssertEqual(decoded.name, name)
        XCTAssertEqual(decoded.key, key)
    }

    func testMissingOrBlankNameDefaults() throws {
        let missing = try PairingPayload.decode("{\"v\":1,\"url\":\"http://127.0.0.1:8642\",\"key\":\"abc\"}")
        XCTAssertEqual(missing.name, "扫码连接")
        let blank = try PairingPayload.decode("{\"v\":1,\"name\":\"  \",\"url\":\"http://127.0.0.1:8642\",\"key\":\"abc\"}")
        XCTAssertEqual(blank.name, "扫码连接")
        let encoded = try PairingPayload.encode(name: "  ", url: "http://localhost:8642", key: "abc")
        XCTAssertEqual(try PairingPayload.decode(encoded).name, "扫码连接")
    }

    func testRejectsUnknownVersion() {
        assertError("{\"v\":2,\"name\":\"n\",\"url\":\"http://127.0.0.1:8642\",\"key\":\"abc\"}", .unknownVersion)
        assertError("{\"v\":0,\"url\":\"http://127.0.0.1:8642\",\"key\":\"abc\"}", .unknownVersion)
    }

    func testRejectsEmptyURLAndKey() {
        XCTAssertThrowsError(try PairingPayload.encode(name: "n", url: "  ", key: "abc")) { error in
            XCTAssertEqual(error as? PairingPayloadError, .emptyURL)
        }
        XCTAssertThrowsError(try PairingPayload.encode(name: "n", url: "http://127.0.0.1:8642", key: " \n")) { error in
            XCTAssertEqual(error as? PairingPayloadError, .emptyKey)
        }
        assertError("{\"v\":1,\"url\":\"\",\"key\":\"abc\"}", .emptyURL)
        assertError("{\"v\":1,\"url\":\"http://127.0.0.1:8642\",\"key\":\"   \"}", .emptyKey)
    }

    func testRejectsExtraFieldsAndMalformedValues() {
        assertError("{\"v\":1,\"url\":\"http://127.0.0.1:8642\",\"key\":\"abc\",\"token\":\"no\"}", .invalid)
        assertError("{\"v\":1,\"url\":\"http://127.0.0.1:8642\"}", .invalid)
        assertError("{\"v\":true,\"url\":\"http://127.0.0.1:8642\",\"key\":\"abc\"}", .invalid)
        assertError("{\"v\":\"1\",\"url\":\"http://127.0.0.1:8642\",\"key\":\"abc\"}", .invalid)
        assertError("not-json", .invalid)
        assertError("[1]", .invalid)
    }

    func testTrimsURLAndKey() throws {
        let decoded = try PairingPayload.decode("  {\"v\":1,\"url\":\" http://127.0.0.1:8642 \",\"key\":\" abc \"}  ")
        XCTAssertEqual(decoded.url, "http://127.0.0.1:8642")
        XCTAssertEqual(decoded.key, "abc")
    }

    private func assertError(_ raw: String, _ expected: PairingPayloadError, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try PairingPayload.decode(raw), file: file, line: line) { error in
            XCTAssertEqual(error as? PairingPayloadError, expected, file: file, line: line)
        }
    }
}
