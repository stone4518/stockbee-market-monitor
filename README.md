# Stockbee Market Monitor（美股动量交易环境监控）

macOS 原生 SwiftUI 桌面应用。它自动读取 Stockbee 官网 Market Monitor 最新发布的市场广度数据，结合 SPY/QQQ 趋势和 XLK/SMH/XLY 板块相对强度，用一套**自定义的 100 分模型**给出市场环境等级（A/B/C/D），以及对应的 Minervini VCP 和 Qullamaggie HTF 策略建议。

> 评分模型是自定义的交易环境过滤器，**不是 Stockbee 官方评级**，也**没有经过历史回测**。它只反映市场环境，不是个股买卖信号。应用只读取行情，不连接券商、不下单、不保存任何账号密码。

## 安装

1. 打开 `StockbeeMarketMonitor.dmg`，把 **Stockbee Market Monitor.app** 拖到“应用程序”文件夹。
2. **第一次打开**：右键应用 → “打开” → 再点“打开”。如果系统提示“无法验证开发者”，到 **系统设置 → 隐私与安全性** 页面底部点“仍要打开”。
   也可以在终端执行：`xattr -dr com.apple.quarantine "/Applications/Stockbee Market Monitor.app"`
3. 系统要求：macOS 13 及以上；通用二进制，Apple Silicon 和 Intel 都能运行。

签名状态：本地 **ad-hoc 签名**，**没有** Apple Developer ID 签名，也**没有**公证（notarization）。所以只适合本机或自己的电脑使用，不适合公开分发。

**卸载**：删除 `/Applications/Stockbee Market Monitor.app`，再删除本地缓存 `~/Library/Application Support/StockbeeMarketMonitor`。

## 界面

| 区域 | 内容 |
|---|---|
| 顶栏 | 最新已发布交易日（美东）、上次检查和上次成功时间、刷新按钮（⌘R）、数据来源设置（⌘,）、来源标签（官方 / 非官方 / 离线缓存）、时效标签（最新 / 尚未发布 / 过期） |
| 左栏 | 4% Up / 4% Down / 10D Ratio 大字；Quarter、10D、5D、3D Ratio，T2108，Quarter Up/Down，SPY/QQQ，板块的当前值，以及“正常”“理想做多”参考值和状态；近 10 个交易日 4% Up/Down 柱状图 |
| 右上 | 7 个模块的读数、权重、得分（鼠标悬停可看规则和计算过程）、合计、A/B/C/D 区间（当前等级高亮） |
| 右下 | 总分环、等级、距 A 级还差几分、主要扣分项、VCP/HTF 建议、广度和动量变化信号、阻止评分的原因、数据提示 |
| 底栏 | 刷新状态（是否发现新交易日）、官网 MM 页面和原始数据链接 |

**刷新**：启动时、每 15 分钟、电脑唤醒后各自动检查一次，也可以手动刷新；正在刷新时不会重复发请求。Stockbee 数据在美股**收盘后**才更新，检查频率**不代表盘中实时**。

**完整评分的条件**（缺一不可）：7 个模块都有值；广度数据没有过期（最多落后 1 个交易日）；5 只 ETF 都有与广度数据**同一交易日**的收盘价，并且来自同一行情商；数据源是官网自动发现的官方表格；当前不是离线缓存。否则显示“待评估”和“已验证 x / y 分”。缺失项记 **N/A**，不按 0 分计算。

**离线**：断网或官网不可访问时，显示上次成功抓取的缓存，并标注“离线缓存 · 只读”。缓存数据**不发布等级**。

## 数据与评分规则

详见 [docs/数据源与评分规则.md](docs/数据源与评分规则.md)：数据来源、指标定义（已用官方数据逐行核实）、交易日和过期策略、100 分阶梯规则、规则审查与修改建议。

## 从源码构建

```bash
xcode-select --install          # 未安装 Xcode / Command Line Tools 时
swift test                      # 运行全部单元测试（含真实官方数据回归测试）
swift run stockbee-probe .      # 联网实测：抓官方数据和行情，输出完整评分，生成 probe.txt / probe.json
bash build-mac.command          # 生成 dist/ 下的 .app、ZIP、DMG（通用二进制，ad-hoc 签名）
```

`.github/workflows/mac.yml` 会在 GitHub 的 macOS 机器上自动完成：抓取原始数据存档 → 单元测试 → 联网探针 → 构建并打包 → 产物检查 → 启动应用并截图。结果写回 `ci-results` 分支。

## 目录

| 路径 | 说明 |
|---|---|
| `Sources/StockbeeCore/Core.swift` | 数据模型、比率计算、NYSE 交易日历、数据时效、100 分评分（与网络无关，方便修改规则） |
| `Sources/StockbeeCore/Parsing.swift` | 官网表格地址发现、CSV/HTML 解析、按列名识别（不猜列位置） |
| `Sources/StockbeeCore/Network.swift` | 联网取数、多行情商、行情解析与校验 |
| `Sources/stockbee-probe/` | 命令行联网实测探针 |
| `MacApp/` | SwiftUI 界面、状态与缓存、截图模式 |
| `Tests/StockbeeCoreTests/` | 单元测试；`Resources/` 里的真实数据样本是 2026-11-12 实际抓取的 |
| `scripts/` | 原始数据抓取、UI 截图脚本 |
| `docs/` | 数据源与评分规则、验收报告、安装说明 |
| `Docs/交接/` | 交接时的原始文档（历史参考） |

## 已知限制

- 所有数据源都是公开网页接口，没有服务保障：Blogger 和 Yahoo 偶尔会限流（HTTP 429），任何一方改版都可能导致取数失败。失败时应用会明确提示，不会编造数据。
- Cboe 行情文件实测比 Nasdaq 晚一个交易日，只有在前两家都不可用时才会用到；它缺当天收盘时，相关模块显示 N/A。
- T2108 是 Worden 股票池的口径，不是 Russell 3000。
- 评分阈值继承自交接版本，没有回测。
