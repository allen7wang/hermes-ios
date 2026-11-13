# 深挖：类别里评分相对高的，加上 DSH 这一波

评分是美国 App Store、2026-11-13。能力是商店文案，不是实测。

Hermes iOS v4.0.1 对照：连自建 API；服务端会话可续聊、批工具、管定时任务；本机另有草稿、项目、检索。审批在已经打开的会话里，只有「允许本次 / 拒绝」。没有系统推送，没有扫码，没有 diff 浏览。

## Hermex（222）— 商店里的 Hermes 客户端头名

文案写明连自建 Hermes，包括 Hermes Webapp。旧的 Web UI 服务器还能用，标成 legacy。[2]

手机上声称能做的，和「再做一个聊天框」不是一回事：

- 打开已有会话，看流式回复、工具和推理
- 对正在跑的一轮：排队、改方向、停止
- 文件改动看 diff，浏览工作区文件
- 发照片、文件，听写
- Bots 和 Sessions 分开；看板和卡片；Tasks、Skills、Memory、Usage
- 选模型、Profile、推理档位
- 锁屏 Live Activities 和灵动岛显示还在跑的任务
- 可选通知
- 把 Web UI 上的聊天、草稿、通知迁到 Hermes host

2.1 的版本说明把「连 Hermes Webapp」当成这次的接入方式：host 从 gateway 提供 dashboard，手机登录后照常聊。单个 Profile 的 Webapp 会在手机上说明原因并让你改。[2]

和 Hermes iOS 的差别：对方把「跑的时候你不在会话里」当成正常状态（灵动岛、通知、之后再看 diff）。这边的审批要人已经在那条会话里。看板、Skills、Memory 先别照抄，那些取决于 Gateway 有没有对应接口，文案有不等于 API 有。

## Hermes Conduit（53）— 同一份工作，做成 Bot 通讯录

独立客户端，覆盖 iPhone、iPad、Mac、Apple Watch。session、profile、bot、tool 和桌面是同一套。[3]

多出来的是 Bot 被当成联系人：头像墙、拖进群、@、谁先答；大活丢给 workstream，做完或要你时回报。Linux 主机上可以看 Bot 的桌面并接手登录。有实时语音（文案写 Gemini Live、Qwen Live、GPT）。[3]

Hermes iOS 没有这条「Bot 主页」。要不要做，取决于你用不用 Hermes 的多 Bot。单会话续聊用不上头像墙。Watch 和语音是加分项，不是这一类的共同项。Hermex 和 DSH 客户端都没把语音当第一句。

## Moshi（619）— 评分最高，但是终端，不是 API 客户端

给编码 Agent 用的移动终端。Agent 跑在服务器上，手机用 Mosh 接上，换网络、休眠、进地铁不断会话。文案点名从沙发上看 Claude Code，在咖啡店 nudge Codex，也能看 Cursor、Windsurf、Copilot、Aider。语音转终端在设备上跑 Whisper。任务完成走 webhook 推送。SSH key 用 Face ID。[4]

版本说明里已经有 Chat View：Agent 提问时给选项预览，子 Agent 显示模型和耗时。所以它在从纯终端往「Agent 问答」长，底层仍是会话存活，不是某家的审批 API。

不该学的是再做一个 SSH 客户端。Hermes 已经有 API。该记住的是两句：会话不能因为手机休眠就死；做完要有一条推送，而不是等你回去刷新。

## Paseo（115）— 一家客户端管三个 CLI

自建 server，连本机开发环境。Claude Code、Codex、OpenCode 一个界面。Agent 用你机器上的环境，不是云沙箱。可选端到端加密中继，人在外面也能连。开源。[5]

手机功能：设备端语音、git worktree、看 diff、实时流、做完推送。

这是「官方还没把手机做好之前」的多 Agent 遥控器。Claude 和 Codex 现在有官方手机路径，Paseo 的窗口会变窄。对 Hermes 仍有用的是：diff 和推送是它 115 个评分买到的东西，不是模型切换。

Codex Relay（59）是同一件事的单产品版：本机要跑 `npx codex-relay`，手机跟线程、批审批、贴图。官方 Codex 进了 ChatGPT 之后，这类单点第三方的空间变小。Hermes 还没有官方 App，空间还在。

## DSH 这一波 — 评分还很少，句子已经齐了

官方没有手机端。[1] 商店里能找到的遥控客户端，评分都是个位数。文案高度重复，说明大家在抄同一张需求清单，不是在做出差异化：

| 能力 | DSH Mobile [9] | Pocket for DSH [10] | 掌中鲸 [7] | AI-HUB [8] |
| --- | --- | --- | --- | --- |
| 活在电脑上，手机续聊 | 有 | 有，历史和桌面同一份 | 有，可中断 | 有 |
| 扫码，不填地址 | 文案未强调 | 装插件后扫码 | 电脑伴侣出码 | 插件面板扫码，声明不填 IP/端口 |
| 批工具 | 允许/拒绝 | 能看到命令和文件改动 | 审批中心 | 文案写能接着聊、看改了什么 |
| Agent 提问 | 要能答，不然干等 | 未单列 | 一键回答 | 人在外面时 Agent 停下来问你 |
| 通知 | 做完、提问、失败，外加通知中心 | 结束的会话有徽章和通知 | 审批、提问、错误 | 未在摘到的段落里单列 |
| 声明第三方 | 未强调隶属 | 直连自己的电脑 | 配对密钥留在设备 | 写明与 DeepSeek 无隶属 |

Happier（16）把同一张清单写得更硬：Agent 要跑命令时，推送上就有 Allow 和 Deny。等决定的会话单独成组，叫 Needs attention；还在跑的归到 Working。diff 可以标行，再把批注发回 Agent。[6] 评分不高，但这是这一类里把「人没打开 App」写清楚的一份文案。

Fish Pocket 不要算进这张表。它的引擎在手机里，不连电脑。那是「把 dsh 塞进 iPhone」，不是「给没有手机端的 dsh 做遥控器」。

## 对 Hermes iOS 有用的，就这几条

商店评分能排上的，和这周刚出现的，要的是同一条回路：

1. 人不在会话里，也能知道要批、要答、做完了。
2. 批的时候能看见命令或 diff，而不只是一条聊天气泡。
3. 正在跑的一轮可以停、可以改口，不是只能等它跑完再开下一条。
4. 新用户扫码，不手填地址。Hermes iOS 的现有用户已经配过连接，这条排在回路后面。

不要从这一类学：语音陪伴、Bot 头像墙、把 Agent 搬进手机、再做一个 Mosh 终端。

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
