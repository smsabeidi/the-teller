import SwiftUI

@main
@MainActor
struct TheTellerApp: App {
    @State private var connection: TellerConnection
    @State private var api: TellerAPI
    @State private var player: TellerPlayer
    @State private var connectionRevision = 0

    init() {
        let connection = AppConfiguration.connection
        _connection = State(initialValue: connection)
        let api = TellerAPI(baseURL: connection.baseURL, accessKey: connection.accessKey)
        _api = State(initialValue: api)
        _player = State(initialValue: TellerPlayer(api: api))
    }

    var body: some Scene {
        WindowGroup {
            TellerRootView(api: api, player: player, connection: connection, saveConnection: updateConnection)
                .id(connectionRevision)
        }
    }

    private func updateConnection(_ next: TellerConnection) {
        guard next != connection else { return }
        player.close()
        let api = TellerAPI(baseURL: next.baseURL, accessKey: next.accessKey)
        self.api = api
        player = TellerPlayer(api: api)
        connection = next
        connectionRevision += 1
    }
}

enum AppConfiguration {
    static var connection: TellerConnection {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["TELLER_API_BASE_URL"],
           let url = URL(string: override), url.host != nil {
            return TellerConnection(baseURL: url, accessKey: nil)
        }
        #endif
        if let saved = TellerConnection.restore() { return saved }
        return TellerConnection(baseURL: apiBaseURL, accessKey: nil)
    }

    private static var apiBaseURL: URL {
        let configured = Bundle.main.object(forInfoDictionaryKey: "TellerAPIBaseURL") as? String
        #if DEBUG
        let value = configured
        let schemes = ["http", "https"]
        #else
        let value = configured
        let schemes = ["https"]
        #endif

        if let value, let url = URL(string: value), let scheme = url.scheme,
           schemes.contains(scheme), url.host != nil {
            return url
        }
        #if DEBUG
        return URL(string: "http://127.0.0.1:8000")!
        #else
        // A shipping build needs an HTTPS backend supplied by the build configuration.
        return URL(string: "https://the-teller.invalid")!
        #endif
    }
}
