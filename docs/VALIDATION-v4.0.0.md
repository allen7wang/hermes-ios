# Hermes iOS v4.0.0 验证记录

日期：2026-10-25（北京时间）

基线：v3.9.0 / `04d3c1c5d6d1a5d1e0c31e54ecb93096d4e4cc99`

## 交付范围

- 首屏改为工作台：新对话、最多三条继续草稿、全部草稿、最近进行中对话、最近项目，以及统一检索和全部对话。
- 统一检索当前连接本机项目名称/简介、资料标题/正文、对话标题/标签、消息正文/收藏备注、文字草稿。空白或超过 200 字符的关键词不执行匹配；忽略大小写与变音差异。归档默认排除，可明确纳入；回收站、其他连接、远端和孤立草稿不进入结果。项目指令及对话系统提示词不参与检索。
- 关键词匹配完整文字，摘要在命中附近摘录；按类别计全部匹配，最多显示最新 50 条，同时间用复合目标标识排序。类别筛选不重新扫描数据。200 ms 防抖，后台计算、协作取消及完整请求快照检查阻止过期结果发布，不持久化搜索索引。
- 结果可打开项目、资料、对话、消息原文或草稿。导航时重查连接及目标存在；切换聊天前先确认当前草稿持久化成功，失败则保持当前选择与输入，不自动发送。归档草稿打开后仍不能发送，需先恢复。
- 草稿不新增修改时间；新对话草稿优先，其余按关联对话更新时间排列。保留完整正文，仅列表预览摘录。
- 项目列表按一次聚合计算各项目对话数，资料批量操作收进“整理资料”；原有入口与操作仍可到达。README 精简为产品概览，新增使用指南，旧 README 正文及历史截图说明完整归档。
- 无新增持久化字段、服务端接口或依赖，继续按最低所需版本导出，读取 v1–v7 JSON 备份。

- 修复原有对话/新对话/连接切换的草稿写失败保护；同一目标不重载，保存连接、创建项目对话和分支前同样先保存当前草稿。

## 结果

| 检查 | 结果 | 范围 |
| --- | --- | --- |
| Mac Catalyst 完整 XCTest | 475 项通过，0 失败、0 跳过 | 最终结果包无 runtimeWarnings |
| iOS 18.1 完整 XCTest | 475 项通过，0 失败、0 跳过 | 隔离 iPhone 16 Pro，结果包无 runtimeWarnings |
| iOS Simulator Release | 构建通过，实际版本 4.0.0 | 通用模拟器目标，arm64 与 x86_64 |
| 布局截图 | 三张逐张检查 | 390 × 1200、1024 × 1200、390 × 1100 |
| 原生点击、真机、真实 API、系统文件往返 | 未执行 | 按已授权的自动验收与发布范围交付 |

本版新增 22 项检查：19 项领域/模型、3 项布局。领域/模型覆盖五类字段全文、深处 Unicode 命中摘录、中文/表情/大小写/变音、空白与 200 字符边界、每类 50 条保留但 325 条完整计数、稳定顺序及复合消息标识；归档显式选择、回收站/跨连接/远端/孤立草稿排除；新草稿优先、项目计数聚合；目标过期、草稿写入失败、旧切换入口与修复后恢复切换、生成中只读、损坏存储保护、重启及 v7 实际导入。

最终源码在两平台验证后逐文件 SHA-256 核对保持。19 项逻辑测试不替代统一检索输入、筛选与点按导航的原生交互。

## 编译修正

首轮构建发现旧对话行组件仅限原文件访问，改为项目内共享组件后重跑。一次单独的 Catalyst build 动作未解析到对应运行目标；最终采用完整 test 动作验证。未执行的构建不计入通过统计。

## 布局证据

三张布局来自 XCTest 的临时 JSON、独立 UserDefaults、无凭证与拒绝网络的隔离窗口。渲染前后核对连接、项目、对话、回收站、选择及草稿保持。不是原生点击或真机截图。

- [工作台窄布局](../preview/workspace-home-v4-demo.png)
- [统一检索宽布局](../preview/workspace-search-v4-demo.png)
- [全部草稿窄布局](../preview/workspace-drafts-v4-demo.png)

## 复现

Xcode 27.1，健康副本 `/private/tmp/hermes-v4-workspace`。原 iCloud 目录同步前逐文件核对基线，备份替换文件，保留原有重复 Swift 文件及本机数据。仅清理本任务已完成旧版本的临时构建目录，保留源码与测试结果。

```sh
xcodebuild -project Hermes.xcodeproj -scheme HermesTests \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath /private/tmp/hermes-v4-validation \
  -clonedSourcePackagesDirPath /private/tmp/hermes-v1-validation/SourcePackages \
  SUPPORTS_MACCATALYST=YES CODE_SIGNING_ALLOWED=NO \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -resultBundlePath /private/tmp/hermes-v4-final.xcresult test

xcodebuild -project Hermes.xcodeproj -scheme HermesTests \
  -configuration Release -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /private/tmp/hermes-v4-ios-release \
  -clonedSourcePackagesDirPath /private/tmp/hermes-v1-validation/SourcePackages \
  CODE_SIGNING_ALLOWED=NO \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile build

xcodebuild -project Hermes.xcodeproj -scheme HermesTests \
  -configuration Debug \
  -destination 'platform=iOS Simulator,id=<isolated-device-uuid>' \
  -derivedDataPath /private/tmp/hermes-v4-ios-release \
  -clonedSourcePackagesDirPath /private/tmp/hermes-v1-validation/SourcePackages \
  CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -resultBundlePath /private/tmp/hermes-v4-ios-tests.xcresult test
```

结果包需尚不存在；缓存路径可按本机调整。两平台计数不相加为独立测试数。

iOS 使用本次创建的 iPhone 16 Pro / iOS 18.1（22B81），设备 UUID 为 `95999CEE-F4C6-41B4-8C68-413BEF540841`，完成后仅删除本次设备。日志为 `/private/tmp/hermes-v4-final.log`、`/private/tmp/hermes-v4-ios-release.log`、`/private/tmp/hermes-v4-ios-tests.log`；结构化结果为 `/private/tmp/hermes-v4-catalyst-summary.json` 与 `/private/tmp/hermes-v4-ios-summary.json`。

发布三张 PNG 从最终 Catalyst 结果包 `WorkspaceDiscoveryVisualTests` 附件导出，来源清单与 SHA-256 保存在 `/private/tmp/hermes-v4-preview-provenance.json`。该导出不依赖两平台共享的临时 PNG 路径，避免后运行平台覆盖布局来源。

## 限制

- 非草稿源码预览 prerelease，无签名 IPA，不代表 App Store 上架。
- 本轮未执行原生点击、检索输入/归档开关/结果导航的实际交互、VoiceOver、真机、真实 Hermes API、跨设备恢复或系统文件导出/导入往返。自动逻辑测试及隔离渲染不等同于这些验收。
- 检索不包含图片 OCR、附件字节、未加载的远端数据或服务端草稿；没有跨连接搜索和设备同步。每类展示上限 50 是呈现限制，完整正文仍参与匹配，匹配总数不受该上限截断。
- 草稿筛选与导航检查覆盖同一 AppModel 的本机状态，不提供跨进程或跨设备锁；原有共享模型窗口的冲突保护继续沿用。
