#if os(macOS)
import SwiftUI
import Charts
import AppKit

enum Palette {
    static let navy = Color(red: 0.08, green: 0.19, blue: 0.34)
    static let blue = Color(red: 0.12, green: 0.37, blue: 0.70)
    static let background = Color(red: 0.945, green: 0.958, blue: 0.976)
    static let border = Color(red: 0.82, green: 0.86, blue: 0.91)
    static let positive = Color(red: 0.08, green: 0.55, blue: 0.37)
    static let negative = Color(red: 0.83, green: 0.32, blue: 0.23)
    static let amber = Color(red: 0.77, green: 0.48, blue: 0.08)
    static func grade(_ g: String?) -> Color {
        switch g { case "A": return positive; case "B": return blue; case "C": return amber; case "D": return negative; default: return amber }
    }
}

struct DashboardView: View {
    @EnvironmentObject var model: MonitorModel
    var body: some View {
        VStack(spacing: 0) {
            HeaderBar()
            ScrollView {
                HStack(alignment: .top, spacing: 14) {
                    LeftPanel().frame(minWidth: 520, maxWidth: .infinity)
                    RightPanel().frame(minWidth: 520, maxWidth: .infinity)
                }
                .padding(14)
            }
            StatusBar()
        }
        .background(Palette.background)
        .preferredColorScheme(.light)
        .onAppear { model.start() }
        .sheet(isPresented: $model.showSettings) { SettingsView().environmentObject(model) }
    }
}

// MARK: - 顶栏

struct HeaderBar: View {
    @EnvironmentObject var model: MonitorModel
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "chart.bar.xaxis").font(.system(size: 28, weight: .bold)).foregroundColor(Palette.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("Stockbee Market Monitor").font(.title2.bold())
                Text("美股动量交易环境监控 · 收盘后广度数据，非盘中实时").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text("最新已发布交易日（美东）：\(model.latestDate)").font(.subheadline.weight(.semibold))
                Text("上次检查 \(time(model.lastCheck)) · " + (model.isCache ? "缓存保存于 \(time(model.cacheSavedAt))" : "上次成功 \(time(model.lastSuccess))"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button { Task { await model.refresh() } } label: {
                if model.loading { ProgressView().controlSize(.small) } else { Label("刷新数据", systemImage: "arrow.clockwise") }
            }
            .disabled(model.loading).keyboardShortcut("r", modifiers: .command)
            Button { model.showSettings = true } label: { Label("数据来源", systemImage: "gearshape") }
            VStack(alignment: .trailing, spacing: 3) {
                Badge(text: sourceBadge.0, tint: sourceBadge.1)
                if let f = model.freshness { Badge(text: f.label, tint: f.usableForScoring ? Palette.positive : Palette.negative) }
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
        .background(.white)
        .overlay(alignment: .bottom) { Palette.border.frame(height: 1) }
    }
    var sourceBadge: (String, Color) {
        guard let s = model.snapshot else { return ("无数据", Palette.amber) }
        if model.isCache { return ("离线缓存 · 只读", Palette.amber) }
        return s.official ? ("Stockbee 官方", Palette.blue) : ("非官方 / 未核验", Palette.negative)
    }
    func time(_ d: Date?) -> String { d?.formatted(date: .omitted, time: .shortened) ?? "—" }
}

struct Badge: View {
    let text: String; let tint: Color
    var body: some View {
        Text(text).font(.caption.weight(.bold)).foregroundStyle(tint)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(tint.opacity(0.10), in: Capsule())
    }
}

// MARK: - 左栏：最新指标

struct IndicatorRow: Identifiable {
    let name: String; let value: String; let normal: String; let ideal: String; let state: String; let note: String
    var id: String { name }
}

struct LeftPanel: View {
    @EnvironmentObject var model: MonitorModel
    var body: some View {
        VStack(spacing: 12) {
            SectionCard(title: "当日最新指标", symbol: "chart.bar.fill") {
                HStack {
                    Label("最新完整交易日（美东）", systemImage: "calendar")
                    Spacer()
                    Text(model.latestDate).font(.title3.bold()).foregroundStyle(Palette.blue)
                }
                .padding(10).background(Palette.background, in: RoundedRectangle(cornerRadius: 8))
                HStack(spacing: 10) {
                    MetricTile(title: "4% Up", value: model.snapshot?.latest.map { "\($0.up4)" } ?? "N/A", tint: Palette.positive)
                    MetricTile(title: "4% Down", value: model.snapshot?.latest.map { "\($0.down4)" } ?? "N/A", tint: Palette.negative)
                    MetricTile(title: "10D Ratio", value: fmt(model.snapshot?.ratio(10)), tint: Palette.blue)
                }
                IndicatorTable(rows: rows)
                if let s = model.snapshot {
                    Text("来源：\(s.sourceName) · 抓取 \(s.fetchedAt.formatted(date: .abbreviated, time: .shortened))\(model.quoteVendor.map { " · ETF：\($0)" } ?? "")")
                        .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            SectionCard(title: "近10交易日 4% Up / Down", symbol: "chart.xyaxis.line") {
                TrendChart(days: Array((model.snapshot?.rows.prefix(10) ?? []).reversed()))
                Text("3D/5D/10D Ratio = 最近 N 个交易日 4% Up 合计 ÷ 4% Down 合计；已用官方表格 226 个交易日逐行核对 5D/10D 定义。")
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
    var rows: [IndicatorRow] {
        let s = model.snapshot, l = s?.latest, a = model.assessment
        func st(_ x: Double?, _ normal: Double, _ ideal: Double) -> String {
            guard let x else { return "N/A" }
            return x >= ideal ? "理想" : (x >= normal ? "正常" : "偏弱")
        }
        let r10 = s?.ratio(10), r5 = s?.ratio(5), r3 = s?.ratio(3), q = s?.quarterRatio
        return [
            IndicatorRow(name: "Quarter Ratio", value: fmt(q), normal: "≥1.0", ideal: "≥1.5", state: st(q, 1, 1.5),
                         note: l.map { "季度涨≥25%：\($0.quarterUp) / 跌≥25%：\($0.quarterDown)" } ?? ""),
            IndicatorRow(name: "10D Ratio", value: fmt(r10), normal: "≥1.0", ideal: "≥2.0", state: st(r10, 1, 2),
                         note: l?.reported10.map { "官方公布 \(String(format: "%.2f", $0))" } ?? "复算"),
            IndicatorRow(name: "5D Ratio", value: fmt(r5), normal: "≥1.0", ideal: "≥2.0", state: st(r5, 1, 2),
                         note: l?.reported5.map { "官方公布 \(String(format: "%.2f", $0))" } ?? "复算"),
            IndicatorRow(name: "3D Ratio", value: fmt(r3), normal: "≥1.0", ideal: "≥1.5", state: st(r3, 1, 1.5), note: "官方未公布，按同定义复算"),
            IndicatorRow(name: "T2108", value: l?.t2108.map { String(format: "%.2f%%", $0) } ?? "N/A", normal: "≥50%", ideal: "≥70%",
                         state: st(l?.t2108, 50, 70), note: "高于40日均线占比"),
            IndicatorRow(name: "Quarter Up / Down", value: l.map { "\($0.quarterUp) / \($0.quarterDown)" } ?? "N/A", normal: "Up>Down", ideal: "—",
                         state: l.map { $0.quarterUp > $0.quarterDown ? "正常" : "偏弱" } ?? "N/A", note: l?.universe.map { "股票池 \($0)" } ?? ""),
            IndicatorRow(name: "SPY/QQQ 趋势", value: a.items[4].value, normal: "站上MA20/50", ideal: "25/25",
                         state: a.items[4].score.map { "\($0)/25" } ?? "N/A", note: model.quoteVendor ?? "行情不可用"),
            IndicatorRow(name: "XLK/SMH/XLY 领导力", value: a.items[6].value, normal: "跑赢SPY", ideal: "10/10",
                         state: a.items[6].score.map { "\($0)/10" } ?? "N/A", note: "20日相对强度")
        ]
    }
}

struct MetricTile: View {
    let title: String; let value: String; let tint: Color
    var body: some View {
        VStack(spacing: 6) {
            Text(title).font(.headline)
            Text(value).font(.system(size: 32, weight: .heavy, design: .rounded)).foregroundStyle(tint).minimumScaleFactor(0.6).lineLimit(1)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 14)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct IndicatorTable: View {
    let rows: [IndicatorRow]
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("指标").frame(maxWidth: .infinity, alignment: .leading)
                Text("当前值").frame(width: 150, alignment: .leading)
                Text("正常").frame(width: 78, alignment: .leading)
                Text("理想做多").frame(width: 70, alignment: .leading)
                Text("状态").frame(width: 48, alignment: .leading)
            }
            .font(.subheadline.bold()).padding(.vertical, 7).padding(.horizontal, 6).background(Palette.background)
            ForEach(rows) { r in
                HStack(spacing: 6) {
                    Text(r.name).font(.system(size: 12.5, weight: .medium)).frame(maxWidth: .infinity, alignment: .leading)
                    Text(r.value).font(.system(size: 12.5).monospacedDigit()).lineLimit(1).truncationMode(.tail).frame(width: 150, alignment: .leading)
                    Text(r.normal).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).frame(width: 78, alignment: .leading)
                    Text(r.ideal).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
                    Text(r.state).font(.system(size: 12, weight: .bold)).foregroundStyle(color(r.state)).frame(width: 48, alignment: .leading)
                }
                .padding(.vertical, 6).padding(.horizontal, 6)
                .help(r.note)
                .overlay(alignment: .bottom) { Palette.border.opacity(0.7).frame(height: 0.5) }
            }
        }
    }
    func color(_ s: String) -> Color {
        if s == "理想" { return Palette.positive }
        if s == "偏弱" { return Palette.negative }
        if s == "N/A" { return Palette.amber }
        return .primary
    }
}

struct TrendChart: View {
    let days: [BreadthDay]
    var body: some View {
        if days.isEmpty {
            Text("尚无可验证的历史数据").frame(maxWidth: .infinity, minHeight: 200).foregroundStyle(.secondary)
        } else {
            Chart {
                ForEach(days) { d in
                    BarMark(x: .value("交易日", String(d.date.suffix(5))), y: .value("数量", d.up4))
                        .foregroundStyle(by: .value("方向", "4% Up")).position(by: .value("方向", "4% Up"))
                    BarMark(x: .value("交易日", String(d.date.suffix(5))), y: .value("数量", d.down4))
                        .foregroundStyle(by: .value("方向", "4% Down")).position(by: .value("方向", "4% Down"))
                }
            }
            .chartForegroundStyleScale(["4% Up": Palette.positive, "4% Down": Palette.negative])
            .chartLegend(position: .top, alignment: .leading)
            .frame(height: 210)
        }
    }
}

// MARK: - 右栏：评分与建议

struct RightPanel: View {
    @EnvironmentObject var model: MonitorModel
    var body: some View {
        let a = model.assessment
        VStack(spacing: 12) {
            SectionCard(title: "100分环境评分系统", symbol: "checkmark.seal.fill") {
                ScoreTable(a: a)
                HStack(spacing: 8) {
                    GradeBadge(g: "A", range: "80–100", text: "按计划参与", current: a.grade)
                    GradeBadge(g: "B", range: "65–79", text: "精选小仓", current: a.grade)
                    GradeBadge(g: "C", range: "45–64", text: "观察为主", current: a.grade)
                    GradeBadge(g: "D", range: "0–44", text: "暂停新仓", current: a.grade)
                }
            }
            SectionCard(title: "评分结果与策略建议", symbol: "lightbulb.fill") {
                ResultSummary(a: a)
                HStack(alignment: .top, spacing: 10) {
                    AdviceCard(name: "VCP · Minervini", text: a.vcp, icon: "chart.line.uptrend.xyaxis")
                    AdviceCard(name: "HTF · Qullamaggie", text: a.htf, icon: "flag.checkered")
                }
                SignalsList(a: a)
                NoticeList(title: "阻止完整评分的原因", lines: a.total == nil ? a.blockers : [], tint: Palette.negative, icon: "xmark.octagon")
                NoticeList(title: "数据提示", lines: model.warnings, tint: Palette.amber, icon: "exclamationmark.triangle")
                Text("\(Scorer.ruleVersion)。本模型为自定义交易环境过滤器，非 Stockbee 官方评级，未经历史回测；缺失数据记 N/A，不按 0 分；仅反映市场环境，不是个股买卖建议。")
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct ScoreTable: View {
    let a: Assessment
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("评分模块").frame(maxWidth: .infinity, alignment: .leading)
                Text("当前读数").frame(width: 170, alignment: .leading)
                Text("权重").frame(width: 40, alignment: .trailing)
                Text("得分").frame(width: 56, alignment: .trailing)
            }
            .font(.subheadline.bold()).padding(.vertical, 7).padding(.horizontal, 6).background(Palette.background)
            ForEach(a.items) { item in
                HStack(spacing: 6) {
                    Text(item.name).font(.system(size: 12.5)).frame(maxWidth: .infinity, alignment: .leading)
                    Text(item.value).font(.system(size: 12.5).monospacedDigit()).lineLimit(1).truncationMode(.tail).frame(width: 170, alignment: .leading)
                    Text("\(item.maxScore)").font(.system(size: 12.5)).frame(width: 40, alignment: .trailing)
                    Text(item.score.map { "\($0)" } ?? "N/A").font(.system(size: 12.5, weight: .bold))
                        .foregroundStyle(item.score == nil ? Palette.amber : Color.primary).frame(width: 56, alignment: .trailing)
                }
                .padding(.vertical, 6).padding(.horizontal, 6)
                .help("规则：\(item.rule)\n计算：\(item.detail)")
                .overlay(alignment: .bottom) { Palette.border.opacity(0.7).frame(height: 0.5) }
            }
            HStack(spacing: 6) {
                Text("合计").frame(maxWidth: .infinity, alignment: .leading)
                Text(a.total == nil ? "已验证 \(a.partial)/\(a.availableMax)" : "7项完整").font(.caption).foregroundStyle(.secondary).frame(width: 170, alignment: .leading)
                Text("100").frame(width: 40, alignment: .trailing)
                Text(a.total.map { "\($0)" } ?? "待评估").foregroundStyle(a.total == nil ? Palette.amber : Palette.blue).frame(width: 56, alignment: .trailing)
            }
            .font(.subheadline.bold()).padding(.vertical, 7).padding(.horizontal, 6).background(Palette.background)
        }
    }
}

struct GradeBadge: View {
    let g: String; let range: String; let text: String; let current: String?
    var body: some View {
        let tint = Palette.grade(g)
        VStack(spacing: 3) {
            Text("\(g)级").font(.headline)
            Text(range).font(.subheadline)
            Text(text).font(.caption)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 8)
        .foregroundStyle(tint).background(tint.opacity(current == g ? 0.28 : 0.09), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(current == g ? tint : .clear, lineWidth: 2))
    }
}

struct ResultSummary: View {
    let a: Assessment
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                Circle().stroke(Palette.border, lineWidth: 14)
                Circle().trim(from: 0, to: CGFloat(a.total ?? 0) / 100)
                    .stroke(Palette.grade(a.grade), style: StrokeStyle(lineWidth: 14, lineCap: .round)).rotationEffect(.degrees(-90))
                VStack(spacing: 2) {
                    Text(a.total.map { String($0) } ?? "—").font(.system(size: 36, weight: .bold))
                    Text("/ 100").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(width: 132, height: 132)
            VStack(alignment: .leading, spacing: 6) {
                Text("当前环境等级").font(.headline)
                Text(a.grade.map { "\($0) 级" } ?? "待评估").font(.system(size: 28, weight: .bold)).foregroundStyle(Palette.grade(a.grade))
                if let gap = a.gapToIdeal {
                    Text(gap == 0 ? "已达到理想做多环境（A级 ≥80）" : "距理想做多环境（A级 80分）还差 \(gap) 分").font(.subheadline)
                } else {
                    Text("已验证 \(a.partial)/\(a.availableMax) 分，数据不完整，不发布等级").font(.subheadline).foregroundStyle(Palette.amber)
                }
                if !a.topDeductions.isEmpty {
                    Text("主要扣分：" + a.topDeductions.prefix(3).map { "\($0.name) −\($0.deduction ?? 0)" }.joined(separator: "，"))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

struct AdviceCard: View {
    let name: String; let text: String; let icon: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(name, systemImage: icon).font(.subheadline.bold()).foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading).padding(9).background(Palette.navy)
            Text(text).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading).padding(.horizontal, 9).padding(.bottom, 8)
        }
        .background(Palette.background).clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct SignalsList: View {
    let a: Assessment
    var body: some View {
        if !a.signals.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("广度与动量变化").font(.subheadline.bold())
                ForEach(a.signals) { s in
                    Label(s.text, systemImage: icon(s.kind)).font(.caption).foregroundStyle(color(s.kind))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    func icon(_ k: Signal.Kind) -> String {
        switch k { case .improving: return "arrow.up.right"; case .deteriorating: return "arrow.down.right"; case .extreme: return "exclamationmark.circle"; case .neutral: return "arrow.right" }
    }
    func color(_ k: Signal.Kind) -> Color {
        switch k { case .improving: return Palette.positive; case .deteriorating: return Palette.negative; case .extreme: return Palette.amber; case .neutral: return .secondary }
    }
}

struct NoticeList: View {
    let title: String; let lines: [String]; let tint: Color; let icon: String
    var body: some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption.bold()).foregroundStyle(tint)
                ForEach(lines, id: \.self) { t in
                    Label(t, systemImage: icon).font(.caption).foregroundStyle(tint).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(9)
            .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

// MARK: - 底栏与设置

struct StatusBar: View {
    @EnvironmentObject var model: MonitorModel
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: model.error == nil ? "info.circle" : "exclamationmark.triangle.fill")
                .foregroundStyle(model.error == nil ? Palette.blue : Palette.negative)
            Text(model.status).lineLimit(2)
            Spacer()
            Text("每15分钟自动检查").foregroundStyle(.secondary)
            Link("Stockbee 官网 MM 页面", destination: URL(string: GoogleSheetDiscovery.officialPage)!)
            if let s = model.snapshot, let u = URL(string: s.sourceURL) { Link("原始数据", destination: u) }
        }
        .font(.caption).padding(.horizontal, 16).padding(.vertical, 8).background(.white)
        .overlay(alignment: .top) { Palette.border.frame(height: 1) }
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: MonitorModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("数据来源与自动刷新").font(.title2.bold())
            Text("程序每15分钟、以及电脑唤醒后检查一次。Stockbee 广度数据在美股收盘后由作者更新，检查频率不代表盘中实时。")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("市场广度来源", selection: $model.sourceMode) {
                Text("Stockbee 官方 Google Sheet（默认，自动从官网发现）").tag("official")
                Text("Stage2Stocks 非官方独立复算（仅参考，不发布等级）").tag("thirdparty")
            }
            .pickerStyle(.radioGroup)
            if model.sourceMode == "official" {
                TextField("手动指定 Google Sheet 链接（留空=自动发现，推荐）", text: $model.manualSheetURL).textFieldStyle(.roundedBorder)
                Text("手动链接会被标记为“官方关联未核验”，不发布完整等级。").font(.caption).foregroundStyle(.secondary)
            }
            Text("ETF 行情依次尝试：Yahoo Finance → Nasdaq.com → Cboe 延时行情；同一次评分的 5 只 ETF 必须来自同一家，且必须包含与广度数据同一交易日的收盘价。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("本地缓存：~/Library/Application Support/StockbeeMarketMonitor（仅断网时只读查看）").font(.caption).foregroundStyle(.secondary)
            Spacer()
            HStack {
                Button("打开 Stockbee 官网") { NSWorkspace.shared.open(URL(string: GoogleSheetDiscovery.officialPage)!) }
                Spacer()
                Button("取消") { model.showSettings = false }
                Button("保存并刷新") { model.saveSettings() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 640, height: 400)
    }
}

struct SectionCard<Content: View>: View {
    let title: String; let symbol: String; let content: Content
    init(title: String, symbol: String, @ViewBuilder content: () -> Content) { self.title = title; self.symbol = symbol; self.content = content() }
    var body: some View {
        VStack(spacing: 0) {
            Label(title, systemImage: symbol).font(.title3.bold()).foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.vertical, 9).background(Palette.navy)
            VStack(spacing: 10) { content }.padding(12)
        }
        .background(.white).clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.border, lineWidth: 1))
    }
}

func fmt(_ n: Double?) -> String { n.map { String(format: "%.2f", $0) } ?? "N/A" }
#endif
