import SwiftUI
import UniformTypeIdentifiers

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
        if player.book?.id != book.id {
            player.open(book)
        }
        showingPlayer = true
        refreshLibrary()
    }

    private func playSample() {
        let sample = TellerSample.book
        if player.book?.id != sample.id {
            player.openSample(sample, lines: sample.lines, autoplay: true)
        } else if !player.isPlaying && !player.isLoading {
            player.play()
        }
        showingPlayer = true
    }
}

enum TellerSample {
    static let book: Book = {
        let lines = [
            StoryLine(index: 0, speaker: "Narrator", text: "At the end of the pier, the lantern was burning for the first time in twelve years."),
            StoryLine(index: 1, speaker: "Nora", text: "You saw who lit it?", emotion: "whisper"),
            StoryLine(index: 2, speaker: "Elias", text: "No. But someone has been leaving my name in the keeper’s log.", emotion: "scared"),
            StoryLine(index: 3, speaker: "Narrator", text: "Nora reached for the door. From the other side, someone turned the handle first.")
        ]
        return Book(
            id: "teller-sample-lantern-keeper",
            title: "The Lantern Keeper",
            author: "The Teller",
            cast: [
                "Narrator": CastMember(voice: "narrator_f", gender: "female", lines: 2),
                "Nora": CastMember(voice: "f1", gender: "female", lines: 1),
                "Elias": CastMember(voice: "m1", gender: "male", lines: 1)
            ],
            totalLines: lines.count,
            unlocked: true,
            previewLines: lines.count,
            lines: lines
        )
    }()
}
