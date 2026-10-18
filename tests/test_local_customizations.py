"""本 fork 的定制功能守护测试。

这个 fork 跟随上游 cclank/tokei，同时叠加了几项本地定制（见 docs/local-customizations.md）。
合并上游时任何一项被冲掉或悄悄失效，这里都要报错。

行为测试优先；Swift 界面层没法单独跑的地方用「源码里还在」做最低限度的守护，
这类断言失败时要人工确认是上游重构了写法（改断言）还是定制真的丢了（补回来）。
"""
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

try:
    from .test_codex_limits import USAGE
except ImportError:
    from test_codex_limits import USAGE


ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "Tokei" / "Sources" / "Tokei"


def source(name):
    return (SRC / name).read_text(encoding="utf-8")


class SourceGuard(unittest.TestCase):
    def assertInSource(self, needle, name):
        self.assertTrue(needle in source(name), f"{name} 里找不到定制代码：{needle}")


def tencent_item(credits, model="claude-opus-4.7", stale_prompt=None):
    """一条 WorkBuddy / CodeBuddy 会话记录；stale_prompt 模拟子代理上陈旧的 message.usage。"""
    prompt = 1000
    return {
        "type": "function_call",
        "id": "entry-1",
        "sessionId": "session-1",
        "timestamp": "2026-09-17T12:00:00+08:00",
        "message": {"usage": {"input_tokens": stale_prompt or prompt, "output_tokens": 10,
                              "total_tokens": (stale_prompt or prompt) + 10}},
        "providerData": {
            "messageId": "generation-1",
            "requestModelId": model,
            "requestModelName": model,
            "rawUsage": {
                "prompt_tokens": prompt,
                "completion_tokens": 10,
                "total_tokens": prompt + 10,
                "prompt_cache_hit_tokens": 600,
                # Anthropic 风格的键恒为 0，真实缓存写在 OpenAI 风格的键里
                "cache_creation_input_tokens": 0,
                "prompt_cache_write_tokens": 100,
                "credit": credits,
            },
        },
    }


class TencentCreditBillingTests(unittest.TestCase):
    """腾讯系（WorkBuddy / CodeBuddy）按服务端积分计费：1,000 积分 = 50 元。"""

    def test_credit_price_is_fifty_yuan_per_thousand(self):
        self.assertEqual(USAGE._CREDIT_CNY, 0.05)

    def test_credited_request_is_billed_in_yuan_not_dollars(self):
        for model_id_first in (False, True):  # WorkBuddy / CodeBuddy
            record = USAGE._workbuddy_usage_record(tencent_item(40.0), model_id_first)
            self.assertAlmostEqual(record["credits"], 40.0)
            self.assertAlmostEqual(record["cost_cny"], 2.0)
            self.assertEqual(record["cost"], 0.0)

    def test_recalc_does_not_reprice_credit_billing_from_tokens(self):
        model = {"name": "claude-opus-4.7", "in": 1_000_000, "out": 100_000, "cr": 0, "cw": 0,
                 "reason": 0, "cost": 0.0, "cost_cny": 5.0, "credits": 100.0}
        result = {tool: {"ranges": {"all": {"models": [dict(model)], "cost": 0.0}}}
                  for tool in ("workbuddy", "workbuddy_ai", "codebuddy")}
        USAGE._recalc_costs(result)
        for tool in result:
            self.assertEqual(result[tool]["ranges"]["all"]["models"][0]["cost"], 0.0, tool)
            self.assertEqual(result[tool]["ranges"]["all"]["cost"], 0.0, tool)

    def test_old_ledger_days_are_corrected_on_read(self):
        day = {"credits": 100.0, "cost": 3.0, "cost_cny": 0,
               "models": {"claude-opus-5": {"credits": 100.0, "cost": 3.0, "cost_cny": 0}}}
        fixed = USAGE._tencent_credit_day(day)
        self.assertAlmostEqual(fixed["cost_cny"], 5.0)
        self.assertEqual(fixed["cost"], 0.0)
        self.assertEqual(day["cost"], 3.0)  # 账本本身不改

    def test_daily_yuan_includes_tencent_tools(self):
        record = USAGE._workbuddy_usage_record(tencent_item(40.0))
        cache = {"workbuddy": {"/tmp/a.jsonl": {"records": [record]}}}
        with mock.patch.object(USAGE, "_load_ledger", return_value={"tools": {}}):
            daily, _models, by_tool = USAGE._cny_breakdown(cache)
        self.assertAlmostEqual(daily[record["date"]], 2.0)
        self.assertAlmostEqual(by_tool[record["date"]]["workbuddy"], 2.0)


class WorkBuddyParsingTests(unittest.TestCase):
    def test_raw_usage_wins_over_stale_message_usage(self):
        record = USAGE._workbuddy_usage_record(tencent_item(1.0, stale_prompt=200))
        self.assertEqual(record["in"] + record["cr"] + record["cw"], 1000)

    def test_cache_write_aliases_take_the_largest_value(self):
        record = USAGE._workbuddy_usage_record(tencent_item(1.0))
        self.assertEqual(record["cw"], 100)
        self.assertEqual(USAGE._workbuddy_max_number(
            {"cache_creation_input_tokens": 0, "prompt_cache_write_tokens": 7},
            "cache_creation_input_tokens", "prompt_cache_write_tokens"), 7)

    def test_model_names_are_normalized(self):
        self.assertEqual(USAGE._normalize_agent_model("claude-opus-4-7"), "claude-opus-4.7")
        self.assertEqual(USAGE._normalize_agent_model("claude-opus-4-7-1m"), "claude-opus-4.7-1m")
        self.assertEqual(USAGE._normalize_agent_model("glm-5.3-ioa"), "glm-5.3")
        self.assertEqual(USAGE._normalize_agent_model("custom-local:gpt-5.6-sol"), "gpt-5.6-sol")


class CodeBuddyIDETests(unittest.TestCase):
    """CodeBuddy IDE 扩展的 history/**/index.json 与 CLI 的 projects/*.jsonl 合并统计。"""

    def write_ide_session(self, base, credit):
        session = base / "user" / "history" / "workspace" / "session-ide"
        (session / "messages").mkdir(parents=True)
        (session / "messages" / "msg-1.json").write_text(
            json.dumps({"extra": json.dumps({"modelId": "claude-opus-4.7"})}), encoding="utf-8")
        (session / "index.json").write_text(json.dumps({"requests": [{
            "id": "req-1", "startedAt": 1_789_000_000_000, "messages": ["msg-1"],
            "usage": {"inputTokens": 500, "outputTokens": 50, "cacheTokens": 300,
                      "cachedWriteTokens": 100, "credit": credit},
        }]}), encoding="utf-8")
        return session / "index.json"

    def test_ide_history_is_parsed_with_credit_billing(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = self.write_ide_session(Path(tmp), credit=20.0)
            parsed = USAGE._parse_codebuddy_ide_file(str(path))
        record = parsed["records"][0]
        self.assertEqual(parsed["sid"], "session-ide")
        self.assertEqual(record["model"], "claude-opus-4.7")
        self.assertEqual((record["in"], record["cr"], record["cw"], record["out"]), (100, 300, 100, 50))
        self.assertAlmostEqual(record["cost_cny"], 1.0)
        self.assertEqual(record["cost"], 0.0)

    def test_scan_merges_ide_history_with_cli_projects(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            cli = root / "projects" / "demo"
            cli.mkdir(parents=True)
            (cli / "main.jsonl").write_text(json.dumps(tencent_item(40.0)) + "\n", encoding="utf-8")
            ide = root / "CodeBuddyExtension"
            self.write_ide_session(ide, credit=20.0)
            cache = {"v": USAGE._SCAN_CACHE_VERSION}
            with mock.patch.object(USAGE, "CODEBUDDY_DIR", str(root / "projects")), \
                 mock.patch.object(USAGE, "CODEBUDDY_IDE_DIRS", [str(ide)]), \
                 mock.patch.object(USAGE, "ledger_touch"), \
                 mock.patch.object(USAGE, "ledger_reconcile",
                                   side_effect=lambda _tool, days, _sources=None: days):
                result = USAGE.scan_codebuddy(USAGE.range_bounds(), cache)
        usage = result["ranges"]["all"]
        self.assertAlmostEqual(usage["credits"], 60.0)
        self.assertAlmostEqual(usage["cost_cny"], 3.0)


class ClaudeExtraAccountTests(unittest.TestCase):
    """第二个 Claude 账号（~/.claude-<name>）：按各账号 history.jsonl 归属用量，只读。"""

    def make_home(self, tmp):
        home = Path(tmp)
        (home / ".claude").mkdir()
        (home / ".claude-acc2").mkdir()
        (home / ".claude-acc2" / ".claude.json").write_text("{}", encoding="utf-8")
        (home / ".claude-empty").mkdir()  # 没登录过（没有 .claude.json）不算账号
        history = lambda rows: "\n".join(
            json.dumps({"sessionId": sid, "timestamp": ts}) for sid, ts in rows) + "\n"
        (home / ".claude-acc2" / "history.jsonl").write_text(
            history([("shared", 2000), ("only-acc2", 1000)]), encoding="utf-8")
        (home / ".claude" / "history.jsonl").write_text(
            history([("shared", 1000), ("shared", 3000), ("only-main", 1000)]), encoding="utf-8")
        return home

    def test_only_logged_in_config_dirs_count_as_accounts(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = self.make_home(tmp)
            with mock.patch.object(USAGE, "HOME", str(home)):
                self.assertEqual(USAGE._claude_extra_accounts(), [("acc2", str(home / ".claude-acc2"))])

    def test_usage_follows_the_account_that_asked_last(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = self.make_home(tmp)
            cache = {}
            with mock.patch.object(USAGE, "HOME", str(home)):
                owners = USAGE._claude_session_owners(cache)
        self.assertNotIn("only-main", owners)  # 只跟踪出现在额外账号里的会话
        times = {}
        owner = lambda sid, ts: USAGE._claude_owner(owners, times, sid, ts)
        self.assertEqual(owner("only-acc2", 5000), "acc2")
        self.assertEqual(owner("shared", 1500), "")      # 默认账号 1000 提问
        self.assertEqual(owner("shared", 2500), "acc2")  # acc2 2000 接手
        self.assertEqual(owner("shared", 3500), "")      # 默认账号 3000 又接回
        self.assertEqual(owner("only-main", 5000), "")

    def test_no_extra_accounts_means_no_split(self):
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / ".claude").mkdir()
            with mock.patch.object(USAGE, "HOME", tmp):
                self.assertEqual(USAGE._claude_session_owners({}), {})

    def test_collector_outputs_account_usage(self):
        self.assertIn('"account_usage"', (ROOT / "usage.30s.py").read_text(encoding="utf-8"))


class SwiftCustomizationTests(SourceGuard):
    def test_account_split_adds_up_to_total(self):
        """默认账号 + 额外账号 必须恒等于总量（Model.swift 的 primaryAccount / account）。"""
        with tempfile.TemporaryDirectory() as tmp:
            binary = Path(tmp) / "local-customizations-check"
            build = subprocess.run(
                ["swiftc", "-parse-as-library", str(SRC / "Model.swift"), str(SRC / "L10n.swift"),
                 str(ROOT / "tests/swift/LocalCustomizationsCheck.swift"), "-o", str(binary)],
                capture_output=True, text=True, cwd=ROOT)
            self.assertEqual(build.returncode, 0, build.stderr)
            run = subprocess.run([str(binary)], capture_output=True, text=True)
            self.assertEqual(run.returncode, 0, run.stderr + run.stdout)
            self.assertIn("local customization checks passed", run.stdout)

    # 以下为源码级守护：界面层不单独编译运行，只确认定制代码还在。
    def test_extra_claude_accounts_get_their_own_cards(self):
        self.assertInSource("u.claude.primaryAccount", "PanelView.swift")
        self.assertInSource('"Claude Code · \\(name)"', "PanelView.swift")

    def test_cards_are_sorted_by_usage_including_extra_accounts(self):
        # 上游 v1.0.47 起自带按用量排序；本 fork 让它认得额外账号卡，默认账号卡只按默认账号的量排
        self.assertInSource("UsageCardOrdering.sorted", "PanelView.swift")
        self.assertInSource('id.hasPrefix("claude-")', "UsageCardOrdering.swift")
        self.assertInSource('case "claude": return u.claude.primaryAccount', "UsageCardOrdering.swift")

    def test_extra_account_quota_is_read_only_from_its_own_keychain_item(self):
        self.assertInSource("func fetchExtraAccountQuotas", "ClaudeCLIQuotaBridge.swift")
        self.assertInSource('"\\(defaultKeychainService)-\\(hash)"', "ClaudeCLIQuotaBridge.swift")
        self.assertInSource('claude["extra_accounts"]', "DataLoader.swift")

    def test_deepseek_harness_reads_cli_and_desktop_sessions(self):
        self.assertInSource(".dsh/sessions", "DataLoader.swift")
        self.assertInSource("dsh-desktop/harness/sessions", "DataLoader.swift")
        self.assertInSource("DSH Desktop/harness/sessions", "DataLoader.swift")

    def test_dashboard_shows_tencent_yuan(self):
        self.assertInSource("usage.workbuddy, usage.workbuddyAI, usage.codebuddy", "DashboardView.swift")
        self.assertInSource('day.cny_by_tool?["workbuddy"]', "DashboardView.swift")
        self.assertInSource('L("未计费")', "Design.swift")

    def test_local_build_never_installs_an_upstream_package(self):
        """官方安装包不含本地定制，本地版只能提示有新版，不能下载安装。"""
        self.assertInSource("isLocalBuild", "Updater.swift")
        self.assertInSource("localBuildUpdateAvailable", "Updater.swift")
        self.assertInSource("guard !Self.isLocalBuild else { return }", "Updater.swift")


class SyncToolingTests(unittest.TestCase):
    def test_sync_script_exists_and_parses(self):
        script = ROOT / "scripts" / "sync-upstream.sh"
        self.assertTrue(os.access(script, os.X_OK))
        self.assertEqual(subprocess.run(["bash", "-n", str(script)]).returncode, 0)


if __name__ == "__main__":
    unittest.main()
