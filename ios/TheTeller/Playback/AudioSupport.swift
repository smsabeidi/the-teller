import AVFoundation
import Foundation
import MediaPlayer

struct VoiceChoice {
    let voice: AVSpeechSynthesisVoice?
    let pitch: Float
}

struct SpeechDelivery {
    var pitch: Float = 1
    var pace: Float = 1
    var volume: Float = 1

    init(emotion: String) {
        switch emotion.lowercased() {
        case "happy", "excited": pitch = 1.12; pace = 1.08
        case "sad", "tender": pitch = 0.94; pace = 0.9; volume = 0.8
        case "angry": pitch = 0.9; pace = 1.08
        case "scared", "surprised": pitch = 1.17; pace = 1.03
        case "whisper": pitch = 0.94; pace = 0.92; volume = 0.48
        case "sarcastic": pitch = 0.95; pace = 0.94
        default: break
        }
    }
}

@MainActor
func buildVoiceChoices(for book: Book) -> [String: VoiceChoice] {
    let preferredLanguage = AVSpeechSynthesisVoice.currentLanguageCode()
    let installedVoices = AVSpeechSynthesisVoice.speechVoices()
    let englishVoices = installedVoices.filter { $0.language.hasPrefix("en-") }
    let available = englishVoices.isEmpty
        ? installedVoices.filter { $0.language == preferredLanguage }
        : englishVoices
    let ordered = available.sorted {
        let lhsPreferred = $0.language == preferredLanguage
        let rhsPreferred = $1.language == preferredLanguage
        if lhsPreferred != rhsPreferred { return lhsPreferred }
        if $0.quality != $1.quality { return $0.quality.rawValue > $1.quality.rawValue }
        return $0.identifier < $1.identifier
    }
    let slots = Set(book.cast.values.map(\.voice)).union(["narrator_f", "narrator_m", "f1", "f2", "f3", "f4", "m1", "m2", "m3", "m4", "m5"])
    let sortedSlots = slots.sorted {
        let lhsNarrator = $0.hasPrefix("narrator_")
        let rhsNarrator = $1.hasPrefix("narrator_")
        return lhsNarrator == rhsNarrator ? $0 < $1 : lhsNarrator
    }
    var bySlot: [String: VoiceChoice] = [:]
    var usedVoices: Set<String> = []
    for (index, slot) in sortedSlots.enumerated() {
        let feminine = slot.hasPrefix("f") || slot == "narrator_f"
        let gender: AVSpeechSynthesisVoiceGender = feminine ? .female : .male
        let sameGender = ordered.filter { $0.gender == gender }
        let unique = sameGender.first { !usedVoices.contains($0.identifier) }
            ?? ordered.first { !usedVoices.contains($0.identifier) }
        let fallbackVoices = sameGender.isEmpty ? ordered : sameGender
        let reused = fallbackVoices.isEmpty ? nil : fallbackVoices[index % fallbackVoices.count]
        let voice = unique ?? reused ?? AVSpeechSynthesisVoice(language: preferredLanguage)
        let variants: [Float] = [0.85, 0.93, 1.03, 1.13, 1.21]
        let pitch = unique == nil ? variants[index % variants.count] : 1
        bySlot[slot] = VoiceChoice(voice: voice, pitch: pitch)
        if let voice { usedVoices.insert(voice.identifier) }
    }
    var roster = ["Narrator": bySlot["narrator_f"] ?? VoiceChoice(voice: nil, pitch: 1)]
    for (speaker, member) in book.cast {
        roster[speaker] = bySlot[member.voice]
    }
    return roster
}

enum PlayerFailure: LocalizedError {
    case lineUnavailable
    case audioUnavailable

    var errorDescription: String? {
        switch self {
        case .lineUnavailable: "This line is unavailable. Reopen the audiobook and try again."
        case .audioUnavailable: "Audio could not be played. Try playing this line again."
        }
    }
}

final class PlaybackDelegate: NSObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    @MainActor var completed: ((ObjectIdentifier, Bool) -> Void)?
    @MainActor var spoken: ((ObjectIdentifier, Int) -> Void)?

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        finish(ObjectIdentifier(player), success: flag)
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        finish(ObjectIdentifier(player), success: false)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        finish(ObjectIdentifier(utterance), success: true)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange,
                           utterance: AVSpeechUtterance) {
        let identifier = ObjectIdentifier(utterance)
        let offset = characterRange.location
        Task { @MainActor [weak self] in self?.spoken?(identifier, offset) }
    }

    private func finish(_ identifier: ObjectIdentifier, success: Bool) {
        Task { @MainActor [weak self] in self?.completed?(identifier, success) }
    }
}

final class AudioEvents {
    private var notifications: [NSObjectProtocol] = []
    private var commands: [(MPRemoteCommand, Any)] = []

    func observe(_ name: Notification.Name, object: Any?, using handler: @escaping @Sendable (Notification) -> Void) {
        let handle = NotificationCenter.default.addObserver(forName: name, object: object, queue: .main, using: handler)
        notifications.append(handle)
    }

    func remote(_ command: MPRemoteCommand, action: @escaping @MainActor @Sendable () -> Void) {
        remote(command) { _ in
            Task { @MainActor in action() }
            return .success
        }
    }

    func remote(_ command: MPRemoteCommand, handler: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus) {
        commands.append((command, command.addTarget(handler: handler)))
    }

    func removeRemoteCommands() {
        for (command, token) in commands { command.removeTarget(token) }
        commands.removeAll()
    }

    deinit {
        removeRemoteCommands()
        for token in notifications { NotificationCenter.default.removeObserver(token) }
    }
}
