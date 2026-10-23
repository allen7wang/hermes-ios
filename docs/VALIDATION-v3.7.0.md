# Hermes iOS v3.7.0 验证记录

日期：2026-10-23 至 2026-10-24（北京时间）

基线：v3.6 工作提交 / `cacb5765dd72597d56233b7f837dedf2c8f46f3d`

## 交付范围

- 消息库多选新增“引用到草稿”，收藏与取消收藏移入同一底栏菜单。沿用当前连接、进行中与归档来源及隐藏选择，排除回收站、服务端和其他连接；来源最多 100 条、500,000 字符。
- 以打开检查页时的来源与目标草稿为快照，展示目标连接、对话、项目、原草稿、完整引用及最终草稿。默认追加，替换非空草稿需二次确认；可复制预览草稿，成功后可查看目标草稿。
- 引用沿用完整 Markdown 汇编信息，每行加引用前缀，保留全文与空白、稳定消息时间顺序。收藏备注始终排除，来源图片仅用占位说明，不加载或附加附件。
- 完整引用及最终草稿分别最多 100,000 字符，包含元数据、换行与引用标记，超限拒绝而不截断。替换可用于原草稿过长的情况，但引用自身仍须满足上限。
- 目标只允许当前进行中或尚未创建记录的新对话。提交前重建来源并核对连接名称、全部消息快照、目标身份/标题/项目与原草稿全文。一次原子保存草稿成功后才更新界面，不自动发送、不改动历史与收藏。
- 沿用现有草稿 JSON 和 v1–v7 备份，按内容选择最低所需格式；无新增持久化字段、API 或依赖。

## 结果

| 检查 | 结果 | 范围 |
|---|---|---|
| Mac Catalyst XCTest | 395 项通过，0 失败、0 跳过 | 新增 12 项引用规则、17 项模型和 3 项布局检查；结果包无 runtimeWarnings |
| iOS Simulator Release | 编译通过 | 通用 iOS 模拟器目标，实际应用版本 3.7.0 |
| iOS 18.1 专项 | 91 项通过，0 失败、0 跳过 | 新引用及原消息库、批量收藏与资料引用添加回归；结果包无 runtimeWarnings |
| 布局截图 | 三张逐张检查 | 390 × 1200 两张、1024 × 1100 一张 |
| 原生点击、真机触摸 | 未执行 | 本轮继续按已授权的自动验收与发布范围交付 |

规则检查涵盖带 CRLF、空行与代码块的完整文字、4,000 字符以上 Unicode 正文、备注与附件标识排除、图片占位、稳定组合标识排序、100,000 字符精确边界及引用前缀膨胀。追加/替换保留首尾空白，空白引用拒绝，超长原草稿可替换。

模型检查涵盖只读快照、混合来源、当前目标与新对话草稿、来源正文/备注/标题/项目归属过期、目标切换/改名/归档与草稿冲突、引用自身超限及追加超限时替换、写入失败不发布、恢复保护、重新加载及 JSON 备份导入、附件与其他草稿保留。受控流式测试检查生成期间保存引用后，新回复继续完成且不覆盖草稿、不额外发送请求。

引用准备使用冻结来源；切换追加/替换仅改变同一引用与原草稿的组合。确认框显式执行替换，并在最终提交再次校验。发生冲突时保留打开时的预览、禁用写入，可复制预览或返回重新检查。成功后的“查看目标草稿”仅在目标仍为当前进行中/新对话时启用；AppShell 清除来源定位后打开目标，不调用“回到来源消息”。

## 合并与复验

本次功能原先独立基于 v3.5 开发，修正了备份恢复测试遗漏“（已导入）”名称标记的断言后，通过 370 项 Catalyst、66 项 iOS 专项及 Release 构建。发布前发现主分支新增 v3.6“批量添加资料引用”，原推送与原目录同步均被基线检查安全拒绝，未覆盖其他更新。保留远端新增功能后合并本次 32 项检查（含新增两种执行顺序的组合回归），以 v3.7 重新构建和测试；本页最终数量仅采用合并后的结果。原独立验证记录留在 `/private/tmp/hermes-v3-6-workspace` 及对应 xcresult，不能作为合并版本的通过证据。

## 布局证据

使用隔离 UserDefaults、临时文件、无凭证示例数据与拒绝网络请求的 URLProtocol 守卫。图像由 Mac Catalyst XCTest 验证窗口生成，不是 iPhone/iPad 原生触摸截图；渲染检查本身不执行保存按钮、替换确认或导航点击。

- [追加引用 · 窄布局](../preview/draft-quote-append-v3-7-demo.png)
- [替换草稿 · 宽布局](../preview/draft-quote-replace-v3-7-demo.png)
- [草稿冲突保护 · 窄布局](../preview/draft-quote-conflict-v3-7-demo.png)

## 复现

使用 Xcode 27.1（27A9275）。开发、构建与发布验证在健康副本 `/private/tmp/hermes-v3-7-workspace` 完成；预期变更同步回原 iCloud 目录，替换前核对上述 v3.6 工作提交基线并保留原文件备份。原有四个同步重复 Swift 文件与本机数据不纳入发布。构建前仅清理已知旧版临时 DerivedData，保留源码和 xcresult 记录。

```sh
xcodebuild -project Hermes.xcodeproj -scheme HermesTests \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath /private/tmp/hermes-v3-7-validation \
  -clonedSourcePackagesDirPath /private/tmp/hermes-v1-validation/SourcePackages \
  SUPPORTS_MACCATALYST=YES CODE_SIGNING_ALLOWED=NO \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -resultBundlePath /private/tmp/hermes-v3-7-final.xcresult test

xcodebuild -project Hermes.xcodeproj -scheme HermesTests \
  -configuration Release -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /private/tmp/hermes-v3-7-ios-release \
  -clonedSourcePackagesDirPath /private/tmp/hermes-v1-validation/SourcePackages \
  CODE_SIGNING_ALLOWED=NO \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile build
```

iOS 专项使用本次新建的隔离 iPhone 16 Pro / iOS 18.1（22B81），设备 UUID 为 `272D445F-D662-4167-AE84-6E13B424C404`，替换 UUID 后复现。结束后只删除本次设备，不重置已有模拟器。

```sh
xcodebuild -project Hermes.xcodeproj -scheme HermesTests \
  -configuration Debug \
  -destination 'platform=iOS Simulator,id=<isolated-device-uuid>' \
  -derivedDataPath /private/tmp/hermes-v3-7-ios-release \
  -clonedSourcePackagesDirPath /private/tmp/hermes-v1-validation/SourcePackages \
  CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -only-testing:HermesTests/MessageDraftQuoteTests \
  -only-testing:HermesTests/MessageDraftQuoteModelTests \
  -only-testing:HermesTests/MessageDraftQuoteVisualTests \
  -only-testing:HermesTests/MessageLibraryTests \
  -only-testing:HermesTests/MessageLibraryBatchModelTests \
  -only-testing:HermesTests/ProjectReferenceAdditionTests \
  -only-testing:HermesTests/ProjectReferenceAdditionVisualTests \
  -resultBundlePath /private/tmp/hermes-v3-7-ios-tests.xcresult test
```

日志分别为 `/private/tmp/hermes-v3-7-final.log`、`/private/tmp/hermes-v3-7-ios-release.log` 和 `/private/tmp/hermes-v3-7-ios-tests.log`。结果包路径需尚不存在，依赖缓存位置可按本机调整。iOS 专项是另一平台的执行，不与完整 Catalyst 数量相加。

## 限制

- 非草稿源码预览 prerelease，无签名 IPA，不代表 App Store 上架。
- 本轮未执行原生点击、替换确认与导航的实际交互、VoiceOver、真机、真实 Hermes API、跨设备恢复或系统文件导出/导入往返；未验证 iOS 17、iOS 27 或完整 iOS 回归。
- 引用只是草稿中的文字，后续来源编辑不会自动同步，没有绑定实时资料或出处校验；发送前仍须手动检查正文、目标与请求上下文。所选正文按原文保留，不自动附加来源备注、连接配置、项目知识库正文或其他未选消息。
- 替换没有一键撤销，可在确认前复制原草稿；关闭未保存检查页不写入草稿。聊天页已有待发送图片保持原局部状态，本轮没有通过交互测试验证该状态。
- 允许生成期间整理草稿，不停止回复、不新增网络请求。并发检查限共享同一 AppModel 的窗口，不提供跨进程或跨设备锁；使用既有 drafts.json 单文件原子写入。
