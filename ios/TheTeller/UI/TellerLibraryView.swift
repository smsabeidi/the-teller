import SwiftUI

@MainActor
struct TellerLibraryView: View {
    let api: TellerAPI
    let player: TellerPlayer
    let refresh: Int
    let open: (Book) -> Void

    @State private var books: [LibraryBook] = []
    @State private var isLoading = false
    @State private var openingID: String?
    @State private var removingID: String?
    @State private var pendingDeletion: LibraryBook?
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Your library")
                        .font(.system(.largeTitle, design: .serif, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text("Pick up where your story left off.")
                        .foregroundStyle(TellerTheme.muted)
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.circle")
                        .font(.subheadline)
                        .foregroundStyle(TellerTheme.accent)
                        .accessibilityIdentifier("library-error")
                    Button("Try again") { Task { await load() } }
                        .font(.subheadline.weight(.semibold))
                        .accessibilityIdentifier("library-refresh")
                }

                if isLoading && books.isEmpty {
                    ProgressView("Loading your library…")
                        .accessibilityIdentifier("library-loading")
                } else if books.isEmpty && errorMessage == nil {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: "books.vertical")
                            .font(.title2)
                            .foregroundStyle(TellerTheme.accent)
                            .accessibilityHidden(true)
                        Text("No stories yet")
                            .font(.system(.title3, design: .serif, weight: .semibold))
                        Text("Create a preview and it will appear here.")
                            .font(.subheadline)
                            .foregroundStyle(TellerTheme.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                    .tellerCard()
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("library-empty")
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(books) { book in
                            row(book)
                        }
                    }
                }
            }
            .frame(maxWidth: 540)
            .padding(.horizontal, 24)
            .padding(.top, 28)
            .padding(.bottom, 22)
            .frame(maxWidth: .infinity)
        }
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
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            books = try await api.listBooks()
            errorMessage = nil
        } catch {
            if !Task.isCancelled { errorMessage = error.localizedDescription }
        }
    }

    private func openBook(_ book: LibraryBook) async {
        guard openingID == nil else { return }
        openingID = book.id
        errorMessage = nil
        defer { openingID = nil }
        do {
            open(try await api.book(id: book.id))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func remove(_ book: LibraryBook) async {
        removingID = book.id
        errorMessage = nil
        defer { removingID = nil }
        do {
            try await api.deleteBook(id: book.id)
            player.removeProgress(for: book.id)
            books.removeAll { $0.id == book.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
