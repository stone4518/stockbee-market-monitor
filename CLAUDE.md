# CLAUDE.md — Stockbee Market Monitor

你是接手这个 macOS SwiftUI 应用的开发者。先读 `Docs/Claude_项目交接文档.md` 和 `StockbeeMac/README_使用说明.md`，再看源码；视觉布局参照 `Design/`。这是源码开发版，12项Linux单测通过，不等于Mac真机或在线数据验收通过。

**工作优先级**：macOS 编译并实际启动 → 官方Stockbee发布数据真实抓取并与官网逐项核对 → 5个ETF行情与交易日一致性 → 7项完整评分与风险建议 → 异常场景测试 → 实际交付 `.app`。

**红线**：不将fixture/原型数值视作实时数据；缺失项不能以0分替代；未拿到完整且同日数据时不能发布等级；第三方数据不能冒充Stockbee官方；不自动下单。请明确说明全部未经验证的地方。

Mac上优先运行：`cd StockbeeMac && swift test -j 2 && bash build-mac.command`，再实际打开 `dist/Stockbee Market Monitor.app`，逐项完成交接文档中的验收清单。
