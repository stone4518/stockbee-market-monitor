import XCTest
@testable import StockbeeCore

final class CoreTests: XCTestCase {
    func sample() throws -> BreadthSnapshot {
        let url = Bundle.module.url(forResource:"sample", withExtension:"csv")!
        let s = try String(contentsOf: url, encoding:.utf8)
        let rows = try TabularParser.breadth(TabularParser.csv(s))
        return BreadthSnapshot(sourceName:"fixture",sourceURL:"fixture",official:false,rows:rows)
    }
    func testCSV() throws {
        XCTAssertEqual(TabularParser.csv("a,b\n\"c, d\",\"e\"\"f\""), [["a","b"],["c, d","e\"f"]])
    }
    func testParsesMarketRow() throws {
        let s = try sample()
        XCTAssertEqual(s.rows.count,10)
        XCTAssertEqual(s.latest?.date,"2026-11-10")
        XCTAssertEqual(s.latest?.up4,68)
        XCTAssertEqual(s.latest?.down4,124)
        XCTAssertEqual(s.latest?.t2108,57)
        XCTAssertEqual(s.quarterRatio ?? 0,238.0/416.0,accuracy:0.001)
        XCTAssertNotNil(s.ratio(3))
        XCTAssertNotNil(s.ratio(5))
        XCTAssertNotNil(s.ratio(10))
    }
    func testNoGuessingWithoutHeaders() throws {
        XCTAssertThrowsError(try TabularParser.breadth([["date","up","down"],["2026-11-10","20","40"]]))
    }
    func testIncompleteScoreIsNeverAFullScore() throws {
        let a = Scorer.assess(try sample(),[:])
        XCTAssertNil(a.total)
        XCTAssertNil(a.grade)
        XCTAssertEqual(a.availableMax,65)
        XCTAssertTrue(a.vcp.contains("不完整"))
    }
    func testFullScoreAndRange() throws {
        let s = try sample()
        let ds = (0..<70).map { index -> String in
            let date = Calendar(identifier:.gregorian).date(byAdding:.day,value:index-69,to:ISO8601DateFormatter().date(from:"2026-11-10T12:00:00Z")!)!
            let f = DateFormatter();f.timeZone=TimeZone(secondsFromGMT:0);f.dateFormat="yyyy-MM-dd"
            return f.string(from:date)
        }
        let symbols = ["SPY","QQQ","XLK","SMH","XLY"]
        var quotes:[String:QuoteHistory] = [:]
        for symbol in symbols {
            let slope = symbol == "SMH" ? 1.5 : 1.0
            quotes[symbol] = QuoteHistory(symbol:symbol,dates:ds,closes:(0..<70).map{100+Double($0)*slope})
        }
        let assessment = Scorer.assess(s,quotes)
        XCTAssertNotNil(assessment.total)
        XCTAssertEqual(assessment.items.map(\.maxScore).reduce(0,+),100)
        XCTAssertTrue((0...100).contains(assessment.total!))
    }
    func testSheetDiscovery() {
        let html = "<iframe src=\"https://docs.google.com/spreadsheets/d/e/2PACX-abc/pubhtml?gid=2&amp;single=true\"></iframe>"
        let links = GoogleSheetDiscovery.sheetLinks(html:html)
        XCTAssertEqual(links.count,1)
        XCTAssertTrue(GoogleSheetDiscovery.csvURLs(links[0]).first!.absoluteString.contains("output=csv"))
    }
    func testHTMLTableParsing() throws {
        let html = "<table><tr><th>Date</th><th>Up 4% today</th><th>Down 4% today</th><th>Up 25% in a quarter</th><th>Down 25% in a quarter</th><th>T2108</th></tr><tr><td>Nov 10, 2026</td><td>68</td><td>124</td><td>238</td><td>416</td><td>57%</td></tr></table>"
        let days = try TabularParser.breadth(TabularParser.htmlTables(html)[0])
        XCTAssertEqual(days.count,1)
        XCTAssertEqual(days[0].quarterDown,416)
    }
    func testMissingRows() throws {
        var s = try sample()
        s.rows = Array(s.rows.prefix(2))
        XCTAssertNil(s.ratio(3))
        XCTAssertNil(Scorer.assess(s,[:]).total)
    }
    func testQuoteAsOfDateAndRelativeStrength() {
        let dates = (1...35).map{String(format:"2026-10-%02d",$0)}
        let spy = QuoteHistory(symbol:"SPY",dates:dates,closes:(0..<35).map{100+Double($0)})
        let xlk = QuoteHistory(symbol:"XLK",dates:dates,closes:(0..<35).map{100+Double($0)*2})
        XCTAssertGreaterThan(xlk.relativeGain(versus:spy) ?? 0,0)
        XCTAssertEqual(spy.through("2026-10-21").dates.count,21)
    }
    func testDifferentDatesNeverCreateFullScore() throws {
        let sample = try sample()
        let symbols = ["SPY","QQQ","XLK","SMH","XLY"]
        var quotes:[String:QuoteHistory] = [:]
        let dates = (1...70).map { String(format:"2026-01-%02d",$0) }
        for ticker in symbols { quotes[ticker] = QuoteHistory(symbol:ticker,dates:dates,closes:(0..<70).map{100 + Double($0)}) }
        let result = Scorer.assess(sample,quotes)
        XCTAssertNil(result.total)
        XCTAssertNil(result.items[4].score)
        XCTAssertNil(result.items[6].score)
    }
    func testBadT2108Rejected() throws {
        let table = [["Date","Up 4% today","Down 4% today","Up 25% in quarter","Down 25% in quarter","T2108"],
          ["Nov 10, 2026","68","124","238","416","105%"]]
        XCTAssertThrowsError(try TabularParser.breadth(table))
    }
    func testHeaderSplitAcrossRows() throws {
        let table = [["Date","Up","Down","Up","Down","T2108"],
         ["","4% today","4% today","25% in quarter","25% in quarter",""],
         ["Nov 10, 2026","68","124","238","416","57%"]]
        XCTAssertEqual(try TabularParser.breadth(table).first?.date,"2026-11-10")
    }
}
