# Stockbee Market Monitor for macOS

面向 macOS 的 SwiftUI 原生桌面应用。左侧展示 Stockbee Market Monitor 的4% Up/Down、3/5/10日动量比、Quarter Ratio、T2108及最近10日走势；右上为自定义100分市场环境评分，右下为 A/B/C/D 等级以及 Minervini VCP、Qullamaggie HTF 风险建议。

> **状态：源码开发版 / macOS 真机验收未完成。** 核心解析与评分在 Linux Swift 6.2 环境中通过了12项自动化测试。此执行环境没有 macOS SDK、不能运行或编译 Mac 的 `.app`，也不能向外联网验证官方Google Sheets和行情接口。因此不能承诺数据源可长期稳定访问，更不能把它称为完成真机测试的签名安装包。

## 一、在Mac上安装（第一次）

1. 解压 `StockbeeMac-source.zip`，打开 `StockbeeMac` 文件夹。
2. 系统要求 macOS 13 Ventura 或更高版本，建议 Apple Silicon / Intel Mac、Xcode 15或更新版本（或支持Swift 5.9+的Command Line Tools）。
3. 如尚未安装 Apple 命令行开发工具，在终端执行 `xcode-select --install`，完成后重试。
4. 右键 `build-mac.command` → **打开**，或在终端运行：`bash build-mac.command`。
5. 构建脚本会自动执行 `swift test`，任何单元测试失败立即停止；成功后生成 `dist/Stockbee Market Monitor.app`。之后双击 `.app` 启动。
6. 第一次启动如遇 macOS Gatekeeper 提示，右键应用 → 打开；如仍受拦截，可在“系统设置 → 隐私与安全性”核实后允许。**不要关闭系统全局安全防护。**

完成后可把 `dist/Stockbee Market Monitor.app` 拖到“应用程序”文件夹。当前生成的是本机 ad-hoc 签名的自用程序，**不是经Apple开发者证书签名、公证的正式安装包**。

## 二、数据读取设计

- **默认：Stockbee官方来源**。每次刷新先读取 [Stockbee MM页面](https://stockbee.blogspot.com/p/mm.html)，从页面自动发现其公开Google Sheets嵌入链接，尝试读取公开CSV与HTML表格，并按原始交易日期及列名进行校验。
- **官方页面解析失败时**：打开右上角“数据源”设置，可手动贴入从官方页面取得的Google Sheets链接。**手动贴入链接仅标记为“用户提供表格，官方关联未核验”**，不会冒充官方来源。
- **可选备援：Stage2Stocks**。在“数据源”中切换到“非官方独立复算”可尝试其它公开市场广度源。它的股票池、成交量过滤、Quarter计算可能不同，程序明确标识，不能等同Stockbee官方数据。
- **SPY/QQQ、XLK/SMH/XLY**：使用Yahoo Finance公开日线；不可用时尝试Stooq。若它们的日期与Stockbee数据日期不一致，不参与评分；不同提供商的数据不会混用于行业相对强度。
- **T2108**：在当前设计中取自Market Monitor表格。图中“Russell 3000广度”采用T2108作为广度代理，不代表已独立统计Russell 3000成分股40日均线占比。
- **刷新间隔**：启动时、点击“刷新”时及窗口打开后每15分钟尝试联网更新一次；按美东交易日显示最后一期数据及本机检查时间。
- **不是盘中逐笔实时**：Market Monitor的4% Up/Down基于美股收盘后统计，公式和发布时间由Stockbee控制。每15分钟检查不会把晚间更新的数据变成盘中实时行情。

## 三、100分评分（自定义，非官方）

| 模块 | 权重 | 具体打分 |
|---|---:|---|
| Quarter Ratio | 20 | ≥1.5得20；≥1得15；≥0.7得8；否则0 |
| 10D Ratio | 15 | ≥2得15；≥1.3得11；≥1得7；否则0 |
| 5D Ratio | 5 | ≥2得5；≥1.3得4；≥1得3；否则0 |
| 3D Ratio | 5 | ≥1.5得5；≥1得3；否则0 |
| SPY/QQQ趋势 | 25 | 各站上MA20得4、站上MA50得5、MA20五个交易日前后斜率为正得3；双指数全部达标额外+1 |
| T2108（广度代理） | 20 | ≥70%得20；≥60%得17；≥50%得12；≥40%得7；否则0 |
| XLK/SMH/XLY板块相对SPY | 10 | 近20个**共同交易日**相对SPY走强，分别得3/4/3 |

总分与策略参考：A级80–100（VCP按计划、HTF可参与），B级65–79（VCP精选小仓、HTF仅极强领涨股），C级45–64（VCP观察、HTF暂停新仓），D级0–44（两种策略暂停新仓）。策略建议是环境筛选，不是买卖信号；还须满足个股形态、突破量能、风险预算及止损规则。

**只要任何一个模块数据缺失，总分和等级一律显示“—/待评估”，只显示已有的部分分数 `有效分值/可用权重`，不把缺失按0分。** 数据源解析失败会清除上一期评分，避免误把旧数据作为新数据。

## 四、故障处理

- **官网自动发现失败**：访问官方MM页面确认当前iframe是否仍指向公开Google Sheets。必要时在应用设置里贴入该Google Sheets地址。若Stockbee取消公开发布权限，必须等待数据源恢复权限；程序不会绕过登录、付费墙或访问限制。
- **全部行情待接入**：可能因Yahoo或Stooq访问限制。查看底部状态及右下“警告”，确认本机网络和行情提供商公开端点是否可访问。
- **部分评分显示横线**：代表所需数据不足、日期错位、源不可用或公式分母为0；不能推断市场处于D级。
- **上次检查时间更新，交易日不更新**：这是正常可能情况，说明源尚未发布新的收盘数据，或者源本身延迟；程序不能替发布者生成官方数据。

## 五、源码目录

- `Sources/StockbeeCore/Core.swift`：行情数据结构、比率计算、100分规则。
- `Sources/StockbeeCore/Parsing.swift`：Google Sheets/HTML/CSV解析及官方iframe发现。
- `Sources/StockbeeCore/Network.swift`：公开HTTP源的请求、价格数据。
- `MacApp/ContentView.swift`：双栏SwiftUI界面和图表。
- `MacApp/MonitorModel.swift`：刷新、日期一致性、错误处理和设置。
- `MacApp/StockbeeMacApp.swift`：Mac程序入口。
- `Tests/StockbeeCoreTests`：可在Mac或Linux运行的自动化单元测试。
- `build-mac.command`：Mac本机编译、先测试再构建。

## 六、验证范围

| 测试项 | 本次结果 |
|---|---|
| 核心Swift构建和12项解析/评分单测 | 通过 |
| SwiftUI源码语法解析 | 通过（未做macOS SDK类型检查） |
| Google Sheets iframe提取（离线样本） | 通过 |
| 缺失行情不发布完整等级 | 通过 |
| 评分权重总和100及范围约束 | 通过 |
| 不匹配交易日不出完整等级 | 通过 |
| 官方源**真实在线访问** | 未验证：当前执行环境无外网DNS |
| 真正macOS 13+二进制构建与应用启动 | 未验证：当前执行环境为Linux |
| Apple开发者签名和公证 | 未执行 |

**交付前检查结论**：此交付是**可在Mac上编译并验证的完整源码开发版**，不是已经验证能稳定拉取正式实时数据的最终安装版。必须通过Mac本机编译及至少一次在线数据验收后，才可认定为正式可用。
