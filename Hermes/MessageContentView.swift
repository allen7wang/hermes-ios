import SwiftUI
import UIKit

struct MessageContentView: View {
    let text: String
    var rendersMarkdown = true

    var body: some View {
        if rendersMarkdown {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(MessageContent.blocks(text)) { block in
                    switch block.kind {
                    case .prose(let prose):
                        Text((try? AttributedString(markdown: prose, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(prose))
                            .font(.system(size: 15)).lineSpacing(4).textSelection(.enabled)
                    case .code(let language, let code):
                        CodeBlockView(language: language, code: code)
                    }
                }
            }
        } else {
            Text(text).font(.system(size: 15)).lineSpacing(4).textSelection(.enabled)
        }
    }
}

private struct CodeBlockView: View {
    let language: String?
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "代码").lineLimit(1)
                Spacer(minLength: 12)
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                } label: {
                    Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(copied ? "代码已复制" : "复制代码块")
            }
            .font(.caption.weight(.medium)).foregroundStyle(HermesTheme.accent)
            .padding(.horizontal, 12)
            Divider().overlay(HermesTheme.muted.opacity(0.2))
            ScrollView(.horizontal) {
                Text(code).font(.system(size: 13, design: .monospaced))
                    .textSelection(.enabled).fixedSize(horizontal: true, vertical: false)
                    .padding(12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HermesTheme.background, in: RoundedRectangle(cornerRadius: 10))
        .onChange(of: code) { _, _ in copied = false }
    }
}
