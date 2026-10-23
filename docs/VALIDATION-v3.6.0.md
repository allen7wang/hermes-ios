# Hermes iOS v3.6.0 验证记录

日期：2026-10-23

基线：v3.5.0 / `8e98c2643333134449799466929353bb673a47be`

交付：批量添加项目资料引用的源码、回归测试、示例截图与说明；远端提交状态以仓库分支为准。本轮不交付签名 IPA。

## 范围

- 从资料库、资料详情及资料批量整理页选择待添加资料，调整顺序，明确选择目标对话。
- 保留原引用位置，按选择顺序追加未引用项；包含进行中、归档、回收站及无需改动的行。
- 检查完整前后顺序、编号、篇数、字符量和涉及资料全文，保存前重新验证全部选中范围与快照。
- 超出 5 篇或 50,000 正文字符时整批拒绝；一次原子写入，不改动消息、草稿、收藏、图片、日期或状态。
- 接入已发布的 v3.5 消息库更新；无新增持久化字段或依赖，沿用 v1–v7 JSON 备份。

## 结果

| 检查 | 结果 | 范围 |
|---|---|---|
| Mac Catalyst XCTest | 363 项通过，0 失败、0 跳过 | 完整回归，结果包无 runtimeWarnings |
| iOS 18.1 XCTest | 363 项通过，0 失败、0 跳过 | 本轮专用 iPhone 16 Pro（22B81），完整回归，结果包无 runtimeWarnings |
| iOS Simulator Release | 通过 | 通用目标，实际 CFBundleShortVersionString 为 3.6.0 |
| 布局检查 | 三张逐张检查 | 390 × 1200、1024 × 1300、390 × 1500；从 Catalyst 结果包导出 |
| 原生点击 | 未完成 | 独立宿主构建通过；交互工具打开窗口时 Mac 锁屏，未取得可交互窗口 |

新增 21 项回归验证追加顺序与已有位置、空引用和重复去重、无效输入、5 篇与 50,000 字符边界、精确连接/项目范围、只读预览、混合状态与无需变更行、明确子集、过期完整引用/标题/状态/归属、永久删除、涉及资料编辑、无关资料及收藏更新保留、单行超限整批拒绝、写入失败、恢复保护、下一次上下文顺序、重复提交不写入、回复期间保护，以及重启和 v7 备份往返后的全部其他数据保留。

新增 3 项布局测试同时验证只渲染和预览不会写文件或修改草稿。iOS 与 Catalyst 是两个平台上的相同测试集，不把它们相加为不同用例数量。

## 过程与证据

初期 v3.4 基线上的尝试遇到磁盘空间不足、SwiftUI Section 初始化写法及测试图片格式问题，均不计入通过统计。清理本对话可再生成的临时编译缓存，修正界面初始化及 JPEG 测试图片后，接入期间新增的 v3.5，并使用最终 v3.6 源码完整重跑两平台测试。未清理个人文件、依赖源码或已有结果包。

开发与验证位于 `/private/tmp/hermes-refadd-20261023-workspace`。91 个 Swift 源码、测试、工程及生成脚本记录 SHA-256，用于最终提交与回写原项目前核对。复用旧缓存目录名称不代表产物版本；正式 iOS Release 的版本已单独检查。

- Catalyst 结果：`/private/tmp/hermes-refadd-20261023-catalyst.xcresult`
- iOS 结果：`/private/tmp/hermes-refadd-20261023-ios.xcresult`
- Release 日志：`/private/tmp/hermes-refadd-20261023-ios-release.log`
- [资料与对话选择](../preview/addition-select-v3-6-demo.png)
- [添加前后方案 · 宽布局](../preview/addition-review-wide-v3-6-demo.png)
- [添加前后方案 · 窄布局](../preview/addition-review-compact-v3-6-demo.png)

提交的三张图来自 Catalyst XCTest 隔离窗口的结果附件，使用示例数据和 URLProtocol 网络守卫；不是原生点击或真机截图。单独构建的原生宿主使用独立目录、空凭证及网络拦截，仅用于尝试点击验收，其启动代码和数据不进入正式工程。锁屏阻止验收，故不声称原生流程通过。

iOS 使用本轮创建的隔离设备 `F69B2BC6-3B77-4326-916F-EAB68C8B0238`，通过后只关闭并删除此设备，没有重置或清理其他模拟器。

## 复现

Xcode 27.1（27A9275），Mac macOS 27.0.1。依赖缓存路径按本机调整；结果包路径需尚不存在。

```sh
xcodebuild -project Hermes.xcodeproj -scheme HermesTests \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath /private/tmp/hermes-v3-4-validation \
  -clonedSourcePackagesDirPath /private/tmp/hermes-v1-validation/SourcePackages \
  SUPPORTS_MACCATALYST=YES CODE_SIGNING_ALLOWED=NO \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile test

xcodebuild -project Hermes.xcodeproj -scheme HermesTests \
  -configuration Release -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /private/tmp/hermes-v3-4-ios-release \
  -clonedSourcePackagesDirPath /private/tmp/hermes-v1-validation/SourcePackages \
  CODE_SIGNING_ALLOWED=NO -disableAutomaticPackageResolution \
  -onlyUsePackageVersionsFromResolvedFile build

xcodebuild -project Hermes.xcodeproj -scheme HermesTests \
  -configuration Debug -destination 'platform=iOS Simulator,id=<isolated-device-uuid>' \
  -derivedDataPath /private/tmp/hermes-v3-4-ios-release \
  -clonedSourcePackagesDirPath /private/tmp/hermes-v1-validation/SourcePackages \
  CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile test
```

## 限制

- 未执行原生点击、VoiceOver、真机触摸、真实 Hermes API、系统文件导出/导入往返或跨设备恢复；未验证 iOS 17 与 iOS 27 运行。
- 更新只影响当前保存的资料选择和后续请求，不改写历史文字、编号或曾发送的资料；没有一键撤销，可重新选择资料或恢复备份。
- 字符量不是模型令牌量，模型如何引用仍取决于服务端。并发检查限共享同一 AppModel 的窗口，不提供跨进程或跨设备锁。
