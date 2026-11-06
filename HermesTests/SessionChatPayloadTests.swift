import XCTest
@testable import Hermes

final class SessionChatPayloadTests: XCTestCase {
    func testTextOnlyKeepsLegacyInputString() throws {
        for input in ["继续", "", "引号\"与换行\n以及/斜杠"] {
            let body = try SessionChatPayload.body(input: input, imageData: nil)
            XCTAssertEqual(body, try JSONEncoder().encode(["input": input]))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
            XCTAssertEqual(json, ["input": input])
        }
    }

    func testImageAndTextUsesOpenAIParts() throws {
        let image = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let body = try SessionChatPayload.body(input: "描述图片", imageData: image)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["input"])
        let parts = try XCTUnwrap(json["input"] as? [[String: Any]])
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(Set(parts[0].keys), ["type", "text"])
        XCTAssertEqual(parts[0]["type"] as? String, "text")
        XCTAssertEqual(parts[0]["text"] as? String, "描述图片")
        XCTAssertEqual(Set(parts[1].keys), ["type", "image_url"])
        XCTAssertEqual(parts[1]["type"] as? String, "image_url")
        let imageURL = try XCTUnwrap(parts[1]["image_url"] as? [String: String])
        XCTAssertEqual(imageURL, ["url": SessionChatPayload.jpegDataURL(image)])
        XCTAssertEqual(SessionChatPayload.jpegDataURLPrefix, "data:image/jpeg;base64,")
        XCTAssertTrue(SessionChatPayload.jpegDataURL(image).hasPrefix(SessionChatPayload.jpegDataURLPrefix))
    }

    func testImageOnlyOmitsEmptyTextPart() throws {
        let image = Data([0x01, 0x02])
        let body = try SessionChatPayload.body(input: "", imageData: image)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["input"])
        let parts = try XCTUnwrap(json["input"] as? [[String: Any]])
        XCTAssertEqual(parts.count, 1)
        XCTAssertEqual(parts[0]["type"] as? String, "image_url")
        XCTAssertNil(parts[0]["text"])
        let imageURL = try XCTUnwrap(parts[0]["image_url"] as? [String: String])
        XCTAssertEqual(imageURL["url"], SessionChatPayload.jpegDataURL(image))
        XCTAssertTrue(imageURL["url"]?.hasPrefix("data:image/jpeg;base64,") == true)
    }
}
