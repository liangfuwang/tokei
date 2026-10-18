# 本 fork 的本地定制

这个 fork 跟随上游 [cclank/tokei](https://github.com/cclank/tokei)，在上游之上叠加下面几项定制。
每项都有守护测试（`tests/test_local_customizations.py`），合并上游时丢了或失效会直接报错。

## 跟随上游的流程

1. 每天 10:00 有定时任务检查上游（`scripts/install-upstream-check.sh` 安装），发了新版本会弹 macOS 通知，同一版本只通知一次。只检查，不合并。
2. 运行 `scripts/sync-upstream.sh`。它会：
   1. fetch 上游，预演冲突；
   2. 在新分支 `sync/<版本>` 上合并；
   3. 跑定制守护测试（必须全过），再跑全套测试，和合并前对比，只报新增失败；
   4. 打本地包（`TOKEI_LOCAL_BUILD=1`）。

   它不推送、不安装、不动 main。
3. 有冲突时脚本停在 sync 分支上。按下表保住定制、解决冲突并提交，然后运行 `scripts/sync-upstream.sh --verify`。
4. 确认无误后执行 `git checkout main && git merge --ff-only sync/<版本>`，再安装、推送到 fork。

本地版（`TokeiLocalBuild=true`）的「检查更新」查到上游新版时只提示，不会下载安装官方包，因为官方包不含这些定制。

## 定制清单

| 定制 | 位置 | 合并时注意 |
|---|---|---|
| 腾讯积分计费：WorkBuddy / CodeBuddy 有积分时 ¥ = 积分 × 0.05（1,000 积分 = 50 元），美元置 0 | `usage.30s.py`：`_CREDIT_CNY`、`_workbuddy_usage_record`、`_parse_codebuddy_ide_file`、`_recalc_costs` 里腾讯系分支 | 上游没有积分概念，常把这几处改回按价格表估美元 |
| 账本旧天读取时按积分纠正；按天 / 回顾的人民币含腾讯系 | `usage.30s.py`：`_tencent_credit_day`、`_cny_breakdown`、`build_daily_costs`、`build_wrapped` | 只改返回值，不写账本 |
| CodeBuddy IDE 扩展 `history/**/index.json` 与 CLI 合并统计 | `usage.30s.py`：`CODEBUDDY_IDE_DIRS`、`scan_codebuddy` | |
| WorkBuddy：rawUsage 优先于陈旧的 message.usage；缓存写多套键取最大；模型名 `claude-opus-4-7` 统一成 `4.7` | `usage.30s.py`：`_workbuddy_usage_record`、`_workbuddy_max_number`、`_normalize_agent_model` | 改解析逻辑要调高 `_WORKBUDDY_PARSER_VERSION` |
| DeepSeek Harness 同时读 CLI（`~/.dsh`）和桌面版会话 | `DataLoader.swift` 的 DSH 解压部分 | |
| 多个 Claude Code 账号（`~/.claude-<name>`）：按各账号 history.jsonl 归属用量；额外账号的额度只读它自己的钥匙串条目；额外账号单独成卡 | `usage.30s.py`：`_claude_*`、`claude.account_usage`；`ClaudeCLIQuotaBridge.swift`、`DataLoader.swift`、`Model.swift`（`primaryAccount` / `account(_:)`）、`PanelView.swift` | 默认账号 + 额外账号必须恒等于总量；对账号目录和钥匙串只读 |
| 首页卡片按当前范围 token 用量从大到小排序（只排序，不改卡片大小），额外账号卡也参与排序 | 上游 v1.0.47 起自带排序；本 fork 只改 `UsageCardOrdering.swift` 的 `tokens(for:)`：认得 `claude-<name>`，默认账号卡按 `primaryAccount` 排 | 上游改这个函数时保住这两处 |
| 仪表盘：腾讯系人民币；有用量无价钱时显示「未计费」 | `DashboardView.swift`、`Design.swift` 的 `StatBar` | |
| 本地版不安装官方包 | `Updater.swift`：`localBuildUpdateAvailable` | |
