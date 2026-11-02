# 原生验收记录 · 2026-11-01

本页保留当时的验收结果；后续系统备份往返及连接切换复验见 [2026-11-02 记录](VALIDATION-native-2026-11-02.md)。

任务：[hermes-ios#1](https://github.com/allen7wang/hermes-ios/issues/1)。本轮使用 GitHub macOS runner 上的独立 iPhone 16 Pro / iOS 18.5（22F77）模拟器，Xcode 16.4（16F6）、macOS 15.8.2。操作由 XCUITest 点按、输入及调用系统文件界面完成，不代表真机触摸验收。

## 当前结果

| 验收内容 | 状态 | 证据 |
| --- | --- | --- |
| 现有领域、模型及布局回归 | 475 通过，0 失败、0 跳过 | [完整回归与 Release 运行](https://github.com/allen7wang/hermes-ios/actions/runs/41283262336)、[摘要](evidence/native-2026-11-01/regression-summary.json) |
| iOS Simulator Release 构建 | 通过 | 同一运行的 Verify Release build 步骤 |
| 工作台、检索结果、归档及草稿保护 | 3 项原生用例通过 | [原生工作台运行](https://github.com/allen7wang/hermes-ios/actions/runs/41286792974)、[完整摘要](evidence/native-2026-11-01/workspace-run-summary.json) |
| 系统备份导出 | 已实际保存 JSON，并显示成功反馈 | [文件往返运行](https://github.com/allen7wang/hermes-ios/actions/runs/41289259132)、下方截图 |
| 系统备份导入、冲突及空安装恢复 | 未完成 | 已能打开系统选择器并看到导出的文件；选择文件后尚未观察到选择器退出或导入预览，仍在定位 |
| 真实 Hermes API 对话及审批 | 未执行 | 尚无获授权的隔离测试服务配置 |

工作台运行的完整包包含 4 项用例，结果为 **3 通过、1 失败**；失败的是备份用例，不能称该轮整体通过。独立备份运行仍未通过，不把已有备份模型单元测试等同于系统文件往返成功。

## 已完成的原生检查

- 从统一检索打开项目、资料、消息、草稿及归档对话；按对话类型查看结果，显式打开归档开关后加入归档，回收站与其他连接不出现在该列表。
- 归档对话显示恢复入口，输入控件不可用。
- 编辑草稿后退出 App，以同一隔离安装重启，通过检索打开后完整文字仍在。
- 将隔离草稿文件替换为目录制造写入失败；点按新对话被拒绝，错误可见，原输入和当前对话保留。
- 系统导出在“在我的 iPhone 上 → Hermes”保存 JSON，随后在导入选择器中看到同一文件。

## 修正与隔离

修正原有消息库批量字符统计表达式在 Xcode 16.4 上的类型检查超时，逐项累加保持原统计语义。现有 475 项回归和 Release 构建均在修正后通过。

新增独立 HermesUITests target、Debug 专用隔离夹具与 CI。只有明确设置测试标志和合法 run UUID 才使用独立 UserDefaults / Application Support 数据；空凭据存储不访问钥匙串，自定义会话拒绝网络。Release 不包含夹具。App Documents 可供系统文件界面访问，内部记录仍在 Application Support。

回归及 Release 基于 `531ffa6`，3 项工作台交互基于 `85eba63`；后续到 `3af1db8` 只修改备份测试操作和工作流，Hermes、Hermes.xcodeproj 与 tools 产品树保持一致。

## 截图

- [草稿写入失败阻止新对话](evidence/native-2026-11-01/draft-write-failure.png)
- [重启后恢复编辑过的草稿](evidence/native-2026-11-01/draft-after-restart.png)
- [打开项目结果](evidence/native-2026-11-01/project-result.png)
- [打开资料结果](evidence/native-2026-11-01/document-result.png)
- [归档对话不可发送](evidence/native-2026-11-01/archived-read-only.png)
- [系统导出选择器](evidence/native-2026-11-01/system-export-picker.png)
- [系统导出成功](evidence/native-2026-11-01/system-export-saved.png)
- [导入选择后仍停留在选择器](evidence/native-2026-11-01/import-selection-pending.png)

截图逐张检查；来源、原始附件名、CI commit 和 SHA-256 见 [provenance.json](evidence/native-2026-11-01/provenance.json)。完整 xcresult / 日志由 CI 保留 14 天，本目录保留关键摘要和截图。

## 真实 API 所缺条件

已检查仓库 Actions Secrets、Variables、Environments 和自托管 runner，均无测试配置；本机为 WSL，无 Xcode 或 SSH Mac 别名。本机虽已安装 Hermes，但 `~/.hermes/.env` 未设置 API Server 项，gateway 配置为空。未发现已配置的获授权隔离 API 服务。

需要提供测试服务地址，以及凭据的现有安全配置位置；不要把实际密钥写进 Issue、仓库或验收截图。拿到条件后，按 [原生验收复现与真实 API 步骤](NATIVE-ACCEPTANCE.md) 完成真实对话、审批及服务端日志核对。当前任务保持打开。
