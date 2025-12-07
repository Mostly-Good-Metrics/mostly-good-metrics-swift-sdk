import Foundation

/// Handles network communication with the MostlyGoodMetrics API
final class NetworkClient {
    private let configuration: MGMConfiguration
    private let session: URLSession
    private let encoder: JSONEncoder

    /// Current retry-after interval from rate limiting (in seconds)
    private var retryAfterDate: Date?

    init(configuration: MGMConfiguration) {
        self.configuration = configuration

        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = 30
        sessionConfig.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: sessionConfig)

        self.encoder = JSONEncoder()
    }

    /// Sends a batch of events to the API
    /// - Parameters:
    ///   - events: The events to send
    ///   - context: The context to apply to all events
    ///   - completion: Completion handler with result
    func sendEvents(
        _ events: [MGMEvent],
        context: MGMEventContext?,
        completion: @escaping (Result<Void, MGMError>) -> Void
    ) {
        // Check if we're still in rate limit backoff
        if let retryAfter = retryAfterDate, Date() < retryAfter {
            completion(.failure(.rateLimited(retryAfter: retryAfter.timeIntervalSinceNow)))
            return
        }

        let url = configuration.baseURL.appendingPathComponent("v1/events")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.apiKey, forHTTPHeaderField: "X-MGM-Key")

        // Set bundle ID if available
        let bundleId = configuration.bundleId ?? Bundle.main.bundleIdentifier
        if let bundleId = bundleId {
            request.setValue(bundleId, forHTTPHeaderField: "X-MGM-Bundle-Id")
        }

        let payload = MGMEventsPayload(events: events, context: context)

        do {
            let jsonData = try encoder.encode(payload)

            // Compress with gzip if data is large enough (> 1KB)
            if jsonData.count > 1024, let compressedData = GzipCompression.compress(jsonData) {
                request.httpBody = compressedData
                request.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
            } else {
                request.httpBody = jsonData
            }
        } catch {
            completion(.failure(.encodingError(error)))
            return
        }

        if configuration.enableDebugLogging {
            debugLog("Sending \(events.count) events to \(url)")
            if let jsonData = request.httpBody,
               request.value(forHTTPHeaderField: "Content-Encoding") != "gzip",
               let jsonString = String(data: jsonData, encoding: .utf8) {
                debugLog("Request body: \(jsonString)")
            }
        }

        let task = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }

            if let error = error {
                self.debugLog("Network error: \(error.localizedDescription)")
                completion(.failure(.networkError(error)))
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                completion(.failure(.invalidResponse))
                return
            }

            switch httpResponse.statusCode {
            case 204:
                self.debugLog("Successfully sent \(events.count) events")
                completion(.success(()))

            case 400:
                let errorMessage = self.parseErrorMessage(from: data)
                self.debugLog("Bad request: \(errorMessage)")
                if let data = data, let responseBody = String(data: data, encoding: .utf8) {
                    self.debugLog("Response body: \(responseBody)")
                }
                completion(.failure(.badRequest(errorMessage)))

            case 401:
                self.debugLog("Unauthorized - invalid API key")
                completion(.failure(.unauthorized))

            case 403:
                let errorMessage = self.parseErrorMessage(from: data)
                self.debugLog("Forbidden: \(errorMessage)")
                completion(.failure(.forbidden(errorMessage)))

            case 429:
                let retryAfter = self.parseRetryAfter(from: httpResponse)
                self.retryAfterDate = Date().addingTimeInterval(retryAfter)
                self.debugLog("Rate limited, retry after \(retryAfter) seconds")
                completion(.failure(.rateLimited(retryAfter: retryAfter)))

            case 500...599:
                let errorMessage = self.parseErrorMessage(from: data)
                self.debugLog("Server error: \(errorMessage)")
                completion(.failure(.serverError(httpResponse.statusCode, errorMessage)))

            default:
                self.debugLog("Unexpected status code: \(httpResponse.statusCode)")
                completion(.failure(.unexpectedStatusCode(httpResponse.statusCode)))
            }
        }

        task.resume()
    }

    private func parseErrorMessage(from data: Data?) -> String {
        guard let data = data else { return "Unknown error" }

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? String {
            return error
        }

        return String(data: data, encoding: .utf8) ?? "Unknown error"
    }

    private func parseRetryAfter(from response: HTTPURLResponse) -> TimeInterval {
        if let retryAfterString = response.value(forHTTPHeaderField: "Retry-After"),
           let retryAfter = Double(retryAfterString) {
            return retryAfter
        }
        return 60 // Default to 60 seconds if not specified
    }

    private func debugLog(_ message: String) {
        if configuration.enableDebugLogging {
            print("[MostlyGoodMetrics] \(message)")
        }
    }
}

/// Errors that can occur when interacting with the MostlyGoodMetrics API
public enum MGMError: Error, LocalizedError {
    case networkError(Error)
    case encodingError(Error)
    case invalidResponse
    case badRequest(String)
    case unauthorized
    case forbidden(String)
    case rateLimited(retryAfter: TimeInterval)
    case serverError(Int, String)
    case unexpectedStatusCode(Int)
    case invalidEventName(String)

    public var errorDescription: String? {
        switch self {
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .encodingError(let error):
            return "Failed to encode events: \(error.localizedDescription)"
        case .invalidResponse:
            return "Invalid response from server"
        case .badRequest(let message):
            return "Bad request: \(message)"
        case .unauthorized:
            return "Invalid or missing API key"
        case .forbidden(let message):
            return "Forbidden: \(message)"
        case .rateLimited(let retryAfter):
            return "Rate limited. Retry after \(Int(retryAfter)) seconds"
        case .serverError(let code, let message):
            return "Server error (\(code)): \(message)"
        case .unexpectedStatusCode(let code):
            return "Unexpected status code: \(code)"
        case .invalidEventName(let name):
            return "Invalid event name '\(name)'. Must be alphanumeric + underscore, start with letter, max 255 chars"
        }
    }
}
