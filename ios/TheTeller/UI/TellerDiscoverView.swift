import SwiftUI

@MainActor
struct TellerDiscoverView: View {
    let api: TellerAPI
    let openBook: (Book) -> Void

    @State private var query = ""
    @State private var response: CatalogResponse?
    @State private var reloadCount = 0
    @State private var openingTask: Task<Void, Never>?
    @State private var openingID: Int?
    @State private var openingError: OpeningError?
    @State private var pagingTask: Task<Void, Never>?
    @State private var pagingError: String?
    @FocusState private var searchFocused: Bool

    private struct CatalogRequest: Equatable {
        let query: String
        let revision: Int
    }

    private struct CatalogResponse {
        let request: CatalogRequest
        let result: Result<CatalogPage, Error>
    }

    private struct OpeningError {
        let bookID: Int
        let message: String
    }

    private var request: CatalogRequest {
        CatalogRequest(query: query.trimmingCharacters(in: .whitespacesAndNewlines), revision: reloadCount)
    }

    var body: some View {
        let currentRequest = request
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                heading
                searchField
                catalog(currentRequest)
            }
            .frame(maxWidth: 540)
            .padding(.horizontal, 24)
            .padding(.top, 26)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .foregroundStyle(TellerTheme.ink)
        .background(TellerTheme.paper.ignoresSafeArea())
        .task(id: currentRequest) { await load(currentRequest) }
        .onChange(of: currentRequest.query) { _, _ in cancelActions() }
        .onDisappear { cancelActions() }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Discover classics")
                .font(.system(.largeTitle, design: .serif, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Text("Listen to new renditions of public-domain books from Project Gutenberg.")
                .foregroundStyle(TellerTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(TellerTheme.muted)
                .accessibilityHidden(true)
            TextField("Search by title or author", text: $query)
                .focused($searchFocused)
                .submitLabel(.search)
                .onSubmit { searchFocused = false }
                .accessibilityIdentifier("discover-search")
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(TellerTheme.muted)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 4)
        .frame(minHeight: 50)
        .tellerCard()
    }

    @ViewBuilder
    private func catalog(_ currentRequest: CatalogRequest) -> some View {
        if let response, response.request == currentRequest {
            switch response.result {
            case .success(let page) where page.items.isEmpty:
                let browsing = currentRequest.query.isEmpty
                messageCard(browsing ? "No classics available" : "No books found",
                            detail: browsing ? "Check again in a moment." : "Try a different title or author.",
                            retry: browsing)
                    .accessibilityIdentifier("discover-empty")
            case .success(let page):
                LazyVStack(alignment: .leading, spacing: 12) {
                    Text(currentRequest.query.isEmpty ? "Featured books" : "Search results")
                        .font(.system(.title2, design: .serif, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    ForEach(page.items) { book in bookRow(book) }
                    if pagingTask != nil {
                        ProgressView("Loading more books…")
                    } else if let next = page.nextPage {
                        if let pagingError { Text(pagingError).font(.footnote).foregroundStyle(TellerTheme.accent) }
                        Button(pagingError == nil ? "Load more books" : "Try again") { loadMore(after: page, next: next) }
                            .frame(minHeight: 44)
                    }
                }
            case .failure(let error):
                messageCard("Couldn’t load the catalog", detail: error.localizedDescription, retry: true)
                    .accessibilityIdentifier("discover-error")
            }
        } else {
            ProgressView(currentRequest.query.isEmpty ? "Loading classics…" : "Searching for books…")
                .tint(TellerTheme.accent)
                .accessibilityIdentifier("discover-loading")
        }
    }

    private func messageCard(_ title: String, detail: String, retry: Bool) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.system(.title3, design: .serif, weight: .semibold))
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(TellerTheme.muted)
            if retry {
                Button("Try again") { reloadCount += 1 }
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 44)
                    .foregroundStyle(TellerTheme.accent)
                    .accessibilityIdentifier("discover-retry")
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tellerCard()
    }

    private func bookRow(_ book: CatalogBook) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { prepare(book) } label: {
                HStack(alignment: .top, spacing: 13) {
                    cover(book)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(book.title)
                            .font(.system(.title3, design: .serif, weight: .semibold))
                        if !book.authors.isEmpty {
                            Text(book.authors.joined(separator: ", "))
                                .font(.subheadline)
                                .foregroundStyle(TellerTheme.muted)
                        }
                        if !book.summary.isEmpty {
                            Text(book.summary)
                                .font(.footnote)
                                .foregroundStyle(TellerTheme.muted)
                                .lineLimit(3)
                        }
                        if openingID == book.id {
                            Text("Preparing audio…")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(TellerTheme.accent)
                        }
                    }
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if openingID == book.id {
                        ProgressView()
                            .tint(TellerTheme.accent)
                            .accessibilityHidden(true)
                    } else {
                        Image(systemName: "play.circle.fill")
                            .font(.title2)
                            .foregroundStyle(TellerTheme.accent)
                            .accessibilityHidden(true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(openingID != nil)
            .accessibilityHint("Prepares a spoken rendition and opens the player")
            .accessibilityIdentifier("discover-book-\(book.id)")

            if let openingError, openingError.bookID == book.id {
                VStack(alignment: .leading, spacing: 4) {
                    Text(openingError.message)
                        .font(.footnote)
                        .foregroundStyle(TellerTheme.accent)
                    Button("Try again") { prepare(book) }
                        .font(.subheadline.weight(.semibold))
                        .frame(minHeight: 44)
                        .foregroundStyle(TellerTheme.accent)
                        .accessibilityIdentifier("discover-book-retry")
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 3)
            }
        }
        .tellerCard()
    }

    private func cover(_ book: CatalogBook) -> some View {
        let size = CGSize(width: 54, height: 78)
        let url = URL(string: book.cover).flatMap { $0.scheme == "https" && $0.host != nil ? $0 : nil }
        return AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                TellerTheme.softAccent.overlay {
                    Image(systemName: "book.closed")
                        .font(.title3)
                        .foregroundStyle(TellerTheme.accent)
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)
    }

    private func load(_ pending: CatalogRequest) async {
        do {
            if !pending.query.isEmpty { try await Task.sleep(for: .milliseconds(300)) }
            let books = try await api.catalog(query: pending.query)
            guard !Task.isCancelled, request == pending else { return }
            response = CatalogResponse(request: pending, result: .success(books))
        } catch {
            guard !Task.isCancelled, request == pending else { return }
            response = CatalogResponse(request: pending, result: .failure(error))
        }
    }

    private func loadMore(after previous: CatalogPage, next: Int) {
        let pending = request
        pagingError = nil
        pagingTask = Task {
            do {
                let page = try await api.catalog(query: pending.query, page: next)
                guard !Task.isCancelled, request == pending else { return }
                let currentIDs = Set(previous.items.map(\.id))
                let items = previous.items + page.items.filter { !currentIDs.contains($0.id) }
                response = CatalogResponse(request: pending, result: .success(CatalogPage(items: items, nextPage: page.nextPage)))
            } catch {
                guard !Task.isCancelled, request == pending else { return }
                pagingError = error.localizedDescription
            }
            pagingTask = nil
        }
    }

    private func prepare(_ book: CatalogBook) {
        guard openingTask == nil else { return }
        let pending = request
        searchFocused = false
        openingID = book.id
        openingError = nil
        openingTask = Task {
            do {
                let rendition = try await api.openCatalog(id: book.id)
                guard !Task.isCancelled else { return }
                openingID = nil
                openingTask = nil
                guard request == pending else { return }
                openBook(rendition)
            } catch {
                guard !Task.isCancelled else { return }
                openingID = nil
                openingTask = nil
                guard request == pending else { return }
                openingError = OpeningError(bookID: book.id, message: error.localizedDescription)
            }
        }
    }

    private func cancelActions() {
        openingTask?.cancel()
        openingTask = nil
        openingID = nil
        openingError = nil
        pagingTask?.cancel()
        pagingTask = nil
        pagingError = nil
    }
}
