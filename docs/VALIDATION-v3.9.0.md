# Hermes iOS v3.9.0 验证记录

日期：2026-10-24（北京时间）

基线：v3.8 工作提交 / `96684b2a643507845e77a4feb12c1d7f13ff4abd`

## 交付范围

- 消息库“更多”菜单新增“存为项目资料”。来源沿用当前连接的本机进行中、归档、未分组及跨项目消息，不含回收站、其他连接或服务端；最多 100 条、500,000 个来源文字字符，至少一条消息有非空正文。
- 先明确选择同连接的任意目标项目，初始无项目选择；显示已有篇数与正文容量。资料库已满时不进入编辑，缺少项目时提示先创建项目。
- 完整 Markdown 汇编预填标题和正文，包含消息来源及时间顺序，不加入收藏备注，图片只保留占位。预填最多 100,000 字符；超过则拒绝转换，不截断，20,000–100,000 字符仍完整保留供手动精简。
- 最终标题 1–80 字符且不换行，正文 1–20,000 字符，目标最多 20 篇、200,000 正文字符。计数及容量使用现有资料格式归一后的文字，修剪首尾空白并保留内部格式；只新增一篇，不自动拆分。
- 检查页冻结完整来源与目标项目。保存前重新核对连接名称、所有消息与来源元数据及完整项目快照；来源过期、目标改变、恢复状态或回复生成期间拒绝写入。
- 显式“重新检查目标项目”使用同一来源重新验证，仅更新目标项目快照，保留编辑输入；来源已改变时刷新失败，需返回消息库重新选择。输入可复制，只保存在当前页，关闭或切换连接后不自动恢复。
- 一次原子保存成功后显示完成态并可查看新资料，拒绝原检查重复提交。保留来源、已有资料、对话、草稿、图片、收藏与参考资料选择，不自动引用或发送。
- 保存为普通项目资料，沿用 v7 资料备份及 v1–v7 读取；没有新增持久化来源关联、依赖或 API。

## 合并范围

本次开发开始后发现远端新增 v3.8“批量移除资料引用”。在完整验证前，将本次改动暂存，快进至上述远端提交，再恢复并合入采集功能，以 v3.9 统一验证。原目录只在基线匹配后同步，保留 v3.8 的代码、入口与历史文档。

新增双顺序集成用例：先冻结采集和移除引用两个方案，再分别以两种顺序提交；新资料与已有资料、剩余引用顺序、消息、草稿及重启状态均保留，新资料不自动引用。

## 编译修正

首次构建发现编辑页的 SwiftUI Section 标题与 footer 组合没有对应重载，未执行测试。改为显式 header/footer 闭包后，用最终源码重新构建及测试。首次日志保留在 `/private/tmp/hermes-v3-9-final.log` 和 `/private/tmp/hermes-v3-9-ios-release.log`，不计入通过统计。

首轮可执行套件为 453 项，452 项通过、1 项失败：新增备份恢复测试错误地比较未修剪末尾换行的预填文字，修正为比较实际已保存的资料正文，以验证现有归一格式的往返。同时将长正文编辑区改为固定高度内部滚动，并增加收起键盘入口。最终统计采用这些修正后的完整重跑，原结果包 `/private/tmp/hermes-v3-9-verified.xcresult` 保留。

## 结果

| 检查 | 结果 | 范围 |
|---|---|---|
| Mac Catalyst 完整 XCTest | 453 项通过，0 失败、0 跳过 | 新增 13 项格式/边界、17 项模型与集成、3 项布局；结果包无 runtimeWarnings |
| iOS Simulator Release | 构建通过 | 通用 iOS 模拟器目标，实际版本 3.9.0 |
| iOS 18.1 完整 XCTest | 453 项通过，0 失败、0 跳过 | 合并后完整套件，结果包无 runtimeWarnings |
| 布局截图 | 三张逐张检查 | 390 × 1100、1024 × 1200、390 × 1300 |
| 原生点击、真机 | 未执行 | 本轮继续按已授权的自动验收与发布范围交付 |

格式检查覆盖完整长 Unicode 正文、元数据与稳定顺序、备注和附件标识排除、纯图/空白拒绝与混合来源、100,000 预填边界、20,000 以上不截断、标题正文归一及 20 篇/200,000 字符容量边界。

模型检查覆盖跨项目、未分组和归档来源、同名项目的精确标识、完整来源和项目快照、来源正文/备注/标签/归属过期、目标资料/简介/指令/日期变化、连接切换和改名、容量拒绝、原子写入失败、恢复保护、刷新后保留编辑内容、旧检查重复提交拒绝、重启与 v7 实际导入、图片/草稿/引用保留，以及生成期间阻止保存。

## 布局证据

由 Mac Catalyst XCTest 隔离窗口生成，使用临时 JSON、独立 UserDefaults、无凭证示例数据与拒绝网络的 URLProtocol。渲染前后核对项目、消息、草稿及当前选择不变。不是 iPhone/iPad 原生点击或真机截图，渲染本身不执行编辑、刷新、保存或查看资料的点击。

- [明确选择目标项目](../preview/message-capture-projects-v3-9-demo.png)
- [编辑资料与容量检查](../preview/message-capture-editor-v3-9-demo.png)
- [项目冲突与保留输入](../preview/message-capture-conflict-v3-9-demo.png)

## 复现

使用 Xcode 27.1（27A9275），健康副本 `/private/tmp/hermes-v3-9-workspace`。同步原 iCloud 目录前核对上述基线，保留被替换原文件的备份；四个原有同步重复 Swift 文件及本机数据不纳入发布。仅清理已完成的旧版临时 DerivedData 以提供构建空间，源码及 xcresult 保留。

```sh
xcodebuild -project Hermes.xcodeproj -scheme HermesTests \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath /private/tmp/hermes-v3-9-validation \
  -clonedSourcePackagesDirPath /private/tmp/hermes-v1-validation/SourcePackages \
  SUPPORTS_MACCATALYST=YES CODE_SIGNING_ALLOWED=NO \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -resultBundlePath /private/tmp/hermes-v3-9-reviewed.xcresult test

xcodebuild -project Hermes.xcodeproj -scheme HermesTests \
  -configuration Release -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /private/tmp/hermes-v3-9-ios-release \
  -clonedSourcePackagesDirPath /private/tmp/hermes-v1-validation/SourcePackages \
  CODE_SIGNING_ALLOWED=NO \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile build
```

iOS 使用本次新建的隔离 iPhone 16 Pro / iOS 18.1（22B81），设备 UUID 为 `CF97D6C6-83B7-49C0-B61D-B7F2450BDFF9`；替换 UUID 后复现。结束后只删除本次设备，不重置已有模拟器。

```sh
xcodebuild -project Hermes.xcodeproj -scheme HermesTests \
  -configuration Debug \
  -destination 'platform=iOS Simulator,id=<isolated-device-uuid>' \
  -derivedDataPath /private/tmp/hermes-v3-9-ios-release \
  -clonedSourcePackagesDirPath /private/tmp/hermes-v1-validation/SourcePackages \
  CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -resultBundlePath /private/tmp/hermes-v3-9-ios-tests.xcresult test
```

日志分别为 `/private/tmp/hermes-v3-9-reviewed.log`、`/private/tmp/hermes-v3-9-ios-release-reviewed.log` 和 `/private/tmp/hermes-v3-9-ios-tests.log`。结果包路径需尚不存在，缓存可按本机调整；两平台测试数不相加为独立测试数量。

## 限制

- 非草稿源码预览 prerelease，无签名 IPA，不代表 App Store 上架。
- 本轮未执行原生点击、编辑/刷新/保存/详情导航与放弃编辑确认的实际交互、VoiceOver、真机、真实 Hermes API、跨设备恢复或系统文件导出/导入往返；未验证 iOS 17、iOS 27。
- 100,000 是完整汇编自动预填的上限；保存校验用户编辑后的合法资料文字，不重新生成或强制保留原始汇编。用户可精简、改写来源说明与正文。
- 新资料是采集时的独立文字快照，后续来源更新不会自动同步；没有 OCR、实时引用关系或历史资料来源校验。完整迁移使用 JSON 备份。
- 输入只在当前检查页保留，不是持久化草稿；关闭、切换连接或退出 App 前可先复制。显式刷新不改输入，源消息变化需重新选择。
- 冲突检查仅覆盖共享同一 AppModel 的窗口，不提供跨进程或跨设备锁；使用现有 connections.json 单文件原子写入，失败不发布部分结果。
