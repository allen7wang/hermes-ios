# Hermes iOS v2.0.0 验证记录

日期：2026-10-23

基线：v1.1.0 / `75fe535663c1c0220778a18f3b9747d984e72293`

## 交付范围

- 项目工作区：创建、编辑、搜索、项目简介与共同指令、进行中/归档/回收站概览、原对话打开、独立新对话和 Markdown 导出。
- 五个常驻入口；工作台与消息库按项目组合筛选；单条和批量归属整理；对话设置与项目归属同次保存。
- 项目指令与对话指令按顺序组合，仅用于本机项目请求；发送前预览显示来源及实际内容，项目变化后标记过期。
- 解散项目保留所有对话、图片、收藏、草稿与配置；备份 v6 及旧版迁移、稳定关系映射与重复导入。

## 验证结果

| 检查 | 结果 | 范围 |
|---|---|---|
| Mac Catalyst XCTest | 188 项通过，0 失败、0 跳过 | 新增 21 项项目逻辑、2 项消息库组合筛选、3 项布局检查 |
| iOS Simulator Release 通用目标 | 编译通过 | 无签名，应用版本 2.0.0；没有运行 iOS 模拟器 |
| 布局截图检查 | 通过 | 390 × 844 与 1024 × 1000，隔离示例数据 |
| 独立代码审查 | 未发现发布阻断问题 | 数据保留、连接隔离、请求内容、备份映射、预览过期与确认动作 |

新测试覆盖旧记录无项目字段的解码；项目字段与数量边界；连接编辑和切换；保存失败；新建独立项目草稿且不联网；归档对话移动与回收站保护；设置与归属原子保存；解散保留活动、归档、回收站、图片、草稿和日期；事务中断恢复；分支归属；v6 往返、版本降级拒绝、失联引用、跨连接相同项目标识；外部及同安装重复导入；8000 字符项目指令与 10000 字符对话指令组合；真实请求与预览一致且不携带简介或其他对话；回复中禁止更改项目。

## 截图

以下由 XCTest 在 Mac Catalyst 验证窗口生成，属于真实代码布局截图，不是 iPhone/iPad 设备运行或触摸交互验收。

- [项目列表窄宽布局](../preview/projects-v2-demo.png)
- [项目筛选工作台宽布局](../preview/project-workbench-v2-demo.png)
- [项目上下文预览窄宽布局](../preview/project-context-v2-demo.png)

使用独立临时目录、固定示例消息、内存凭据和网络阻断，不读取真实聊天与密钥。

## 验证路径与复现

受 iCloud 占位文件读取等待影响，开发和验证在本机副本完成。基线文件逐一按 Git 索引对象摘要验证；29 个改动文件已同步回原工作区并逐文件核对摘要，原文件保留在忽略的本地备份目录。发布使用独立 Git 副本，并核对提交树与已验证源码。

最终测试结果包：`/private/tmp/hermes-v2-final.xcresult`。

```sh
xcodebuild -project Hermes.xcodeproj -scheme HermesTests \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath /private/tmp/hermes-v2-validation \
  SUPPORTS_MACCATALYST=YES CODE_SIGNING_ALLOWED=NO test

xcodebuild -project Hermes.xcodeproj -scheme HermesTests \
  -configuration Release -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /private/tmp/hermes-v2-ios-release \
  CODE_SIGNING_ALLOWED=NO build
```

实际验证复用了现有 Swift Package 缓存，并禁止自动改动已解析的依赖版本。

## 限制

- Xcode 27.1（27A9275）要求 CoreSimulator 1174.9.2，本机为 1171.7，iOS 模拟器运行仍被禁用。没有重置或删除用户模拟器。
- 原生工具确认 Mac 锁屏，无法继续原生点击验证。项目创建/编辑/移动/解散确认、五入口导航返回和系统文件导出器的原生交互仍需补验；Catalyst 测试与布局截图不能替代这些验收。
- 没有连接真实 Hermes API Server；请求一致性使用 URLProtocol 模拟响应检查，未验证真实模型路由、工具执行或网络稳定性。
- 未验收真机文件 App 的 Markdown 导出、JSON 备份往返、后台/锁屏恢复或签名分发。本版为 Xcode 源码预览版，不含签名 IPA，也不表示已上架 App Store。
- 项目仅属于本机连接，简介和其他对话不会自动进入请求；共同指令会随本机项目请求发送，并随 JSON 备份导出。解散项目后旧备份仍可能包含原项目定义。
