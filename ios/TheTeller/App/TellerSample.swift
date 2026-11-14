import Foundation

struct TellerSample {
    let book: Book
    let genre: String
    let symbol: String

    static let all = [
        TellerSample(
            slug: "lantern-keeper", title: "The Lantern Keeper", genre: "Mystery", symbol: "light.beacon.max",
            characters: [
                ("Narrator", "narrator_f", "female"),
                ("Nora", "f1", "female"),
                ("Elias", "m1", "male")
            ],
            lines: [
                ("Narrator", "At the end of the pier, the lantern was burning for the first time in twelve years.", "neutral"),
                ("Nora", "You saw who lit it?", "whisper"),
                ("Elias", "No. But someone has been leaving my name in the keeper’s log.", "scared"),
                ("Narrator", "Nora reached for the door. From the other side, someone turned the handle first.", "neutral")
            ]
        ),
        TellerSample(
            slug: "radio-orchard", title: "The Radio Orchard", genre: "Science fiction", symbol: "antenna.radiowaves.left.and.right",
            characters: [
                ("Narrator", "narrator_f", "female"),
                ("May", "f1", "female"),
                ("Ivo", "m1", "male")
            ],
            lines: [
                ("Narrator", "When May switched off the transmitter, the orchard kept broadcasting.", "neutral"),
                ("Ivo", "It's reading out tomorrow's weather.", "surprised"),
                ("May", "Wait. That's my voice. I haven't recorded that yet.", "scared"),
                ("Narrator", "The broadcast ended with the sound of an apple hitting a metal roof.", "neutral"),
                ("Ivo", "Do we have a metal roof?", "whisper")
            ]
        ),
        TellerSample(
            slug: "blue-umbrella", title: "The Blue Umbrella", genre: "Romance", symbol: "umbrella",
            characters: [
                ("Narrator", "narrator_f", "female"),
                ("Ruth", "f2", "female"),
                ("Ben", "m2", "male")
            ],
            lines: [
                ("Narrator", "The bookshop put its umbrellas out after closing for anyone walking home in the rain.", "neutral"),
                ("Ruth", "I thought you'd take the blue one.", "tender"),
                ("Ben", "I always do. You keep putting it back.", "happy"),
                ("Ruth", "Then I guess either of us could have said something sooner.", "tender"),
                ("Narrator", "The rain was almost over, but they opened it anyway.", "neutral")
            ]
        )
    ]

    private init(
        slug: String,
        title: String,
        genre: String,
        symbol: String,
        characters: [(name: String, voice: String, gender: String)],
        lines: [(speaker: String, text: String, emotion: String)]
    ) {
        self.genre = genre
        self.symbol = symbol
        let transcript = lines.enumerated().map { index, line in
            StoryLine(index: index, speaker: line.speaker, text: line.text, emotion: line.emotion)
        }
        let cast = Dictionary(uniqueKeysWithValues: characters.map { character in
            let count = transcript.filter { $0.speaker == character.name }.count
            return (character.name, CastMember(voice: character.voice, gender: character.gender, lines: count))
        })
        self.book = Book(
            id: "teller-sample-" + slug,
            title: title,
            author: "The Teller",
            cast: cast,
            totalLines: transcript.count,
            unlocked: true,
            previewLines: transcript.count,
            lines: transcript
        )
    }
}
