import Foundation
import LocalAuthentication
import LyricsXFoundation
import Security

enum AILyricsTranslationCredentialError: Error {
    case keychain(OSStatus)
    case invalidStoredValue

    var isTransient: Bool {
        guard case let .keychain(status) = self else {
            return false
        }
        return [
            errSecInteractionNotAllowed,
            errSecNotAvailable,
        ].contains(status)
    }
}

enum AILyricsTranslationCredentialStore {
    private struct StoredCredential: Codable {
        let version: Int
        let endpointOrigin: String
        let apiKey: String
    }

    private static let account = "api-key-v2"
    private static let legacyAccount = "api-key"
    private static let cacheLock = NSLock()
    private static var cachedCredential: StoredCredential?

    private static var service: String {
        return "\(Bundle.main.bundleIdentifier ?? "com.JH.LyricsX").ai-lyrics-translation"
    }

    static func apiKey(
        for endpoint: URL,
        allowingAuthenticationUI: Bool = false
    ) throws -> String? {
        return try readAPIKey(
            for: endpoint,
            allowingAuthenticationUI: allowingAuthenticationUI,
            useCache: true
        )
    }

    private static func readAPIKey(
        for endpoint: URL,
        allowingAuthenticationUI: Bool,
        useCache: Bool
    ) throws -> String? {
        guard let endpointOrigin = AILyricsTranslationPolicy.endpointOrigin(endpoint) else {
            throw AILyricsTranslationCredentialError.invalidStoredValue
        }
        if useCache,
           let cachedCredential = cachedCredentialValue(),
           cachedCredential.endpointOrigin == endpointOrigin {
            return cachedCredential.apiKey
        }

        var result: CFTypeRef?
        let authenticationContext = LAContext()
        authenticationContext.interactionNotAllowed = !allowingAuthenticationUI
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
            // Background translation passes `false` and therefore never surprises
            // the user with an authentication sheet after a signer or ACL change.
            kSecUseAuthenticationContext as String: authenticationContext,
        ] as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw AILyricsTranslationCredentialError.keychain(status)
        }
        guard let data = result as? Data,
              let storedCredential = try? JSONDecoder().decode(StoredCredential.self, from: data),
              storedCredential.version == 1 else {
            throw AILyricsTranslationCredentialError.invalidStoredValue
        }
        guard storedCredential.endpointOrigin == endpointOrigin else {
            return nil
        }
        let apiKey = try validatedAPIKey(storedCredential.apiKey)
        let validatedCredential = StoredCredential(
            version: 1,
            endpointOrigin: endpointOrigin,
            apiKey: apiKey
        )
        cacheCredential(validatedCredential)
        return apiKey
    }

    /// Whether a key is stored for this endpoint's origin, without disclosing
    /// it. The cache is deliberately bypassed: the point of asking is to tell
    /// the user what the Keychain actually holds, so a key removed out of band
    /// must not keep reporting as present for the rest of the session.
    static func hasAccessibleAPIKey(
        for endpoint: URL,
        allowingAuthenticationUI: Bool = false
    ) throws -> Bool {
        return try readAPIKey(
            for: endpoint,
            allowingAuthenticationUI: allowingAuthenticationUI,
            useCache: false
        ) != nil
    }

    static func store(apiKey: String, for endpoint: URL) throws {
        let apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            try removeAPIKey()
            return
        }
        let validatedAPIKey = try validatedAPIKey(apiKey)
        guard let endpointOrigin = AILyricsTranslationPolicy.endpointOrigin(endpoint) else {
            throw AILyricsTranslationCredentialError.invalidStoredValue
        }
        let storedCredential = StoredCredential(
            version: 1,
            endpointOrigin: endpointOrigin,
            apiKey: validatedAPIKey
        )
        guard let credentialData = try? JSONEncoder().encode(storedCredential) else {
            throw AILyricsTranslationCredentialError.invalidStoredValue
        }

        let query = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary
        let attributes = [kSecValueData as String: credentialData] as CFDictionary
        let updateStatus = SecItemUpdate(query, attributes)
        if updateStatus == errSecSuccess {
            cacheCredential(storedCredential)
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw AILyricsTranslationCredentialError.keychain(updateStatus)
        }

        let addStatus = SecItemAdd([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: credentialData,
        ] as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw AILyricsTranslationCredentialError.keychain(addStatus)
        }
        cacheCredential(storedCredential)
    }

    static func removeAPIKey() throws {
        cacheCredential(nil)
        var firstError: OSStatus?
        for account in [account, legacyAccount] {
            let status = SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ] as CFDictionary)
            if status != errSecSuccess,
               status != errSecItemNotFound,
               firstError == nil {
                firstError = status
            }
        }
        if let firstError {
            throw AILyricsTranslationCredentialError.keychain(firstError)
        }
    }

    static func validatedAPIKey(_ value: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.utf8.count <= 16_384,
              !value.unicodeScalars.contains(where: {
                  CharacterSet.newlines.contains($0) || CharacterSet.controlCharacters.contains($0)
              }) else {
            throw AILyricsTranslationCredentialError.invalidStoredValue
        }
        return value
    }

    private static func cachedCredentialValue() -> StoredCredential? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cachedCredential
    }

    private static func cacheCredential(_ value: StoredCredential?) {
        cacheLock.lock()
        cachedCredential = value
        cacheLock.unlock()
    }
}

enum OpenAICompatibleLyricsTranslatorError: Error {
    case invalidResponse
    case httpStatus(Int)
    case responseTooLarge
    /// The track used up its requests before every line was answered.
    case requestLimitReached
}

struct AILyricsTranslationResult {
    /// Line index → translated text, for every line the endpoint answered.
    /// Returned as data rather than as a merged `Lyrics` so the caller applies
    /// it to the lyrics on screen when the answer lands, instead of replacing
    /// them with a snapshot taken before the request went out.
    let translations: [Int: String]
    /// Lines that never came back: dropped for size, or unanswered after every retry.
    let failedLineCount: Int
    /// Why lines failed, as the last of them ended: what their final request
    /// came back with, or `requestLimitReached`. Nil when every line came back.
    let failure: Error?
}

final class OpenAICompatibleLyricsTranslator {
    private static let maximumRequestBytes = 2_097_152
    private static let maximumResponseBytes = 2_097_152
    private static let maximumAttempts = 3
    /// The requests one track may make, per batch: enough to retry a batch
    /// twice or split it once, and the bound on what an endpoint that keeps
    /// answering with something unusable can cost. Unbounded, splitting and
    /// retrying one such batch of 24 lines came to about 95 requests.
    private static let requestsPerBatch = 3

    /// The requests a track has left, shared by its batches and by the halves
    /// a batch is split into.
    private final class RequestBudget {
        var remainingRequests: Int

        init(remainingRequests: Int) {
            self.remainingRequests = remainingRequests
        }
    }
    /// Enough for a one-line answer plus whatever a reasoning model spends
    /// before it: the probe now has to come back as parseable JSON with the
    /// translation in it, so a cap tight enough to truncate would report a
    /// working endpoint as broken.
    private static let connectionTestMaxTokens = 512
    private static let connectionTestLineIndex = 0
    private static let connectionTestLineText = "Connection test."

    private final class BoundedResponseLoader: NSObject, URLSessionDataDelegate {
        private let configuration: URLSessionConfiguration
        private let maximumResponseBytes: Int
        private let lock = NSLock()

        private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
        private var session: URLSession?
        private var task: URLSessionDataTask?
        private var response: URLResponse?
        private var data = Data()
        private var isFinished = false

        init(configuration: URLSessionConfiguration, maximumResponseBytes: Int) {
            self.configuration = configuration
            self.maximumResponseBytes = maximumResponseBytes
        }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { continuation in
                    lock.lock()
                    guard !isFinished else {
                        lock.unlock()
                        continuation.resume(throwing: CancellationError())
                        return
                    }

                    self.continuation = continuation
                    let session = URLSession(
                        configuration: configuration,
                        delegate: self,
                        delegateQueue: nil
                    )
                    let task = session.dataTask(with: request)
                    self.session = session
                    self.task = task
                    let isAlreadyCancelled = Task.isCancelled
                    lock.unlock()

                    if isAlreadyCancelled {
                        cancel()
                    } else {
                        task.resume()
                    }
                }
            }, onCancel: { [weak self] in
                self?.cancel()
            })
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            // The request carries a bearer credential. Require the user to configure
            // the final endpoint instead of risking forwarding it through a redirect.
            completionHandler(nil)
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            if response.expectedContentLength > Int64(maximumResponseBytes) {
                completionHandler(.cancel)
                finish(.failure(OpenAICompatibleLyricsTranslatorError.responseTooLarge))
                return
            }

            lock.lock()
            let shouldContinue = !isFinished
            if shouldContinue {
                self.response = response
            }
            lock.unlock()
            completionHandler(shouldContinue ? .allow : .cancel)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive newData: Data) {
            lock.lock()
            let exceedsLimit = !isFinished && newData.count > maximumResponseBytes - data.count
            if !isFinished, !exceedsLimit {
                data.append(newData)
            }
            lock.unlock()

            if exceedsLimit {
                dataTask.cancel()
                finish(.failure(OpenAICompatibleLyricsTranslatorError.responseTooLarge))
            }
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            didCompleteWithError error: Error?
        ) {
            if let error {
                finish(.failure(error))
                return
            }

            lock.lock()
            let response = self.response
            let data = self.data
            lock.unlock()
            guard let response else {
                finish(.failure(OpenAICompatibleLyricsTranslatorError.invalidResponse))
                return
            }
            finish(.success((data, response)))
        }

        private func cancel() {
            lock.lock()
            let task = self.task
            lock.unlock()
            task?.cancel()
            finish(.failure(CancellationError()))
        }

        private func finish(_ result: Result<(Data, URLResponse), Error>) {
            lock.lock()
            guard !isFinished else {
                lock.unlock()
                return
            }
            isFinished = true
            let continuation = self.continuation
            let session = self.session
            self.continuation = nil
            self.session = nil
            task = nil
            lock.unlock()

            switch result {
            case .success:
                session?.finishTasksAndInvalidate()
            case .failure:
                session?.invalidateAndCancel()
            }
            continuation?.resume(with: result)
        }
    }

    func translate(
        lyrics: Lyrics,
        configuration: AILyricsTranslationConfiguration,
        apiKey: String
    ) async throws -> AILyricsTranslationResult {
        let sourceLines = AILyricsTranslationPolicy.translationInputLines(
            lyrics: lyrics,
            targetLanguage: configuration.targetLanguage
        )
        guard !sourceLines.isEmpty else {
            return AILyricsTranslationResult(translations: [:], failedLineCount: 0, failure: nil)
        }

        let batches = try AILyricsTranslationBatchPolicy.batches(sourceLines)
        let sourceLanguage = lyrics.metadata.language
        let budget = RequestBudget(remainingRequests: batches.count * Self.requestsPerBatch)
        var translations: [Int: String] = [:]
        // The policy drops any line too large to batch on its own. Those never
        // reach a request, so nothing further down would report them — without
        // this they would be silently missing from the failure count too.
        var failedLineCount = sourceLines.count - batches.reduce(0) { $0 + $1.count }
        var failure: Error? = failedLineCount > 0 ? AILyricsTranslationError.lyricsTooLarge : nil
        for batch in batches {
            try Task.checkCancellation()
            let result = try await translateBatch(
                batch,
                configuration: configuration,
                sourceLanguage: sourceLanguage,
                apiKey: apiKey,
                budget: budget
            )
            translations.merge(result.translations) { _, new in new }
            failedLineCount += result.failedIndices.count
            failure = result.failure ?? failure
        }
        return AILyricsTranslationResult(
            translations: translations,
            failedLineCount: failedLineCount,
            failure: failure
        )
    }

    private func translateBatch(
        _ lines: [AILyricsTranslationInputLine],
        configuration: AILyricsTranslationConfiguration,
        sourceLanguage: String?,
        apiKey: String,
        budget: RequestBudget
    ) async throws -> (translations: [Int: String], failedIndices: [Int], failure: Error?) {
        var remaining = lines
        var translations: [Int: String] = [:]
        var lastFailure: Error?

        for attempt in 0 ..< Self.maximumAttempts where !remaining.isEmpty {
            try Task.checkCancellation()
            guard budget.remainingRequests > 0 else {
                return (
                    translations,
                    remaining.map(\.index),
                    OpenAICompatibleLyricsTranslatorError.requestLimitReached
                )
            }
            budget.remainingRequests -= 1
            do {
                let payload = try OpenAICompatibleChatRequest(
                    configuration: configuration,
                    sourceLanguage: sourceLanguage,
                    sourceLines: remaining
                )
                let request = try request(
                    endpoint: configuration.endpoint,
                    apiKey: apiKey,
                    payload: payload
                )
                let data = try await responseData(for: request)
                let content = try OpenAICompatibleChatResponse.content(from: data)
                let parsed = try AILyricsTranslationPolicy.parsedTranslations(
                    response: content,
                    expectedLines: remaining
                )
                translations.merge(parsed.translations) { _, new in new }
                remaining = remaining.filter { parsed.missingIndices.contains($0.index) }
                // An answer that left lines out did not translate them.
                lastFailure = remaining.isEmpty ? nil : AILyricsTranslationError.invalidResponse
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                lastFailure = error
                if shouldSplit(error), remaining.count > 1 {
                    let midpoint = remaining.count / 2
                    let first = try await translateBatch(
                        Array(remaining[..<midpoint]),
                        configuration: configuration,
                        sourceLanguage: sourceLanguage,
                        apiKey: apiKey,
                        budget: budget
                    )
                    let second = try await translateBatch(
                        Array(remaining[midpoint...]),
                        configuration: configuration,
                        sourceLanguage: sourceLanguage,
                        apiKey: apiKey,
                        budget: budget
                    )
                    return (
                        translations
                            .merging(first.translations) { _, new in new }
                            .merging(second.translations) { _, new in new },
                        first.failedIndices + second.failedIndices,
                        second.failure ?? first.failure
                    )
                }

                guard attempt + 1 < Self.maximumAttempts, shouldRetry(error) else {
                    return (translations, remaining.map(\.index), error)
                }
                try await Task.sleep(nanoseconds: UInt64(pow(2, Double(attempt)) * 1_000_000_000))
            }
        }

        return (translations, remaining.map(\.index), lastFailure)
    }

    private func shouldSplit(_ error: Error) -> Bool {
        if let error = error as? OpenAICompatibleLyricsTranslatorError {
            switch error {
            case .responseTooLarge, .httpStatus(413):
                return true
            case .invalidResponse, .httpStatus(_), .requestLimitReached:
                return false
            }
        }
        guard let error = error as? AILyricsTranslationError else { return false }
        return error == .invalidResponse || error == .lyricsTooLarge
    }

    private func shouldRetry(_ error: Error) -> Bool {
        if let error = error as? OpenAICompatibleLyricsTranslatorError {
            switch error {
            case .httpStatus(let status):
                return status == 429 || (500 ..< 600).contains(status)
            case .invalidResponse, .responseTooLarge, .requestLimitReached:
                return false
            }
        }
        if let error = error as? URLError {
            switch error.code {
            case .timedOut,
                 .cannotFindHost,
                 .cannotConnectToHost,
                 .networkConnectionLost,
                 .dnsLookupFailed,
                 .notConnectedToInternet,
                 .resourceUnavailable:
                return true
            default:
                return false
            }
        }
        if let error = error as? AILyricsTranslationError {
            return error == .invalidResponse
        }
        return false
    }

    /// Sends the same request shape the translator sends, with the small token
    /// cap below so a "Save and Test" stays cheap, and requires a usable
    /// translation back for the one line it asked about.
    ///
    /// Settling for a non-empty body is not enough: an endpoint that ignores
    /// `response_format: json_object` answers with prose, passes that check,
    /// and then fails every real request behind a green "Connection succeeded."
    func testConnection(
        configuration: AILyricsTranslationConfiguration,
        apiKey: String
    ) async throws {
        let probeLine = AILyricsTranslationInputLine(
            index: Self.connectionTestLineIndex,
            text: Self.connectionTestLineText
        )
        let payload = try OpenAICompatibleChatRequest(
            configuration: configuration,
            sourceLanguage: nil,
            sourceLines: [probeLine],
            maxTokens: Self.connectionTestMaxTokens
        )
        let request = try request(
            endpoint: configuration.endpoint,
            apiKey: apiKey,
            payload: payload
        )
        let data = try await responseData(for: request)
        let content: String
        do {
            content = try OpenAICompatibleChatResponse.content(from: data)
        } catch {
            throw OpenAICompatibleLyricsTranslatorError.invalidResponse
        }
        let parsed = try AILyricsTranslationPolicy.parsedTranslations(
            response: content,
            expectedLines: [probeLine]
        )
        // Answered is enough: with an English target the probe line comes
        // back as it went, which is no translation to keep but still proves
        // the endpoint works.
        guard !parsed.missingIndices.contains(probeLine.index) else {
            throw OpenAICompatibleLyricsTranslatorError.invalidResponse
        }
    }

    private func request<Payload: Encodable>(
        endpoint: URL,
        apiKey: String,
        payload: Payload
    ) throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let requestBody = try JSONEncoder().encode(payload)
        guard requestBody.count <= Self.maximumRequestBytes else {
            throw AILyricsTranslationError.lyricsTooLarge
        }
        request.httpBody = requestBody
        return request
    }

    private func responseData(for request: URLRequest) async throws -> Data {
        let (data, response) = try await data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw OpenAICompatibleLyricsTranslatorError.invalidResponse
        }
        guard 200 ..< 300 ~= response.statusCode else {
            throw OpenAICompatibleLyricsTranslatorError.httpStatus(response.statusCode)
        }
        return data
    }

    private func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = 120
        return try await BoundedResponseLoader(
            configuration: configuration,
            maximumResponseBytes: Self.maximumResponseBytes
        ).data(for: request)
    }
}

extension OpenAICompatibleLyricsTranslator {
    /// Says what failed, for the Lab pane's status line, after a connection
    /// test or a translation. One generic sentence sent the user hunting
    /// through three settings when the endpoint had answered 401.
    static func failureDescription(for error: Error) -> String {
        let noTranslationDescription = NSLocalizedString(
            "The endpoint did not answer with a translation. It may not support JSON mode.",
            comment: "Status shown when the AI translation endpoint gives a well-formed HTTP answer that is not a translation."
        )
        if let error = error as? OpenAICompatibleLyricsTranslatorError {
            switch error {
            case .httpStatus(let status):
                return String(
                    format: NSLocalizedString(
                        "The endpoint answered HTTP %d.",
                        comment: "Status shown when the AI translation endpoint test gets a non-2xx answer; %d is the HTTP status code."
                    ),
                    status
                )
            case .responseTooLarge:
                return NSLocalizedString(
                    "The endpoint's answer was too large to read.",
                    comment: "Status shown when the AI translation endpoint test gets an oversized answer."
                )
            case .invalidResponse:
                return noTranslationDescription
            case .requestLimitReached:
                return NSLocalizedString(
                    "Stopped after too many requests for this song.",
                    comment: "Status shown when AI translation used up the requests one song may make before every line was answered."
                )
            }
        }
        if let error = error as? AILyricsTranslationError {
            switch error {
            case .invalidResponse:
                return noTranslationDescription
            case .lyricsTooLarge:
                return NSLocalizedString(
                    "A lyric line is too long to send.",
                    comment: "Status shown when a lyric line is too long for an AI translation request."
                )
            case .invalidEndpoint,
                 .insecureEndpoint,
                 .missingModel,
                 .missingTargetLanguage,
                 .invalidTargetLanguage,
                 .configurationTooLarge:
                return NSLocalizedString(
                    "AI translation settings are incomplete or invalid.",
                    comment: "Status for AI lyric translation when its configuration is invalid."
                )
            }
        }
        if let error = error as? URLError {
            return String(
                format: NSLocalizedString(
                    "The request failed: %@",
                    comment: "Status shown when the AI translation endpoint test fails at the network layer; %@ is the system's description."
                ),
                error.localizedDescription
            )
        }
        return error.localizedDescription
    }
}
