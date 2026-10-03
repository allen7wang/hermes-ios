# 更新记录

## v0.2.0 · 聊天体验增强

- 回复改为逐段实时显示，并展示 Hermes 的工具运行状态；支持停止和失败后重试。
- 支持从照片图库选图发送，使用 Hermes API 的内联图片格式；图片在本机单独保存，删除对话时清理。
- 增加连接状态检测、对话搜索、重命名和文本分享。
- 补充流式事件、图片请求及旧版聊天数据兼容性测试。

已通过 Xcode 27 的 iOS 18.1 模拟器构建和测试。真实 Hermes API Server 的端到端连接仍需在配置服务后验证。本版本仅发布源代码，不包含签名 IPA。

## v0.1.0 · 首个预览版

Hermes iOS 是用于连接自托管 Hermes Agent API Server 的原生 SwiftUI 客户端，支持 iOS 17 及更新版本。

### 新增

- 配置服务地址、API 密钥和模型，并通过 `/v1/models` 测试连接。
- 通过 `/v1/chat/completions` 发送消息；支持停止等待中的请求及失败后重试。
- 在设备本地保存对话，支持新建、切换和删除对话。
- 将 API 密钥保存在 iOS 钥匙串，提供深色界面和 App 图标。

### 安装与验证

- 下载源代码，用 Xcode 打开 `Hermes.xcodeproj`。真机运行需在 Xcode 中选择自己的签名 Team。
- 已通过 Xcode 27 的 iOS Simulator 构建，并在 iPhone 16 Pro（iOS 18.1）模拟器启动。
- 本次发布不包含签名后的 IPA；发布时未连接运行中的 Hermes API Server，真实消息往返尚未验证。
- 使用前请参照 [README](README.md) 启用 Hermes Agent API Server，并配置手机可访问的地址和密钥。
