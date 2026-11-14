import SwiftUI

@MainActor
struct TellerRootView: View {
    let api: TellerAPI
    let player: TellerPlayer
    let connection: TellerConnection
    let saveConnection: (TellerConnection) -> Void

    @Environment(\.scenePhase) private var scenePhase
    @State private var tab: Page
    @State private var showingPlayer = false
    @State private var libraryRefresh = 0
    @State private var showingHumanAudio = false

    private enum Page: Hashable { case create, discover, library, settings }

    init(api: TellerAPI, player: TellerPlayer, connection: TellerConnection, saveConnection: @escaping (TellerConnection) -> Void) {
        self.api = api
        self.player = player
        self.connection = connection
        self.saveConnection = saveConnection
        _tab = State(initialValue: connection.baseURL.host == "the-teller.invalid" ? .settings : .create)
    }

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack {
                CreateStoryView(api: api, open: open, playSample: playSample)
                    .safeAreaInset(edge: .bottom, spacing: 0) { miniPlayer }
                    .toolbar(.hidden, for: .navigationBar)
            }
            .tag(Page.create)
            .tabItem {
                Label("Create", systemImage: "book.closed")
                    .accessibilityIdentifier("create-tab")
            }

            NavigationStack {
                TellerDiscoverView(api: api, openBook: openDiscoveredBook)
                    .safeAreaInset(edge: .bottom, spacing: 0) { miniPlayer }
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Human narration", systemImage: "headphones") { showingHumanAudio = true }
                                .accessibilityIdentifier("discover-human")
                        }
                    }
            }
            .tag(Page.discover)
            .tabItem { Label("Discover", systemImage: "sparkle.magnifyingglass") }

            NavigationStack {
                TellerLibraryView(api: api, player: player, refresh: libraryRefresh, open: open)
                    .safeAreaInset(edge: .bottom, spacing: 0) { miniPlayer }
                    .toolbar(.hidden, for: .navigationBar)
            }
            .tag(Page.library)
            .tabItem {
                Label("Library", systemImage: "books.vertical")
                    .accessibilityIdentifier("library-tab")
            }

            NavigationStack {
                TellerConnectionView(connection: connection, save: saveConnection)
            }
            .tag(Page.settings)
            .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .tint(TellerTheme.accent)
        .fullScreenCover(isPresented: $showingPlayer) {
            TellerPlayerView(api: api, player: player, didUnlock: refreshLibrary)
        }
        .sheet(isPresented: $showingHumanAudio) {
            TellerHumanAudioView(api: api, pauseTeller: player.pause)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { player.checkpoint() }
        }
    }

    @ViewBuilder
    private var miniPlayer: some View {
        if let book = player.book {
            TellerMiniPlayer(book: book, player: player) { showingPlayer = true }
        }
    }

    private func refreshLibrary() {
        libraryRefresh += 1
    }

    private func open(_ book: Book) {
        player.open(book)
        showingPlayer = true
        refreshLibrary()
    }

    private func openDiscoveredBook(_ book: Book) {
        player.open(book, autoplay: true)
        showingPlayer = true
        refreshLibrary()
    }

    private func playSample(_ sample: Book) {
        if player.book?.id != sample.id {
            player.openSample(sample, lines: sample.lines, autoplay: true)
        } else if !player.isPlaying && !player.isLoading {
            player.play()
        }
        showingPlayer = true
    }
}
