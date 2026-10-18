import Foundation

// 本 fork 的多 Claude 账号拆分：默认账号 = 总量 − 额外账号，两张卡相加必须恒等于总量。
@main
struct LocalCustomizationsCheck {
    static func expect(_ condition: Bool, _ message: String) {
        if !condition {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    static func range(_ scale: Int, sessions: Int) -> String {
        """
        {"hit": 0.5, "in": \(scale), "out": \(scale * 2), "cr": \(scale * 30), "cw": \(scale * 3),
         "cost": \(Double(scale) / 100), "models": [], "sessions": \(sessions)}
        """
    }

    static func ranges(_ scale: Int, sessions: Int) -> String {
        let r = range(scale, sessions: sessions)
        return """
        {"today": \(r), "yesterday": \(r), "week": \(r), "last_week": \(r),
         "month": \(r), "year": \(r), "all": \(r)}
        """
    }

    static func main() {
        let json = """
        {"ranges": \(ranges(1000, sessions: 9)), "session_name": "x", "session_total": 0,
         "q5": 12, "q7": 30,
         "account_usage": {"acc2": \(ranges(300, sessions: 2)), "acc3": \(ranges(100, sessions: 1))},
         "extra_accounts": [{"name": "acc2", "q5": 1, "q7": 14}, {"name": "acc3", "q5": 9, "q7": 10}]}
        """
        let stat: ClaudeStat
        do {
            stat = try JSONDecoder().decode(ClaudeStat.self, from: Data(json.utf8))
        } catch {
            expect(false, "decode ClaudeStat with account_usage: \(error)")
            return
        }
        expect(stat.accountNames == ["acc2", "acc3"], "account names: \(stat.accountNames)")
        let main = stat.primaryAccount, acc2 = stat.account("acc2"), acc3 = stat.account("acc3")
        for key in [RangeKey.today, .yesterday, .week, .lastWeek, .month, .year, .all] {
            let total = stat.ranges.get(key), a = main.ranges.get(key), b = acc2.ranges.get(key), c = acc3.ranges.get(key)
            expect(a.in + b.in + c.in == total.in && a.out + b.out + c.out == total.out
                   && a.cr + b.cr + c.cr == total.cr && a.cw + b.cw + c.cw == total.cw,
                   "\(key) tokens add up")
            expect(abs(a.cost + b.cost + c.cost - total.cost) < 1e-9, "\(key) cost adds up")
            expect(a.sessions + b.sessions + c.sessions == total.sessions, "\(key) sessions add up")
        }
        expect(main.q5 == 12 && main.q7 == 30, "default account keeps its own quota")
        expect(acc2.q5 == 1 && acc2.q7 == 14, "extra account shows its own quota")
        expect(acc3.q5 == 9 && acc3.q7 == 10, "third account shows its own quota")
        expect(main.account_usage == nil && acc2.account_usage == nil, "split stats carry no nested accounts")

        let names = ClaudeAccountDisplayNames.self
        var aliases = names.updating("{}", accountID: "claude", name: "Main")
        aliases = names.updating(aliases, accountID: "claude-acc2", name: "Second")
        aliases = names.updating(aliases, accountID: "claude-acc3", name: "第三个账号") // l10n-ignore
        expect(names.title(for: "claude", in: aliases) == "Claude Code · Main", "primary alias")
        expect(names.title(for: "claude-acc2", in: aliases) == "Claude Code · Second", "second alias")
        expect(names.title(for: "claude-acc3", in: aliases) == "Claude Code · 第三个账号", "unicode alias") // l10n-ignore
        expect(names.title(for: "claude-acc4", in: aliases) == "Claude Code · acc4", "unknown alias fallback")
        expect(names.title(for: "claude", in: "broken") == "Claude Code", "malformed JSON fallback")
        expect(names.title(for: "claude-acc2", in: "[]") == "Claude Code · acc2", "wrong JSON type fallback")
        aliases = names.updating(aliases, accountID: "claude-acc2", name: "")
        expect(names.title(for: "claude-acc2", in: aliases) == "Claude Code · acc2", "empty alias resets")
        aliases = names.updating(aliases, accountID: "claude", name: "  ")
        expect(names.title(for: "claude", in: aliases) == "Claude Code", "whitespace uses fallback")
        aliases = names.updating(aliases, accountID: "claude", name: "Two Words ")
        expect(names.names(in: aliases)["claude"] == "Two Words ", "editing preserves trailing spaces")
        aliases = names.updating(aliases, accountID: "claude", name: String(repeating: "x", count: 100))
        expect(names.names(in: aliases)["claude"]?.count == 64, "long names are capped")
        expect(stat.accountNames == ["acc2", "acc3"], "aliases never change account identity")

        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        do {
            for name in [".claude-acc2", ".claude-acc3", ".claude-unlogged", "other"] {
                let dir = home.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                if name != ".claude-unlogged" {
                    try Data().write(to: dir.appendingPathComponent(".claude.json"))
                }
            }
            expect(names.localAccountIDs(home: home) == ["claude", "claude-acc2", "claude-acc3"], "discover all logged-in directories without reading their files")
        } catch { expect(false, "directory fixture: \(error)") }
        print("local customization checks passed")
    }
}
