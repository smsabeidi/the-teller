import AVFoundation
import MediaPlayer
import Observation
import SwiftUI

@MainActor
struct TellerHumanAudioView: View {
    let api: TellerAPI
    let pauseTeller: () -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var searchFocused: Bool
    @State private var player = HumanAudioPlayer()
    @State private var input = ""
    @State private var searchBy = SearchBy.title
    @State private var query = CatalogQuery(text: "", by: .title)
    @State private var books: [HumanAudiobook] = []
    @State private var nextOffset: Int?
    @State private var hasLoaded = false
    @State private var isLoading = false
    @State private var catalogError: String?
    @State private var catalogTask: Task<Void, Never>?
    @State private var selectedBook: HumanAudiobook?
    @State private var loadedBook: HumanAudiobook?
    @State private var bookError: String?
    @State private var bookTask: Task<Void, Never>?
    @State private var draftTime: Double?

    private enum SearchBy: String {
        case title, author
        var label: String { rawValue.capitalized }
    }

    private struct CatalogQuery: Equatable {
        let text: String
        let by: SearchBy
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let book = selectedBook {
                        detail(loadedBook ?? book)
                    } else {
                        catalog
                    }
                }
                .frame(maxWidth: 550)
                .padding(22)
                .frame(maxWidth: .infinity)
            }
            .id(selectedBook?.id)
            .scrollDismissesKeyboard(.interactively)
            .background(TellerTheme.paper.ignoresSafeArea())
            .foregroundStyle(TellerTheme.ink)
            .navigationTitle(selectedBook == nil ? "Human-read audiobooks" : "LibriVox audiobook")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if selectedBook != nil {
                        Button("Back", systemImage: "chevron.left", action: backToCatalog)
                    } else {
                        Button("Done") { dismiss() }
                    }
                }
            }
        }
        .tint(TellerTheme.accent)
        .onAppear { if !hasLoaded { fetchCatalog() } }
        .onDisappear {
            catalogTask?.cancel()
            bookTask?.cancel()
            player.stop()
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { note in
            let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            if type == AVAudioSession.InterruptionType.began.rawValue { player.pause() }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { player.pause() }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.mediaServicesWereResetNotification)) { _ in
            player.stop()
        }
    }

    private var catalog: some View {
        VStack(alignment: .leading, spacing: 17) {
            Text("Volunteer recordings from LibriVox, streamed from the Internet Archive.")
                .foregroundStyle(TellerTheme.muted)
            VStack(spacing: 10) {
                PaneSearchField(text: $input, focus: $searchFocused, submit: submitSearch)
                Picker("Search by", selection: $searchBy) {
                    Text(SearchBy.title.label).tag(SearchBy.title)
                    Text(SearchBy.author.label).tag(SearchBy.author)
                }
                .pickerStyle(.segmented)
                Button("Search recordings", action: submitSearch)
                    .buttonStyle(TellerPrimaryButtonStyle())
                    .accessibilityIdentifier("human-audio-search")
            }
            .padding(14)
            .tellerCard()

            if hasLoaded {
                Text(query.text.isEmpty ? "Recent recordings" : "Search results")
                    .font(.system(.title2, design: .serif, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
            }
            if !books.isEmpty {
                LazyVStack(spacing: 10) {
                    ForEach(books) { book in catalogRow(book) }
                }
            } else if hasLoaded && catalogError == nil && !isLoading {
                Text(query.text.isEmpty ? "No recordings are available." : "No recordings found. Try another title or author.")
                    .foregroundStyle(TellerTheme.muted)
            }
            if isLoading {
                ProgressView("Loading recordings…").accessibilityIdentifier("human-audio-loading")
            } else if let catalogError {
                errorPanel(catalogError) { fetchCatalog(offset: nextOffset) }
            } else if let nextOffset {
                Button("Load more recordings") { fetchCatalog(offset: nextOffset) }
                    .frame(minHeight: 44)
            }
        }
    }

    private func catalogRow(_ book: HumanAudiobook) -> some View {
        Button { open(book) } label: {
            HStack(alignment: .top, spacing: 12) {
                cover(book.coverURL)
                VStack(alignment: .leading, spacing: 5) {
                    Text(book.title).font(.system(.title3, design: .serif, weight: .semibold))
                    if !book.authors.isEmpty { Text(book.authors.joined(separator: ", ")).font(.subheadline) }
                    if let count = book.trackCount, count > 0 {
                        Text(count == 1 ? "1 track" : "\(count) tracks").font(.footnote)
                    }
                }
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(TellerTheme.accent)
                    .accessibilityHidden(true)
            }
            .padding(14)
            .contentShape(Rectangle())
            .tellerCard()
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("human-audio-book-\(book.id)")
    }

    private func cover(_ url: URL?) -> some View {
        AsyncImage(url: url.flatMap { Self.archiveURL($0) ? $0 : nil }) { phase in
            if let image = phase.image { image.resizable().scaledToFill() }
            else {
                TellerTheme.softAccent.overlay {
                    Image(systemName: "headphones").foregroundStyle(TellerTheme.accent)
                }
            }
        }
        .frame(width: 48, height: 60)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func detail(_ book: HumanAudiobook) -> some View {
        Text(book.title)
            .font(.system(.largeTitle, design: .serif, weight: .semibold))
            .accessibilityAddTraits(.isHeader)
        if !book.authors.isEmpty { Text(book.authors.joined(separator: ", ")).foregroundStyle(TellerTheme.muted) }
        if !book.description.isEmpty { Text(book.description).font(.subheadline) }
        VStack(alignment: .leading, spacing: 4) {
            if let source = book.sourceURL, Self.libriVoxURL(source) {
                Link("Recording on LibriVox", destination: source).frame(minHeight: 44)
            }
            if let rights = book.rightsURL, Self.libriVoxURL(rights) {
                Link("U.S. public-domain information", destination: rights).frame(minHeight: 44)
            }
        }
        if let track = player.track {
            transport(track)
        } else if let tracks = loadedBook?.tracks, let first = tracks.min(by: { $0.index < $1.index }) {
            let checkpoint = player.checkpoint.flatMap { $0.bookID == book.id ? $0 : nil }
            let last = tracks.first { $0.id == checkpoint?.trackID }
            Button(last == nil ? "Play recording" : "Resume recording", systemImage: "play.fill") {
                listen(book, track: last ?? first, startAt: last == nil ? 0 : checkpoint?.seconds ?? 0)
            }
                .buttonStyle(TellerPrimaryButtonStyle())
                .accessibilityIdentifier("human-audio-play")
        }
        if let bookError {
            errorPanel(bookError) { fetchTracks(book) }
        } else if loadedBook == nil {
            ProgressView("Loading tracks…")
        } else if let tracks = loadedBook?.tracks, !tracks.isEmpty {
            Text("Tracks")
                .font(.system(.title2, design: .serif, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(tracks.sorted { $0.index < $1.index }) { track in
                    trackRow(track, book: book)
                }
            }
        } else {
            Text("No playable tracks were found.").foregroundStyle(TellerTheme.muted)
        }
    }

    private func transport(_ track: HumanTrack) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(track.title).font(.system(.title3, design: .serif, weight: .semibold))
            if let error = player.errorMessage {
                errorPanel(error, retry: player.play)
            } else if player.isBuffering {
                ProgressView("Buffering…")
            }
            if let duration = player.duration, duration > 0 {
                Slider(value: Binding(
                    get: { min(duration, draftTime ?? player.elapsed) },
                    set: { draftTime = $0 }
                ), in: 0...duration) { editing in
                    if !editing, let time = draftTime {
                        player.seek(to: time)
                        draftTime = nil
                    }
                }
                .accessibilityLabel("Position in track")
                .accessibilityValue(Self.time(draftTime ?? player.elapsed))
                HStack {
                    Text(Self.time(draftTime ?? player.elapsed))
                    Spacer()
                    Text(Self.time(duration))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(TellerTheme.muted)
            }
            HStack(spacing: 10) {
                Button("Back 15 seconds", systemImage: "gobackward.15") { player.seek(to: player.elapsed - 15) }
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 44, minHeight: 44)
                    .disabled(player.duration == nil)
                Button(player.wantsPlayback ? "Pause" : "Play", systemImage: player.wantsPlayback ? "pause.fill" : "play.fill") {
                    player.wantsPlayback ? player.pause() : player.play()
                }
                .frame(minHeight: 44)
                .accessibilityIdentifier("human-audio-toggle")
                Button("Forward 15 seconds", systemImage: "goforward.15") { player.seek(to: player.elapsed + 15) }
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 44, minHeight: 44)
                    .disabled(player.duration == nil)
                Spacer(minLength: 0)
                Menu {
                    ForEach([0.75, 1, 1.25, 1.5, 2], id: \.self) { rate in
                        Button(rate.formatted() + "×") { player.setRate(rate) }
                    }
                } label: {
                    Text(player.rate.formatted() + "×").frame(minHeight: 44)
                }
                .accessibilityLabel("Playback speed, \(player.rate.formatted()) times")
            }
            .buttonStyle(.borderless)
        }
        .padding(16)
        .tellerCard()
    }

    private func trackRow(_ track: HumanTrack, book: HumanAudiobook) -> some View {
        Button { listen(book, track: track) } label: {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: player.track?.id == track.id ? "waveform" : "play.circle")
                    .foregroundStyle(TellerTheme.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(track.title).font(.body.weight(.medium))
                    if !track.readers.isEmpty {
                        Text("Read by " + track.readers.joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(TellerTheme.muted)
                    }
                }
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                if let duration = track.durationSeconds {
                    Text(Self.time(Double(duration))).font(.caption.monospacedDigit())
                }
            }
            .frame(minHeight: 44)
            .padding(10)
            .contentShape(Rectangle())
            .background(player.track?.id == track.id ? TellerTheme.softAccent : TellerTheme.card,
                        in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("human-audio-track-\(track.index)")
    }

    private func errorPanel(_ message: String, retry: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(message, systemImage: "exclamationmark.circle")
                .font(.subheadline)
                .foregroundStyle(TellerTheme.accent)
            Button("Try again", action: retry).frame(minHeight: 44)
        }
        .accessibilityIdentifier("human-audio-error")
    }

    private func submitSearch() {
        searchFocused = false
        query = CatalogQuery(text: input.trimmingCharacters(in: .whitespacesAndNewlines), by: searchBy)
        fetchCatalog()
    }

    private func fetchCatalog(offset: Int? = nil) {
        catalogTask?.cancel()
        if offset == nil {
            books = []
            hasLoaded = false
            nextOffset = nil
        }
        catalogError = nil
        isLoading = true
        let pending = query
        catalogTask = Task {
            do {
                let page = try await api.humanCatalog(query: pending.text, by: pending.by.rawValue, offset: offset ?? 0)
                try Task.checkCancellation()
                var ids = Set(books.map(\.id))
                books += page.items.filter { ids.insert($0.id).inserted }
                nextOffset = page.nextOffset
                hasLoaded = true
            } catch {
                guard !Task.isCancelled else { return }
                catalogError = error.localizedDescription
            }
            isLoading = false
        }
    }

    private func open(_ book: HumanAudiobook) {
        searchFocused = false
        selectedBook = book
        fetchTracks(book)
    }

    private func fetchTracks(_ book: HumanAudiobook) {
        bookTask?.cancel()
        bookError = nil
        loadedBook = nil
        bookTask = Task {
            do {
                let details = try await api.humanBook(id: book.id)
                try Task.checkCancellation()
                guard selectedBook?.id == book.id else { return }
                loadedBook = details
            } catch {
                guard !Task.isCancelled, selectedBook?.id == book.id else { return }
                bookError = error.localizedDescription
            }
        }
    }

    private func backToCatalog() {
        bookTask?.cancel()
        player.stop()
        draftTime = nil
        loadedBook = nil
        selectedBook = nil
    }

    private func listen(_ book: HumanAudiobook, track: HumanTrack, startAt: Double = 0) {
        draftTime = nil
        player.open(book, track: track, startAt: startAt, pauseTeller: pauseTeller)
    }

    fileprivate static func archiveURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == "archive.org"
            && url.user == nil && url.password == nil && url.port == nil && url.path.hasPrefix("/download/")
    }

    private static func libriVoxURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == "librivox.org"
            && url.user == nil && url.password == nil && url.port == nil
    }

    fileprivate static func time(_ seconds: Double) -> String {
        let safe = Int(seconds.isFinite ? min(3_600_000, max(0, seconds)) : 0)
        return String(format: "%d:%02d", safe / 60, safe % 60)
    }
}

@MainActor
private struct PaneSearchField: View {
    @Binding var text: String
    @FocusState.Binding var focus: Bool
    let submit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").accessibilityHidden(true)
            TextField("Search LibriVox", text: $text)
                .focused($focus)
                .submitLabel(.search)
                .onSubmit(submit)
                .accessibilityIdentifier("human-audio-query")
        }
        .frame(minHeight: 44)
    }
}

@MainActor
@Observable
private final class HumanAudioPlayer {
    struct Checkpoint: Codable {
        let bookID: String
        let trackID: String
        let seconds: Double
    }

    private static let checkpointKey = "Teller.lastHumanRecording"
    private(set) var checkpoint: Checkpoint? = UserDefaults.standard.data(forKey: checkpointKey)
        .flatMap { try? JSONDecoder().decode(Checkpoint.self, from: $0) }
    private(set) var track: HumanTrack?
    private(set) var elapsed = 0.0
    private(set) var duration: Double?
    private(set) var rate = 1.0
    private(set) var wantsPlayback = false
    private(set) var isBuffering = false
    private(set) var errorMessage: String?

    @ObservationIgnored private let avPlayer = AVPlayer()
    @ObservationIgnored private let audioSession = AVAudioSession.sharedInstance()
    @ObservationIgnored private var nowPlaying: MPNowPlayingSession?
    @ObservationIgnored private var timeObservation: NSKeyValueObservation?
    @ObservationIgnored private var itemObservation: NSKeyValueObservation?
    @ObservationIgnored private let events = AudioEvents()
    @ObservationIgnored private var endObservation: NSObjectProtocol?
    @ObservationIgnored private var failedObservation: NSObjectProtocol?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var book: HumanAudiobook?
    @ObservationIgnored private var pauseTeller: (() -> Void)?
    @ObservationIgnored private var hasSession = false
    @ObservationIgnored private var finished = false
    @ObservationIgnored private var needsReload = false
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var lastSavedAt = Date.distantPast

    func open(_ book: HumanAudiobook, track: HumanTrack, startAt: Double = 0, pauseTeller: @escaping () -> Void) {
        self.pauseTeller = pauseTeller
        if self.book?.id == book.id && self.track?.id == track.id {
            play()
            return
        }
        self.book = book
        self.track = track
        elapsed = max(0, startAt)
        lastSavedAt = .distantPast
        finished = false
        needsReload = true
        play()
    }

    func play() {
        guard let track, !wantsPlayback else { return }
        guard TellerHumanAudioView.archiveURL(track.audioURL),
              ["mp3", "m4a", "m4b"].contains(track.audioURL.pathExtension.lowercased()),
              track.audioURL.query == nil, track.audioURL.fragment == nil else {
            errorMessage = "This recording has an unsupported streaming address."
            return
        }
        pauseTeller?()
        do {
            if !hasSession {
                try audioSession.setCategory(.playback, mode: .spokenAudio)
                try audioSession.setActive(true)
                hasSession = true
            }
        } catch {
            errorMessage = "Audio couldn’t start. Try playing again."
            return
        }
        errorMessage = nil
        if avPlayer.currentItem == nil || needsReload {
            replace(with: track)
        } else if finished {
            seek(to: 0)
        }
        finished = false
        wantsPlayback = true
        avPlayer.play()
        avPlayer.rate = Float(rate)
        updatePlaybackState()
        startNowPlaying()
    }

    func pause() {
        guard wantsPlayback || hasSession else { return }
        wantsPlayback = false
        isBuffering = false
        avPlayer.pause()
        saveCheckpoint()
        updateNowPlaying()
        releaseSession()
    }

    func stop() {
        pause()
        clearItem()
        events.removeRemoteCommands()
        nowPlaying?.nowPlayingInfoCenter.nowPlayingInfo = nil
        nowPlaying = nil
        book = nil
        track = nil
        pauseTeller = nil
        errorMessage = nil
        elapsed = 0
        duration = nil
        finished = false
        needsReload = false
    }

    func seek(to time: Double) {
        guard time.isFinite, let duration else { return }
        elapsed = min(duration, max(0, time))
        finished = false
        let target = CMTime(seconds: elapsed, preferredTimescale: 600)
        avPlayer.seek(to: target)
        saveCheckpoint()
        updateNowPlaying()
    }

    func setRate(_ newRate: Double) {
        guard (0.75...2).contains(newRate) else { return }
        rate = newRate
        if wantsPlayback { avPlayer.rate = Float(newRate) }
        updateNowPlaying()
    }

    private func replace(with track: HumanTrack) {
        clearItem()
        needsReload = false
        duration = track.durationSeconds.map(Double.init)
        let item = AVPlayerItem(url: track.audioURL)
        item.audioTimePitchAlgorithm = .timeDomain
        avPlayer.replaceCurrentItem(with: item)
        let current = revision
        if elapsed > 0 { avPlayer.seek(to: CMTime(seconds: elapsed, preferredTimescale: 600)) }
        itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor in self?.itemChanged(revision: current) }
        }
        timeObservation = avPlayer.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.updatePlaybackState() }
        }
        let center = NotificationCenter.default
        endObservation = center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.endOfTrack(revision: current) }
        }
        failedObservation = center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.streamFailed(revision: current) }
        }
        timeObserver = avPlayer.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.3, preferredTimescale: 600), queue: .main) { [weak self] time in
            let seconds = time.seconds
            Task { @MainActor in
                guard let self, self.revision == current, seconds.isFinite else { return }
                self.elapsed = max(0, seconds)
                self.refreshDuration()
                if self.avPlayer.timeControlStatus == .playing, Date().timeIntervalSince(self.lastSavedAt) >= 12 {
                    self.saveCheckpoint()
                }
            }
        }
    }

    private func clearItem() {
        revision += 1
        itemObservation = nil
        timeObservation = nil
        if let endObservation { NotificationCenter.default.removeObserver(endObservation) }
        if let failedObservation { NotificationCenter.default.removeObserver(failedObservation) }
        if let timeObserver { avPlayer.removeTimeObserver(timeObserver) }
        endObservation = nil
        failedObservation = nil
        timeObserver = nil
        avPlayer.replaceCurrentItem(with: nil)
    }

    private func itemChanged(revision current: Int) {
        guard revision == current, let item = avPlayer.currentItem else { return }
        switch item.status {
        case .readyToPlay:
            refreshDuration()
            updatePlaybackState()
        case .failed:
            streamFailed(revision: current)
        default:
            break
        }
    }

    private func streamFailed(revision current: Int) {
        guard revision == current else { return }
        pause()
        needsReload = true
        errorMessage = "The recording couldn’t be streamed. Check your connection and try again."
    }

    private func endOfTrack(revision current: Int) {
        guard revision == current, wantsPlayback else { return }
        if let book, let track, let next = book.tracks?.filter({ $0.index > track.index }).min(by: { $0.index < $1.index }),
           let pauseTeller {
            wantsPlayback = false
            open(book, track: next, pauseTeller: pauseTeller)
        } else {
            finished = true
            if let duration { elapsed = duration }
            pause()
        }
    }

    private func saveCheckpoint() {
        guard let book, let track else { return }
        if finished {
            checkpoint = nil
            UserDefaults.standard.removeObject(forKey: Self.checkpointKey)
        } else {
            let progress = Checkpoint(bookID: book.id, trackID: track.id, seconds: elapsed)
            guard let data = try? JSONEncoder().encode(progress) else { return }
            checkpoint = progress
            UserDefaults.standard.set(data, forKey: Self.checkpointKey)
        }
        lastSavedAt = .now
    }

    private func refreshDuration() {
        guard let measured = avPlayer.currentItem?.duration.seconds, measured.isFinite, measured > 0,
              measured != duration else { return }
        duration = measured
        updateNowPlaying()
    }

    private func updatePlaybackState() {
        isBuffering = wantsPlayback && avPlayer.timeControlStatus != .playing
        updateNowPlaying()
    }

    private func releaseSession() {
        if hasSession {
            try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
            hasSession = false
        }
    }

    private func startNowPlaying() {
        if nowPlaying == nil {
            let media = MPNowPlayingSession(players: [avPlayer])
            let commands = media.remoteCommandCenter
            events.remote(commands.playCommand) { [weak self] in self?.play() }
            events.remote(commands.pauseCommand) { [weak self] in self?.pause() }
            events.remote(commands.togglePlayPauseCommand) { [weak self] in
                guard let self else { return }
                wantsPlayback ? pause() : play()
            }
            commands.skipBackwardCommand.preferredIntervals = [15]
            commands.skipForwardCommand.preferredIntervals = [15]
            events.remote(commands.skipBackwardCommand) { [weak self] in
                guard let self else { return }
                seek(to: elapsed - 15)
            }
            events.remote(commands.skipForwardCommand) { [weak self] in
                guard let self else { return }
                seek(to: elapsed + 15)
            }
            events.remote(commands.changePlaybackPositionCommand) { [weak self] command in
                guard let event = command as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
                let time = event.positionTime
                Task { @MainActor in self?.seek(to: time) }
                return .success
            }
            nowPlaying = media
        }
        updateNowPlaying()
        nowPlaying?.becomeActiveIfPossible(completion: nil)
    }

    private func updateNowPlaying() {
        guard let nowPlaying, let book, let track else { return }
        let commands = nowPlaying.remoteCommandCenter
        commands.skipBackwardCommand.isEnabled = duration != nil
        commands.skipForwardCommand.isEnabled = duration != nil
        commands.changePlaybackPositionCommand.isEnabled = duration != nil
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyAlbumTitle: book.title,
            MPMediaItemPropertyArtist: track.readers.isEmpty ? "LibriVox" : track.readers.joined(separator: ", "),
            MPMediaItemPropertyMediaType: MPMediaType.audioBook.rawValue,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: avPlayer.timeControlStatus == .playing ? rate : 0,
        ]
        if let duration { info[MPMediaItemPropertyPlaybackDuration] = duration }
        nowPlaying.nowPlayingInfoCenter.nowPlayingInfo = info
    }
}
