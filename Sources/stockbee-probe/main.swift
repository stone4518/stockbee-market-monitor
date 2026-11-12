import Foundation
import StockbeeCore

// 联网实测探针：与 App 使用同一套 StockbeeCore 代码，抓取官方广度 + ETF 行情并输出完整评分。
// 用法：swift run stockbee-probe [输出目录]
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let started = Date()
var report: [String] = []
func say(_ s: String) { print(s); report.append(s) }
func f(_ x: Double?) -> String { x.map { String(format: "%.4f", $0) } ?? "N/A" }

say("Stockbee 联网实测探针 · 运行时间 UTC \(ISO8601DateFormatter().string(from: started)) · 美东 \(DayClock.nyDate(started))")
say("最近已收盘交易日（按NYSE日历）：\(TradingCalendar.lastClosedSession(at: started))")
var exitCode: Int32 = 0
do {
    let snap = try await DataFetcher.fetchOfficial()
    let l = snap.latest!
    let fresh = Freshness.evaluate(dataDate: l.date)
    say("官方数据源：\(snap.sourceName) · \(snap.sourceURL)")
    say("行数 \(snap.rows.count) · 最新交易日 \(l.date) · 时效：\(fresh.label)")
    say("4% Up \(l.up4) · 4% Down \(l.down4) · Quarter Up \(l.quarterUp) · Quarter Down \(l.quarterDown) · T2108 \(l.t2108.map{String($0)} ?? "N/A") · 股票池 \(l.universe.map{String($0)} ?? "N/A")")
    say("复算 3D \(f(snap.ratio(3))) · 5D \(f(snap.ratio(5)))（官方 \(l.reported5.map{String($0)} ?? "N/A")） · 10D \(f(snap.ratio(10)))（官方 \(l.reported10.map{String($0)} ?? "N/A")） · Quarter \(f(snap.quarterRatio))")
    let issues = snap.ratioConsistency()
    say(issues.isEmpty ? "官方 5D/10D 与日度复算一致（容差0.006）" : "一致性问题：" + issues.joined(separator: "；"))
    say("近10个交易日：" + snap.rows.prefix(10).map { "\($0.date) \($0.up4)/\($0.down4)" }.joined(separator: " | "))

    let bundle = await DataFetcher.fetchQuotes()
    say("行情商：\(bundle.vendor?.rawValue ?? "无可用") · 成功 \(bundle.quotes.count)/5")
    for msg in bundle.failures { say("  行情失败：\(msg)") }
    var aligned: [String: QuoteHistory] = [:]
    for (s, h) in bundle.quotes.sorted(by: { $0.key < $1.key }) {
        let t = h.through(l.date)
        say("  \(s) 原始最新 \(h.lastDate ?? "-") · 对齐至 \(t.lastDate ?? "-") 收盘 \(t.lastClose.map{String($0)} ?? "-") · 共 \(t.dates.count) 根")
        if t.lastDate == l.date { aligned[s] = t } else { say("  \(s) 缺少 \(l.date) 当日收盘，不参与评分") }
    }
    var blockers: [String] = []
    if !fresh.usableForScoring { blockers.append("广度数据\(fresh.label)") }
    let a = Scorer.assess(snap, aligned, blockers: blockers)
    say("—— 100分评分（\(Scorer.ruleVersion)）——")
    for i in a.items { say("  \(i.name)：\(i.score.map{String($0)} ?? "N/A")/\(i.maxScore) · 读数 \(i.value) · \(i.detail)") }
    say("总分：\(a.total.map{String($0)} ?? "待评估（已验证 \(a.partial)/\(a.availableMax)）") · 等级：\(a.grade ?? "待评估")")
    say("VCP：\(a.vcp)"); say("HTF：\(a.htf)")
    for s in a.signals { say("  信号：\(s.text)") }
    for b in a.blockers { say("  阻断：\(b)") }

    let json: [String: Any] = [
        "runAtUTC": ISO8601DateFormatter().string(from: started), "source": snap.sourceURL, "latestDate": l.date, "freshness": fresh.label,
        "up4": l.up4, "down4": l.down4, "quarterUp": l.quarterUp, "quarterDown": l.quarterDown, "t2108": l.t2108 as Any,
        "ratio3": snap.ratio(3) as Any, "ratio5": snap.ratio(5) as Any, "ratio10": snap.ratio(10) as Any, "quarterRatio": snap.quarterRatio as Any,
        "reported5": l.reported5 as Any, "reported10": l.reported10 as Any, "quoteVendor": bundle.vendor?.rawValue as Any,
        "items": a.items.map { ["name": $0.name, "score": $0.score as Any, "max": $0.maxScore, "value": $0.value, "detail": $0.detail] },
        "total": a.total as Any, "grade": a.grade as Any, "vcp": a.vcp, "htf": a.htf, "blockers": a.blockers
    ]
    let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: URL(fileURLWithPath: outDir).appendingPathComponent("probe.json"))
} catch {
    say("失败：\(error.localizedDescription)")
    exitCode = 1
}
try? report.joined(separator: "\n").write(to: URL(fileURLWithPath: outDir).appendingPathComponent("probe.txt"), atomically: true, encoding: .utf8)
exit(exitCode)
