import Foundation

struct HumanCatalogPage: Decodable, Sendable {
    let items: [HumanAudiobook]
    let nextOffset: Int?

    enum CodingKeys: String, CodingKey {
        case items
        case nextOffset = "next_offset"
    }
}

struct HumanAudiobook: Decodable, Sendable, Identifiable, Equatable {
    let id: String
    let title: String
    let authors: [String]
    let description: String
    let coverURL: URL?
    let sourceURL: URL?
    let rightsURL: URL?
    let durationSeconds: Int?
    let trackCount: Int?
    let tracks: [HumanTrack]?

    enum CodingKeys: String, CodingKey {
        case id, title, authors, description, tracks
        case coverURL = "cover_url"
        case sourceURL = "source_url"
        case rightsURL = "rights_url"
        case durationSeconds = "duration_seconds"
        case trackCount = "track_count"
    }
}

struct HumanTrack: Decodable, Sendable, Identifiable, Equatable {
    let id: String
    let index: Int
    let title: String
    let audioURL: URL
    let durationSeconds: Int?
    let readers: [String]

    enum CodingKeys: String, CodingKey {
        case id, index, title, readers
        case audioURL = "audio_url"
        case durationSeconds = "duration_seconds"
    }
}
