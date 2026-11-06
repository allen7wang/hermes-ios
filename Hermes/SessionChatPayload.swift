import Foundation

enum SessionChatPayload {
    static let jpegDataURLPrefix = "data:image/jpeg;base64,"

    static func jpegDataURL(_ imageData: Data) -> String {
        jpegDataURLPrefix + imageData.base64EncodedString()
    }

    static func body(input: String, imageData: Data?) throws -> Data {
        guard let imageData else {
            return try JSONEncoder().encode(["input": input])
        }
        return try JSONEncoder().encode(ImageBody(input: parts(text: input, imageData: imageData)))
    }

    static func parts(text: String, imageData: Data) -> [Part] {
        var parts: [Part] = []
        if !text.isEmpty {
            parts.append(.text(text))
        }
        parts.append(.image(jpegDataURL(imageData)))
        return parts
    }

    enum Part: Encodable {
        case text(String)
        case image(String)

        func encode(to encoder: Encoder) throws {
            switch self {
            case .text(let text):
                try TextPart(text: text).encode(to: encoder)
            case .image(let url):
                try ImagePart(url: url).encode(to: encoder)
            }
        }

        private struct TextPart: Encodable {
            let type: String
            let text: String

            init(text: String) {
                type = "text"
                self.text = text
            }
        }

        private struct ImagePart: Encodable {
            struct ImageURL: Encodable { let url: String }
            let type: String
            let imageURL: ImageURL

            init(url: String) {
                type = "image_url"
                imageURL = ImageURL(url: url)
            }

            enum CodingKeys: String, CodingKey {
                case type
                case imageURL = "image_url"
            }
        }
    }

    private struct ImageBody: Encodable {
        let input: [Part]
    }
}
