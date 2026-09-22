import Foundation
import OboeDomain

struct AIHTTPResponse: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let body: Data
}

protocol AIHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> AIHTTPResponse
}

/// 执行类 AI 请求共享的 HTTP 语义：超时、响应上限、状态码与 URLError 映射。
/// 连接测试/制卡/句析/修卡四个入口的错误分类必须完全一致。
enum AIHTTPSupport {
    /// 执行类请求统一超时（URLRequest 与 URLSession 双侧生效）。
    static let executionTimeout: TimeInterval = 60
    static let defaultMaximumResponseBytes = 256 * 1_024

    static func validateStatus(_ response: AIHTTPResponse) throws {
        switch response.statusCode {
        case 200..<300:
            return
        case 400, 404, 422:
            throw AIConnectionError.unsupportedConfiguration(statusCode: response.statusCode)
        case 401, 403:
            throw AIConnectionError.authenticationFailed
        case 402:
            throw AIConnectionError.insufficientBalance
        case 408:
            throw AIConnectionError.timedOut
        case 429:
            throw AIConnectionError.rateLimited(
                retryAfterSeconds: retryAfterSeconds(in: response.headers)
            )
        case 500...599:
            throw AIConnectionError.serviceUnavailable(statusCode: response.statusCode)
        default:
            throw AIConnectionError.unexpectedStatus(statusCode: response.statusCode)
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

    static func map(_ error: URLError) -> AIConnectionError {
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
}

final class URLSessionAIHTTPTransport: AIHTTPTransport, @unchecked Sendable {
    private let session: URLSession

    init(timeout: TimeInterval) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        session = URLSession(configuration: configuration)
    }

    deinit {
        session.invalidateAndCancel()
    }

    func send(_ request: URLRequest) async throws -> AIHTTPResponse {
        let redirectDelegate = SameOriginRedirectDelegate(originalRequest: request)
        let (body, response) = try await session.data(for: request, delegate: redirectDelegate)
        if redirectDelegate.rejectedCrossOriginRedirect {
            throw AIConnectionError.redirectRejected
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIConnectionError.malformedResponse
        }
        let headers = httpResponse.allHeaderFields.reduce(into: [String: String]()) { result, item in
            guard let key = item.key as? String else { return }
            result[key] = String(describing: item.value)
        }
        return AIHTTPResponse(
            statusCode: httpResponse.statusCode,
            headers: headers,
            body: body
        )
    }
}

final class SameOriginRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let originalRequest: URLRequest
    private let lock = NSLock()
    private var didRejectCrossOriginRedirect = false

    init(originalRequest: URLRequest) {
        self.originalRequest = originalRequest
    }

    var rejectedCrossOriginRedirect: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didRejectCrossOriginRedirect
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let redirected = Self.redirectedRequest(
            originalRequest: originalRequest,
            proposedRequest: request
        )
        if redirected == nil {
            lock.lock()
            didRejectCrossOriginRedirect = true
            lock.unlock()
        }
        completionHandler(redirected)
    }

    /// 只放行同源 HTTPS 重定向，并把原请求的凭据/协议头带回
    /// （`Authorization` 以及 Anthropic 的 `x-api-key`/`anthropic-version`）。
    static func redirectedRequest(
        originalRequest: URLRequest,
        proposedRequest: URLRequest
    ) -> URLRequest? {
        guard let originalURL = originalRequest.url,
              let proposedURL = proposedRequest.url,
              origin(of: originalURL) == origin(of: proposedURL) else {
            return nil
        }
        var redirected = proposedRequest
        for header in ["Authorization", "x-api-key", "anthropic-version"] {
            redirected.setValue(
                originalRequest.value(forHTTPHeaderField: header),
                forHTTPHeaderField: header
            )
        }
        return redirected
    }

    private static func origin(of url: URL) -> String? {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(), !host.isEmpty else {
            return nil
        }
        let port = url.port ?? 443
        return "https://\(host):\(port)"
    }
}
