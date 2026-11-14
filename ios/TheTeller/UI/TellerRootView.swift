import SwiftUI

@MainActor
struct TellerRootView: View {
    let api: TellerAPI
    let player: TellerPlayer

    @Environment(\.scenePhase) private var scenePhase
    @State private var tab: Page = .create
    @State private var showingPlayer = false
    @State private var libraryRefresh = 0

    private enum Page: Hashable { case create, library }

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
                TellerLibraryView(api: api, player: player, refresh: libraryRefresh, open: open)
                    .safeAreaInset(edge: .bottom, spacing: 0) { miniPlayer }
                    .toolbar(.hidden, for: .navigationBar)
            }
            .tag(Page.library)
            .tabItem {
                Label("Library", systemImage: "books.vertical")
                    .accessibilityIdentifier("library-tab")
            }
        }
        .tint(TellerTheme.accent)
        .fullScreenCover(isPresented: $showingPlayer) {
            TellerPlayerView(api: api, player: player, didUnlock: refreshLibrary)
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

    private func playSample(_ sample: Book) {
        if player.book?.id != sample.id {
            player.openSample(sample, lines: sample.lines, autoplay: true)
        } else if !player.isPlaying && !player.isLoading {
            player.play()
        }
        showingPlayer = true
    }
}
