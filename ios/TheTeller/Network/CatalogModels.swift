import Foundation

struct CatalogPage: Decodable, Sendable {
    let items: [CatalogBook]
    let nextPage: Int?

    enum CodingKeys: String, CodingKey {
        case items
        case nextPage = "next_page"
    }
}

struct CatalogBook: Decodable, Sendable, Identifiable, Equatable {
    let id: Int
    let title: String
    let authors: [String]
    let summary: String
    let cover: String
    let sourceURL: String?

    init(id: Int, title: String, authors: [String] = [], summary: String = "", cover: String = "", sourceURL: String? = nil) {
        self.id = id
        self.title = title
        self.authors = authors
        self.summary = summary
        self.cover = cover
        self.sourceURL = sourceURL
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let summary = try values.decodeIfPresent(String.self, forKey: .summary)
            ?? values.decodeIfPresent(String.self, forKey: .description)
        let sourceURL = try values.decodeIfPresent(String.self, forKey: .sourceURL)
            ?? values.decodeIfPresent(String.self, forKey: .ebookURL)
            ?? values.decodeIfPresent(String.self, forKey: .source)
        self.init(
            id: try values.decode(Int.self, forKey: .id),
            title: try values.decode(String.self, forKey: .title),
            authors: try values.decodeIfPresent([String].self, forKey: .authors) ?? [],
            summary: summary ?? "",
            cover: try values.decodeIfPresent(String.self, forKey: .cover) ?? "",
            sourceURL: sourceURL
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, authors, summary, description, cover, source
        case sourceURL = "source_url"
        case ebookURL = "ebook_url"
    }
}
