import Foundation

/// CSA DCL 下载客户端：分页拉取三张全量表，产出与随包 JSON 同构的 Data。
///
/// 分页约束（沿用 `Tools/fetch_matter_catalogs.sh` 的实测结论）：
/// - `pagination.limit` 固定 100，更大分页会在约 190 KB 处被截断；
/// - 用响应里 `pagination.next_key` 翻页；`pagination.total` 不可信（恒为 "0"）；
/// - 响应偶发为空，需逐页做完整性校验并重试。
///
/// 表之间与页之间均串行：刻意不做并发，避免触发服务端限流与截断。
enum DCLClient {
    /// DCL 公开只读接口基址。
    static let baseURL = URL(string: "https://on.dcl.csa-iot.org/dcl")!

    /// 单页请求的分页大小（不可调大）。
    private static let pageLimit = 100

    /// 单页请求超时。
    private static let requestTimeout: TimeInterval = 30

    /// 单页连续失败的重试次数。
    private static let maxRetries = 5

    /// 重试前的等待时长（逐次退避）。在下面那个分页节奏下，偶发的连接拒绝约 1 秒即可恢复，
    /// 故退避保持很短；真正会长时间拒绝服务的是高频连发（见 `interPageDelay`）。
    private static let retryDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8)]

    /// 分页之间的间隔：基础 5 秒，再按响应体大小追加（每 30 KB 加 1 秒）。
    ///
    /// DCL 对请求频率非常敏感：实测每秒数次的节奏会在连发约 30–40 次后开始拒绝连接
    /// （表现为 TLS 握手失败 `SSL_ERROR_SYSCALL`，且拒绝状态持续数分钟）。
    /// 构建期脚本 `Tools/fetch_matter_catalogs.sh` 以约 6–7 秒/次的节奏跑完 143 页无碍，
    /// 这里对齐到同一量级。产品表单页约 90 KB（厂商表 / 认证表仅 2–4 KB），故按体积追加间隔。
    private static func interPageDelay(byteCount: Int) -> Duration {
        .seconds(5) + .seconds(byteCount / 30_000)
    }

    /// 防死循环的分页上限。
    private static let maxPages = 500

    enum ClientError: LocalizedError {
        case invalidURL
        case pageFailed(DCLTable, Int, Int)
        case malformedResponse(DCLTable, Int)

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                "请求地址无效"
            case let .pageFailed(table, page, attempts):
                "\(table.label)第 \(page) 页连续 \(attempts) 次请求失败"
            case let .malformedResponse(table, page):
                "\(table.label)第 \(page) 页响应缺少预期字段"
            }
        }
    }

    /// 单表下载结果（同构 JSON + 条目数）。
    struct Outcome: Sendable {
        var table: DCLTable
        var count: Int
        var data: Data
    }

    /// 拉取一张表并返回同构 JSON。
    /// - Parameter progress: 每完成一页回调一次（已完成页数）。
    static func fetch(
        table: DCLTable,
        progress: @Sendable (Int) async -> Void
    ) async throws -> Outcome {
        var pages: [Page] = []
        var key = ""
        var page = 0

        while page < maxPages {
            try Task.checkCancellation()
            page += 1
            let items = try await fetchPage(table: table, key: key, page: page)
            pages.append(items)
            await progress(page)
            guard let next = items.nextKey, !next.isEmpty else { break }
            key = next
            try await Task.sleep(for: interPageDelay(byteCount: items.byteCount))
        }

        let encoded = try encode(pages: pages, for: table)
        return Outcome(table: table, count: encoded.count, data: encoded.data)
    }

    // MARK: - 单页

    private struct Page {
        /// 顶层数组的原始 JSON 对象（逐表结构不同）。
        var items: [Any]
        var nextKey: String?
        /// 响应体字节数（用于按体积调整分页间隔）。
        var byteCount: Int
    }

    private static func fetchPage(table: DCLTable, key: String, page: Int) async throws -> Page {
        var lastError: Error = ClientError.malformedResponse(table, page)
        for attempt in 1...maxRetries {
            try Task.checkCancellation()
            do {
                let response = try await request(table: table, key: key, page: page)
                if let parsed = parse(response.object, byteCount: response.byteCount, for: table) { return parsed }
                lastError = ClientError.malformedResponse(table, page)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
            if attempt < maxRetries {
                try await Task.sleep(for: retryDelays[min(attempt - 1, retryDelays.count - 1)])
            }
        }
        if let clientError = lastError as? ClientError { throw clientError }
        throw ClientError.pageFailed(table, page, maxRetries)
    }

    /// 发一次请求并解码为 JSON 对象。
    private static func request(
        table: DCLTable, key: String, page: Int
    ) async throws -> (object: [String: Any], byteCount: Int) {
        guard let url = pageURL(table: table, key: key) else { throw ClientError.invalidURL }

        var request = URLRequest(url: url)
        request.timeoutInterval = requestTimeout
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClientError.malformedResponse(table, page)
        }
        return (object, data.count)
    }

    /// 分页请求 URL。
    ///
    /// `next_key` 是 protobuf 的 base64 编码，可能含 `+`（如产品表第 31 页的 `AAAUAC8AAAP+Lw==`）。
    /// `URLQueryItem` 不会转义 `+`，而服务端会把未转义的 `+` 当空格解析，导致该 key 无效、
    /// 请求被拒——表现为从那一页起分页永远失败（实测产品表恒定卡在第 32 页）。
    /// 故这里显式做 RFC 3986 的 unreserved 转义（`+` → `%2B`）。
    private static func pageURL(table: DCLTable, key: String) -> URL? {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent(table.endpointPath),
            resolvingAgainstBaseURL: false
        ) else { return nil }
        components.percentEncodedQueryItems = [
            URLQueryItem(name: "pagination.limit", value: "\(pageLimit)"),
            URLQueryItem(name: "pagination.key", value: percentEncoded(key)),
        ]
        return components.url
    }

    /// RFC 3986 unreserved（`A-Z a-z 0-9 - . _ ~`）之外全部百分号编码。
    private static func percentEncoded(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func parse(_ object: [String: Any], byteCount: Int, for table: DCLTable) -> Page? {
        guard let items = object[table.responseKey] as? [Any] else { return nil }
        let nextKey = (object["pagination"] as? [String: Any])?["next_key"] as? String
        return Page(items: items, nextKey: nextKey, byteCount: byteCount)
    }

    // MARK: - 编码（与随包 JSON 同构）

    private static func encode(pages: [Page], for table: DCLTable) throws -> (data: Data, count: Int) {
        switch table {
        case .vendors:
            var rows: [String: String] = [:]
            for page in pages {
                for item in page.items {
                    guard let vendor = item as? [String: Any],
                          let vid = vendor["vendorID"] as? Int,
                          let name = (vendor["vendorName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !name.isEmpty
                    else { continue }
                    rows["\(vid)"] = name
                }
            }
            let data = try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys])
            return (data, rows.count)

        case .products:
            var rows: [ProductKey: [Any]] = [:]
            for page in pages {
                for item in page.items {
                    guard let model = item as? [String: Any],
                          let vid = model["vid"] as? Int,
                          let pid = model["pid"] as? Int
                    else { continue }
                    let name = ((model["productName"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let label = ((model["productLabel"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let resolved = name.isEmpty ? label : name
                    guard !resolved.isEmpty else { continue }
                    let deviceType = model["deviceTypeId"] as? Int ?? 0
                    rows[ProductKey(vendorID: vid, productID: pid)] = [vid, pid, resolved, deviceType]
                }
            }
            let data = try JSONSerialization.data(withJSONObject: rows.keys.sorted().map { rows[$0]! })
            return (data, rows.count)

        case .certifiedModels:
            var rows: [CertifiedKey: [Any]] = [:]
            for page in pages {
                for item in page.items {
                    guard let model = item as? [String: Any],
                          let vid = model["vid"] as? Int,
                          let pid = model["pid"] as? Int,
                          let version = model["softwareVersion"] as? Int
                    else { continue }
                    let type = (model["certificationType"] as? String) ?? ""
                    let value = model["value"] as? Int ?? 0
                    rows[CertifiedKey(vendorID: vid, productID: pid, softwareVersion: version)] = [vid, pid, version, type, value]
                }
            }
            let data = try JSONSerialization.data(withJSONObject: rows.keys.sorted().map { rows[$0]! })
            return (data, rows.count)
        }
    }

    private struct ProductKey: Hashable, Comparable {
        let vendorID: Int
        let productID: Int

        static func < (lhs: Self, rhs: Self) -> Bool {
            (lhs.vendorID, lhs.productID) < (rhs.vendorID, rhs.productID)
        }
    }

    private struct CertifiedKey: Hashable, Comparable {
        let vendorID: Int
        let productID: Int
        let softwareVersion: Int

        static func < (lhs: Self, rhs: Self) -> Bool {
            (lhs.vendorID, lhs.productID, lhs.softwareVersion) < (rhs.vendorID, rhs.productID, rhs.softwareVersion)
        }
    }
}

private extension DCLTable {
    /// 分页接口路径。
    var endpointPath: String {
        switch self {
        case .vendors: "vendorinfo/vendors"
        case .products: "model/models"
        case .certifiedModels: "compliance/certified-models"
        }
    }

    /// 响应里承载数据的顶层键。
    var responseKey: String {
        switch self {
        case .vendors: "vendorInfo"
        case .products: "model"
        case .certifiedModels: "certifiedModel"
        }
    }
}