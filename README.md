# Hermes iOS

一个原生 SwiftUI 客户端，用 iPhone 或 iPad 连接你自己的 Hermes Agent API Server。

## 已实现

- 配置服务地址、API 密钥与模型；通过 `/v1/models` 测试连接。
- 通过 `/v1/chat/completions` 发送对话，支持停止等待中的请求。
- 在设备本地保存对话；API 密钥存于系统钥匙串。
- 深色界面、对话记录、新对话、删除对话和失败后重试。

## 运行

1. 用 Xcode 打开 `Hermes.xcodeproj`，选择 `Hermes` scheme 和模拟器或真机。
2. 真机运行时，在 Xcode 的 Signing & Capabilities 中选择你的 Team，并按需修改 Bundle Identifier。
3. 在运行 Hermes Agent 的主机上启用 API Server：在 `~/.hermes/.env` 设置 `API_SERVER_ENABLED=true` 和 `API_SERVER_KEY=<your-secret>`，然后运行 `hermes gateway`。服务默认仅监听 `127.0.0.1:8642`；这是主机自身的回环地址，iPhone 无法直接连接。请为手机提供可访问的 HTTPS 地址，或在可信局域网中配置服务监听地址。
4. 在 App 的“连接设置”中填写可从手机访问的地址和密钥。地址可以是服务根路径或以 `/v1` 结尾。

远程服务要求 HTTPS。局域网 HTTP 只接受 `localhost`、`.local` 主机名及私有 IPv4 地址。不要把带有终端工具权限的 Hermes API 直接暴露到公网。

本仓库发布的是 Xcode 源代码工程，不包含签名后的 IPA。首版使用非流式聊天响应，等待较长任务时可停止请求并重试。

## 构建

```sh
xcodebuild -project Hermes.xcodeproj -scheme Hermes \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

工程文件可用 `ruby tools/generate_project.rb` 重新生成。图标可用 `python3 tools/generate_icon.py Hermes/Assets.xcassets/AppIcon.appiconset/AppIcon.png` 重新生成。

API 格式依据 [Hermes Agent 官方 API Server 文档](https://hermes-agent.nousresearch.com/docs/user-guide/features/api-server)。
