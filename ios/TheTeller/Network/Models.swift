import Foundation

enum StorySource: Sendable {
    case link(String)
    case text(String)
    case file(URL)
}

struct StoryLine: Codable, Sendable, Identifiable, Equatable {
    let index: Int
    let speaker: String
    let text: String
    let emotion: String

    var id: Int { index }

    init(index: Int, speaker: String, text: String, emotion: String = "neutral") {
        self.index = index
        self.speaker = speaker
        self.text = text
        self.emotion = emotion
    }

    private enum CodingKeys: String, CodingKey {
        case index = "i"
        case speaker, text, emotion
    }
}

struct CastMember: Codable, Sendable, Equatable {
    let voice: String
    let gender: String
    let lines: Int
}

struct Chapter: Codable, Sendable, Identifiable, Equatable {
    let title: String
    let start: Int

    var id: Int { start }
}

struct Book: Codable, Sendable, Identifiable, Equatable {
    let id: String
    let title: String
    let author: String
    let cover: String
    let words: Int
    let cast: [String: CastMember]
    let totalLines: Int
    let unlocked: Bool
    let previewLines: Int
    let lines: [StoryLine]
    let chapters: [Chapter]
    let provider: String
    let aiCast: Bool
    let aiAvailable: Bool

    var availableLines: Int { unlocked ? totalLines : previewLines }

    init(
        id: String,
        title: String,
        author: String = "",
        cover: String = "",
        words: Int = 0,
        cast: [String: CastMember] = [:],
        totalLines: Int,
        unlocked: Bool,
        previewLines: Int,
        lines: [StoryLine],
        chapters: [Chapter] = [],
        provider: String = "browser",
        aiCast: Bool = false,
        aiAvailable: Bool = false
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.cover = cover
        self.words = words
        self.cast = cast
        self.totalLines = totalLines
        self.unlocked = unlocked
        self.previewLines = previewLines
        self.lines = lines
        self.chapters = chapters
        self.provider = provider
        self.aiCast = aiCast
        self.aiAvailable = aiAvailable
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, author, cover, words, cast, unlocked, lines, chapters, provider
        case totalLines = "total_lines"
        case previewLines = "preview_lines"
        case aiCast = "ai_cast"
        case aiAvailable = "ai_available"
    }
}

struct LibraryBook: Codable, Sendable, Identifiable, Equatable {
    let id: String
    let title: String
    let author: String
    let cover: String
    let createdAt: Date
    let unlocked: Bool

    private enum CodingKeys: String, CodingKey {
        case id, title, author, cover, unlocked
        case createdAt = "created_at"
    }
}

struct LinePage: Codable, Sendable, Equatable {
    let total: Int
    let available: Int
    let lines: [StoryLine]
}

enum LineAudio: Sendable {
    case mp3(Data)
    case speechFallback
}
