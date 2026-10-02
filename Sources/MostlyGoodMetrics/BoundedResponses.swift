import Foundation

/// SDK-owned URLSession tasks stream into bounded buffers instead of allowing
/// completion-handler tasks to accumulate an unlimited response in memory.
final class BoundedResponses: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct Pending {
        var data = Data()
        var response: URLResponse?
        let completion: (Data?, URLResponse?, Error?) -> Void
    }
    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]
    private let maxRequests = 8

    func task(in session: URLSession, request: URLRequest,
              completion: @escaping (Data?, URLResponse?, Error?) -> Void) -> URLSessionDataTask? {
        let task = lock.withLock { () -> URLSessionDataTask? in
            guard pending.count < maxRequests else { return nil }
            let task = session.dataTask(with: request)
            pending[task.taskIdentifier] = Pending(completion: completion)
            return task
        }
        if task == nil { completion(nil, nil, URLError(.dataLengthExceedsMaximum)) }
        return task
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let headerLength = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init)
        if response.expectedContentLength > Int64(JSONSafety.maxBytes) || (headerLength ?? 0) > Int64(JSONSafety.maxBytes) {
            finish(dataTask, error: URLError(.dataLengthExceedsMaximum))
            completionHandler(.cancel)
            return
        }
        let exists = lock.withLock { () -> Bool in
            guard var state = pending[dataTask.taskIdentifier] else { return false }
            state.response = response
            pending[dataTask.taskIdentifier] = state
            return true
        }
        completionHandler(exists ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let overflow = lock.withLock { () -> Bool in
            guard var state = pending[dataTask.taskIdentifier] else { return false }
            guard data.count <= JSONSafety.maxBytes - state.data.count else { return true }
            state.data.append(data)
            pending[dataTask.taskIdentifier] = state
            return false
        }
        if overflow {
            finish(dataTask, error: URLError(.dataLengthExceedsMaximum))
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(task, error: error)
    }

    private func finish(_ task: URLSessionTask, error: Error?) {
        let state = lock.withLock { pending.removeValue(forKey: task.taskIdentifier) }
        // Removal before calling a consumer ensures cancellation and completion
        // cannot deliver twice, including synchronous reentrant requests.
        state?.completion(error == nil ? state?.data : nil, state?.response, error)
    }
}
