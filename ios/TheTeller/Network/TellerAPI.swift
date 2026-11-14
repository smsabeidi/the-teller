import Foundation

enum TellerAPIError: LocalizedError, Sendable {
    case invalidConfiguration
    case invalidResponse
    case guestSessionUnavailable
    case missingStory
    case unsupportedFile
    case fileTooLarge
    case preparationFailed
    case http(statusCode: Int, message: String)

    var statusCode: Int? {
        if case let .http(statusCode, _) = self {
            return statusCode
        }
        return nil
    }

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return "The Teller couldn't open its server address."
        case .invalidResponse:
            return "The Teller received an unexpected response. Try again."
        case .guestSessionUnavailable:
            return "The Teller couldn't start your guest session. Check your connection and try again."
        case .missingStory:
            return "Enter a link, choose a file, or paste your story."
        case .unsupportedFile:
            return "Choose an EPUB, PDF, DOCX, or TXT file."
        case .fileTooLarge:
            return "Choose a file that is 100 MB or smaller."
        case .preparationFailed:
            return "The Teller couldn't prepare this story. Check that the file is available and try again."
        case let .http(_, message):
            return message
        }
    }
}

actor TellerAPI {
    private let baseURL: URL
    private let session: URLSession
    private var bootstrap: Task<Void, Error>?
    private var didBootstrap = false

    init(baseURL: URL) {
        self.baseURL = baseURL
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = .shared
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .onlyFromMainDocumentDomain
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: configuration)
    }

    func importStory(
        _ source: StorySource,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> Book {
        try await ensureGuestSession()
        let multipart = try await StoryMultipart.prepare(source)
        defer { try? FileManager.default.removeItem(at: multipart.url) }
        try Task.checkCancellation()

        var request = try request(method: "POST", path: ["api", "import"])
        request.setValue("multipart/form-data; boundary=\(multipart.boundary)", forHTTPHeaderField: "Content-Type")
        progress?(0)
        let delegate = progress.map(UploadProgress.init)
        let (data, response) = try await session.upload(for: request, fromFile: multipart.url, delegate: delegate)
        let book: Book = try decode(data, response: response)
        progress?(1)
        return book
    }

    func book(id: String) async throws -> Book {
        try await json(path: ["api", "books", id])
    }

    func listBooks() async throws -> [LibraryBook] {
        let response: LibraryResponse = try await json(path: ["api", "my", "books"])
        return response.books
    }

    func deleteBook(id: String) async throws {
        let response: DeleteResponse = try await json(method: "DELETE", path: ["api", "my", "books", id])
        guard response.deleted else { throw TellerAPIError.invalidResponse }
    }

    func continueBook(id: String) async throws -> Book {
        let response: UnlockResponse = try await json(method: "POST", path: ["api", "my", "books", id, "unlock"])
        guard response.unlocked else { throw TellerAPIError.invalidResponse }
        return try await book(id: id)
    }

    func lines(bookID: String, start: Int, count: Int = 80) async throws -> LinePage {
        try await json(
            path: ["api", "books", bookID, "lines"],
            query: [
                URLQueryItem(name: "start", value: String(max(0, start))),
                URLQueryItem(name: "count", value: String(min(500, max(1, count))))
            ]
        )
    }

    func audio(bookID: String, line: Int) async throws -> LineAudio {
        try await ensureGuestSession()
        var request = try request(method: "GET", path: ["api", "books", bookID, "lines", String(line), "audio"])
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        let http = try Self.validate(data, response)
        switch http.statusCode {
        case 204:
            return .speechFallback
        case 200 where http.mimeType == "audio/mpeg" && !data.isEmpty:
            return .mp3(data)
        default:
            throw TellerAPIError.invalidResponse
        }
    }

    private func ensureGuestSession() async throws {
        if let bootstrap {
            try await bootstrap.value
            try Task.checkCancellation()
            return
        }
        let request = try request(method: "GET", path: ["api", "account"])
        guard let url = request.url else { throw TellerAPIError.invalidConfiguration }
        let cookieStorage = HTTPCookieStorage.shared
        if didBootstrap && Self.hasGuestCookie(cookieStorage, for: url) {
            try Task.checkCancellation()
            return
        }

        let session = session
        let bootstrap = Task {
            let (data, response) = try await session.data(for: request)
            _ = try Self.validate(data, response)
            guard Self.hasGuestCookie(cookieStorage, for: url) else {
                throw TellerAPIError.guestSessionUnavailable
            }
        }
        self.bootstrap = bootstrap
        defer { self.bootstrap = nil }
        try await bootstrap.value
        didBootstrap = true
        try Task.checkCancellation()
    }

    private static func hasGuestCookie(_ storage: HTTPCookieStorage, for url: URL) -> Bool {
        storage.cookies(for: url)?.contains { $0.name == "voiceemo_session" && !$0.value.isEmpty } == true
    }

    private func json<Value: Decodable>(
        method: String = "GET",
        path: [String],
        query: [URLQueryItem] = []
    ) async throws -> Value {
        try await ensureGuestSession()
        let request = try request(method: method, path: path, query: query)
        let (data, response) = try await session.data(for: request)
        return try decode(data, response: response)
    }

    private func request(method: String, path: [String], query: [URLQueryItem] = []) throws -> URLRequest {
        let supportedSchemes = ["https", "http"]
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              supportedSchemes.contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              path.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") })
        else {
            throw TellerAPIError.invalidConfiguration
        }
        let root = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = root + "/" + path.joined(separator: "/")
        components.queryItems = query.isEmpty ? nil : query

        guard let url = components.url else { throw TellerAPIError.invalidConfiguration }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func decode<Value: Decodable>(_ data: Data, response: URLResponse) throws -> Value {
        _ = try Self.validate(data, response)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        do {
            return try decoder.decode(Value.self, from: data)
        } catch {
            throw TellerAPIError.invalidResponse
        }
    }

    private static func validate(_ data: Data, _ response: URLResponse) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else { throw TellerAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let detail = try? JSONDecoder().decode(ErrorResponse.self, from: data).detail
            let fallback: String
            switch http.statusCode {
            case 401: fallback = "The Teller's server requires authentication."
            case 402: fallback = "This audiobook requires a purchase to continue."
            case 403: fallback = "This part of the audiobook is unavailable."
            case 404: fallback = "The audiobook could not be found."
            case 413: fallback = "The story exceeds the import limit."
            case 429: fallback = "Too many requests. Try again in a moment."
            default: fallback = "The Teller's server returned an error (\(http.statusCode)). Try again."
            }
            throw TellerAPIError.http(statusCode: http.statusCode, message: detail ?? fallback)
        }
        return http
    }
}

private struct LibraryResponse: Decodable {
    let books: [LibraryBook]
}

private struct DeleteResponse: Decodable {
    let deleted: Bool
}

private struct UnlockResponse: Decodable {
    let unlocked: Bool
}

private struct ErrorResponse: Decodable {
    let detail: String
}

private final class UploadProgress: NSObject, URLSessionTaskDelegate {
    private let update: @Sendable (Double) -> Void

    init(_ update: @escaping @Sendable (Double) -> Void) {
        self.update = update
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        update(min(1, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
    }
}
