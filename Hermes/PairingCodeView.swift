import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

struct PairingCodeView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                content
                Text("配对码含密钥，只给你自己的另一台手机扫。")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
        .background(HermesTheme.background)
        .navigationTitle("配对码")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
    }

    private var content: some View {
        PairingCodeBody(
            name: pairingName,
            url: pairingURL,
            key: pairingKey
        )
    }

    private var pairingName: String {
        activeProfile?.name ?? "当前连接"
    }

    private var pairingURL: String {
        (activeProfile?.serverURL ?? model.settings.serverURL)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var pairingKey: String {
        model.key(for: model.activeProfileID)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var activeProfile: ConnectionProfile? {
        model.profiles.first { $0.id == model.activeProfileID }
    }
}

private struct PairingCodeBody: View {
    let name: String
    let url: String
    let key: String

    var body: some View {
        if key.isEmpty {
            ContentUnavailableView("当前连接没有密钥，无法出码", systemImage: "key.slash", description: Text(name))
        } else if url.isEmpty {
            ContentUnavailableView("当前连接没有服务地址，无法出码", systemImage: "link.badge.plus", description: Text(name))
        } else if let host = URLComponents(string: url)?.host?.lowercased(),
                  host == "localhost" || host == "::1" || host.hasPrefix("127.") {
            ContentUnavailableView("此地址只能在本机访问", systemImage: "network.slash",
                description: Text("请先将连接地址改为另一台手机能访问的局域网地址或 HTTPS 地址，再生成配对码。"))
        } else if !encoded.isEmpty, let image = PairingQRImage.make(encoded) {
            VStack(spacing: 8) {
                Text(name).font(.title3.weight(.semibold)).foregroundStyle(.white)
                Text(url).font(.footnote).foregroundStyle(HermesTheme.muted)
                    .textSelection(.enabled).multilineTextAlignment(.center)
            }
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(width: 260, height: 260)
                .padding(16)
                .background(.white, in: RoundedRectangle(cornerRadius: 16))
                .accessibilityLabel("配对码")
                .privacySensitive()
        } else {
            ContentUnavailableView("无法生成配对码", systemImage: "qrcode", description: Text("请检查当前连接后重试。"))
        }
    }

    private var encoded: String {
        (try? PairingPayload.encode(name: name, url: url, key: key)) ?? ""
    }
}

private enum PairingQRImage {
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    static func make(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "Q"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
