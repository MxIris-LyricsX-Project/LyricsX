import Foundation
import LyricsXFoundation
import Security

enum AILyricsTranslationCredentialError: Error {
    case keychain(OSStatus)
    case invalidStoredValue
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
        let authenticationUI = allowingAuthenticationUI
            ? kSecUseAuthenticationUIAllow
            : kSecUseAuthenticationUIFail
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
            // Background translation passes `false` and therefore never surprises
            // the user with an authentication sheet after a signer or ACL change.
            kSecUseAuthenticationUI as String: authenticationUI,
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

    static func clearSessionCache() {
        cacheCredential(nil)
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
}

final class OpenAICompatibleLyricsTranslator {
    private static let maximumRequestBytes = 2_097_152
    private static let maximumResponseBytes = 2_097_152

    private struct ConnectionTestPayload: Encodable {
        let model: String
        let messages: [OpenAICompatibleChatRequest.Message]

        init(model: String) {
            self.model = model
            messages = [
                OpenAICompatibleChatRequest.Message(
                    role: "user",
                    content: "Reply with OK."
                ),
            ]
        }
    }

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
    ) async throws -> Lyrics {
        let sourceLines = AILyricsTranslationPolicy.translationInputLines(
            lyrics: lyrics,
            targetLanguage: configuration.targetLanguage
        )
        guard !sourceLines.isEmpty else {
            return lyrics
        }
        let payload = try OpenAICompatibleChatRequest(
            configuration: configuration,
            sourceLanguage: lyrics.metadata.language,
            sourceLines: sourceLines
        )
        let request = try request(
            endpoint: configuration.endpoint,
            apiKey: apiKey,
            payload: payload
        )
        let data = try await responseData(for: request)
        let content = try OpenAICompatibleChatResponse.content(from: data)
        return try AILyricsTranslationPolicy.merging(
            response: content,
            into: lyrics,
            targetLanguage: configuration.targetLanguage,
            expectedIndices: sourceLines.map(\.index)
        )
    }

    func testConnection(
        endpoint: URL,
        model: String,
        apiKey: String
    ) async throws {
        let request = try request(
            endpoint: endpoint,
            apiKey: apiKey,
            payload: ConnectionTestPayload(model: model)
        )
        let data = try await responseData(for: request)
        do {
            _ = try OpenAICompatibleChatResponse.content(from: data)
        } catch {
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
