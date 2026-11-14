import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct CreateStoryView: View {
    let api: TellerAPI
    let open: (Book) -> Void
    let playSample: (Book) -> Void

    @State private var mode: Mode = .link
    @State private var link = ""
    @State private var story = ""
    @State private var selectedFile: URL?
    @State private var showFilePicker = false
    @State private var discardDraft = false
    @State private var importTask: Task<Void, Never>?
    @State private var attempt: UUID?
    @State private var uploadFraction: Double?
    @State private var importError: String?
    @FocusState private var focused: Mode?

    private enum Mode: String, CaseIterable, Identifiable {
        case link, file, paste

        var id: String { rawValue }

        var title: String {
            switch self {
            case .link: "Link"
            case .file: "Files"
            case .paste: "Paste"
            }
        }

        var icon: String {
            switch self {
            case .link: "link"
            case .file: "doc"
            case .paste: "text.alignleft"
            }
        }
    }

    private var allowedTypes: [UTType] {
        [.pdf, .plainText] + ["epub", "docx"].compactMap { UTType(filenameExtension: $0) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                heading
                form
                sample
            }
            .frame(maxWidth: 540)
            .padding(.horizontal, 24)
            .padding(.top, 26)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(TellerTheme.paper.ignoresSafeArea())
        .foregroundStyle(TellerTheme.ink)
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: allowedTypes, allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let file = urls.first {
                    selectedFile = file
                    importError = nil
                }
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError { importError = error.localizedDescription }
            }
        }
        .confirmationDialog("Discard this draft?", isPresented: $discardDraft, titleVisibility: .visible) {
            Button("Discard", role: .destructive) {
                story = ""
                clearMessage()
            }
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("THE TELLER", systemImage: "waveform")
                .font(.caption.weight(.semibold))
                .tracking(2.2)
                .foregroundStyle(TellerTheme.accent)
                .accessibilityLabel("The Teller")
            Text("Every story has a voice.")
                .font(.system(.largeTitle, design: .serif, weight: .semibold))
                .tracking(-1)
                .accessibilityAddTraits(.isHeader)
            Text("Bring a story to life with a narrator and a cast of distinct voices.")
                .font(.body)
                .foregroundStyle(TellerTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Bring a story")
                .font(.system(.title2, design: .serif, weight: .semibold))
                .accessibilityAddTraits(.isHeader)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { sourceOptions }
                VStack(spacing: 6) { sourceOptions }
            }

            Group {
                switch mode {
                case .link: linkEntry
                case .file: fileEntry
                case .paste: textEntry
                }
            }
            .disabled(importTask != nil)

            Button {
                createPreview()
            } label: {
                Label("Create free preview", systemImage: "arrow.right")
            }
            .buttonStyle(TellerPrimaryButtonStyle())
            .accessibilityIdentifier("create-preview")
            .disabled(source == nil || importTask != nil)

            importStatus
        }
        .padding(18)
        .tellerCard()
    }

    private var sourceOptions: some View {
        ForEach(Mode.allCases) { option in
            Button {
                focused = nil
                mode = option
                clearMessage()
            } label: {
                Label(option.title, systemImage: option.icon)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(mode == option ? TellerTheme.softAccent : TellerTheme.paper, in: RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(mode == option ? TellerTheme.accent : TellerTheme.ink)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(mode == option ? .isSelected : [])
            .accessibilityIdentifier("source-" + option.rawValue)
            .disabled(importTask != nil)
        }
    }

    private var linkEntry: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Public story link")
                .font(.subheadline.weight(.semibold))
                .accessibilityHidden(true)
            TextField("https://…", text: $link)
                .accessibilityLabel("Public story link")
                .accessibilityIdentifier("story-link")
                .textContentType(.URL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .focused($focused, equals: .link)
                .onSubmit(createPreview)
                .padding(12)
                .background(TellerTheme.paper, in: RoundedRectangle(cornerRadius: 10))
            Text("For public web stories. If a site restricts access, try Files or Paste.")
                .font(.footnote)
                .foregroundStyle(TellerTheme.muted)
        }
    }

    private var fileEntry: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                showFilePicker = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "doc.badge.plus")
                        .font(.title3)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(selectedFile?.lastPathComponent ?? "Choose a story file")
                            .font(.subheadline.weight(.semibold))
                            .accessibilityIdentifier("selected-file")
                        Text("EPUB, PDF, DOCX, TXT · up to 100 MB")
                            .font(.footnote)
                            .foregroundStyle(TellerTheme.muted)
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(TellerTheme.paper, in: RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("pick-file")
            .accessibilityHint("Opens Files")
        }
    }

    private var textEntry: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack { pasteActions }
                VStack(alignment: .leading) { pasteActions }
            }
            ZStack(alignment: .topLeading) {
                if story.isEmpty {
                    Text("Paste your story here…")
                        .foregroundStyle(TellerTheme.muted)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 5)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                TextEditor(text: $story)
                    .scrollContentBackground(.hidden)
                    .accessibilityLabel("Story text")
                    .accessibilityIdentifier("story-text")
                    .focused($focused, equals: .paste)
                    .frame(minHeight: 130, maxHeight: 210)
            }
            .padding(8)
            .background(TellerTheme.paper, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var pasteActions: some View {
        Group {
            Text("Story text")
                .font(.subheadline.weight(.semibold))
                .accessibilityHidden(true)
            PasteButton(payloadType: String.self) { values in
                guard let value = values.first else { return }
                if story.isEmpty {
                    story = value
                } else {
                    story += "\n\n" + value
                }
                clearMessage()
            }
            .buttonBorderShape(.capsule)
            .tint(TellerTheme.accent)
            .accessibilityIdentifier("paste-from-clipboard")
            if !story.isEmpty {
                Button("Discard") { discardDraft = true }
                    .font(.subheadline)
                    .foregroundStyle(TellerTheme.accent)
                    .padding(.vertical, 8)
                    .accessibilityIdentifier("discard-draft")
            }
        }
    }

    @ViewBuilder
    private var importStatus: some View {
        if importTask != nil {
            VStack(alignment: .leading, spacing: 8) {
                if let progress = uploadFraction, progress < 1 {
                    ProgressView(value: progress)
                        .tint(TellerTheme.accent)
                }
                Text(importMessage)
                    .font(.footnote.weight(.semibold))
                    .accessibilityIdentifier("import-status")
                Button("Cancel") { cancelImport() }
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 44, alignment: .leading)
                    .accessibilityIdentifier("cancel-import")
            }
            .foregroundStyle(TellerTheme.accent)
        } else if let error = importError {
            Label(error, systemImage: "exclamationmark.circle")
                .font(.footnote)
                .foregroundStyle(TellerTheme.accent)
                .accessibilityIdentifier("import-status")
        } else {
            Text("No account required. Your story is sent to The Teller to prepare the audiobook.")
                .font(.footnote)
                .foregroundStyle(TellerTheme.muted)
        }
    }

    private var sample: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Listen first")
                .font(.system(.title2, design: .serif, weight: .semibold))
                .accessibilityAddTraits(.isHeader)

            ForEach(TellerSample.all, id: \.book.id) { entry in
                Button {
                    playSample(entry.book)
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: entry.symbol)
                            .font(.title2)
                            .foregroundStyle(TellerTheme.accent)
                            .frame(width: 56, height: 56)
                            .background(TellerTheme.softAccent, in: RoundedRectangle(cornerRadius: 12))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.book.title)
                                .font(.system(.headline, design: .serif))
                            Text("\(entry.genre) · \(entry.book.cast.count) voices")
                                .font(.footnote)
                                .foregroundStyle(TellerTheme.muted)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "play.circle")
                            .font(.title2)
                            .foregroundStyle(TellerTheme.accent)
                            .accessibilityHidden(true)
                    }
                    .padding(14)
                    .tellerCard()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(entry.book.id == TellerSample.all.first?.book.id ? "play-sample" : entry.book.id)
                .accessibilityLabel("Play sample, " + entry.book.title)
            }
        }
    }

    private var source: StorySource? {
        switch mode {
        case .link:
            let value = link.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : .link(value)
        case .file:
            return selectedFile.map(StorySource.file)
        case .paste:
            return story.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : .text(story)
        }
    }

    private var importMessage: String {
        guard let progress = uploadFraction else {
            return mode == .file ? "Preparing file…" : "Submitting story…"
        }
        if progress < 1 {
            return mode == .file ? "Uploading file… \(Int(progress * 100))%" : "Submitting story…"
        }
        return "Preparing your preview…"
    }

    private func createPreview() {
        guard let source, importTask == nil else { return }
        focused = nil
        clearMessage()
        let id = UUID()
        attempt = id
        importTask = Task {
            do {
                let book = try await api.importStory(source) { fraction in
                    Task { @MainActor in
                        guard self.attempt == id else { return }
                        self.uploadFraction = max(self.uploadFraction ?? 0, fraction)
                    }
                }
                guard !Task.isCancelled, attempt == id else { return }
                importTask = nil
                attempt = nil
                switch source {
                case .link: link = ""
                case .file: selectedFile = nil
                case .text: story = ""
                }
                open(book)
            } catch {
                guard attempt == id else { return }
                importTask = nil
                attempt = nil
                importError = error.localizedDescription
                UIAccessibility.post(notification: .announcement, argument: error.localizedDescription)
            }
        }
    }

    private func cancelImport() {
        attempt = nil
        importTask?.cancel()
        importTask = nil
        importError = "Import canceled. Your source is still here if you want to try again."
    }

    private func clearMessage() {
        importError = nil
        uploadFraction = nil
    }
}
