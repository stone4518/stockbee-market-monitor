import Foundation

public enum TabularParser {
    public static func csv(_ text: String) -> [[String]] {
        var result = [[String]](), current = [String](), cell = "", quoted = false
        let chars = Array(text.replacingOccurrences(of: "\u{feff}", with: ""))
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\"" {
                if quoted && i + 1 < chars.count && chars[i + 1] == "\"" { cell.append("\""); i += 1 }
                else { quoted.toggle() }
            } else if c == "," && !quoted {
                current.append(cell); cell = ""
            } else if (c == "\n" || c == "\r") && !quoted {
                if c == "\r" && i + 1 < chars.count && chars[i + 1] == "\n" { i += 1 }
                current.append(cell); cell = ""
                if current.contains(where: { !$0.isEmpty }) { result.append(current) }
                current = []
            } else { cell.append(c) }
            i += 1
        }
        if !cell.isEmpty || !current.isEmpty { current.append(cell); result.append(current) }
        return result
    }
    public static func extractMatches(_ s: String, pattern: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { match in
            (0..<match.numberOfRanges).map { index in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : ns.substring(with: range)
            }
        }
    }
    public static func htmlUnescape(_ text: String) -> String {
        var result = text
        let substitutions = ["&amp;": "&", "&lt;":"<", "&gt;": ">", "&quot;":"\"", "&#39;":"'", "&nbsp;":" ", "&#x27;":"'", "&#47;":"/", "\\/":"/", "\\u003d":"=", "\\u0026":"&"]
        for (a,b) in substitutions { result = result.replacingOccurrences(of: a, with: b) }
        // Numeric HTML entities, a rare occurrence in Google Sheets.
        for m in extractMatches(result, pattern: #"&#(\d+);"#).reversed() {
            if let n = UInt32(m[1]), let scalar = UnicodeScalar(n) { result = result.replacingOccurrences(of: m[0], with: String(scalar)) }
        }
        return result
    }
    public static func htmlTables(_ html: String) -> [[[String]]] {
        let tables = extractMatches(html, pattern: #"<table\b[^>]*>(.*?)</table>"#)
        return tables.map { table in
            extractMatches(table[1], pattern: #"<tr\b[^>]*>(.*?)</tr>"#).map { row in
                extractMatches(row[1], pattern: #"<(?:td|th)\b[^>]*>(.*?)</(?:td|th)>"#).map { cell in
                    let flattened = cell[1].replacingOccurrences(of: #"<br\s*/?>"#, with: " ", options: .regularExpression)
                       .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
                    return htmlUnescape(flattened).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }.filter { !$0.isEmpty }
        }
    }
    private static func normalized(_ s: String) -> String {
        let lower = s.lowercased().replacingOccurrences(of: "%", with: "")
        return lower.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }
    private static func which(_ header: String) -> String? {
        let h = normalized(header)
        if h == "date" || h == "day" || h == "tradingdate" || h.contains("date") { return "date" }
        if h == "t2108" || h.contains("above40") || h.contains("40dayavg") || h.contains("40dayaverage") || h.contains("40dma") { return "t2108" }
        if (h.contains("quarter") || h.contains("65day") || h.contains("qtr")) && (h.contains("25") || h.contains("quarter")) {
            if h.contains("up") || h.contains("bull") || h.contains("gain") { return "quarterUp" }
            if h.contains("down") || h.contains("bear") || h.contains("declin") { return "quarterDown" }
        }
        if (h.contains("5day") || h.contains("5d")) && h.contains("ratio") { return "reported5" }
        if (h.contains("10day") || h.contains("10d")) && h.contains("ratio") { return "reported10" }
        if h.contains("4") && !h.contains("40") && !h.contains("34") {
            if h.contains("up") || h.contains("bull") || h.contains("breakout") { return "up4" }
            if h.contains("down") || h.contains("bear") || h.contains("breakdown") { return "down4" }
        }
        return nil
    }
    private static func numeric(_ s: String) -> Double? {
        var n = s.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "")
        n = n.replacingOccurrences(of: "%", with: "").replacingOccurrences(of: "−", with: "-")
        if n.isEmpty || n == "--" || n == "—" || n == "-" { return nil }
        return Double(n)
    }
    private static func integer(_ s: String) -> Int? {
        guard let n = numeric(s), n.isFinite, n >= 0, n <= 20000, n.rounded() == n else { return nil }
        return Int(n)
    }
    /// Fails closed unless the table identifies the core required columns by header names.
    public static func breadth(_ cells: [[String]]) throws -> [BreadthDay] {
        var bestRows: [BreadthDay] = []
        // Google Sheet often has one or more title/header rows, so search the first 20.
        for headerIndex in 0..<min(20,cells.count) {
            for headerHeight in 1...min(3, cells.count - headerIndex) {
                let headerRows = Array(cells[headerIndex..<(headerIndex + headerHeight)])
                let maxColumns = headerRows.map(\.count).max() ?? 0
                var map = [String:Int]()
                for i in 0..<maxColumns {
                    let columnHeader = headerRows.compactMap { i < $0.count ? $0[i] : nil }.joined(separator: " ")
                    if let type = which(columnHeader), map[type] == nil { map[type] = i }
                }
                let required = ["date", "up4", "down4", "quarterUp", "quarterDown"]
                guard required.allSatisfy({ map[$0] != nil }) else { continue }
                var days = [String:BreadthDay]()
                func field(_ r: [String], _ kind: String) -> String {
                    guard let idx = map[kind], idx < r.count else { return "" }
                    return r[idx]
                }
                for row in cells.dropFirst(headerIndex + headerHeight) {
                    guard let date = DayClock.parse(field(row,"date")),
                          let up = integer(field(row,"up4")), let down = integer(field(row,"down4")),
                          let qUp = integer(field(row,"quarterUp")), let qDown = integer(field(row,"quarterDown")) else { continue }
                    let t = numeric(field(row,"t2108"))
                    if let t, !(0...100).contains(t) { continue }
                    let rep5 = numeric(field(row,"reported5"))
                    let rep10 = numeric(field(row,"reported10"))
                    days[date] = BreadthDay(date: date, up4: up, down4: down, quarterUp: qUp, quarterDown: qDown, t2108: t, reported5: rep5, reported10: rep10)
                }
                let ordered = days.values.sorted { $0.date > $1.date }
                if ordered.count > bestRows.count { bestRows = ordered }
            }
        }
        guard !bestRows.isEmpty else { throw MonitorError.invalidData("数据表未找到可核验的日期、4% Up/Down和Quarter Up/Down列；未猜测列位置") }
        return bestRows
    }
}

public enum GoogleSheetDiscovery {
    public static let officialPage = "https://stockbee.blogspot.com/p/mm.html"
    /// 同时识别旧版 `docs.google.com/spreadsheet/pub?key=…`（Stockbee 官网当前实际嵌入的形式，2026-11 实测）
    /// 与新版 `docs.google.com/spreadsheets/d/…` 地址。
    public static func sheetLinks(html: String) -> [String] {
        let s = TabularParser.htmlUnescape(html)
        var links: [String] = []
        for p in [#"(?:src|href|content)\s*=\s*['\"](https?://docs\.google\.com/spreadsheets?/[^'\"]+)['\"]"#, #"(https?://docs\.google\.com/spreadsheets?/[^\s\"'<>\\]+)"#] {
            for found in TabularParser.extractMatches(s, pattern: p) where found.count > 1 {
                links.append(found[1].replacingOccurrences(of: "http://", with: "https://"))
            }
        }
        var seen = Set<String>()
        return links.filter { link in
            guard let key = identity(link), !seen.contains(key) else { return false }
            seen.insert(key); return true
        }
    }
    /// 去重用的表格身份：旧版用 key，新版用文档 ID，再加 gid。
    static func identity(_ link: String) -> String? {
        guard let u = URLComponents(string: link) else { return nil }
        let items = u.queryItems ?? []
        let gid = items.first(where: { $0.name == "gid" })?.value ?? ""
        if let key = items.first(where: { $0.name == "key" })?.value { return "key:" + key + "#" + gid }
        if let r = u.path.range(of: #"/spreadsheets/d/(e/)?[^/]+"#, options: .regularExpression) { return String(u.path[r]) + "#" + gid }
        return nil
    }
    public static func csvURLs(_ original: String) -> [URL] {
        guard let comps = URLComponents(string: original), comps.host == "docs.google.com" else { return [] }
        let path = comps.path
        let query = comps.queryItems ?? []
        let gid = query.first(where: { $0.name == "gid" })?.value
        let gidPart = gid.map { "&gid=" + $0 } ?? ""
        let base = "https://docs.google.com"
        var result = [String]()
        if path.hasPrefix("/spreadsheet/"), let key = query.first(where: { $0.name == "key" })?.value {
            // 旧版发布地址：Google 会 302 到新版 /spreadsheets/d/<id>/pub。
            result.append(base + "/spreadsheet/pub?key=" + key + "&output=csv" + gidPart)
        } else if let span = path.range(of: #"/spreadsheets/d/e/[^/]+"#, options: .regularExpression) {
            result.append(base + String(path[span]) + "/pub?output=csv" + gidPart)
        } else if let span = path.range(of: #"/spreadsheets/d/[^/]+"#, options: .regularExpression) {
            let p = String(path[span])
            result += [base + p + "/pub?output=csv" + gidPart, base + p + "/gviz/tq?tqx=out:csv" + gidPart, base + p + "/export?format=csv" + gidPart]
        } else { return [] }
        result.append(original)
        var seen = Set<String>()
        return result.filter { seen.insert($0).inserted }.compactMap(URL.init(string:))
    }
}
