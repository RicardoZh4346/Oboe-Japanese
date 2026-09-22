import Foundation
import OboeDomain

/// 通过供应商原生「列出模型」接口获取可选模型。复用与连接测试相同的
/// 安全 transport（HTTPS、同源重定向、无缓存无 Cookie），但使用独立的
/// 超时与响应上限。结果只存在于内存，绝不写入数据库或备份。
public struct HTTPAIModelCatalogClient: AIModelCatalogClient, Sendable {
    static let timeout: TimeInterval = 20
    static let maximumResponseBytes = 512 * 1_024
    static let maximumPageCount = 20

    private let transport: any AIHTTPTransport

    public init() {
        transport = URLSessionAIHTTPTransport(timeout: Self.timeout)
    }

    init(transport: any AIHTTPTransport) {
        self.transport = transport
    }

    public func fetchModels(
        configuration: AIConfiguration,
        credential: String
    ) async throws -> [AIModelDescriptor] {
        guard !credential.isEmpty,
              credential.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }) else {
            throw AIModelCatalogError.invalidCredential
        }
        let endpoint = try Self.catalogEndpoint(for: configuration)

        var seenIDs = Set<String>()
        var seenCursors = Set<String>()
        var descriptors: [AIModelDescriptor] = []
        var queryItems = endpoint.initialQueryItems

        for _ in 0..<Self.maximumPageCount {
            let url = try Self.url(endpoint.url, adding: queryItems)
            let request = Self.makeRequest(url: url, credential: credential, endpoint: endpoint)
            let response = try await send(request)
            try Self.validateStatus(response)
            guard response.body.count <= Self.maximumResponseBytes else {
                throw AIModelCatalogError.responseTooLarge
            }
            let page = try AIModelListPageDecoder.decode(
                response.body,
                protocolKind: endpoint.protocolKind
            )
            for raw in page.models
            where Self.isTextGenerationCapable(raw, protocolKind: endpoint.protocolKind) {
                if seenIDs.insert(raw.id).inserted {
                    descriptors.append(
                        AIModelDescriptor(id: raw.id, displayName: raw.displayName)
                    )
                }
            }
            guard let cursor = page.nextCursor, !cursor.isEmpty,
                  let name = page.cursorQueryItemName,
                  seenCursors.insert(cursor).inserted else {
                break
            }
            queryItems = endpoint.initialQueryItems + [URLQueryItem(name: name, value: cursor)]
        }

        let sorted = descriptors.sorted()
        guard !sorted.isEmpty else { throw AIModelCatalogError.emptyModelList }
        return sorted
    }

    // MARK: - Endpoint & request

    struct AIModelCatalogEndpoint: Sendable {
        let url: URL
        let protocolKind: AIProtocolKind
        let apiKeyHeaderStyle: AIAPIKeyHeaderStyle
        let initialQueryItems: [URLQueryItem]
    }

    static func catalogEndpoint(
        for configuration: AIConfiguration
    ) throws -> AIModelCatalogEndpoint {
        let baseURL: URL
        let listPath: String
        let protocolKind: AIProtocolKind
        let headerStyle: AIAPIKeyHeaderStyle
        if let preset = AIProviderPresetRegistry.preset(for: configuration.serviceKind) {
            guard let presetURL = URL(string: preset.baseURL) else {
                throw AIModelCatalogError.malformedResponse
            }
            baseURL = presetURL
            listPath = preset.modelListPath
            protocolKind = preset.protocolKind
            headerStyle = preset.apiKeyHeaderStyle
        } else {
            // 自定义服务：按 OpenAI 兼容约定在用户 baseURL 后拼 /models。
            baseURL = configuration.baseURL
            listPath = "models"
            protocolKind = .openAICompatible
            headerStyle = .bearer
        }
        let url = try endpointURL(baseURL: baseURL, listPath: listPath)
        let initialQueryItems: [URLQueryItem]
        switch protocolKind {
        case .anthropic:
            initialQueryItems = [URLQueryItem(name: "limit", value: "100")]
        case .gemini:
            initialQueryItems = [URLQueryItem(name: "pageSize", value: "100")]
        case .openAICompatible, .dashScope, .xAI:
            initialQueryItems = []
        }
        return AIModelCatalogEndpoint(
            url: url,
            protocolKind: protocolKind,
            apiKeyHeaderStyle: headerStyle,
            initialQueryItems: initialQueryItems
        )
    }

    /// 把列表路径拼到 baseURL 之后；路径已以该路径结尾时不重复拼接
    /// （自定义服务允许用户直接粘贴 …/models 地址）。
    static func endpointURL(baseURL: URL, listPath: String) throws -> URL {
        let trimmed = listPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return baseURL }
        if baseURL.path.lowercased().hasSuffix("/\(trimmed.lowercased())") {
            return baseURL
        }
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw AIModelCatalogError.malformedResponse
        }
        let basePath = components.path.hasSuffix("/")
            ? String(components.path.dropLast())
            : components.path
        components.path = basePath + "/" + trimmed
        guard let url = components.url else {
            throw AIModelCatalogError.malformedResponse
        }
        return url
    }

    static func url(_ base: URL, adding items: [URLQueryItem]) throws -> URL {
        guard !items.isEmpty else { return base }
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw AIModelCatalogError.malformedResponse
        }
        components.queryItems = (components.queryItems ?? []) + items
        guard let url = components.url else {
            throw AIModelCatalogError.malformedResponse
        }
        return url
    }

    static func makeRequest(
        url: URL,
        credential: String,
        endpoint: AIModelCatalogEndpoint
    ) -> URLRequest {
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: timeout
        )
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        switch endpoint.apiKeyHeaderStyle {
        case .bearer:
            request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        case .xAPIKey:
            request.setValue(credential, forHTTPHeaderField: "x-api-key")
        case .xGoogAPIKey:
            request.setValue(credential, forHTTPHeaderField: "x-goog-api-key")
        }
        if endpoint.protocolKind == .anthropic {
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        return request
    }

    private func send(_ request: URLRequest) async throws -> AIHTTPResponse {
        do {
            try Task.checkCancellation()
            let response = try await transport.send(request)
            try Task.checkCancellation()
            return response
        } catch is CancellationError {
            throw AIModelCatalogError.cancelled
        } catch let error as AIModelCatalogError {
            throw error
        } catch let error as AIConnectionError {
            // transport 层错误（同源重定向拒绝、非 HTTP 响应等）。
            switch error {
            case .redirectRejected:
                throw AIModelCatalogError.redirectRejected
            case .malformedResponse:
                throw AIModelCatalogError.malformedResponse
            default:
                throw AIModelCatalogError.connectionFailed
            }
        } catch let error as URLError {
            throw Self.map(error)
        } catch {
            throw AIModelCatalogError.connectionFailed
        }
    }

    // MARK: - Status & transport error mapping

    static func validateStatus(_ response: AIHTTPResponse) throws {
        switch response.statusCode {
        case 200..<300:
            return
        case 400, 404, 422:
            throw AIModelCatalogError.unsupportedConfiguration(statusCode: response.statusCode)
        case 401, 403:
            throw AIModelCatalogError.authenticationFailed
        case 402:
            throw AIModelCatalogError.insufficientBalance
        case 408:
            throw AIModelCatalogError.timedOut
        case 429:
            throw AIModelCatalogError.rateLimited(
                retryAfterSeconds: retryAfterSeconds(in: response.headers)
            )
        case 500...599:
            throw AIModelCatalogError.serviceUnavailable(statusCode: response.statusCode)
        default:
            throw AIModelCatalogError.unexpectedStatus(statusCode: response.statusCode)
        }
    }

    private static func retryAfterSeconds(in headers: [String: String]) -> Int? {
        guard let value = headers.first(where: {
            $0.key.caseInsensitiveCompare("Retry-After") == .orderedSame
        })?.value.trimmingCharacters(in: .whitespacesAndNewlines),
        let seconds = Int(value), seconds >= 0 else {
            return nil
        }
        return min(seconds, 86_400)
    }

    static func map(_ error: URLError) -> AIModelCatalogError {
        switch error.code {
        case .cancelled:
            .cancelled
        case .timedOut:
            .timedOut
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
            .networkUnavailable
        case .secureConnectionFailed, .serverCertificateHasBadDate,
             .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid, .clientCertificateRejected,
             .clientCertificateRequired:
            .secureConnectionFailed
        default:
            .connectionFailed
        }
    }

    // MARK: - Capability filter

    /// 文本生成能力过滤：声明了能力字段的按其声明判断，再套用
    /// 「显然不是文本生成模型」的 ID 黑名单（embedding/图像/语音等）。
    static func isTextGenerationCapable(
        _ model: AIRawModelEntry,
        protocolKind: AIProtocolKind
    ) -> Bool {
        if let methods = model.generationMethods,
           !methods.contains(where: {
               $0.caseInsensitiveCompare("generateContent") == .orderedSame
           }) {
            return false
        }
        if let modalities = model.outputModalities, !modalities.isEmpty,
           !modalities.contains(where: {
               $0.caseInsensitiveCompare("text") == .orderedSame
           }) {
            return false
        }
        let lowered = model.id.lowercased()
        return !Self.nonTextGenerationMarkers.contains(where: { lowered.contains($0) })
    }

    static let nonTextGenerationMarkers: [String] = [
        "embed", "moderation", "tts", "whisper", "transcribe",
        "dall-e", "image", "imagen", "audio", "realtime", "video",
        "sambert", "cosyvoice", "paraformer", "gummy", "wav2lip",
        "wanx", "rerank", "computer-use", "aqa"
    ]
}

// MARK: - Page decoding

/// 单个模型条目的原始字段（decoder 产出，能力过滤前）。
struct AIRawModelEntry: Sendable {
    var id: String
    var displayName: String?
    var outputModalities: [String]?
    var generationMethods: [String]?
}

/// 一页解码结果：`nextCursor` 非空表示还有下一页，
/// `cursorQueryItemName` 是翻页时使用的查询参数名。
struct AIModelListPage: Sendable {
    var models: [AIRawModelEntry]
    var nextCursor: String?
    var cursorQueryItemName: String?

    init(models: [AIRawModelEntry], nextCursor: String? = nil, cursorQueryItemName: String? = nil) {
        self.models = models
        self.nextCursor = nextCursor
        self.cursorQueryItemName = cursorQueryItemName
    }
}

/// 按协议族解析模型列表响应。顶层不是 JSON 对象或缺少预期集合时
/// 抛出 `malformedResponse`；缺字段的单条记录跳过而非整页作废。
enum AIModelListPageDecoder {
    static func decode(_ body: Data, protocolKind: AIProtocolKind) throws -> AIModelListPage {
        guard let object = try? JSONSerialization.jsonObject(with: body),
              let dict = object as? [String: Any] else {
            throw AIModelCatalogError.malformedResponse
        }
        switch protocolKind {
        case .openAICompatible: return try decodeOpenAICompatible(dict)
        case .anthropic: return try decodeAnthropic(dict)
        case .gemini: return try decodeGemini(dict)
        case .dashScope: return try decodeDashScope(dict)
        case .xAI: return try decodeXAI(dict)
        }
    }

    /// OpenAI 兼容：{"data": [{"id": "..."}]}；容忍 has_more/last_id 分页。
    private static func decodeOpenAICompatible(_ dict: [String: Any]) throws -> AIModelListPage {
        guard let data = dict["data"] as? [[String: Any]] else {
            throw AIModelCatalogError.malformedResponse
        }
        let models = data.compactMap { item -> AIRawModelEntry? in
            guard let id = item["id"] as? String, !id.isEmpty else { return nil }
            return AIRawModelEntry(
                id: id,
                displayName: (item["display_name"] as? String) ?? (item["displayName"] as? String)
            )
        }
        var page = AIModelListPage(models: models)
        if (dict["has_more"] as? Bool) == true,
           let lastID = dict["last_id"] as? String, !lastID.isEmpty {
            page.nextCursor = lastID
            page.cursorQueryItemName = "after_id"
        }
        return page
    }

    /// Anthropic：{"data": [{"id": "...", "display_name": "..."}],
    ///  "has_more": bool, "last_id": "..."}，翻页参数 after_id。
    private static func decodeAnthropic(_ dict: [String: Any]) throws -> AIModelListPage {
        guard let data = dict["data"] as? [[String: Any]] else {
            throw AIModelCatalogError.malformedResponse
        }
        let models = data.compactMap { item -> AIRawModelEntry? in
            guard let id = item["id"] as? String, !id.isEmpty else { return nil }
            return AIRawModelEntry(
                id: id,
                displayName: item["display_name"] as? String
            )
        }
        var page = AIModelListPage(models: models)
        if (dict["has_more"] as? Bool) == true,
           let lastID = dict["last_id"] as? String, !lastID.isEmpty {
            page.nextCursor = lastID
            page.cursorQueryItemName = "after_id"
        }
        return page
    }

    /// Gemini 原生：{"models": [{"name": "models/x",
    ///  "supportedGenerationMethods": ["generateContent"]}],
    ///  "nextPageToken": "..."}。
    private static func decodeGemini(_ dict: [String: Any]) throws -> AIModelListPage {
        guard let models = dict["models"] as? [[String: Any]] else {
            throw AIModelCatalogError.malformedResponse
        }
        let entries = models.compactMap { item -> AIRawModelEntry? in
            guard let name = item["name"] as? String, !name.isEmpty else { return nil }
            let id = name.hasPrefix("models/") ? String(name.dropFirst("models/".count)) : name
            return AIRawModelEntry(
                id: id,
                displayName: item["displayName"] as? String,
                generationMethods: item["supportedGenerationMethods"] as? [String]
            )
        }
        var page = AIModelListPage(models: entries)
        if let token = dict["nextPageToken"] as? String, !token.isEmpty {
            page.nextCursor = token
            page.cursorQueryItemName = "pageToken"
        }
        return page
    }

    /// DashScope 原生：{"data": {"models": [{"model": "..."}]}}。
    /// 对包裹层级与字段名做宽容解析（data.models / models / data[]，
    /// model / model_id / id / name）。
    private static func decodeDashScope(_ dict: [String: Any]) throws -> AIModelListPage {
        let list: [[String: Any]]?
        var nextCursor: String?
        if let data = dict["data"] as? [String: Any] {
            list = (data["models"] as? [[String: Any]]) ?? (data["data"] as? [[String: Any]])
            nextCursor = (data["next_token"] as? String)
                ?? (data["nextToken"] as? String)
                ?? (data["next_page_token"] as? String)
        } else {
            list = (dict["models"] as? [[String: Any]]) ?? (dict["data"] as? [[String: Any]])
            nextCursor = (dict["next_token"] as? String) ?? (dict["nextToken"] as? String)
        }
        guard let list else { throw AIModelCatalogError.malformedResponse }
        let entries = list.compactMap { item -> AIRawModelEntry? in
            let id = (item["model"] as? String)
                ?? (item["model_id"] as? String)
                ?? (item["id"] as? String)
                ?? (item["name"] as? String)
            guard let id, !id.isEmpty else { return nil }
            return AIRawModelEntry(id: id, displayName: item["display_name"] as? String)
        }
        var page = AIModelListPage(models: entries)
        if let nextCursor, !nextCursor.isEmpty {
            page.nextCursor = nextCursor
            page.cursorQueryItemName = "next_token"
        }
        return page
    }

    /// xAI 原生：{"models": [{"id": "...", "output_modalities": ["text"]}]}；
    /// 返回中混有图像/embedding 等非文本模型，由能力过滤剔除。
    private static func decodeXAI(_ dict: [String: Any]) throws -> AIModelListPage {
        guard let list = (dict["models"] as? [[String: Any]])
            ?? (dict["data"] as? [[String: Any]]) else {
            throw AIModelCatalogError.malformedResponse
        }
        let entries = list.compactMap { item -> AIRawModelEntry? in
            let id = (item["id"] as? String) ?? (item["name"] as? String)
            guard let id, !id.isEmpty else { return nil }
            let modalities = (item["output_modalities"] as? [String])
                ?? (item["outputModalities"] as? [String])
            return AIRawModelEntry(
                id: id,
                displayName: item["display_name"] as? String,
                outputModalities: modalities
            )
        }
        return AIModelListPage(models: entries)
    }
}

// MARK: - UI test client

/// UI 测试用 client：返回稳定的虚拟模型列表，不发起网络请求。
/// 通过 `AIModelCatalogClient` 注入，界面据此走真实的列表选择流程。
public struct UITestAIModelCatalogClient: AIModelCatalogClient, Sendable {
    public init() {}

    public func fetchModels(
        configuration: AIConfiguration,
        credential: String
    ) async throws -> [AIModelDescriptor] {
        let prefix = "uitest-\(configuration.serviceKind.rawValue)"
        return [
            AIModelDescriptor(id: "\(prefix)-model-a", displayName: "UITest Model A"),
            AIModelDescriptor(id: "\(prefix)-model-b", displayName: "UITest Model B")
        ]
    }
}
