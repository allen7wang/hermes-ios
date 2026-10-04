import Foundation
import UIKit

enum ImageAttachmentStore {
    private static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Attachments", isDirectory: true)
    }

    static func prepare(_ original: Data) throws -> Data {
        guard let image = UIImage(data: original) else { throw ImageError.invalidImage }
        let longestSide = max(image.size.width, image.size.height)
        guard longestSide > 0 else { throw ImageError.invalidImage }
        let ratio = min(1, 1600 / longestSide)
        let size = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
        let renderer = UIGraphicsImageRenderer(size: size)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        guard let data = resized.jpegData(compressionQuality: 0.72) else {
            throw ImageError.invalidImage
        }
        if data.count <= 2_000_000 { return data }
        guard let smaller = resized.jpegData(compressionQuality: 0.48),
              smaller.count <= 2_000_000 else { throw ImageError.tooLarge }
        return smaller
    }

    static func save(_ jpeg: Data, id: UUID = UUID(), directory: URL? = nil) throws -> UUID {
        try FileManager.default.createDirectory(at: directory ?? defaultDirectory, withIntermediateDirectories: true)
        try jpeg.write(to: fileURL(for: id, directory: directory), options: [.atomic, .completeFileProtectionUnlessOpen])
        return id
    }

    static func load(_ id: UUID, directory: URL? = nil) throws -> Data {
        try Data(contentsOf: fileURL(for: id, directory: directory))
    }

    static func image(_ id: UUID) -> UIImage? {
        UIImage(contentsOfFile: fileURL(for: id).path)
    }

    static func remove(_ id: UUID, directory: URL? = nil) {
        try? FileManager.default.removeItem(at: fileURL(for: id, directory: directory))
    }

    static func fileURL(for id: UUID, directory: URL? = nil) -> URL {
        (directory ?? defaultDirectory).appendingPathComponent(id.uuidString).appendingPathExtension("jpg")
    }

    enum ImageError: LocalizedError {
        case invalidImage
        case tooLarge

        var errorDescription: String? {
            switch self {
            case .invalidImage: "无法读取这张图片。"
            case .tooLarge: "图片压缩后仍超过 2 MB，请选择较小的图片。"
            }
        }
    }
}
