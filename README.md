# Hermes iOS

一个原生 SwiftUI 客户端，用 iPhone 或 iPad 连接你自己的 Hermes Agent API Server。

## 已实现

- 保存、编辑和切换多个服务器连接；各连接的密钥分别存于系统钥匙串，本机历史与文字草稿分别保存。
- 通过 `/v1/models` 读取可用模型名称或别名，支持列表选择及手动填写；测试连接，并在主界面查看当前连接名称与状态。
- 本机对话和服务端会话的文字草稿自动保存在设备上，切换会话或重新打开 App 后恢复；发送后清空对应草稿。
- 通过 `/v1/chat/completions` 实时显示流式回复与工具运行状态，支持停止和失败后重试。
- 从照片图库选择一张图片随消息发送；图片会压缩到最长边 1600 像素、最多 2 MB。
- 在设备本地保存对话和图片，支持搜索、重命名、分享文本、新建及删除对话；API 密钥存于系统钥匙串。
- 在“服务端”新建和续聊远端会话，实时显示回复与工具进度；支持停止，以及服务端要求审批时的“允许本次”或“拒绝”。
- 查看远端会话，分批加载更早的消息；支持重命名、删除和分享已加载的文本记录。
- 查看所有定时任务（包括已暂停任务），创建、编辑、删除、暂停、恢复或手动运行任务，并查看最近的错误状态。

## 运行

1. 用 Xcode 打开 `Hermes.xcodeproj`，选择 `Hermes` scheme 和模拟器或真机。
2. 真机运行时，在 Xcode 的 Signing & Capabilities 中选择你的 Team，并按需修改 Bundle Identifier。
3. 在运行 Hermes Agent 的主机上启用 API Server：在 `~/.hermes/.env` 设置 `API_SERVER_ENABLED=true` 和 `API_SERVER_KEY=<your-secret>`，然后运行 `hermes gateway`。服务默认仅监听 `127.0.0.1:8642`；这是主机自身的回环地址，iPhone 无法直接连接。请为手机提供可访问的 HTTPS 地址，或在可信局域网中配置服务监听地址。
4. 在 App 的“连接管理”中编辑默认连接，或添加多个连接，填写可从手机访问的地址和密钥。地址可以是服务根路径、以 `/v1` 结尾，或包含服务端 Profile 路径，例如 `https://example.com/p/work/v1`。

远程服务要求 HTTPS。局域网 HTTP 只接受 `localhost`、`.local` 主机名及私有 IPv4 地址。不要把带有终端工具权限的 Hermes API 直接暴露到公网。

本仓库发布的是 Xcode 源代码工程，不包含签名后的 IPA。图片理解能力取决于你配置的 Hermes 模型。分享对话时导出文本，图片用 `[图片]` 标记；删除对话会一并删除其本地图片。

“对话记录”保存于当前设备；“服务端”读取 Hermes 服务器上的会话，二者不会自动合并。服务端会话首次加载最近 100 条消息，可以继续加载更早的记录。续聊只发送新消息，由服务端管理上下文和模型；当前支持文本输入。若连接中断，请刷新记录确认服务端状态，App 不会自动重发消息。停止操作会向服务端请求中断，实际停止时间取决于正在运行的工具。

定时任务使用 Hermes 的日程表达式，例如 `every 1h`、`every day at 9am` 或 `0 9 * * *`，时间以服务端配置的时区为准。暂停、恢复及手动运行会直接改变服务器上的任务状态；立即运行也会恢复已暂停的任务。编辑只提交发生变化的名称、任务说明和日程，其他设置由服务器保留。删除任务会取消正在运行的任务，并需在 App 中确认。

## 多连接、模型与草稿

- 点击连接列表中的名称切换当前连接，点击铅笔编辑；保存后该连接成为当前连接。回复进行中需要先停止或等待完成才能修改连接。
- 升级时，旧服务地址、模型、钥匙串密钥和本机历史自动归入“默认连接”。修改名称、密钥或模型会保留该连接的记录；改用不同的服务器地址会另存为新连接，原连接和记录仍可切换回来。末尾 `/v1`、默认端口等写法差异不会创建新连接。
- 左滑删除连接需要确认，会删除对应的本机历史、图片、文字草稿和密钥；不会删除服务器上的会话或任务。
- “读取模型列表”读取 `/v1/models` 公布的名称或别名；列表不代表所有供应商模型。测试连接不会自动替换手动填写的名称，选好模型后需要保存。实际模型由 Hermes 服务端配置决定，服务端会话继续使用自己的模型设置。
- 文字草稿按连接、会话分别保存，仅存在当前设备，不跨设备同步。新对话也有独立草稿。尚未发送的图片不属于草稿，切换对话时会清除，需要重新选择。

## 界面示例

下图使用示例地址，展示多连接管理界面。

<img src="preview/connections-demo.png" width="300" alt="多连接管理界面，使用示例地址">

下图使用模拟会话和模拟审批数据，展示服务端续聊界面。

<img src="preview/remote-session-demo.png" width="300" alt="服务端续聊和审批界面，使用模拟数据">

## 构建

```sh
xcodebuild -project Hermes.xcodeproj -scheme Hermes \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

工程文件可用 `ruby tools/generate_project.rb` 重新生成。图标可用 `python3 tools/generate_icon.py Hermes/Assets.xcassets/AppIcon.appiconset/AppIcon.png` 重新生成。

24 项测试覆盖流式解析、旧数据迁移、连接与草稿隔离、发送中切换保护、模型发现、服务端续聊、消息分页及任务操作，可在 Xcode 的 `HermesTests` scheme 中运行。

v0.5.0 已在 iPhone 16 Pro（iOS 18.1）模拟器通过测试及 Release 构建。连接管理界面使用隔离的示例数据检查；本次未进行真实 Hermes API Server 的端到端测试。

API 格式依据 [Hermes Agent 官方 API Server 文档](https://hermes-agent.nousresearch.com/docs/user-guide/features/api-server)。
