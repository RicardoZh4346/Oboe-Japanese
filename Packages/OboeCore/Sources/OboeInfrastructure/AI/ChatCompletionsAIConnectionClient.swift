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

public struct ChatCompletionsAIConnectionClient: AIConnectionClient, Sendable {
    static let timeout: TimeInterval = 60
    static let maximumResponseBytes = 256 * 1_024
    static let connectionTestMaximumOutputTokens = 128

    private let transport: any AIHTTPTransport

    public init() {
        transport = URLSessionAIHTTPTransport(timeout: Self.timeout)
    }

    init(transport: any AIHTTPTransport) {
        self.transport = transport
    }

    public func testConnection(
        configuration: AIConfiguration,
        credential: String
    ) async throws -> AIConnectionTestResult {
        let request = try makeRequest(configuration: configuration, credential: credential)
        let response: AIHTTPResponse
        do {
            try Task.checkCancellation()
            response = try await transport.send(request)
            try Task.checkCancellation()
        } catch is CancellationError {
            throw AIConnectionError.cancelled
        } catch let error as AIConnectionError {
            throw error
        } catch let error as URLError {
            throw Self.map(error)
        } catch {
            throw AIConnectionError.connectionFailed
        }

        try Self.validateStatus(response)
        guard response.body.count <= Self.maximumResponseBytes else {
            throw AIConnectionError.responseTooLarge
        }

        let envelope: ChatCompletionEnvelope
        do {
            envelope = try JSONDecoder().decode(ChatCompletionEnvelope.self, from: response.body)
        } catch {
            throw AIConnectionError.malformedResponse
        }
        guard let choice = envelope.choices.first else {
            throw AIConnectionError.emptyResponse
        }
        if choice.finishReason == "length" {
            throw AIConnectionError.truncatedResponse
        }
        guard choice.finishReason == "stop" else {
            throw AIConnectionError.malformedResponse
        }
        let content = choice.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            throw AIConnectionError.emptyResponse
        }
        guard let contentData = content.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: contentData),
              let dictionary = object as? [String: Any],
              dictionary.count == 1,
              dictionary["ok"] as? Bool == true else {
            throw AIConnectionError.capabilityMismatch
        }

        return AIConnectionTestResult(
            serviceName: configuration.serviceName,
            modelID: configuration.modelID,
            responseFormatMode: configuration.responseFormatMode
        )
    }

    private func makeRequest(
        configuration: AIConfiguration,
        credential: String
    ) throws -> URLRequest {
        guard !credential.isEmpty,
              credential.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }) else {
            throw AIConnectionError.invalidCredential
        }
        let endpoint = Self.chatCompletionsEndpoint(baseURL: configuration.baseURL)
        var request = URLRequest(
            url: endpoint,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: Self.timeout
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        request.httpBody = try Self.connectionTestBody(for: configuration)
        return request
    }

    static func chatCompletionsEndpoint(baseURL: URL) -> URL {
        if baseURL.path.lowercased().hasSuffix("/chat/completions") {
            return baseURL
        }
        return baseURL
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("completions", isDirectory: false)
    }

    static func connectionTestBody(for configuration: AIConfiguration) throws -> Data {
        var body: [String: Any] = [
            "model": configuration.modelID,
            "messages": [
                [
                    "role": "system",
                    "content": "Return only one JSON object with exactly one boolean field named ok."
                ],
                ["role": "user", "content": "Return {\"ok\":true}." ]
            ],
            "max_tokens": connectionTestMaximumOutputTokens,
            "stream": false
        ]
        switch configuration.responseFormatMode {
        case .jsonSchema:
            body["response_format"] = [
                "type": "json_schema",
                "json_schema": [
                    "name": "oboe_connection_test",
                    "strict": true,
                    "schema": [
                        "type": "object",
                        "properties": ["ok": ["type": "boolean"]],
                        "required": ["ok"],
                        "additionalProperties": false
                    ]
                ]
            ]
        case .jsonObject:
            body["response_format"] = ["type": "json_object"]
        case .promptedJSON:
            break
        }
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

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

struct ChatCompletionEnvelope: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let message: Message
        let finishReason: String

        enum CodingKeys: String, CodingKey {
            case message
            case finishReason = "finish_reason"
        }
    }

    struct Message: Decodable {
        let content: String
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
        redirected.setValue(
            originalRequest.value(forHTTPHeaderField: "Authorization"),
            forHTTPHeaderField: "Authorization"
        )
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
