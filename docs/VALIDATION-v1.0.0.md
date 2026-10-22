# Hermes iOS v1.0.0 验证记录

日期：2026-10-22

基线：v0.11.0 / aa4329579293a9254b4c27fc11788a046ca36c7a

交付内容：v1.0.0 Xcode 源码工程、测试与文档；远端提交和发布状态以仓库分支及 Releases 页面为准。

## 本次范围

1. 对话工作台：标签、归档/恢复、批量整理、搜索与排序、Markdown 文件导出。
2. 对话控制：会话级模型、供应商、系统提示词、0–50 轮上下文；按连接保存新对话默认值。
3. 服务端任务：状态概览、手动或 30/60/120 秒前台刷新、失败退避、复制为新任务。
4. 主导航与界面：对话 / 服务端 / 消息库 / 设置四个入口；连接引导、聊天配置栏、归档提示和版本信息。
5. 数据：备份 v4，兼容 v1–v3；保存失败不显示成功，批量删除使用恢复日志。

## 已完成的验证

| 检查 | 结果 | 范围 |
|---|---|---|
| iOS Simulator Debug build-for-testing | 通过 | 编译应用及测试包，未启动 iOS 模拟器 |
| iOS Simulator Release build | 通过 | 无签名、通用模拟器目标 |
| Mac Catalyst XCTest | 142 项通过，0 失败 | 原有 117 项、新增 22 项逻辑回归、3 项布局截图 |
| 截图人工检查 | 通过 | Mac Catalyst 390 × 844 窄宽布局及 1024 × 1000 宽布局，使用示例数据 |
| git diff --check | 通过 | 格式检查 |
| 未跟踪同步副本 | 保留 | 原有 4 个带空格的 Swift 副本未纳入编译、未修改 |

新增逻辑回归覆盖旧记录迁移、标签去重与边界、归档筛选、确定性排序、设置持久化及连接隔离、并发回复中的操作保护、保存失败、批量删除草稿清理、归档分支继承、v4 往返与中断恢复、重复导入、备份降级拒绝、上下文轮次边界、排除旧图片与备注、模型/供应商/系统消息请求、任务复制和刷新退避。

图片请求的旧测试已改用独立临时目录。Mac Catalyst 的图片和恢复日志使用 Mac 可读的原子写入；iOS 分支仍保留原有的文件保护选项。

## 截图

以下是 XCTest 在 Mac Catalyst 验证窗口中生成的布局图，属于代码渲染的真实截图；不是 iPhone/iPad 设备截图，不代表已完成触摸交互验收。

- [对话工作台窄宽布局](../preview/workbench-v1-demo.png)
- [对话设置窄宽布局](../preview/conversation-settings-v1-demo.png)
- [任务列表宽布局](../preview/server-tasks-v1-demo.png)

## 本机环境限制与待验收项

- Xcode 27.1（27A9275）要求 CoreSimulator 1174.9.2，本机安装的是 1171.7。模拟器支持被 Xcode 禁用；查询模拟器及开发组件初始化未能恢复运行。没有删除、重置或清空用户模拟器。
- 验证时 Mac 处于锁屏状态，原生界面的点击验收尚未完成，尤其是导航返回、标签编辑、批量选择、自动刷新切换、复制任务创建及系统导出器。
- 未连接真实 Hermes API Server。请求格式依据 [Hermes 官方 API 文档](https://hermes-agent.nousresearch.com/docs/user-guide/features/api-server) 并使用 URLProtocol 模拟响应验证，未证明真实模型路由、工具执行、任务创建/运行与联网稳定性。
- 未进行 iPhone/iPad 真机启动、文件 App 的 Markdown 导出、JSON 备份往返、后台/锁屏恢复或签名分发验证。
- 新版仍为源码预览版，没有签名 IPA 或商店发布；Mac Catalyst 用于本次验证，不作为新增的正式 Mac 产品交付。

## 可复现命令

iOS 编译：

```sh
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

本次逻辑回归的替代目标：

```sh
xcodebuild -project Hermes.xcodeproj -scheme HermesTests \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath /private/tmp/hermes-v1-validation \
  SUPPORTS_MACCATALYST=YES CODE_SIGNING_ALLOWED=NO test
```

修复本机 Xcode 组件后，应在实际可用的 iOS 模拟器上运行同一 scheme，再补齐上述交互与真机验收。Catalyst 结果不能替代这些验证。
