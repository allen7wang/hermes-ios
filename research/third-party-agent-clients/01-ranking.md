# 名单：谁在给没有官方 App 的 Agent 做手机端

数据采集：2026-11-13，iTunes Lookup，美国店评分人数。中国店另注。不是下载量。

## 官方有没有手机端

| Agent | 官方手机端 | 第三方在补什么 |
| --- | --- | --- |
| Hermes Agent | 没有 App Store 客户端。本仓库是源码 / 模拟器预览，未上架 | 连你自己的 Gateway / Webapp |
| DeepSeek Harness | 没有。README 只有 `npx @deepseek-ai/dsh web`，默认 `127.0.0.1:3080`，不提手机 [1] | 电脑上跑 dsh，手机续会话、审批、收通知 |
| OpenCode | 没看到官方 App | 连自建 OpenCode server，评分最高约 15 |
| Claude Code | 有。官方 Claude App 的 Code 页 | 第三方还在做，但不再是「没人做」 |
| Codex | 有。官方在 ChatGPT App 里 | Codex Relay 这类还在，窗口在关 |

DSH 官方仓库 `deepseek-ai/deepseek-harness`，2026-11-13 两次查询约 28.0 万 star（279,899，随后 279,907），当天仍在更新。体量和「没有官方手机端」叠在一起，所以第三方这周扎堆，不是因为已经有人做出了高下载 App。

## 商店里能对上号的

只列文案写明「连你自己的 Agent / 电脑」，不列名字里带 Hermes 但实际是另一个聊天壳的。

### Hermes

| App | 评分 | 开发者 | 文案里的接法 |
| --- | --- | --- | --- |
| Hermex | 222 | Uzair Ansar | 直连自建 Hermes，含 Hermes Webapp。旧 Web UI 当 legacy [2] |
| Hermes Conduit | 53 | Long Cheung Ho | 独立客户端，iPhone / iPad / Mac / Apple Watch，同一套 session、profile、bot [3] |
| HermesPilot | 27 | Yang Hangbin | 配 Hermes Link，管 profile、模型、权限、skills、memory、定时任务 |
| Hermes HQ | 3 | Charles McDowell | 连自己电脑上的 Hermes；文案还写了 Nous 的 Hermes Cloud |
| ERMIS | 4 | Ilya Vishneuski | 连自建实例，或切到 Hermes Cloud |
| Hermes Client | 0 | Andrei Beliaev | 非官方，填服务器地址，走 Hermes Gateway |

### 一个 App 管多家 Agent

| App | 评分 | 覆盖 | 要在电脑上装什么 |
| --- | --- | --- | --- |
| Moshi | 619 | Claude Code、Codex、Cursor、Windsurf、Copilot、Aider。本质是给 Agent 用的移动终端 | SSH/Mosh，不是各家 API [4] |
| Paseo | 115 | Claude Code、Codex、OpenCode | 自己的 Paseo server [5] |
| Happier | 16 | Claude Code、Codex、OpenCode、Cursor、Pi、Grok、Gemini、Copilot、Qwen、Kimi 等 | 电脑上的会话还在，手机接上 [6] |
| Lody | 7 | Claude Code、Codex、Gemini CLI、OpenCode、Kimi，以及 ACP | 机器上的 daemon |
| pocketctl | 1（美国店） | Claude Code、Codex、OpenCode | 连 Mac/Linux 主机 |
| Sesori | 3 | 文案点名 OpenCode、Codex、Copilot、Cursor、Claude Code、Pi、Hermes、DeepSeek、Grok Build | 连你已经在用的 Agent |

ServerCC（7）是 SSH 进手机里跑真的 Claude Code/Codex，还能 VNC 看画面。更接近「手机上的终端」，不是会话 API 客户端。

### DSH：这周的第三方，评分都不到 10

美国店 / 中国店评分分开。都是 2026-11-13 查的。

| App | 美国 / 中国评分 | 接法 |
| --- | --- | --- |
| 掌中鲸 | 2 / 9 | 电脑伴侣 App 出二维码。会话、审批、目标板、后台任务、通知 [7] |
| AI-HUB | 0 / 6 | 第三方，声明与 DeepSeek 无隶属。电脑插件面板扫码，不填 IP 和端口 [8] |
| Fish Pocket | 6 / — | **不是远程**。Agent 引擎在 App 里，手机上跑 bash/node/git |
| DSH Mobile | 1 / 5 | 活在自己电脑上。续聊、批工具、回答提问、做完/提问/失败都通知 [9] |
| Pocket for DSH | 0 | 电脑装 `dsh-pocket` 插件，扫码。直连自己的电脑，PIN 不落盘 [10] |
| Fat Fish | 0 | 原生画 DSH Web 的界面。HTTPS 或 SSH 隧道 |

GitHub 上同一周还能看到一串，未上架或只做 Android：`dsh-mobile`、`dsh-mobile-remote`（插件 + Flutter）、`dsh-mobile-apk`（WebView + Termux）、免 root 的 Android 移植。官方 README 不收录这些。它们是社区在补洞，不是 DeepSeek 的产品线。

两种做法不要混：

1. **遥控电脑上的 dsh**（掌中鲸、AI-HUB、DSH Mobile、Pocket for DSH）。和 Hermes iOS 同构。
2. **把 Agent 搬进手机**（Fish Pocket，以及带 Termux 的 APK）。电脑可以不在。那是另一个产品。

## 这一类实际在卖的句子

把评分相对高的和这周的 DSH 文案放在一起，重复的是这几句，不是聊天、生图或购物：

- 电脑上的会话还在，手机接着做
- 扫码，不手填 IP
- 工具要跑的时候，手机上允许或拒绝
- Agent 提问时能答，不然任务干等
- 做完、要决定、失败，这三件事通知你
- 能看见改了什么文件

Hermes iOS v4.0.1 有续聊和审批卡（允许本次 / 拒绝），没有通知、没有扫码、没有 diff。细节在深挖和迭代计划里。

## Sources

[1] https://github.com/deepseek-ai/deepseek-harness
[2] https://apps.apple.com/us/app/hermex/id6767006319?uo=4
[3] https://apps.apple.com/us/app/hermes-conduit/id6790977764?uo=4
[4] https://apps.apple.com/us/app/moshi-herdr-tmux-on-ssh-mosh/id6757859949?uo=4
[5] https://apps.apple.com/us/app/paseo-remote-coding-agents/id6758887924?uo=4
[6] https://apps.apple.com/us/app/happier-remote-claude-codex/id6758554297?uo=4
[7] https://apps.apple.com/us/app/%E6%8E%8C%E4%B8%AD%E9%B2%B8/id6801499896?uo=4
[8] https://apps.apple.com/us/app/ai-hub-desktop/id6821681438?uo=4
[9] https://apps.apple.com/us/app/dsh-mobile-deepseek-harness/id6829688051?uo=4
[10] https://apps.apple.com/us/app/pocket-for-dsh/id6832288744?uo=4
