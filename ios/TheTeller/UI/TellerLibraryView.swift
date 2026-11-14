import SwiftUI

@MainActor
struct TellerLibraryView: View {
    let api: TellerAPI
    let player: TellerPlayer
    let refresh: Int
    let open: (Book) -> Void

    @State private var books: [LibraryBook] = []
    @State private var loadID: UUID?
    @State private var deletedIDs: Set<String> = []
    @State private var openingID: String?
    @State private var removingID: String?
    @State private var pendingDeletion: LibraryBook?
    @State private var query = ""
    @State private var failure: Failure?

    private struct Failure {
        enum Action {
            case refresh
            case open(LibraryBook)
            case delete(LibraryBook)
        }

        let message: String
        let action: Action
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var matchingBooks: [LibraryBook] {
        let search = trimmedQuery
        guard !search.isEmpty else { return books }
        return books.filter { $0.title.localizedStandardContains(search) || $0.author.localizedStandardContains(search) }
    }

    private var latestListening: (book: LibraryBook, progress: TellerPlayer.SavedProgress)? {
        books.compactMap { book -> (book: LibraryBook, progress: TellerPlayer.SavedProgress)? in
            guard let progress = player.savedProgress(for: book.id), !book.unlocked || !progress.isFinished else {
                return nil
            }
            return (book, progress)
        }.max { first, second in
            (first.progress.updatedAt ?? first.book.createdAt) < (second.progress.updatedAt ?? second.book.createdAt)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Your library")
                    .font(.system(.largeTitle, design: .serif, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)

                if let failure { errorCard(failure) }

                if loadID != nil && books.isEmpty {
                    ProgressView("Loading your library…")
                        .accessibilityIdentifier("library-loading")
                } else {
                    libraryContent
                }
            }
            .frame(maxWidth: 540)
            .padding(.horizontal, 24)
            .padding(.top, 28)
            .padding(.bottom, 22)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .foregroundStyle(TellerTheme.ink)
        .background(TellerTheme.paper.ignoresSafeArea())
        .refreshable { await load() }
        .task(id: refresh) { await load() }
        .confirmationDialog(
            "Remove this audiobook?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { book in
            Button("Delete audiobook", role: .destructive) {
                pendingDeletion = nil
                Task { await remove(book) }
            }
            .accessibilityIdentifier("confirm-delete")
        } message: { book in
            Text("“\(book.title)” and its listening progress will be removed from your library.")
        }
    }

    @ViewBuilder
    private var libraryContent: some View {
        if books.isEmpty {
            if failure == nil {
                emptyCard(title: "No stories yet", message: "Create a preview to add a story to your library.", icon: "books.vertical")
                    .accessibilityIdentifier("library-empty")
            }
        } else {
            if let listening = latestListening, trimmedQuery.isEmpty {
                continueShelf(listening.book, progress: listening.progress)
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("All audiobooks")
                    .font(.system(.title2, design: .serif, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                if books.count > 1 || !query.isEmpty { searchField }
                if matchingBooks.isEmpty {
                    emptyCard(title: "No matches", message: "Try a different title or author.", icon: "magnifyingglass")
                        .accessibilityIdentifier("library-search-empty")
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(matchingBooks) { book in row(book) }
                    }
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(TellerTheme.muted)
                .accessibilityHidden(true)
            TextField("Search by title or author", text: $query)
                .submitLabel(.search)
                .accessibilityIdentifier("library-search")
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(TellerTheme.muted)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear library search")
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 4)
        .frame(minHeight: 48)
        .tellerCard()
    }

    private func continueShelf(_ book: LibraryBook, progress: TellerPlayer.SavedProgress) -> some View {
        let position = progress.isPreviewFinished && !book.unlocked
            ? "Preview finished"
            : "Line \(progress.lineIndex + 1)"

        return VStack(alignment: .leading, spacing: 12) {
            Text("Continue listening")
                .font(.system(.title2, design: .serif, weight: .semibold))
                .accessibilityAddTraits(.isHeader)

            Button {
                Task { await openBook(book) }
            } label: {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: "headphones")
                            .font(.title2.weight(.medium))
                            .foregroundStyle(TellerTheme.accent)
                            .frame(width: 52, height: 58)
                            .background(TellerTheme.card, in: RoundedRectangle(cornerRadius: 12))
                            .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 5) {
                            Text(book.title)
                                .font(.system(.title3, design: .serif, weight: .semibold))
                            if !book.author.isEmpty {
                                Text(book.author)
                                    .font(.subheadline)
                                    .foregroundStyle(TellerTheme.muted)
                            }
                            Text(position)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(TellerTheme.muted)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if openingID == book.id {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.right.circle.fill")
                                .font(.title2)
                                .foregroundStyle(TellerTheme.accent)
                        }
                    }

                    if let fraction = progress.fraction {
                        ProgressView(value: fraction)
                            .tint(TellerTheme.accent)
                            .accessibilityHidden(true)
                    }
                }
                .padding(16)
                .background(TellerTheme.softAccent, in: RoundedRectangle(cornerRadius: 20))
                .contentShape(RoundedRectangle(cornerRadius: 20))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Continue listening to \(book.title)")
            .accessibilityValue(position)
            .accessibilityHint("Opens the player at your saved position")
            .accessibilityIdentifier("library-continue")
            .disabled(openingID != nil || removingID == book.id)
        }
    }

    private func emptyCard(title: String, message: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(TellerTheme.accent)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(.title3, design: .serif, weight: .semibold))
            Text(message)
                .font(.subheadline)
                .foregroundStyle(TellerTheme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .tellerCard()
        .accessibilityElement(children: .combine)
    }

    private func errorCard(_ failure: Failure) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(failure.message, systemImage: "exclamationmark.circle")
                .font(.subheadline)
                .foregroundStyle(TellerTheme.accent)
                .accessibilityIdentifier("library-error")
            Button("Try again") {
                switch failure.action {
                case .refresh: Task { await load() }
                case let .open(book): Task { await openBook(book) }
                case let .delete(book): pendingDeletion = book
                }
            }
            .font(.subheadline.weight(.semibold))
            .accessibilityIdentifier("library-refresh")
        }
    }

    private func row(_ book: LibraryBook) -> some View {
        HStack(spacing: 4) {
            Button {
                Task { await openBook(book) }
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: book.unlocked ? "book" : "book.pages")
                        .foregroundStyle(TellerTheme.accent)
                        .frame(width: 44, height: 52)
                        .background(TellerTheme.softAccent, in: RoundedRectangle(cornerRadius: 9))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(book.title)
                            .font(.system(.headline, design: .serif))
                        if !book.author.isEmpty {
                            Text(book.author)
                                .font(.subheadline)
                                .foregroundStyle(TellerTheme.muted)
                        }
                        Text(book.unlocked ? "Full audiobook" : "Free preview")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(TellerTheme.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if openingID == book.id {
                        ProgressView()
                            .accessibilityLabel("Opening story")
                    }
                }
                .padding(12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("library-book-" + book.id)
            .accessibilityHint("Opens the player")
            .disabled(openingID != nil || removingID == book.id)

            Button(role: .destructive) {
                pendingDeletion = book
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(TellerTheme.muted)
                    .frame(width: 44, height: 48)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 4)
            .accessibilityLabel("Delete \(book.title)")
            .accessibilityIdentifier("library-delete-" + book.id)
            .disabled(removingID != nil)
        }
        .tellerCard()
    }

    private func load() async {
        let id = UUID()
        loadID = id
        defer {
            if loadID == id { loadID = nil }
        }
        do {
            let updated = try await api.listBooks()
            guard loadID == id, !Task.isCancelled else { return }
            books = updated.filter { !deletedIDs.contains($0.id) }
            if case .refresh? = failure?.action { failure = nil }
        } catch {
            if loadID == id, !Task.isCancelled {
                failure = Failure(message: error.localizedDescription, action: .refresh)
            }
        }
    }

    private func openBook(_ book: LibraryBook) async {
        guard openingID == nil else { return }
        openingID = book.id
        failure = nil
        defer { openingID = nil }
        do {
            open(try await api.book(id: book.id))
        } catch {
            if !Task.isCancelled { failure = Failure(message: error.localizedDescription, action: .open(book)) }
        }
    }

    private func remove(_ book: LibraryBook) async {
        guard removingID == nil else { return }
        removingID = book.id
        failure = nil
        defer { removingID = nil }
        do {
            try await api.deleteBook(id: book.id)
            deletedIDs.insert(book.id)
            player.removeProgress(for: book.id)
            books.removeAll { $0.id == book.id }
            if books.isEmpty { query = "" }
        } catch {
            if !Task.isCancelled { failure = Failure(message: error.localizedDescription, action: .delete(book)) }
        }
    }
}
