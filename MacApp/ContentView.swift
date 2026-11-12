#if os(macOS)
import SwiftUI
import Charts
import AppKit

private enum Palette {
    static let navy = Color(red: 0.08, green: 0.19, blue: 0.34)
    static let blue = Color(red: 0.12, green: 0.37, blue: 0.70)
    static let background = Color(red: 0.945, green: 0.958, blue: 0.976)
    static let border = Color(red: 0.82, green: 0.86, blue: 0.91)
    static let positive = Color(red: 0.08, green: 0.55, blue: 0.37)
    static let negative = Color(red: 0.83, green: 0.32, blue: 0.23)
    static let amber = Color(red: 0.77, green: 0.48, blue: 0.08)
}

struct DashboardView: View {
    @EnvironmentObject var model: MonitorModel
    private let timer = Timer.publish(every: 900, on: .main, in: .common).autoconnect()
    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                HStack(alignment: .top, spacing: 15) {
                    leftPanel.frame(maxWidth: .infinity)
                    rightPanel.frame(maxWidth: .infinity)
                }
                .padding(16)
            }
            bottomStatus
        }
        .background(Palette.background)
        .preferredColorScheme(.light)
        .task { await model.refresh() }
        .onReceive(timer) { _ in Task { await model.refresh() } }
        .sheet(isPresented: $model.showSettings) { settings }
    }
    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "chart.bar.xaxis").font(.system(size: 30,weight: .bold)).foregroundColor(Palette.blue)
            VStack(alignment:.leading,spacing:3) {
                Text("Stockbee Market Monitor").font(.title2.bold())
                Text("美股动量交易环境监控 · 收盘数据").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment:.trailing,spacing:3) {
                Text("最近交易日（美东）：\(model.latestDate)").font(.subheadline.weight(.semibold))
                Text("上次检查：\(model.lastCheck?.formatted(date:.omitted,time:.standard) ?? "—")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button { Task { await model.refresh() } } label: { Label("刷新数据",systemImage:"arrow.clockwise") }
                .disabled(model.loading)
            Button { model.showSettings = true } label: { Label("数据源",systemImage:"gearshape") }
            Text(model.snapshot?.official == false ? "非官方复算" : "来源最新一条 · 非盘中")
                .font(.caption.weight(.bold)).foregroundStyle(model.snapshot?.official == false ? Palette.amber : Palette.blue)
                .padding(.horizontal,10).padding(.vertical,7)
                .background(Palette.blue.opacity(0.08),in:Capsule())
        }
        .padding(.horizontal,20).padding(.vertical,12)
        .background(.white)
        .overlay(alignment:.bottom) { Palette.border.frame(height:1) }
    }
    private var leftPanel: some View {
        VStack(spacing:14) {
            SectionCard(title:"当日最新指标",symbol:"chart.bar.fill") {
                HStack {
                    Label("最新完整交易日（美东）",systemImage:"calendar")
                    Spacer()
                    Text(model.latestDate).font(.title3.bold()).foregroundStyle(Palette.blue)
                }.padding(12).background(Palette.background,in:RoundedRectangle(cornerRadius:9))
                HStack(spacing:10) {
                    metric("4% Up", model.snapshot?.latest?.up4.description ?? "—",Palette.positive)
                    metric("4% Down", model.snapshot?.latest?.down4.description ?? "—",Palette.negative)
                    metric("10D Ratio", number(model.snapshot?.ratio(10)), Palette.blue)
                }
                VStack(spacing:0) {
                    tableHeader(["指标","当前值","参考","状态"],weights:[2,1.15,1.15,1.1])
                    line("Quarter Ratio",number(model.snapshot?.quarterRatio),"≥1.0",state(model.snapshot?.quarterRatio,good:1))
                    line("10D Ratio",number(model.snapshot?.ratio(10)),"≥2.0",state(model.snapshot?.ratio(10),good:2))
                    line("5D Ratio",number(model.snapshot?.ratio(5)),">1.0",state(model.snapshot?.ratio(5),good:1))
                    line("3D Ratio",number(model.snapshot?.ratio(3)),"≥1.5",state(model.snapshot?.ratio(3),good:1.5))
                    line("T2108", model.snapshot?.latest?.t2108.map{String(format:"%.1f%%",$0)} ?? "—", "≥60%",state(model.snapshot?.latest?.t2108,good:60))
                    line("Quarter Up/Down", pair(model.snapshot?.latest?.quarterUp,model.snapshot?.latest?.quarterDown),"—","—")
                    line("SPY/QQQ 趋势",quotePresence(["SPY","QQQ"]),"MA20/50",model.assessment.items[4].score.map { "\($0)/25" } ?? "待接入")
                    line("XLK/SMH/XLY",quotePresence(["XLK","SMH","XLY"]),"相对SPY",model.assessment.items[6].score.map { "\($0)/10" } ?? "待接入")
                }
                if let snapshot = model.snapshot {
                    Text("数据：\(snapshot.sourceName)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            SectionCard(title:"近10交易日 4% Up/Down 趋势",symbol:"chart.xyaxis.line") {
                if let days = model.snapshot?.rows.prefix(10), !days.isEmpty {
                    Chart {
                        ForEach(Array(days.reversed())) { d in
                            BarMark(x:.value("交易日",String(d.date.suffix(5))),y:.value("数量",d.up4))
                                .foregroundStyle(Palette.positive)
                                .position(by:.value("方向","4% Up"))
                            BarMark(x:.value("交易日",String(d.date.suffix(5))),y:.value("数量",d.down4))
                                .foregroundStyle(Palette.negative)
                                .position(by:.value("方向","4% Down"))
                        }
                    }.frame(height:220)
                    HStack(spacing:16) {
                        Label("4% Up",systemImage:"square.fill").foregroundStyle(Palette.positive)
                        Label("4% Down",systemImage:"square.fill").foregroundStyle(Palette.negative)
                        Spacer()
                    }.font(.caption)
                } else {
                    emptyData("尚无可验证的历史数据")
                }
                Text("Ratio按连续交易日的4%上涨/下跌数量求和后相除；不足样本或分母为0时不强行评分。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var rightPanel: some View {
        VStack(spacing:14) {
            SectionCard(title:"100分环境评分系统",symbol:"checkmark.seal.fill") {
                HStack(spacing:0) {
                    textCell("评分模块",flex:3,bold:true)
                    textCell("权重",flex:0.7,bold:true)
                    textCell("得分",flex:0.8,bold:true)
                }.padding(.vertical,10).background(Palette.background)
                ForEach(model.assessment.items) { item in
                    HStack(spacing:0) {
                        textCell(item.name,flex:3)
                        textCell("\(item.maxScore)",flex:0.7)
                        textCell(item.score.map { "\($0)" } ?? "—",flex:0.8,bold:true)
                    }
                    .padding(.vertical,9)
                    .overlay(alignment:.bottom){ Palette.border.opacity(0.65).frame(height:0.6) }
                    .help(item.explanation)
                }
                HStack(spacing:0) {
                    textCell("合计",flex:3,bold:true)
                    textCell("100",flex:0.7,bold:true)
                    textCell(model.assessment.total.map { "\($0)" } ?? "—",flex:0.8,bold:true)
                }.padding(.vertical,10).background(Palette.background)
                HStack(spacing:9) {
                    gradeBadge("A级","80–100","按计划参与",Palette.positive)
                    gradeBadge("B级","65–79","精选小仓",Palette.blue)
                    gradeBadge("C级","45–64","观察为主",Palette.amber)
                    gradeBadge("D级","0–44","暂停新仓",Palette.negative)
                }
            }
            SectionCard(title:"评分结果与策略建议",symbol:"lightbulb.fill") {
                HStack(alignment:.center,spacing:17) {
                    ZStack {
                        Circle().stroke(Palette.border,lineWidth:15)
                        Circle()
                            .trim(from:0,to:CGFloat(model.assessment.total ?? 0)/100)
                            .stroke(Palette.blue,style:StrokeStyle(lineWidth:15,lineCap:.round))
                            .rotationEffect(.degrees(-90))
                        VStack(spacing:3) {
                            Text(model.assessment.total.map{String($0)} ?? "—").font(.system(size:38,weight:.bold))
                            Text("/ 100").font(.caption).foregroundStyle(.secondary)
                        }
                    }.frame(width:148,height:148)
                    VStack(alignment:.leading,spacing:9) {
                        Text("当前环境等级").font(.headline)
                        Text(model.assessment.grade.map{$0+" 级"} ?? "待评估")
                            .font(.system(size:29,weight:.bold)).foregroundStyle(model.assessment.grade == nil ? Palette.amber : Palette.blue)
                        Text(model.assessment.total == nil ? "有效分值 \(model.assessment.partial)/\(model.assessment.availableMax)，尚未满足100分完整度" : "7项模块已全部计算")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false, vertical:true)
                    }
                    Spacer(minLength:0)
                }.padding(.vertical,4)
                HStack(alignment:.top,spacing:12) {
                    advice("VCP · Minervini",model.assessment.vcp,"chart.line.uptrend.xyaxis")
                    advice("HTF · Qullamaggie",model.assessment.htf,"flag.checkered")
                }
                if !model.quoteSources.isEmpty {
                    Text("指数/板块行情：" + Array(Set(model.quoteSources.values)).sorted().joined(separator:"；"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !model.warnings.isEmpty {
                    VStack(alignment:.leading,spacing:5) {
                        ForEach(model.warnings,id:\.self) { text in
                            Label(text,systemImage:"exclamationmark.triangle")
                                .font(.caption).foregroundStyle(Palette.amber)
                                .fixedSize(horizontal:false,vertical:true)
                        }
                    }.frame(maxWidth:.infinity,alignment:.leading).padding(10)
                        .background(Palette.amber.opacity(0.075),in:RoundedRectangle(cornerRadius:9))
                }
                Text("规则为自定义交易环境过滤器，非Stockbee官方评级；缺失数据不按0分，未获完整100分时不发布环境等级。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var bottomStatus: some View {
        HStack(spacing:9) {
            Image(systemName: model.error == nil ? "info.circle" : "exclamationmark.triangle.fill")
                .foregroundStyle(model.error == nil ? Palette.blue : Palette.negative)
            Text(model.status).lineLimit(2)
            Spacer()
            if model.loading { ProgressView().controlSize(.small) }
            if let data = model.snapshot {
                Link("查看原始来源",destination:URL(string:data.sourceURL)!)
            } else {
                Link("Stockbee官网",destination:URL(string:GoogleSheetDiscovery.officialPage)!)
            }
        }
        .font(.caption).padding(.horizontal,18).padding(.vertical,10).background(.white)
        .overlay(alignment:.top){ Palette.border.frame(height:1) }
    }
    private var settings: some View {
        VStack(alignment:.leading,spacing:16) {
            Text("数据源与自动刷新").font(.title2.bold())
            Text("程序每15分钟检查一次，但Stockbee市场广度数据由其发布者在美股收盘后更新。此刷新频率不等于数据为盘中实时。")
                .foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            Picker("市场广度来源",selection:$model.sourceMode) {
                Text("Stockbee官方Google Sheets（默认）").tag("official")
                Text("Stage2Stocks非官方独立复算（可选）").tag("thirdparty")
            }.pickerStyle(.radioGroup)
            if model.sourceMode == "official" {
                TextField("官方Google Sheets分享/发布链接（可选）",text:$model.manualSheetURL)
                    .textFieldStyle(.roundedBorder)
                Text("留空会自动发现Stockbee博客内嵌表格；如果官网阻断采集，可手动粘贴其Google Sheets链接。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("指数和板块：Yahoo Finance日K线；不可用时尝试Stooq。所有指数数据必须与市场广度匹配同一交易日。")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            HStack {
                Button("打开Stockbee官网") { NSWorkspace.shared.open(URL(string:GoogleSheetDiscovery.officialPage)!) }
                Spacer()
                Button("取消") { model.showSettings = false }
                Button("保存并刷新") { model.saveSettings() }.keyboardShortcut(.defaultAction)
            }
        }.padding(25).frame(width:650,height:380)
    }
    private func metric(_ title:String,_ value:String,_ tint:Color) -> some View {
        VStack(spacing:8) {
            Text(title).font(.headline)
            Text(value).font(.system(size:34,weight:.heavy,design:.rounded)).foregroundStyle(tint)
        }.frame(maxWidth:.infinity).padding(.vertical,17)
            .background(tint.opacity(0.07),in:RoundedRectangle(cornerRadius:10))
    }
    private func tableHeader(_ titles:[String],weights:[CGFloat]) -> some View {
        HStack(spacing:2) {
            ForEach(Array(titles.enumerated()),id:\.offset) { i,t in
                Text(t).font(.subheadline.bold()).frame(maxWidth:.infinity,alignment:i == 0 ? .leading : .center)
                    .frame(minWidth:weights[i]*28).layoutPriority(Double(weights[i]))
            }
        }.padding(9).background(Palette.background,in:RoundedRectangle(cornerRadius:6))
    }
    private func line(_ name:String,_ current:String,_ reference:String,_ state:String) -> some View {
        HStack(spacing:2) {
            Text(name).frame(maxWidth:.infinity,alignment:.leading)
            Text(current).frame(maxWidth:.infinity)
            Text(reference).frame(maxWidth:.infinity)
            Text(state).frame(maxWidth:.infinity).foregroundStyle(state.contains("偏弱") ? Palette.negative : .primary)
        }
        .font(.system(size:12.5)).padding(.vertical,8).padding(.horizontal,7)
        .overlay(alignment:.bottom){ Palette.border.opacity(0.7).frame(height:0.5) }
    }
    private func textCell(_ text:String,flex:CGFloat,bold:Bool=false) -> some View {
        Text(text).font(.system(size:13,weight:bold ? .semibold : .regular))
            .lineLimit(1).frame(maxWidth:.infinity,alignment:flex == 3 ? .leading : .center)
            .frame(minWidth: flex*35).layoutPriority(Double(flex)).padding(.leading,flex == 3 ? 12 : 0)
    }
    private func gradeBadge(_ title:String,_ range:String,_ advice:String,_ tint:Color) -> some View {
        VStack(spacing:5) {
            Text(title).font(.headline)
            Text(range).font(.subheadline)
            Text(advice).font(.caption)
        }.frame(maxWidth:.infinity).padding(.vertical,11)
            .foregroundStyle(tint).background(tint.opacity(0.11),in:RoundedRectangle(cornerRadius:9))
    }
    private func advice(_ name:String,_ description:String,_ icon:String) -> some View {
        VStack(alignment:.leading,spacing:12) {
            Label(name,systemImage:icon).font(.subheadline.bold())
                .foregroundStyle(.white)
                .frame(maxWidth:.infinity,alignment:.leading)
                .padding(10).background(Palette.navy)
            Text(description).font(.subheadline).fixedSize(horizontal:false,vertical:true)
                .frame(maxWidth:.infinity,minHeight:60,alignment:.topLeading).padding(.horizontal,10)
        }.background(Palette.background,in:RoundedRectangle(cornerRadius:8))
            .clipShape(RoundedRectangle(cornerRadius:8))
            .frame(maxWidth:.infinity)
    }
    private func number(_ n:Double?) -> String { n.map { String(format:"%.2f",$0) } ?? "—" }
    private func pair(_ x:Int?,_ y:Int?) -> String { if let x, let y { return "\(x) / \(y)" }; return "—" }
    private func quotePresence(_ keys:[String]) -> String { keys.allSatisfy{model.quotes[$0] != nil} ? "已接入" : "待接入" }
    private func state(_ n:Double?,good:Double) -> String {
        guard let n else { return "待计算" }
        return n >= good ? "达标" : (n >= good * 0.7 ? "关注" : "偏弱")
    }
    private func emptyData(_ msg:String) -> some View {
        Text(msg).frame(maxWidth:.infinity,minHeight:180).foregroundStyle(.secondary)
    }
}

private struct SectionCard<Content: View>: View {
    let title:String
    let symbol:String
    let content:Content
    init(title:String, symbol:String, @ViewBuilder content:() -> Content) {
        self.title = title; self.symbol = symbol; self.content = content()
    }
    var body: some View {
        VStack(spacing:0) {
            Label(title,systemImage:symbol).font(.title3.bold())
                .foregroundStyle(.white)
                .frame(maxWidth:.infinity,alignment:.leading)
                .padding(.horizontal,16).padding(.vertical,11)
                .background(Palette.navy)
            VStack(spacing:12){ content }.padding(12)
        }.background(.white,in:RoundedRectangle(cornerRadius:12))
            .clipShape(RoundedRectangle(cornerRadius:12))
            .overlay(RoundedRectangle(cornerRadius:12).stroke(Palette.border,lineWidth:1))
    }
}
#endif
