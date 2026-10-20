import MarkdownUI
import SwiftUI

extension Theme {
    /// 与 HermesTheme 一致的紧凑深色主题(应用固定深色模式,聊天气泡为 surface 底色)。
    static var hermes: Theme {
        Theme()
            .text {
                FontSize(15)
            }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(.em(0.87))
                ForegroundColor(HermesTheme.accent)
                BackgroundColor(HermesTheme.raised)
            }
            .link {
                ForegroundColor(HermesTheme.accent)
                UnderlineStyle(Text.LineStyle(pattern: .solid))
            }
            .heading1 { configuration in
                configuration.label
                    .markdownMargin(top: .em(0.9), bottom: .em(0.45))
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(.em(1.3))
                    }
            }
            .heading2 { configuration in
                configuration.label
                    .markdownMargin(top: .em(0.9), bottom: .em(0.45))
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(.em(1.15))
                    }
            }
            .heading3 { configuration in
                configuration.label
                    .markdownMargin(top: .em(0.9), bottom: .em(0.45))
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(.em(1.05))
                    }
            }
            .heading4 { configuration in
                configuration.label
                    .markdownMargin(top: .em(0.8), bottom: .em(0.4))
                    .markdownTextStyle { FontWeight(.semibold) }
            }
            .heading5 { configuration in
                configuration.label
                    .markdownMargin(top: .em(0.8), bottom: .em(0.4))
                    .markdownTextStyle { FontWeight(.semibold) }
            }
            .heading6 { configuration in
                configuration.label
                    .markdownMargin(top: .em(0.8), bottom: .em(0.4))
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        ForegroundColor(HermesTheme.muted)
                    }
            }
            .paragraph { configuration in
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .relativeLineSpacing(.em(0.15))
                    .markdownMargin(top: .zero, bottom: .em(0.8))
            }
            .blockquote { configuration in
                HStack(alignment: .top, spacing: 8) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(HermesTheme.muted.opacity(0.6))
                        .frame(width: 3)
                    configuration.label
                        .markdownTextStyle { FontStyle(.italic) }
                        .fixedSize(horizontal: false, vertical: true)
                }
                .markdownMargin(top: .zero, bottom: .em(0.8))
            }
            .codeBlock { configuration in
                ScrollView(.horizontal) {
                    configuration.label
                        .fixedSize(horizontal: false, vertical: true)
                        .relativeLineSpacing(.em(0.15))
                        .relativePadding(.horizontal, length: .em(0.8))
                        .relativePadding(.vertical, length: .em(0.6))
                        .markdownTextStyle {
                            FontFamilyVariant(.monospaced)
                            FontSize(.em(0.87))
                        }
                }
                .background(HermesTheme.background, in: RoundedRectangle(cornerRadius: 10))
                .markdownMargin(top: .zero, bottom: .em(0.8))
            }
            .table { configuration in
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .markdownTableBorderStyle(.init(color: HermesTheme.muted.opacity(0.35), width: 1))
                    .markdownTableBackgroundStyle(.alternatingRows(Color.clear, HermesTheme.raised.opacity(0.35)))
                    .markdownMargin(top: .zero, bottom: .em(0.8))
            }
            .tableCell { configuration in
                configuration.label
                    .markdownTextStyle {
                        if configuration.row == 0 {
                            FontWeight(.semibold)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .relativeLineSpacing(.em(0.15))
                    .relativePadding(.horizontal, length: .em(0.6))
                    .relativePadding(.vertical, length: .em(0.3))
            }
            .thematicBreak {
                Divider()
                    .overlay(HermesTheme.muted.opacity(0.3))
                    .markdownMargin(top: .em(1), bottom: .em(1))
            }
    }
}
