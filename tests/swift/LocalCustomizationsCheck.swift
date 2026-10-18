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
         "account_usage": {"acc2": \(ranges(300, sessions: 2))},
         "extra_accounts": [{"name": "acc2", "q5": 1, "q7": 14}]}
        """
        let stat: ClaudeStat
        do {
            stat = try JSONDecoder().decode(ClaudeStat.self, from: Data(json.utf8))
        } catch {
            expect(false, "decode ClaudeStat with account_usage: \(error)")
            return
        }
        expect(stat.accountNames == ["acc2"], "account names: \(stat.accountNames)")
        let main = stat.primaryAccount, acc2 = stat.account("acc2")
        for key in [RangeKey.today, .yesterday, .week, .lastWeek, .month, .year, .all] {
            let total = stat.ranges.get(key), a = main.ranges.get(key), b = acc2.ranges.get(key)
            expect(a.in + b.in == total.in && a.out + b.out == total.out
                   && a.cr + b.cr == total.cr && a.cw + b.cw == total.cw,
                   "\(key) tokens add up")
            expect(abs(a.cost + b.cost - total.cost) < 1e-9, "\(key) cost adds up")
            expect(a.sessions + b.sessions == total.sessions, "\(key) sessions add up")
        }
        expect(main.q5 == 12 && main.q7 == 30, "default account keeps its own quota")
        expect(acc2.q5 == 1 && acc2.q7 == 14, "extra account shows its own quota")
        expect(main.account_usage == nil && acc2.account_usage == nil, "split stats carry no nested accounts")
        print("local customization checks passed")
    }
}
