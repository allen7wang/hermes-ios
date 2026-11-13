# 第三方手机客户端：官方没做 App 的 Agent

调研日：2026-11-13。上一份 `research/phone-agent-market/` 把豆包、ChatGPT 当成竞品，口径错了，迭代不要用那份。

## 问题

找的是这一类：Agent 本身跑在电脑或自建服务上，官方没有手机 App，第三方把手机做成控制端，上架应用商店。

Hermes Agent 是这个形状。Nous 没有官方 iOS App。Hermes iOS 自己是源码预览，不在商店里。商店里已经有别人做的 Hermes 客户端。

DSH 是同一形状，而且就在这几天。DeepSeek Harness（`dsh`）官方仓库当天两次查询约 28.0 万 star（279,899，随后 279,907），README 只写 `npx @deepseek-ai/dsh web`，本地打开 `127.0.0.1:3080`，全文没有 mobile / iOS / Android。[1] 商店和 GitHub 上的手机端都是第三方。

## 规模怎么读

无法从评分人数确认这一类产品的下载量。美国 App Store 评分人数是 2026-11-13 的 iTunes Lookup，不是下载量，也不是月活。样本中最高为数百个评分。评分个位数的 DSH 客户端不能按下载深挖，它们说明的是窗口刚打开。

| 产品 | 控制谁 | 美国店评分 | 是不是第三方 | 深挖 |
| --- | --- | --- | --- | --- |
| Moshi | 任意跑在 SSH/Mosh 上的编码 Agent | 619 | 是。终端，不是某家 API 的客户端 | 是。类别里评分最高 |
| Hermex | 自建 Hermes | 222 | 是。商店里 Hermes 客户端的头名 | 是 |
| T3 Code | 自己的 T3 环境 | 219 | 否。自家桌面的伴侣 App | 不深挖 |
| Paseo | 本机上的 Claude Code / Codex / OpenCode | 115 | 是。要自建 Paseo server | 是 |
| Orca | 自己的 Orca 桌面终端 | 78 | 否。自家伴侣 | 不深挖 |
| Codex Relay | 本机 Codex | 59 | 是。官方已把 Codex 放进 ChatGPT App，窗口在关 | 短记 |
| Hermes Conduit | 自建 Hermes | 53 | 是 | 是，和 Hermex 一起看 |
| Happier | Claude Code、Codex、OpenCode 等一串 | 16 | 是 | 不按下载深挖。通知上直接允许/拒绝，记一笔 |
| OpenCode Mobile | 自建 OpenCode | 15 | 是 | 不深挖。OpenCode 客户端一大把，评分都在这个量级 |
| DSH 各客户端 | 电脑上的 DeepSeek Harness | 0–9 | 全是第三方 | 作为一波来看，不单拆成「高下载」 |

Hermes 商店里还有名字像、但不是连你自己 Gateway 的：Hermes Agent - Smart Assistant（文案改口成 Grabnix）、Hermes-cli（手机上自己跑 Agent，不连电脑）。不放进竞品。

Claude Code 和 Codex 已经有官方手机路径（Claude App 的 Code 页、ChatGPT 里的 Codex）。第三方还在，但「官方没做、第三方来补」这扇窗在这两家正在关上。Hermes 和 DSH 还开着。

## 怎么读

1. [01-ranking.md](01-ranking.md) — 名单和 DSH 这一波
2. [02-deep-dives.md](02-deep-dives.md) — 评分相对高的：Moshi、Hermex、Conduit、Paseo
3. [03-iteration-plan.md](03-iteration-plan.md) — 对照 Hermes iOS v4.0.1 的实现前基线和迭代建议

整理后的商店字段在 `data/lookup-2026-11-13.json`。能力来自商店文案和官方 README，没有装机实测。

## Sources

[1] https://github.com/deepseek-ai/deepseek-harness
