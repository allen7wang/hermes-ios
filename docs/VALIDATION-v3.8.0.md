# Hermes iOS v3.8.0 验证记录

日期：2026-10-24（北京时间）

基线：v3.7.0 / `891065119fdd7797fc2805d388736616d82912ff`

## 交付范围

- 项目资料库、资料详情和批量整理页提供“移除引用”入口；明确选择资料和同项目目标对话，初始不选择任何对话。保留标题搜索隐藏的选择并显示数量，可选择当前结果或清空选择。
- 移除范围可覆盖项目全部 20 篇、200,000 正文字符资料；这是资料库范围，单段对话的已有引用仍最多 5 篇、50,000 字符。只移除已经存在的所选引用，其余资料保持相对顺序，后续请求按新顺序重新编号。
- 检查页展示进行中、归档和回收站目标的完整前后引用、篇数、字符量、实际移除数量和涉及资料全文；未引用所选资料的对话显示无需改动。全部无需改动时不写入。
- 提交重建方案，核对项目名称、选定资料及全部前后引用涉及的资料快照、目标标题、归属、状态与完整引用。整批检查完成后一次原子保存，失败不发布部分结果。
- 保留资料正文、历史消息、日期、收藏、草稿和图片；最新固定状态、收藏备注、草稿、无关资料和未选对话的修改可保留。不恢复记录或自动发送，生成期间禁止修改引用。
- 不新增持久化字段、依赖或 API。备份兼容读取 v1–v7，按实际内容选择最低版本；含资料继续使用 v7。冲突检查限共享同一 AppModel 的窗口。

## 结果

| 检查 | 结果 | 范围 |
|---|---|---|
| Mac Catalyst 完整 XCTest | 420 项通过，0 失败、0 跳过 | 新增 22 项规则、模型及集成回归和 3 项布局检查；结果包 runtimeWarnings 为空 |
| iOS Simulator Release | 构建通过 | 通用模拟器目标，实际 CFBundleShortVersionString 为 3.8.0 |
| iOS 18.1 完整 XCTest | 420 项通过，0 失败、0 跳过 | 独立 iPhone 16 Pro / iOS 18.1（22B81）；结果包 runtimeWarnings 为空 |
| 布局截图 | 三张逐张检查 | 390 × 1200、1024 × 1300、390 × 1500；分别检查选择、宽窄前后对比 |
| 原生点击 | 未完成 | Computer Use 报告 Mac 锁屏，自动解锁因物理输入暂停；未重试解锁 |

新增逻辑回归涵盖：按保留顺序移除、空引用与全部移除、重复/缺失资料及不合法旧引用拒绝、20 篇/200,000 字符库范围、只读检查、混合状态与无需变化项、精确对话子集、整批原子保存和失败保护、重启加载、v7 编解码与实际导入后的引用重映射、附件与草稿保留。

过期保护分别覆盖完整引用顺序、对话标题、归档/回收站状态、项目迁移、永久删除、移除项和保留项的资料正文修改、项目改名、切换连接、恢复状态与生成忙碌保护。集成检查验证后续上下文重新编号且不改动历史文字；与 v3.7 多消息引用到草稿按两种顺序执行均保留彼此结果；旧添加方案在移除后拒绝，重新检查后可按所选顺序追加引用。

## 布局证据

图像由隔离 UserDefaults、临时 JSON、示例 JPEG 和拒绝网络请求的测试模型生成，从本轮 Catalyst xcresult 导出附件。不是原生点击或真机触摸截图，渲染本身不执行保存、搜索或导航；滚动区域内未全部展示的内容不视为点击验收。

- [目标选择 · 窄布局](../preview/removal-select-compact-v3-8-demo.png)
- [前后检查 · 宽布局](../preview/removal-review-wide-v3-8-demo.png)
- [前后检查 · 窄布局](../preview/removal-review-compact-v3-8-demo.png)

## 复现

在健康源码副本 `/private/tmp/hermes-refadd-20261023-workspace`（已快进至上述 v3.7 基线）使用 Xcode 27.1。复用现有依赖和独立平台构建缓存，未改动已有模拟器；本轮创建独立设备 `4930E34D-026A-47F5-90C5-A1FB672E869D`（iPhone 16 Pro / iOS 18.1，22B81），测试后只关闭并删除该设备。

```sh
xcodebuild -project Hermes.xcodeproj -scheme HermesTests \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath /private/tmp/hermes-v3-4-validation \
  -clonedSourcePackagesDirPath /private/tmp/hermes-v1-validation/SourcePackages \
  SUPPORTS_MACCATALYST=YES CODE_SIGNING_ALLOWED=NO \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -resultBundlePath /private/tmp/hermes-refremove-20261024-catalyst.xcresult test

xcodebuild -project Hermes.xcodeproj -scheme HermesTests \
  -configuration Release -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /private/tmp/hermes-v3-4-ios-release \
  -clonedSourcePackagesDirPath /private/tmp/hermes-v1-validation/SourcePackages \
  CODE_SIGNING_ALLOWED=NO \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile build

xcodebuild -project Hermes.xcodeproj -scheme HermesTests \
  -configuration Debug -destination 'platform=iOS Simulator,id=<isolated-device-uuid>' \
  -derivedDataPath /private/tmp/hermes-v3-4-ios-release \
  -clonedSourcePackagesDirPath /private/tmp/hermes-v1-validation/SourcePackages \
  CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -resultBundlePath /private/tmp/hermes-refremove-20261024-ios.xcresult test
```

结果包路径需尚不存在，模拟器 UUID 和缓存路径按本机调整。对应日志为 `/private/tmp/hermes-refremove-20261024-catalyst.log`、`/private/tmp/hermes-refremove-20261024-ios-release.log`、`/private/tmp/hermes-refremove-20261024-ios.log`。两平台执行同一套用例，不相加计算独立用例数量。

## 边界与未覆盖范围

- 本版为源码预览，无签名 IPA；未执行真机、真实 Hermes API、VoiceOver 或系统文件导出/导入往返验收。自动化备份往返使用临时目录，不代表系统文件选择器交互通过；未验证 iOS 17 或 iOS 27。
- 只整理当前保存的选择，不追溯已经发送的请求。历史消息中的 `[资料N]` 保留原文，不作为当前资料版本的出处凭据；移除不删除资料，重新添加会追加在保留项之后。
- 未提供跨进程/跨设备写锁或独立撤销记录；可检查后重新添加并在对话设置调整顺序。待发送图片由原聊天页持有，本轮通过模型检查保证已存附件保留，未通过点击验证局部选择状态。
