# Hermes iOS v1.1.0 验证记录

日期：2026-10-22

基线：v1.0.0 / 7df5a5e29208bf3263dba9c0fda9fb4b3d57157b

交付内容：v1.1.0 Xcode 源码工程、测试与文档；远端提交和发布状态以仓库分支及 Releases 页面为准。

## 本次范围

1. 本机回收站：移入、撤销、原文查看、单段/批量恢复与确认彻底删除；保留草稿、收藏、配置和共享图片。
2. 发送前上下文预览：与实际请求共用配置验证及上下文裁剪，显示原始消息、系统指令、模型/供应商、遗漏与图片数量；不发送请求。
3. 消息库：组合对话范围、标签、角色和文字搜索，排除回收站。
4. 备份 v5：保留回收站状态，兼容 v1–v4，重复导入保留本机修改与恢复结果。

## 验证结果

| 检查 | 结果 | 范围 |
|---|---|---|
| Mac Catalyst XCTest | 162 项通过，0 失败、0 跳过 | 含 17 项新增逻辑回归、3 项新增布局截图；结果包无运行时警告 |
| iOS Simulator Debug build-for-testing | 通过 | 通用模拟器目标，应用与测试包编译 |
| iOS Simulator Release build | 通过 | 通用模拟器目标，无签名 |
| 截图人工检查 | 通过 | 390 × 844 窄宽布局及 1024 × 1000 宽布局，隔离示例数据 |
| 格式与提交范围 | 通过 | 本轮 28 个文件；原有 4 个带空格的 Swift 同步副本保留且未纳入 |

新增逻辑测试覆盖旧 v4 工作区解码、删除与恢复后的元数据/草稿/图片、归档状态保留、批量恢复且无自动过期、彻底删除仅接受当前连接的回收站记录、跨记录共享图片引用、写入失败不发布成功、恢复日志中断重启、v5 往返和降级拒绝、重复导入优先保留本机恢复结果、回收站记录不可选择或编辑收藏、预览不联网且不写待发送图片、预览与真实请求体一致、过期上下文/空输入/100,000 字符边界、超限发送不修改记录，以及消息库范围/标签/角色组合。

工作区部分 iCloud 占位文件持续等待下载，因此最终验证使用 `/private/tmp/hermes-v1-1-local-validation` 中的本机副本：从上述精确基线取得完整源码，叠加本轮 25 个改动/新增文件，逐个核对大小与 SHA-256。下载完成后，再核对工作区全部 59 个 Swift 源码、工程及生成脚本与验证副本完全一致；原有同步副本没有纳入验证工程。最终回归结果包为 `/private/tmp/hermes-v1-1-local-verified.xcresult`。

原有删除测试已按新语义更新：先验证移入回收站后草稿和图片仍在，再验证彻底删除时清理；共享图片须等最后一段引用它的记录彻底删除后才移除。

## 截图

以下是 XCTest 在 Mac Catalyst 验证窗口中生成的真实布局截图，不是 iPhone/iPad 设备截图，也不代表触摸交互验收。

- [发送前上下文预览](../preview/context-preview-v1-1-demo.png)
- [回收站原文与恢复入口](../preview/trash-v1-1-demo.png)
- [消息库标签与归档状态](../preview/library-v1-1-demo.png)

完整回归还生成工作台、对话设置与服务端任务布局。界面使用隔离的测试目录、示例消息及模拟服务端数据，不读取真实聊天或密钥。

## 限制与待验收

- 本机 Xcode 27.1（27A9275）要求 CoreSimulator 1174.9.2，安装的是 1171.7；Xcode 禁用 iOS 模拟器运行。通用目标编译和 Catalyst 运行不等同于 iPhone/iPad 运行验收。
- 原生点击验收尚未完成；本轮通过原生工具检查时 Mac 仍锁屏。回收站的批量确认、撤销、弹层返回、筛选菜单及系统文件导出器仍需在解锁后的原生界面补验。
- 未连接真实 Hermes API Server。请求检查使用 URLProtocol 模拟响应，未验证服务端实际模型路由、图片理解或网络稳定性。
- 未验证真机文件 App 的 JSON 备份往返、后台/锁屏恢复、签名 IPA 或商店分发。本版仍为源码预览版，Catalyst 仅为验证目标。
- JSON 备份包含回收站内容，普通删除不会从新备份排除这些记录；彻底删除不会追溯修改已经导出的备份文件。删除连接会删除该连接所有本机记录，包括回收站。

## 可复现命令

```sh
xcodebuild -project Hermes.xcodeproj -scheme HermesTests \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath /private/tmp/hermes-v1-validation \
  SUPPORTS_MACCATALYST=YES CODE_SIGNING_ALLOWED=NO test

xcodebuild -project Hermes.xcodeproj -scheme HermesTests \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /private/tmp/hermes-v1-validation \
  CODE_SIGNING_ALLOWED=NO build-for-testing

xcodebuild -project Hermes.xcodeproj -scheme HermesTests \
  -configuration Release -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /private/tmp/hermes-v1-validation \
  CODE_SIGNING_ALLOWED=NO build
```

修复本机开发组件后，应在实际可用的 iOS 模拟器运行同一测试 scheme，并补齐上述原生交互和真机验证。
