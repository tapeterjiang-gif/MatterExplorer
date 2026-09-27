# DCL 数据本地缓存与设置更新入口

## Context

CSA DCL（分布式合规账本）的厂商表与产品表目前是「构建期用 `Tools/fetch_matter_catalogs.sh` 拉取 → 生成随包 JSON → App 只读加载」。数据一旦打包就无法更新，新增的已认证型号必须等 App 重新发版才能查到。

本次改造目标：把 DCL 的高价值数据（厂商表、产品表、认证表）改为**运行时下载 + 本地缓存**，随包 JSON 退化为初始快照与兜底；并在设置页提供手动更新入口，让用户可以在不发版的前提下刷新这些参考数据。

## 已确认口径

- 缓存范围：三张全量表（厂商表 / 产品表 / 认证表）
- 入口形态：设置页新增独立「DCL 数据」分区 + 二级页
- 本次只做缓存与更新入口，**不新增任何把新数据展示到设备详情页等界面的逻辑**（认证表先缓存备用）
- 仅手动更新，不做启动自动更新

## 实测数据（2026-09-26 实拉）

基址 `https://on.dcl.csa-iot.org/dcl`，TLS 1.3 + Amazon 公共 CA（有效期至 2027-03-30），`URLSession` 可直接访问，无需 ATS 例外。

| 数据集 | 端点 | 条目 | 体积 |
|---|---|---|---|
| 厂商表 | `vendorinfo/vendors` | 858 | 22 KB |
| 产品表 | `model/models` | 5282 | 193 KB |
| 认证表 | `compliance/certified-models` | 5412（55 页） | ~216 KB |

分页约束（沿用既有脚本的结论，必须遵守）：`pagination.limit` 固定 **100**，更大分页会在约 190 KB 处被截断；用响应里 `pagination.next_key` 翻页；`pagination.total` 不可信（恒为 `"0"`）；响应偶发为空，需逐页做 JSON 完整性校验并重试。

## 实现步骤

### 1. 新增 `Sources/Core/DCLCatalogStore.swift`（缓存仓库）

参照 `Sources/Core/OTAImageStore.swift` 的既有范式：`final class ... : @unchecked Sendable` + `static let shared` + `NSLock` + `manifest.json` + `.atomic` 写盘 + 每步写 `LogStore` 日志。

- 目录：`Library/DCLData/`
- 文件：`vendors.json`、`products.json`、`certified-models.json`、`manifest.json`
- `enum DCLTable: String, CaseIterable`（`vendors` / `products` / `certifiedModels`），每表带 `fileName`、`bundleResourceName`、中文 `label`
- `struct TableInfo { entryCount: Int; byteCount: Int; fetchedAt: Date }`、`struct Manifest { bundleVersion: String; updatedAt: Date; tables: [String: TableInfo] }`
- `func data(for:) -> Data?`：缓存有效则返回缓存，否则回落 `Bundle.main` 的随包 JSON
- `func snapshot() -> Snapshot`：供设置页展示（更新时间、来源、各表条目数与字节数）
- `func replace(table:count:data:)` / `func restoreBundled()` / `func beginUpdate() -> Bool` / `func endUpdate()`
- `static let didChangeNotification`（沿用 `DeviceRegistry.didChangeNotification` 的既有模式）
- **缓存有效性判定**：manifest 可解码 且 `bundleVersion == 当前 CFBundleVersion` 且对应表文件存在且 `entryCount > 0`。App 升级后 `CFBundleVersion` 变化 → 缓存视为过期，自动回落随包数据（磁盘文件保留，设置页标注「已过期（随包数据生效）」），避免旧缓存盖住新版本内置的快照。

### 2. 新增 `Sources/Core/DCLClient.swift`（下载）

- 三张表各自分页拉取，**表之间与页之间均串行**（分页必须串行；刻意不做并发，避免触发服务端限流与截断）
- 逐页 `URLSession.shared.data(for:)`，请求超时 30 秒；每页解码校验顶层键（`vendorInfo` / `model` / `certifiedModel`）视为完整性校验；失败最多重试 5 次；页间 `try Task.checkCancellation()`
- 产出与随包 JSON **同构**的 `Data`，让两个 Catalog 的解码逻辑零改动：
  - 厂商表：`{"<vendorID>": "<vendorName>"}`（键升序）
  - 产品表：`[[vid, pid, 名称, deviceTypeId], ...]`（按 (vid,pid) 升序；名称缺失时回落 `productLabel`）
  - 认证表：`[[vid, pid, softwareVersion, certificationType, value], ...]`（升序）
- 进度回调：`(表, 已完成页数)`；不显示百分比（`pagination.total` 不可信）

### 3. 新增 `Sources/Core/MatterCertifiedModelCatalog.swift`（认证表查询）

本次不展示，但结构要便于以后使用：`Entry { certificationType: String; value: UInt32 }`，主键 `(vendorID, productID, softwareVersion)`，提供 `entry(vendorID:productID:softwareVersion:)` 与 `reload()`。懒加载，设置页只读 manifest 的条目数，不触发解码，避免 5412 条常驻内存。

### 4. 改造两个既有 Catalog（对外 API 不变）

`MatterVendorCatalog`（`name(for:)`）与 `MatterProductCatalog`（`entry(vendorID:productID:)`）内部改为从 `DCLCatalogStore.shared.data(for:)` 取数据，随包回落由 store 统一负责。

- 把原来的一次性 `static let table` 改为「持锁的懒加载 holder + `reload()`」，以规避 Swift 6 全局可变状态限制
- **不改调用点**：`Sources/Core/DeviceRegistry.swift`（`displayName` / `catalogIdentityText`）与 `Sources/Core/DeviceService.swift`（`vendorName` / `catalogEntry` / `productName` / `deviceTypeID`）签名与行为保持完全一致
- 重载只有一个触发点：`DCLCatalogStore` 提交或恢复完成后调用各 Catalog 的 `reload()`，然后 post `didChangeNotification`

### 5. 设置页与二级页

- `Sources/Features/Settings/SettingsViewModel.swift` 扩展：`dclSnapshot`、`isDCLUpdating`、`dclProgress`、`dclNotice`、`dclErrorMessage`、`dclSummaryText`，以及 `startDCLUpdate()` / `cancelDCLUpdate()` / `restoreBundledDCL()`；`refresh()` 里补 `dclSnapshot` 重取
- `Sources/Features/Settings/SettingsView.swift` 新增 `dclSection`，插在 `logSection` 之后、`developerSection` 之前：
  - 理由：DCL 更新是普通用户偶发使用的「内容数据」操作，应排在「开发者选项」这一调试区之前；同时远离 `resetSection` 这个破坏性分区，避免误触
  - 行内容复用既有范式：`NavigationLink { DCLDataView(viewModel: viewModel) } label: { LabeledContent("DCL 数据", value: viewModel.dclSummaryText) }`
- 新增 `Sources/Features/Settings/DCLDataView.swift`（仿 `PAAManagementView`）：
  - 「状态」：上次更新时间、数据来源（已下载缓存 / 随包快照 / 缓存已过期）、三行 `LabeledContent("厂商表", value: "858 条 · 21.7 KB")`
  - 「操作」：更新中显示不定进度 `ProgressView` + 「正在拉取认证表，已完成 12 页（第 3/3 张表）」；按钮在更新中变为「取消更新」；「恢复为随包数据」为 destructive + 二次确认
  - 「存储」：缓存目录路径（等宽、可选中）、当前随包 `CFBundleVersion`
- `Sources/Features/Devices/DevicesViewModel.swift`：`init()` 里追加监听 `DCLCatalogStore.didChangeNotification` → `reload()`，让设备列表的标题/身份文案在数据更新后立即刷新（唯一需要联动的既有界面）

### 6. 随包快照补齐认证表

`Tools/fetch_matter_catalogs.sh` 增加第三段：拉取 `compliance/certified-models`，生成 `Sources/Resources/matter-certified-models.json`。产物入库后执行 `xcodegen generate`。

### 7. 错误处理与边界

- **按表原子**：逐表下载，成功即写入该表并更新 manifest 中该表的 `fetchedAt`；失败的表保留原数据不动，界面分别报告「厂商表 成功 / 认证表 失败：认证表第 12 页连续 5 次校验失败」
- 下载中禁止重复触发（`beginUpdate()` 互斥）；`endUpdate()` 放 `defer`
- 显式「取消更新」：`task.cancel()`，提示「已取消，本次未改动的表保持原数据」
- 防御性下限：厂商表 < 100 条、产品表 < 1000 条视为异常，拒绝提交该表（防止静默截断把好数据覆盖掉）
- 「恢复为随包数据」：删除三个 json 与 manifest → 各 Catalog `reload()` → 发通知

## 验证方案

模拟器 UDID `0C5A1561-8241-4FB1-9CEB-2A260A0F9C1D`（iPhone 18 Pro）。全程**不得执行 `xcrun simctl uninstall`**。

1. `bash Tools/fetch_matter_catalogs.sh` 生成认证表随包快照 → `xcodegen generate` → `xcodebuild -project MatterExplorer.xcodeproj -scheme MatterExplorer -destination 'platform=iOS Simulator,id=0C5A1561-8241-4FB1-9CEB-2A260A0F9C1D' -derivedDataPath build build`
2. 安装启动，确认默认（未更新）状态下设置页「DCL 数据」行显示「随包数据 · 858 / 5282 / 5412 条」
3. 临时改动验证二级页（simctl 不能点击，**验证后必须还原并重新构建**）：
   - 临时把默认 Tab 由 `.devices` 改为 `.settings`，并临时在 `SettingsView` 的 `.task` 里调用 `viewModel.startDCLUpdate()`
   - `xcrun simctl io <UDID> screenshot /tmp/dcl.png` 读图确认进度文案与最终结果
4. 磁盘校验：`xcrun simctl get_app_container <UDID> com.example.MatterExplorer data` → `ls -l <容器>/Library/DCLData/`，用 `python3 -m json.tool` 核对 manifest 的 `entryCount` 为 858 / 5282 / 5412、`byteCount` 与实际文件一致、`bundleVersion` 等于 Info.plist 的 `CFBundleVersion`；再核对 `products.json` 行数与首行格式 `[vid,pid,name,deviceType]`
5. 界面校验更新生效：设置页「DCL 数据」行摘要应变为「已下载缓存 · …」并显示更新时间
6. 异常路径：临时把基址改为不可达 host → 触发更新 → 应报错且磁盘上的 manifest `updatedAt` 不变（旧数据保留）
7. 还原所有临时代码后重新构建安装，`git diff` 确认只剩功能改动

## 不做的事

- 不新建仓库内规划/说明文档（本文件位于 `.trae/documents/`，仅为方案审批用）
- 不改设备详情页、扫描列表的任何展示逻辑（认证表本次不接入界面）
- 不做启动自动更新、不做后台刷新
- 不重构 `MatterVendorCatalog` / `MatterProductCatalog` 的调用点