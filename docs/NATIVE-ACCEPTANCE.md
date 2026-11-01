# 原生验收：工作台、草稿与系统备份

对应任务：[hermes-ios#1](https://github.com/allen7wang/hermes-ios/issues/1)。

本验收使用独立的 XCUITest 进程，在 iOS 模拟器中实际点按、输入、导航和操作系统文件选择器。它与已有的领域测试、模型测试及静态布局截图分别记录，不代表真机触摸或真实 Hermes API 已验收。

## 运行

需要 macOS、Xcode 和 Ruby 的 xcodeproj gem。首次执行：

```sh
gem install xcodeproj --no-document --user-install
ruby tools/generate_project.rb
xcodebuild -project Hermes.xcodeproj -list
xcrun simctl list devices available
```

使用可用的 iPhone 模拟器 UUID，结果目录必须尚不存在：

```sh
xcodebuild -project Hermes.xcodeproj -scheme HermesUITests \
  -destination 'platform=iOS Simulator,id=<device-uuid>' \
  CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled NO \
  -resultBundlePath NativeAcceptance.xcresult test
```

已有模型与布局回归仍使用 HermesTests scheme。CI 入口为 [Native acceptance](../.github/workflows/native-acceptance.yml)，为每次运行创建并清理专用 iPhone 模拟器；上传环境信息、日志、完整 xcresult、结构化摘要、截图和无凭据的辅助功能树。保留期为 14 天，需长期留存的证据应在过期前下载。

## 隔离范围

- 只有 Debug 构建且明确传入 `HERMES_UI_TESTING=1` 和合法 UUID 的 `HERMES_UI_RUN` 才会建立验收数据；普通运行继续使用原存储。Release 不包含验收夹具。
- 每个 run UUID 使用独立 UserDefaults 和 Application Support/UITests 子目录；进程重启沿用同一 UUID，空安装验证使用新 UUID。
- 夹具使用内存空凭据和拒绝网络的 URLProtocol，不读写系统钥匙串，不连接真实服务。
- 文件导出和导入调用产品的 fileExporter/fileImporter，测试通过系统界面选文件，不直接调用 importBackup 替代界面。
- App 的 Documents 文件夹可从“文件 → 在我的 iPhone 上 → Hermes”访问，用于保存和选择用户导出的文件。对话与验收数据仍存放在 Application Support，密钥仍由钥匙串管理。

## 自动原生交互范围

| 场景 | 核对内容 |
| --- | --- |
| 工作台与检索 | 点按统一检索，输入关键词，打开项目、资料、对话、消息和草稿结果 |
| 归档和连接范围 | 默认不含归档，打开归档开关后可打开归档对话；回收站和其他连接结果不可见 |
| 归档限制 | 打开归档对话后存在恢复入口，输入控件不可用 |
| 草稿持久化 | 编辑后退出 App，重新启动并通过检索打开，核对完整文字 |
| 写入失败保护 | 使用隔离目录制造草稿写入失败，核对错误、切换被拒绝和原输入仍在 |
| 系统文件往返 | 通过系统选择器保存 JSON，再选择该文件导入并确认合并 |
| 已有记录冲突 | 导出后修改本机草稿，导入旧备份后核对已有对话数量与新草稿保留 |
| 空安装恢复 | 新隔离安装通过同一系统文件导入，切换至导入连接，核对原草稿和项目引用 |

每次结果以实际 CI 摘要与截图为准，存在失败时不得把该场景记为通过。

## 真实 API 待验收

当前仓库未配置测试服务 Secret 或自托管 runner，本机为 WSL 且无 Xcode/SSH Mac 配置。真实 API 的服务地址、隔离账号和安全凭据位置仍待提供。

拿到获授权的测试环境后，在普通运行的 App 中执行，不使用上述拒绝网络的夹具：

1. 在“设置”新建独立测试连接，读取模型并测试连接；记录 App commit、Xcode/iOS、服务端版本与脱敏地址。
2. 在“服务端”创建唯一标题的验收会话，发送一次带运行标识的纯文字问题；记录会话 ID、可见回复、完成状态，以及刷新后的记录。
3. 使用测试服务事先确认的无副作用工具场景触发审批，核对请求内容与审批 ID，点按“允许本次”，记录服务端最终执行/回复；如执行拒绝分支，用另一次审批点按“拒绝”并核对结果。不能用伪造 SSE 事件认定真实审批通过。
4. 保留脱敏的客户端截图与服务端日志对应关系。只清理本轮创建的隔离测试记录，按测试环境约定保留必要证据。

真实 API 项未完成前，Issue 保持打开；不得用 XCUITest 夹具或既有 URLProtocol 测试替代此验收。
