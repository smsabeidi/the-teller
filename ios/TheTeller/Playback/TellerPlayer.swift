import AVFoundation
import Foundation
import MediaPlayer
import Observation
import UIKit

@MainActor
@Observable
final class TellerPlayer {
    private(set) var book: Book?
    private(set) var lineIndex = 0
    private(set) var visibleLines: [StoryLine] = []
    private(set) var isPlaying = false
    private(set) var isLoading = false
    private(set) var isLoadingTranscript = false
    private(set) var isFinished = false
    private(set) var rate: Double
    private(set) var lineFraction = 0.0
    private(set) var errorMessage: String?

    var availableLines: Int { book?.availableLines ?? 0 }
    var currentLine: StoryLine? { activeLine ?? visibleLines.first { $0.index == lineIndex } }
    var playedFraction: Double {
        guard availableLines > 0 else { return 0 }
        return min(1, (Double(lineIndex) + lineFraction) / Double(availableLines))
    }
    var hasReachedPreviewEnd: Bool { isFinished && book?.unlocked == false }
    var hasEarlierTranscript: Bool { (visibleLines.first?.index ?? lineIndex) > 0 }
    var hasLaterTranscript: Bool { (visibleLines.last?.index ?? -1) < availableLines - 1 }
    var isSample: Bool { localLines != nil }

    struct SavedProgress {
        let lineIndex: Int
        let fraction: Double?
        let updatedAt: Date?
        let isFinished: Bool
        let isPreviewFinished: Bool
    }

    private struct Position: Codable {
        let line: Int
        let fraction: Double
        let finished: Bool
        let available: Int?
        let total: Int?
        let previewFinished: Bool?
        let updatedAt: Date?
    }

    private struct Prefetch {
        let line: Int
        let task: Task<LineAudio, Error>
    }

    @ObservationIgnored private let api: TellerAPI
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let storagePrefix: String
    @ObservationIgnored private let audioSession = AVAudioSession.sharedInstance()
    @ObservationIgnored private let events = AudioEvents()
    @ObservationIgnored private let delegate = PlaybackDelegate()
    @ObservationIgnored private var synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private var audioPlayer: AVAudioPlayer?
    private var activeLine: StoryLine?
    @ObservationIgnored private var utterance: AVSpeechUtterance?
    @ObservationIgnored private var utteranceOffset = 0
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var transcriptTask: Task<Void, Never>?
    @ObservationIgnored private var ticking: Task<Void, Never>?
    @ObservationIgnored private var prefetch: Prefetch?
    @ObservationIgnored private var clipRevision = 0
    @ObservationIgnored private var transcriptRevision = 0
    @ObservationIgnored private var prefersLocalSpeech = false
    @ObservationIgnored private var sessionActive = false
    @ObservationIgnored private var interruptionActive = false
    @ObservationIgnored private var resumeAfterInterruption = false
    @ObservationIgnored private var lastCheckpoint = ContinuousClock.now
    private var progressRevision = 0
    @ObservationIgnored private var voiceChoices: [String: VoiceChoice] = [:]
    private var localLines: [StoryLine]?

    init(api: TellerAPI, defaults: UserDefaults = .standard, checkpointNamespace: String = "theteller.player") {
        self.api = api
        self.defaults = defaults
        storagePrefix = checkpointNamespace
        let savedRate = defaults.double(forKey: "\(checkpointNamespace).rate")
        rate = (0.75...2).contains(savedRate) ? savedRate : 1
        configureSynthesizer()
        delegate.completed = { [weak self] id, success in self?.clipCompleted(id: id, success: success) }
        delegate.spoken = { [weak self] id, offset in self?.speechAdvanced(id: id, offset: offset) }
        observeAudioSession()
    }

    func open(_ book: Book, autoplay: Bool = false) {
        if let current = self.book, current.id == book.id, !isSample {
            if current != book { reload(book) }
            if autoplay { play() }
            return
        }
        install(book, local: nil, autoplay: autoplay)
    }

    func openSample(_ book: Book, lines: [StoryLine], autoplay: Bool = false) {
        if self.book?.id == book.id, isSample {
            if autoplay { play() }
            return
        }
        install(book, local: lines, autoplay: autoplay)
    }

    func reload(_ updatedBook: Book) {
        guard let book, book.id == updatedBook.id, !isSample else { return }
        let wasPlaying = isPlaying
        updateClipFraction()
        let continueAtNewLine = isFinished && !book.unlocked && updatedBook.availableLines > availableLines
        let nextIndex = continueAtNewLine ? lineIndex + 1 : lineIndex
        let fraction = continueAtNewLine ? 0 : lineFraction
        let remainsFinished = isFinished && !continueAtNewLine
        resetClip()
        resetTranscript()
        self.book = updatedBook
        prefersLocalSpeech = updatedBook.provider == "browser"
        self.voiceChoices = buildVoiceChoices(for: updatedBook)
        visibleLines = updatedBook.lines
        lineIndex = boundedIndex(nextIndex)
        isFinished = remainsFinished && lineIndex == nextIndex && lineIndex == availableLines - 1
        lineFraction = lineIndex == nextIndex ? (isFinished ? 1 : min(0.999, fraction)) : 0
        errorMessage = nil
        checkpoint()
        if wasPlaying { play() } else { loadLines(around: lineIndex) }
        updateNowPlaying()
    }

    func close() {
        pause()
        resetClip()
        resetTranscript()
        events.removeRemoteCommands()
        book = nil
        localLines = nil
        visibleLines = []
        voiceChoices = [:]
        prefersLocalSpeech = false
        lineIndex = 0
        lineFraction = 0
        isFinished = false
        errorMessage = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func toggle() { isPlaying ? pause() : play() }

    func play() {
        guard let book, availableLines > 0, !isPlaying else { return }
        if hasReachedPreviewEnd { return }
        if interruptionActive {
            resumeAfterInterruption = true
            return
        }
        resumeAfterInterruption = false
        if isFinished { select(0, fraction: 0, continuePlaying: false) }
        errorMessage = nil
        isPlaying = true
        if let player = audioPlayer {
            do {
                try activateSession()
                if player.play() {
                    startClock()
                    prefetchNextLine()
                } else {
                    player.delegate = nil
                    audioPlayer = nil
                    startClip(for: book)
                }
            } catch {
                fail(error)
            }
        } else if utterance != nil, synthesizer.isPaused {
            do {
                try activateSession()
                if synthesizer.continueSpeaking() {
                    startClock()
                    prefetchNextLine()
                } else {
                    utterance = nil
                    synthesizer.stopSpeaking(at: .immediate)
                    startClip(for: book)
                }
            } catch {
                fail(error)
            }
        } else {
            startClip(for: book)
        }
        updateNowPlaying()
    }

    func pause() {
        resumeAfterInterruption = false
        suspendPlayback()
    }

    func seek(to index: Int) {
        guard availableLines > 0 else { return }
        resumeAfterInterruption = false
        select(index, fraction: 0, continuePlaying: isPlaying)
    }

    func step(_ offset: Int) {
        guard offset != 0 else { return }
        let (target, overflow) = lineIndex.addingReportingOverflow(offset)
        seek(to: overflow ? (offset > 0 ? Int.max : Int.min) : target)
    }

    func setRate(_ value: Double) {
        guard value.isFinite else { return }
        rate = min(2, max(0.75, value))
        defaults.set(rate, forKey: "\(storagePrefix).rate")
        if let audioPlayer {
            audioPlayer.rate = Float(rate)
        } else if utterance != nil {
            select(lineIndex, fraction: lineFraction, continuePlaying: isPlaying)
        }
        updateNowPlaying()
    }

    func checkpoint() {
        guard let book else { return }
        updateClipFraction()
        lastCheckpoint = .now
        let previous = restorePosition(book.id)
        guard previous != nil || lineIndex > 0 || lineFraction > 0 || isFinished else { return }
        let positionChanged = previous?.line != lineIndex || previous?.fraction != lineFraction || previous?.finished != isFinished
        let metadataChanged = previous?.available != availableLines || previous?.total != book.totalLines
            || previous?.previewFinished != hasReachedPreviewEnd
        guard positionChanged || metadataChanged else { return }
        let new = Position(line: lineIndex, fraction: lineFraction, finished: isFinished,
                           available: availableLines, total: book.totalLines, previewFinished: hasReachedPreviewEnd,
                           updatedAt: positionChanged ? Date() : previous?.updatedAt)
        if let data = try? JSONEncoder().encode(new) {
            defaults.set(data, forKey: positionKey(book.id))
            progressRevision += 1
        }
    }

    func resumeIndex(for bookID: String) -> Int {
        savedProgress(for: bookID)?.lineIndex ?? 0
    }

    func savedProgress(for bookID: String) -> SavedProgress? {
        // Subscribe views to local updates even as they display a different book.
        _ = progressRevision
        guard let position = restorePosition(bookID) else { return nil }
        let fraction = position.total.flatMap { total in
            total > 0 ? min(1, max(0, (Double(position.line) + position.fraction) / Double(total))) : nil
        }
        let previewFinished = position.previewFinished ?? (position.finished && position.total != position.available)
        return SavedProgress(lineIndex: position.line, fraction: fraction, updatedAt: position.updatedAt,
                             isFinished: position.finished && !previewFinished, isPreviewFinished: previewFinished)
    }

    func removeProgress(for bookID: String) {
        if book?.id == bookID { close() }
        defaults.removeObject(forKey: positionKey(bookID))
        progressRevision += 1
    }

    func loadLines(around index: Int) {
        guard availableLines > 0 else { return }
        let target = boundedIndex(index)
        guard !visibleLines.contains(where: { $0.index == target }) else { return }
        fetchTranscript(start: pageStart(for: target), count: 80)
    }

    func loadEarlierLines() {
        guard let first = visibleLines.first, first.index > 0, !isLoadingTranscript else { return }
        let start = max(0, first.index - 80)
        fetchTranscript(start: start, count: first.index - start)
    }

    func loadLaterLines() {
        guard let last = visibleLines.last, hasLaterTranscript, !isLoadingTranscript else { return }
        fetchTranscript(start: last.index + 1, count: 80)
    }

    private func install(_ book: Book, local: [StoryLine]?, autoplay: Bool) {
        close()
        self.book = book
        localLines = local
        prefersLocalSpeech = local != nil || book.provider == "browser"
        visibleLines = (local ?? book.lines).sorted { $0.index < $1.index }
        voiceChoices = buildVoiceChoices(for: book)
        if let previous = restorePosition(book.id), availableLines > 0 {
            let canContinue = previous.finished && book.unlocked && previous.line < availableLines - 1
            let resumeLine = canContinue ? previous.line + 1 : previous.line
            lineIndex = boundedIndex(resumeLine)
            isFinished = previous.finished && !canContinue && lineIndex == resumeLine && lineIndex == availableLines - 1
            lineFraction = isFinished ? 1 : lineIndex == previous.line ? min(0.999, max(0, previous.fraction)) : 0
        }
        registerRemoteCommands()
        if autoplay && !hasReachedPreviewEnd { play() } else { loadLines(around: lineIndex) }
    }

    private func positionKey(_ id: String) -> String { "\(storagePrefix).position.\(id)" }

    private func restorePosition(_ id: String) -> Position? {
        guard let data = defaults.data(forKey: positionKey(id)) else { return nil }
        return try? JSONDecoder().decode(Position.self, from: data)
    }

    private func boundedIndex(_ index: Int) -> Int {
        max(0, min(index, availableLines - 1))
    }

    private func select(_ index: Int, fraction: Double, continuePlaying: Bool) {
        let target = boundedIndex(index)
        resetClip(keepingPrefetch: target)
        lineIndex = target
        lineFraction = min(0.999, max(0, fraction))
        isFinished = false
        errorMessage = nil
        if continuePlaying { play() } else { loadLines(around: target) }
        checkpoint()
        updateNowPlaying()
    }

    private func resetClip(keepingPrefetch line: Int? = nil) {
        clipRevision += 1
        loadTask?.cancel()
        loadTask = nil
        if let prefetch, prefetch.line != line {
            prefetch.task.cancel()
            self.prefetch = nil
        }
        ticking?.cancel()
        ticking = nil
        audioPlayer?.delegate = nil
        audioPlayer?.stop()
        audioPlayer = nil
        activeLine = nil
        utterance = nil
        synthesizer.stopSpeaking(at: .immediate)
        isLoading = false
        isPlaying = false
    }

    private func resetTranscript() {
        transcriptRevision += 1
        transcriptTask?.cancel()
        transcriptTask = nil
        isLoadingTranscript = false
    }

    private func suspendPlayback(deactivate: Bool = true) {
        clipRevision += 1
        loadTask?.cancel()
        loadTask = nil
        prefetch?.task.cancel()
        prefetch = nil
        ticking?.cancel()
        ticking = nil
        updateClipFraction()
        audioPlayer?.pause()
        if utterance != nil, synthesizer.isSpeaking, !synthesizer.isPaused {
            if !synthesizer.pauseSpeaking(at: .immediate) {
                utterance = nil
                synthesizer.stopSpeaking(at: .immediate)
            }
        }
        isPlaying = false
        isLoading = false
        checkpoint()
        if deactivate { deactivateSession() }
        updateNowPlaying()
    }

    private func pageStart(for index: Int) -> Int { index / 80 * 80 }

    private func fetchTranscript(start: Int, count: Int) {
        guard let book, localLines == nil, count > 0 else { return }
        resetTranscript()
        let revision = transcriptRevision
        isLoadingTranscript = true
        errorMessage = nil
        transcriptTask = Task { [weak self, api] in
            do {
                let page = try await api.lines(bookID: book.id, start: start, count: count)
                guard let self, !Task.isCancelled, revision == transcriptRevision else { return }
                mergeTranscript(page.lines)
                isLoadingTranscript = false
            } catch {
                guard let self, !Task.isCancelled, revision == transcriptRevision else { return }
                errorMessage = error.localizedDescription
                isLoadingTranscript = false
            }
        }
    }

    private func mergeTranscript(_ lines: [StoryLine]) {
        let valid = lines.filter { (0..<availableLines).contains($0.index) }
        guard let earliest = valid.first?.index, let latest = valid.last?.index else { return }
        if let first = visibleLines.first?.index, let last = visibleLines.last?.index,
           earliest <= last + 1, latest >= first - 1 {
            var merged = Dictionary(visibleLines.map { ($0.index, $0) }, uniquingKeysWith: { _, newer in newer })
            for line in valid { merged[line.index] = line }
            visibleLines = merged.values.sorted { $0.index < $1.index }
        } else {
            visibleLines = valid.sorted { $0.index < $1.index }
        }
    }

    private func startClip(for book: Book) {
        let index = lineIndex
        let revision = clipRevision
        let existingLine = currentLine
        let local = localLines != nil
        let useSpeech = prefersLocalSpeech
        let cached = prefetch?.line == index ? prefetch?.task : nil
        isLoading = true
        updateNowPlaying()
        loadTask = Task { [weak self, api] in
            do {
                let loaded: [StoryLine]
                if existingLine == nil && !local {
                    loaded = try await api.lines(bookID: book.id, start: index / 80 * 80, count: 80).lines
                } else {
                    loaded = []
                }
                guard !Task.isCancelled else { return }
                guard let line = existingLine ?? loaded.first(where: { $0.index == index }) else {
                    throw PlayerFailure.lineUnavailable
                }
                let clip: LineAudio
                if useSpeech {
                    clip = .speechFallback
                } else if let cached {
                    do {
                        clip = try await cached.value
                    } catch {
                        if Task.isCancelled { return }
                        clip = try await api.audio(bookID: book.id, line: index)
                    }
                } else {
                    clip = try await api.audio(bookID: book.id, line: index)
                }
                guard let self, !Task.isCancelled, clipRevision == revision else { return }
                if !loaded.isEmpty { mergeTranscript(loaded) }
                if prefetch?.line == index { prefetch = nil }
                loadTask = nil
                try begin(clip, line: line)
            } catch {
                guard let self, !Task.isCancelled, clipRevision == revision else { return }
                fail(error)
            }
        }
    }

    private func begin(_ clip: LineAudio, line: StoryLine) throws {
        try activateSession()
        activeLine = line
        switch clip {
        case .mp3(let data):
            let player = try AVAudioPlayer(data: data, fileTypeHint: AVFileType.mp3.rawValue)
            player.delegate = delegate
            player.enableRate = true
            guard player.prepareToPlay() else { throw PlayerFailure.audioUnavailable }
            player.rate = Float(rate)
            player.currentTime = min(0.999, lineFraction) * player.duration
            audioPlayer = player
            guard player.play() else { throw PlayerFailure.audioUnavailable }
        case .speechFallback:
            prefersLocalSpeech = true
            speak(line)
        }
        isLoading = false
        startClock()
        prefetchNextLine()
        updateNowPlaying()
    }

    private func prefetchNextLine() {
        guard let book, !prefersLocalSpeech, !interruptionActive,
              lineIndex + 1 < availableLines, prefetch?.line != lineIndex + 1 else { return }
        prefetch?.task.cancel()
        let next = lineIndex + 1
        prefetch = Prefetch(line: next, task: Task { [api] in
            try await api.audio(bookID: book.id, line: next)
        })
    }

    private func startClock() {
        ticking?.cancel()
        ticking = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(300))
                guard let self, !Task.isCancelled, isPlaying else { return }
                updateClipFraction()
                if lastCheckpoint.duration(to: .now) >= .seconds(5) { checkpoint() }
            }
        }
    }

    private func configureSynthesizer() {
        synthesizer.usesApplicationAudioSession = true
        synthesizer.delegate = delegate
    }

    private func speak(_ line: StoryLine) {
        let fullText = line.text as NSString
        let proposed = min(max(0, fullText.length - 1), Int(Double(fullText.length) * lineFraction))
        var offset = proposed
        if proposed > 0 {
            let whitespace = fullText.rangeOfCharacter(from: .whitespacesAndNewlines, options: .backwards,
                                                       range: NSRange(location: 0, length: proposed))
            offset = whitespace.location == NSNotFound ? 0 : NSMaxRange(whitespace)
        }
        let text = fullText.substring(from: offset)
        let spoken = AVSpeechUtterance(string: text)
        let castVoice = voiceChoices[line.speaker] ?? voiceChoices["Narrator"]
        spoken.voice = castVoice?.voice
        let delivery = SpeechDelivery(emotion: line.emotion)
        spoken.pitchMultiplier = min(1.8, max(0.5, (castVoice?.pitch ?? 1) * delivery.pitch))
        spoken.rate = min(AVSpeechUtteranceMaximumSpeechRate,
                          max(AVSpeechUtteranceMinimumSpeechRate, AVSpeechUtteranceDefaultSpeechRate * Float(rate) * delivery.pace))
        spoken.volume = delivery.volume
        utteranceOffset = offset
        utterance = spoken
        synthesizer.speak(spoken)
    }

    private func speechAdvanced(id: ObjectIdentifier, offset: Int) {
        guard isPlaying, let utterance, ObjectIdentifier(utterance) == id,
              let line = currentLine, !line.text.isEmpty else { return }
        lineFraction = max(lineFraction, min(0.999, Double(utteranceOffset + offset) / Double(line.text.utf16.count)))
        updateNowPlaying()
    }

    private func clipCompleted(id: ObjectIdentifier, success: Bool) {
        guard isPlaying, audioPlayer.map(ObjectIdentifier.init) == id || utterance.map(ObjectIdentifier.init) == id else { return }
        if !success {
            fail(PlayerFailure.audioUnavailable)
        } else if lineIndex + 1 < availableLines {
            select(lineIndex + 1, fraction: 0, continuePlaying: true)
        } else {
            resetClip()
            deactivateSession()
            isFinished = true
            lineFraction = 1
            checkpoint()
            updateNowPlaying()
        }
    }

    private func updateClipFraction() {
        if let audioPlayer, audioPlayer.duration > 0 {
            lineFraction = min(1, max(0, audioPlayer.currentTime / audioPlayer.duration))
        }
    }

    private func fail(_ error: Error) {
        updateClipFraction()
        resetClip()
        deactivateSession()
        errorMessage = error.localizedDescription
        checkpoint()
        updateNowPlaying()
    }

    private func activateSession() throws {
        guard !sessionActive else { return }
        try audioSession.setCategory(.playback, mode: .spokenAudio)
        try audioSession.setActive(true)
        sessionActive = true
    }

    private func deactivateSession() {
        guard sessionActive else { return }
        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
        sessionActive = false
    }

    private func observeAudioSession() {
        events.observe(AVAudioSession.interruptionNotification, object: audioSession) { [weak self] note in
            let rawType = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let rawOptions = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor in self?.interrupted(type: rawType, options: rawOptions) }
        }
        events.observe(AVAudioSession.routeChangeNotification, object: audioSession) { [weak self] note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            guard reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
            Task { @MainActor in self?.pause() }
        }
        events.observe(AVAudioSession.mediaServicesWereResetNotification, object: audioSession) { [weak self] _ in
            Task { @MainActor in self?.resetMediaServices() }
        }
        events.observe(UIApplication.willResignActiveNotification, object: nil) { [weak self] _ in
            Task { @MainActor in self?.checkpoint() }
        }
    }

    private func interrupted(type rawType: UInt?, options rawOptions: UInt) {
        guard let rawType, let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
        switch type {
        case .began:
            guard !interruptionActive else { return }
            interruptionActive = true
            resumeAfterInterruption = isPlaying
            sessionActive = false
            suspendPlayback(deactivate: false)
        case .ended:
            guard interruptionActive else { return }
            interruptionActive = false
            let resumptionAllowed = AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume)
            if resumeAfterInterruption && resumptionAllowed { play() }
            resumeAfterInterruption = false
        @unknown default:
            break
        }
    }

    private func resetMediaServices() {
        checkpoint()
        resetClip()
        sessionActive = false
        interruptionActive = false
        resumeAfterInterruption = false
        synthesizer = AVSpeechSynthesizer()
        configureSynthesizer()
        updateNowPlaying()
    }

    private func registerRemoteCommands() {
        let remote = MPRemoteCommandCenter.shared()
        events.remote(remote.playCommand) { [weak self] in self?.play() }
        events.remote(remote.pauseCommand) { [weak self] in self?.pause() }
        events.remote(remote.togglePlayPauseCommand) { [weak self] in self?.toggle() }
        events.remote(remote.previousTrackCommand) { [weak self] in self?.step(-1) }
        events.remote(remote.nextTrackCommand) { [weak self] in self?.step(1) }
        events.remote(remote.changePlaybackPositionCommand) { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let time = event.positionTime
            Task { @MainActor in self?.seekWithinLine(to: time) }
            return .success
        }
    }

    private func seekWithinLine(to time: Double) {
        guard time.isFinite, let duration = lineDuration, duration > 0 else { return }
        let fraction = min(0.999, max(0, time / duration))
        if let audioPlayer {
            audioPlayer.currentTime = fraction * duration
            lineFraction = fraction
            checkpoint()
            updateNowPlaying()
        } else {
            select(lineIndex, fraction: fraction, continuePlaying: isPlaying)
        }
    }

    private var lineDuration: Double? {
        if let audioPlayer, audioPlayer.duration > 0 { return audioPlayer.duration }
        if let line = currentLine, utterance != nil {
            return max(1, Double(line.text.split(whereSeparator: \.isWhitespace).count) / 2.6)
        }
        return nil
    }

    private func updateNowPlaying() {
        guard let book else { return }
        let remote = MPRemoteCommandCenter.shared()
        let canPlay = availableLines > 0 && !hasReachedPreviewEnd
        remote.playCommand.isEnabled = canPlay
        remote.pauseCommand.isEnabled = canPlay
        remote.togglePlayPauseCommand.isEnabled = canPlay
        remote.previousTrackCommand.isEnabled = lineIndex > 0
        remote.nextTrackCommand.isEnabled = lineIndex + 1 < availableLines
        remote.changePlaybackPositionCommand.isEnabled = lineDuration != nil
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: book.title,
            MPMediaItemPropertyMediaType: MPMediaType.audioBook.rawValue,
            MPNowPlayingInfoPropertyPlaybackQueueIndex: lineIndex,
            MPNowPlayingInfoPropertyPlaybackQueueCount: availableLines,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying && !isLoading ? rate : 0,
        ]
        let artist = book.author.isEmpty ? currentLine?.speaker : book.author
        if let artist { info[MPMediaItemPropertyArtist] = artist }
        if let duration = lineDuration {
            info[MPMediaItemPropertyPlaybackDuration] = duration
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = duration * lineFraction
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
