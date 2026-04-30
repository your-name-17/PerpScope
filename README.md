# Binance USDT EMA+MA(20/60/120) 扫描器

一个使用 Flutter 编写的 Binance USDT 永续合约 **6线混合密度扫描工具**（EMA20/60/120 + MA20/60/120），支持多任务并发扫描与系统级通知（Windows 托盘通知、Android 通知栏、Web 浏览器通知）。

支持平台：Windows/macOS/Linux、Android、Web。

---

## 功能概览

### 1. 6线混合密度扫描
- 从 Binance USDT-M 永续合约市场中筛选交易对。
- 以 24h quoteVolume 排序，扫描前 N 个交易对。
- 拉取 K 线，**自动扩展到至少 1000 根**以保证指标充分热身（特别是 EMA120）。
- **包含当前未走完的 K 线**在密度计算中，实现实时匹配。
- 计算 **6 条指标线**：EMA(20)、EMA(60)、EMA(120)、MA(20)、MA(60)、MA(120)。
- 按以下公式判断是否高密度收敛：

$$
mn = \min(\text{6条线}),\quad
mx = \max(\text{6条线}),\quad
spread = \frac{mx - mn}{|mn|}
$$

当 spread <= threshold 时，视为匹配（高密度收敛区间）。

### 2. 新币扫描
- 扫描 Binance USDT-M 永续合约中“最近 N 天内上新”的币种。
- 新币结果按照最近 1 天的成交额（USDT）降序排序，并受 `topN` 约束。
- 结果会显示币种、上架日期与成交额（USDT）。
- 该功能与 EMA 收敛扫描互相独立，可单独使用。

### 3. 多任务并发
- 支持同时创建多个任务（不同 interval 与 threshold）。
- 每个任务独立运行、独立显示状态、独立存储结果。
- 每个任务可单独开始、停止、删除。

### 4. 连续扫描对齐 K 线收线
- 启用连续扫描后，不再按固定秒数轮询。
- 每个任务会等待到该任务周期的下一根 K 线收线后，再启动下一轮扫描。
- 计算时优先使用 Binance 服务器时间，避免本机时钟偏差。

### 5. 智能提醒
- 仅对“本轮新出现”的匹配币种提醒，避免重复轰炸。
- 若某币种中途消失，后续重新出现时会再次提醒。
- 通知策略：
  - Windows/macOS/Linux：前台弹窗，后台系统通知。
  - Android：统一系统通知（前后台都可接收）。
  - Web：浏览器通知（需授权）。

---

## 参数说明

### 任务参数
- interval：K 线周期（支持 3m / 15m / 1h / 4h / 1d）。
- topN：按 24h quoteVolume 选取前 N 个交易对扫描。
- threshold：密度收敛阈值（建议 0.05 ~ 0.15）。
- klinesLimit：每个交易对拉取的 K 线数量。
  - **自动扩展**：内部会自动确保至少 1000 根 K 线（用于 EMA120 充分热身）。
  - 若指定值 > 1000，会使用指定值。
  - 建议设置 100 ~ 500 即可，自动扩展会处理剩余。
- workers：并发请求数量（建议 8 ~ 20，根据网络与设备调整）。
- 连续扫描：开启后任务会在每根新 K 线收线后自动重复扫描。
  - **实时性**：由于包含未走完 K 线，可实时观察当前形成中的密度状态。

### 新币扫描参数
- 天数：扫描最近 N 天内上新的永续合约。
- topN：按最近 1 天成交额（USDT）排序后，保留前 N 个币种。

### 实用建议
- 想要更快发现机会：选较短 interval（如 3m/15m），提高 workers。
- 想要更稳健结果：选较长 interval（如 1h/4h/1d），适当增大 klinesLimit。
- 结果过少：适当调大 threshold 或 topN。
- 接口超时偏多：适当调小 workers。
- 如果想看“新币”而不是“热币”，请用新币扫描按钮，并把天数控制在 3~30 天之间。

---

## 环境要求

- Flutter SDK 3.38.1+（stable）
- Dart SDK（随 Flutter）
- Android SDK（用于打包/真机调试）
- 可访问 Binance 与 Gradle 依赖站点

主要依赖：
- flutter_local_notifications: ^21.0.0
- http: ^1.2.0

---

## 快速开始

### 1. 安装依赖

```bash
flutter pub get
```

### 2. 桌面运行（Windows 示例）

```bash
flutter run -d windows
```

### 3. Web 运行

```bash
flutter run -d chrome
```

### 4. Android 真机运行

```bash
flutter run
```

---

## Android 打包

### 1. 构建调试包

```bash
flutter build apk --debug
```

产物路径：

```text
build/app/outputs/flutter-apk/app-debug.apk
```

### 2. 构建发布包

```bash
flutter build apk --release
```

发布包需配置签名，参考 Flutter Android 发布文档。

### 3. 已内置的 Android 配置
- Manifest 已声明 POST_NOTIFICATIONS 与 VIBRATE 权限。
- Gradle 已启用 core library desugaring（兼容 flutter_local_notifications v21）。

---

## 通知与权限说明

### Android
- Android 13+ 首次启动会请求通知权限。
- 如果误点拒绝，请到系统设置中手动开启该应用通知。

### Windows
- 应用在前台默认弹窗；切到后台后走系统通知。

### Web
- 浏览器会在首次通知时请求授权。
- 若已拒绝，需要在浏览器站点权限中重新允许。

---

## 常见问题

### 1. 为什么“连续扫描”没有每几秒就触发？
这是预期行为。当前逻辑是按任务 interval 对齐到下一根 K 线收线后再扫，不是固定秒级轮询。

### 2. 为什么看起来会“少通知”？
系统只对“本轮新出现”的匹配币种提醒；同一币种连续命中不会重复提醒。

### 3. 扫描结果为空怎么办？
- 先检查网络是否可访问 Binance。
- 适当增大 threshold。
- 提高 topN 或切换更常见的周期（如 15m/1h）。

### 4. Android 收不到通知怎么办？
- 检查通知权限是否已允许。
- 检查系统是否对该应用做了省电限制或通知拦截。
- 卸载重装后再次授权通知。

### 5. 构建 APK 超时或失败怎么办？
- 检查是否可访问 services.gradle.org、maven.google.com、storage.googleapis.com。
- 网络不稳定时可重试构建，依赖会缓存。

---

## 开发说明

核心文件：
- [lib/main.dart](lib/main.dart)：UI、任务调度、扫描逻辑、通知路由。
- [lib/web_notifications/web_notification_service_web.dart](lib/web_notifications/web_notification_service_web.dart)：Web 通知实现。
- [lib/web_notifications/web_notification_service_stub.dart](lib/web_notifications/web_notification_service_stub.dart)：非 Web 平台占位实现。

核心机制：
- 多任务模型：每个任务都有独立阈值、运行状态、匹配列表与上轮匹配集合。
- 新币种提醒：currentSymbols 与 lastMatchedSymbols 做差集，差集才触发提醒。
- 连续扫描节奏：按 interval 对齐下一根 K 线收线时刻再扫描。
- 新币扫描：复用 Binance 24h ticker 的 `quoteVolume`，按成交额（USDT）降序并截取 `topN`。
- **6 线密度算法**：
  - EMA 计算：首价种子 + 递推（alpha = 2/(span+1)），与 Binance 图表对齐。
  - MA 计算：尾部 span 根 K 线的简单平均。
  - 密度判断：同时考虑 3 条 EMA 与 3 条 MA，找出 6 条线形成的最紧凑区间。
  - 未走完 K 线：实时包含当前形成中的 K 线，可提前捕捉即将收敛信号。
  - K 线充分热身：自动扩展到 1000+ 根以确保 EMA120、MA120 的准确度。

---

## 最近更新日志

### 2026-04-30 (v2.1 移动端 UI 可用性优化)

#### 📱 页面布局优化
- 主界面改为支持**整页上下滑动**，解决手机端控件超出可视区域的问题。
- 参数区、任务区、结果区在小屏设备上可以顺序浏览，不再因屏幕高度不足被截断。

#### 📋 结果面板可视容量提升
- 底部“扫描结果”区域高度已扩大。
- 目标为一次可容纳约 **10 条结果**（具体显示条数会受系统字体与缩放影响）。
- 结果列表依旧支持内部滚动，超过可视数量时可继续下滑查看。

#### ✅ 交互体验改进
- 页面外层滚动与结果列表内层滚动配合，兼顾整体浏览与结果快速查看。
- 移动端操作更稳定，避免“按钮在屏幕外无法点击”的场景。

### 2026-04-29 (v2.0 密度算法重大升级)

#### 🔄 密度算法升级
- **从 3 线 EMA(7/25/99) 升级到 6 线混合**：EMA(20/60/120) + MA(20/60/120)
- 新算法能够捕捉更细微的收敛信号，同时考虑快速 EMA 与稳定 MA 的融合

#### 📊 K 线处理重大改进
- **包含未走完 K 线**：之前自动丢弃最后一根未收线的 K 线；现在实时包含当前形成中的 K 线
  - 好处：可提前 1 ~ 10 秒发现即将出现的收敛信号
  - 适合：高频交易与快速反应场景
- **自动 K 线扩展**：内部自动扩展到 1000 根以上确保指标充分热身
  - 特别是 EMA120 和 MA120 现在计算准确度大幅提升
  - 对齐 Binance 图表所示的指标值

#### 🧪 精度改进
- EMA 首价种子 + 递推法已与 Binance 官方图表对齐
- 调试日志新增：每个扫描币的实际 K 线数量统计与所有 6 条线的值显示
- 解决了之前部分币的 EMA120 计算偏离的问题

#### 📱 UI 更新
- AppBar 标题与应用名改为 "Binance USDT EMA+MA(20/60/120) 扫描器"
- 相应调整了参数界面说明以体现新的 6 线密度算法

---

## 免责声明

本项目仅用于技术研究与策略观察，不构成任何投资建议。数字资产交易存在高风险，请自行评估并承担风险。
