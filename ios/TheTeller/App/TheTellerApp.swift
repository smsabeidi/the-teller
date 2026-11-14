import SwiftUI

@main
@MainActor
struct TheTellerApp: App {
    @State private var player: TellerPlayer
    private let api: TellerAPI

    init() {
        let api = TellerAPI(baseURL: AppConfiguration.apiBaseURL)
        self.api = api
        _player = State(initialValue: TellerPlayer(api: api))
    }

    var body: some Scene {
        WindowGroup {
            TellerRootView(api: api, player: player)
        }
    }
}

enum AppConfiguration {
    static var apiBaseURL: URL {
        let configured = Bundle.main.object(forInfoDictionaryKey: "TellerAPIBaseURL") as? String
        #if DEBUG
        let override = ProcessInfo.processInfo.environment["TELLER_API_BASE_URL"]
        let value = override ?? configured
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
