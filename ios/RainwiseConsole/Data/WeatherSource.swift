import Foundation

protocol WeatherSource: Sendable {
    /// Live conditions; the stream ends or throws when the connection drops.
    func live() -> AsyncThrowingStream<CurrentConditions, Error>
    func history(metric: ChartMetric, range: ChartRange) async throws -> HistorySeries
}

enum CollectorError: LocalizedError {
    case badURL(String)
    case http(Int)
    case unauthorized

    var errorDescription: String? {
        switch self {
        case .badURL(let s): return "Invalid collector address “\(s)”"
        case .http(let code): return "Collector returned HTTP \(code)"
        case .unauthorized: return "Collector rejected the API token"
        }
    }
}

/// Talks to the Python collector over HTTP (REST + Server-Sent Events).
struct CollectorSource: WeatherSource {
    let baseURL: URL
    let token: String?

    init(address: String, token: String?) throws {
        var s = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.contains("://") { s = "http://" + s }
        guard let url = URL(string: s), url.host != nil else { throw CollectorError.badURL(address) }
        baseURL = url
        self.token = (token?.isEmpty ?? true) ? nil : token
    }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 45  // the stream sends a keepalive every 15 s
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    private func request(_ path: String, query: [URLQueryItem] = []) -> URLRequest {
        var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var r = URLRequest(url: comps.url!)
        if let token { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return r
    }

    private static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if http.statusCode == 401 { throw CollectorError.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw CollectorError.http(http.statusCode) }
    }

    func current() async throws -> CurrentConditions {
        let (data, response) = try await Self.session.data(for: request("api/current"))
        try Self.check(response)
        return try JSONDecoder.collector.decode(CurrentConditions.self, from: data)
    }

    func history(metric: ChartMetric, range: ChartRange) async throws -> HistorySeries {
        let r = request("api/history", query: [
            URLQueryItem(name: "metric", value: metric.rawValue),
            URLQueryItem(name: "range", value: range.rawValue),
        ])
        let (data, response) = try await Self.session.data(for: r)
        try Self.check(response)
        return try JSONDecoder.collector.decode(HistorySeries.self, from: data)
    }

    func live() -> AsyncThrowingStream<CurrentConditions, Error> {
        var r = request("api/stream")
        r.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let req = r
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await Self.session.bytes(for: req)
                    try Self.check(response)
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }  // skip keepalives
                        let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        let c = try JSONDecoder.collector.decode(CurrentConditions.self, from: Data(json.utf8))
                        continuation.yield(c)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
