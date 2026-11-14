import SwiftUI

@MainActor
struct TellerMiniPlayer: View {
    let book: Book
    let player: TellerPlayer
    let expand: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: expand) {
                HStack(spacing: 11) {
                    Image(systemName: "waveform")
                        .foregroundStyle(TellerTheme.accent)
                        .frame(width: 39, height: 39)
                        .background(TellerTheme.softAccent, in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(book.title)
                            .font(.system(.subheadline, design: .serif, weight: .semibold))
                            .lineLimit(1)
                        Text(player.isPlaying ? "Now playing" : "Open player")
                            .font(.caption)
                            .foregroundStyle(TellerTheme.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open player, \(book.title)")
            .accessibilityIdentifier("mini-player")

            Button {
                player.toggle()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 46, height: 48)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            .accessibilityIdentifier("mini-play-toggle")
        }
        .padding(.horizontal, 14)
        .foregroundStyle(TellerTheme.ink)
        .tellerCard()
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(TellerTheme.paper)
    }
}

@MainActor
struct TellerPlayerView: View {
    let api: TellerAPI
    let player: TellerPlayer
    let didUnlock: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var unlocking = false
    @State private var continuationError: String?
    @State private var draftLine: Double?
    @State private var isScrubbing = false
    @State private var showingChapters = false
    @State private var showingLineJump = false
    @State private var jumpLine = ""
    @State private var pendingScrollLine: Int?
    @AccessibilityFocusState private var titleFocused: Bool

    private let rates: [Double] = [0.75, 1, 1.25, 1.5, 1.75, 2]

    var body: some View {
        if let book = player.book {
            VStack(spacing: 0) {
                heading(book)
                transcript
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        controls(book)
                    }
            }
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(TellerTheme.ink)
            .tint(TellerTheme.accent)
            .background(TellerTheme.paper.ignoresSafeArea())
            .task { titleFocused = true }
            .sheet(isPresented: $showingChapters) {
                chapterPicker(for: book)
            }
            .sheet(isPresented: $showingLineJump) {
                linePicker
            }
        }
    }

    private var jumpIndex: Int? {
        guard let value = Int(jumpLine.trimmingCharacters(in: .whitespacesAndNewlines)),
              value > 0, value <= player.availableLines else { return nil }
        return value - 1
    }

    private var linePicker: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Line number", text: $jumpLine)
                        .keyboardType(.numberPad)
                        .accessibilityIdentifier("player-jump-line")
                        .listRowBackground(TellerTheme.card)
                } footer: {
                    Text("Enter a line from 1 to \(player.availableLines).")
                }
            }
            .scrollContentBackground(.hidden)
            .background(TellerTheme.paper)
            .foregroundStyle(TellerTheme.ink)
            .navigationTitle("Jump to a line")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingLineJump = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Jump") {
                        guard let jumpIndex else { return }
                        player.seek(to: jumpIndex)
                        showingLineJump = false
                    }
                    .disabled(jumpIndex == nil)
                    .accessibilityIdentifier("player-jump-confirm")
                }
            }
        }
        .tint(TellerTheme.accent)
        .presentationDetents([.medium, .large])
    }

    private func heading(_ book: Book) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                player.checkpoint()
                dismiss()
            } label: {
                Label("Minimize", systemImage: "chevron.down")
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(TellerTheme.accent)
            .accessibilityIdentifier("player-close")

            Text(book.title)
                .font(.system(.title, design: .serif, weight: .semibold))
                .lineLimit(3)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("player-title")
                .accessibilityFocused($titleFocused)
            if !book.author.isEmpty {
                Text(book.author)
                    .font(.subheadline)
                    .foregroundStyle(TellerTheme.muted)
            }
            if let source = book.sourceURL, source.scheme == "https", source.host == "www.gutenberg.org" {
                Link("Project Gutenberg edition", destination: source)
                    .font(.footnote)
                    .foregroundStyle(TellerTheme.accent)
            }
            if let chapter = currentChapter(in: book), availableChapters(for: book).count > 1 {
                Button {
                    showingChapters = true
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "list.bullet.rectangle")
                        Text(chapter.title)
                            .multilineTextAlignment(.leading)
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.semibold))
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 10)
                    .frame(minHeight: 44)
                    .background(TellerTheme.softAccent, in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(TellerTheme.accent)
                .accessibilityLabel("Chapters")
                .accessibilityValue(chapter.title)
                .accessibilityIdentifier("player-chapters")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
    }

    private func availableChapters(for book: Book) -> [Chapter] {
        book.chapters.filter { $0.start >= 0 && $0.start < player.availableLines }
    }

    private func currentChapter(in book: Book) -> Chapter? {
        availableChapters(for: book).last { $0.start <= player.lineIndex }
    }

    private func chapterPicker(for book: Book) -> some View {
        NavigationStack {
            List(availableChapters(for: book)) { chapter in
                let selected = chapter == currentChapter(in: book)
                Button {
                    player.seek(to: chapter.start)
                    showingChapters = false
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(chapter.title)
                                .font(.system(.body, design: .serif, weight: .semibold))
                            Text("Line \(chapter.start + 1)")
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(TellerTheme.muted)
                        }
                        Spacer()
                        if selected {
                            Image(systemName: "checkmark")
                                .foregroundStyle(TellerTheme.accent)
                                .accessibilityHidden(true)
                        }
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("player-chapter-\(chapter.start)")
                .listRowBackground(TellerTheme.card)
            }
            .scrollContentBackground(.hidden)
            .background(TellerTheme.paper)
            .foregroundStyle(TellerTheme.ink)
            .navigationTitle("Chapters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showingChapters = false }
                }
            }
        }
        .tint(TellerTheme.accent)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if player.hasEarlierTranscript {
                        pagingButton("Earlier lines", description: "Load earlier lines", action: player.loadEarlierLines)
                    }
                    ForEach(player.visibleLines) { line in
                        transcriptLine(line).id(line.index)
                    }
                    if player.hasLaterTranscript {
                        pagingButton("More lines", description: "Load more lines", action: player.loadLaterLines)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 6)
            }
            .onChange(of: player.lineIndex, initial: true) { _, index in
                if player.visibleLines.contains(where: { $0.index == index }) {
                    pendingScrollLine = nil
                    proxy.scrollTo(index, anchor: .center)
                } else {
                    pendingScrollLine = index
                }
            }
            .onChange(of: player.visibleLines) { _, lines in
                guard let index = pendingScrollLine, lines.contains(where: { $0.index == index }) else { return }
                pendingScrollLine = nil
                proxy.scrollTo(index, anchor: .center)
            }
        }
    }

    private func pagingButton(_ title: String, description: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if player.isLoadingTranscript {
                ProgressView()
                    .accessibilityLabel("Loading transcript")
            } else {
                Text(title)
                    .font(.subheadline.weight(.semibold))
            }
        }
        .disabled(player.isLoadingTranscript)
        .frame(minHeight: 44)
        .accessibilityLabel(description)
    }

    private func transcriptLine(_ line: StoryLine) -> some View {
        let current = line.index == player.lineIndex
        return Button {
            player.seek(to: line.index)
            player.play()
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                Label {
                    Text(line.speaker)
                } icon: {
                    Image(systemName: current ? "waveform" : "person")
                        .accessibilityHidden(true)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(current ? TellerTheme.accent : TellerTheme.muted)
                Text(line.text)
                    .font(.system(.body, design: .serif))
                    .foregroundStyle(TellerTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(current ? TellerTheme.softAccent : TellerTheme.card, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(current ? .isSelected : [])
        .accessibilityIdentifier("transcript-line-\(line.index)")
        .accessibilityHint("Play from this line")
    }

    private func controls(_ book: Book) -> some View {
        VStack(spacing: 6) {
            if let message = continuationError ?? player.errorMessage {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(TellerTheme.accent)
                    .accessibilityIdentifier("player-status")
            } else if player.isLoading {
                ProgressView("Loading audio…")
                    .font(.footnote)
                    .accessibilityIdentifier("player-status")
            } else if player.hasReachedPreviewEnd {
                Text("End of free preview")
                    .font(.footnote.weight(.semibold))
                    .accessibilityIdentifier("player-status")
            } else if player.isFinished {
                Text("End of audiobook")
                    .font(.footnote.weight(.semibold))
                    .accessibilityIdentifier("player-status")
            }

            if player.availableLines > 0 {
                seekControl(book)
                transport
            }
            if !book.unlocked {
                Button {
                    Task { await continueBook(book) }
                } label: {
                    if unlocking {
                        ProgressView()
                            .accessibilityLabel("Unlocking audiobook")
                    } else {
                        Text("Continue listening")
                    }
                }
                .buttonStyle(TellerPrimaryButtonStyle())
                .accessibilityIdentifier("continue-book")
                .disabled(unlocking)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(TellerTheme.paper.shadow(color: TellerTheme.ink.opacity(0.09), radius: 10, y: -3))
    }

    private func seekControl(_ book: Book) -> some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    positionButton(book)
                    Spacer(minLength: 0)
                    speedPicker
                }
                VStack(alignment: .leading, spacing: 2) {
                    positionButton(book)
                    speedPicker
                }
            }

            if player.availableLines > 1 {
                Slider(
                    value: Binding(
                        get: { draftLine ?? Double(player.lineIndex) },
                        set: { value in
                            if isScrubbing { draftLine = value }
                            else { player.seek(to: Int(value)) }
                        }
                    ),
                    in: 0...Double(player.availableLines - 1),
                    step: 1
                ) { editing in
                    isScrubbing = editing
                    if !editing, let draftLine {
                        player.seek(to: Int(draftLine))
                        self.draftLine = nil
                    }
                }
                .accessibilityLabel("Seek to a line")
                .accessibilityValue("Line \(Int(draftLine ?? Double(player.lineIndex)) + 1) of \(player.availableLines)")
                .accessibilityIdentifier("player-seek")
            }
        }
    }

    private func positionButton(_ book: Book) -> some View {
        let position = "Line \(Int(draftLine ?? Double(player.lineIndex)) + 1) of \(player.availableLines)"
        let canJump = player.availableLines > 1
        return Button {
            jumpLine = ""
            showingLineJump = true
        } label: {
            HStack(spacing: 7) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(position)
                        .font(.footnote.weight(.semibold).monospacedDigit())
                    if canJump || !book.unlocked {
                        Text(canJump ? (book.unlocked ? "Jump to line" : "Free preview · Jump to line") : "Free preview")
                            .font(.caption)
                            .foregroundStyle(TellerTheme.muted)
                    }
                }
                if canJump {
                    Image(systemName: "number.square")
                        .font(.caption.weight(.medium))
                        .accessibilityHidden(true)
                }
            }
            .multilineTextAlignment(.leading)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(TellerTheme.accent)
        .disabled(!canJump)
        .accessibilityLabel(book.unlocked ? position : position + ", free preview")
        .accessibilityHint(canJump ? "Jump to a line" : "")
        .accessibilityIdentifier("player-position")
    }

    private var speedPicker: some View {
        Menu {
            Picker("Playback speed", selection: Binding(get: { player.rate }, set: { player.setRate($0) })) {
                ForEach(rates, id: \.self) { rate in
                    Text(rateLabel(rate)).tag(rate)
                }
            }
        } label: {
            Text(rateLabel(player.rate))
                .font(.footnote.weight(.semibold).monospacedDigit())
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(TellerTheme.softAccent, in: RoundedRectangle(cornerRadius: 8))
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .tint(TellerTheme.accent)
        .accessibilityLabel("Playback speed")
        .accessibilityValue(rateLabel(player.rate))
        .accessibilityIdentifier("player-speed")
    }

    private func rateLabel(_ rate: Double) -> String {
        rate.formatted(.number.precision(.fractionLength(0...2))) + "×"
    }

    private var transport: some View {
        HStack(spacing: 16) {
            Spacer(minLength: 0)

            Button {
                player.step(-1)
            } label: {
                Image(systemName: "backward.end.fill")
                    .frame(width: 46, height: 46)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Previous line")
            .accessibilityIdentifier("player-previous")
            .disabled(player.lineIndex <= 0)

            Button {
                player.toggle()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
                    .foregroundStyle(TellerTheme.onAccent)
                    .frame(width: 58, height: 58)
                    .background(TellerTheme.accent, in: Circle())
            }
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            .accessibilityIdentifier("player-play-toggle")

            Button {
                player.step(1)
            } label: {
                Image(systemName: "forward.end.fill")
                    .frame(width: 46, height: 46)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Next line")
            .accessibilityIdentifier("player-next")
            .disabled(player.lineIndex + 1 >= player.availableLines)

            Spacer(minLength: 0)
        }
        .buttonStyle(.plain)
    }

    private func continueBook(_ book: Book) async {
        unlocking = true
        continuationError = nil
        defer { unlocking = false }
        do {
            let updated = try await api.continueBook(id: book.id)
            guard player.book?.id == book.id else { return }
            player.reload(updated)
            if !player.isPlaying { player.play() }
            didUnlock()
        } catch {
            continuationError = error.localizedDescription
        }
    }
}
