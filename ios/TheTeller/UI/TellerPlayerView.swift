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
    @AccessibilityFocusState private var titleFocused: Bool

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
            .background(TellerTheme.paper.ignoresSafeArea())
            .task { titleFocused = true }
        }
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
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
                proxy.scrollTo(index, anchor: .center)
            }
            .onChange(of: player.visibleLines.first?.index) { _, _ in
                if player.isPlaying { proxy.scrollTo(player.lineIndex, anchor: .center) }
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
                seekControl
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

    private var seekControl: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Line \(min(player.lineIndex + 1, player.availableLines)) of \(player.availableLines)")
                Spacer()
                if player.book?.unlocked == false { Text("Free preview") }
            }
            .font(.footnote.monospacedDigit())
            .foregroundStyle(TellerTheme.muted)

            if player.availableLines > 1 {
                Slider(
                    value: Binding(
                        get: { draftLine ?? Double(player.lineIndex) },
                        set: { draftLine = $0 }
                    ),
                    in: 0...Double(player.availableLines - 1),
                    step: 1
                ) { editing in
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
