import Foundation

struct StoryMultipart: Sendable {
    static let maximumFileBytes = 100_000_000

    let url: URL
    let boundary: String

    static func prepare(_ source: StorySource) async throws -> StoryMultipart {
        let preparation = Task.detached(priority: .userInitiated) { try stage(source) }
        return try await withTaskCancellationHandler {
            let multipart = try await preparation.value
            if Task.isCancelled {
                try? FileManager.default.removeItem(at: multipart.url)
                throw CancellationError()
            }
            return multipart
        } onCancel: {
            preparation.cancel()
        }
    }

    private static func stage(_ source: StorySource) throws -> StoryMultipart {
        let boundary = "TheTeller-\(UUID().uuidString)"
        let manager = FileManager.default
        let url = manager.temporaryDirectory.appendingPathComponent("TheTeller-\(UUID().uuidString).multipart")
        try Task.checkCancellation()
        let created = manager.createFile(atPath: url.path, contents: nil, attributes: [
            .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
        ])
        guard created else { throw TellerAPIError.preparationFailed }
        do {
            let output = try FileHandle(forWritingTo: url)
            defer { try? output.close() }
            switch source {
            case let .link(value):
                try writeField("url", value: value, boundary: boundary, to: output)
            case let .text(value):
                try writeField("text", value: value, boundary: boundary, to: output)
            case let .file(inputURL):
                try writeFile(inputURL, boundary: boundary, to: output)
            }
            try output.write(contentsOf: Data("--\(boundary)--\r\n".utf8))
            try output.close()
            try Task.checkCancellation()
            return StoryMultipart(url: url, boundary: boundary)
        } catch {
            try? manager.removeItem(at: url)
            if error is CancellationError || error is TellerAPIError { throw error }
            throw TellerAPIError.preparationFailed
        }
    }

    private static func writeField(_ name: String, value: String, boundary: String, to output: FileHandle) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TellerAPIError.missingStory
        }
        let header = "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n"
        try output.write(contentsOf: Data(header.utf8))
        try output.write(contentsOf: Data(value.utf8))
        try output.write(contentsOf: Data("\r\n".utf8))
    }

    private static func writeFile(_ inputURL: URL, boundary: String, to output: FileHandle) throws {
        let mimeType: String
        switch inputURL.pathExtension.lowercased() {
        case "epub": mimeType = "application/epub+zip"
        case "pdf": mimeType = "application/pdf"
        case "docx": mimeType = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "txt": mimeType = "text/plain"
        default: throw TellerAPIError.unsupportedFile
        }
        let scoped = inputURL.startAccessingSecurityScopedResource()
        defer {
            if scoped { inputURL.stopAccessingSecurityScopedResource() }
        }

        // Preserve the selected filename for the book title while keeping the MIME header on one line.
        let filename = inputURL.lastPathComponent.unicodeScalars.map { scalar in
            CharacterSet.controlCharacters.contains(scalar) || scalar == "\"" || scalar == "\\" ? "_" : String(scalar)
        }.joined()
        let header = "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n"
            + "Content-Type: \(mimeType)\r\n\r\n"
        try output.write(contentsOf: Data(header.utf8))

        var coordinatorError: NSError?
        var readError: Error?
        NSFileCoordinator().coordinate(readingItemAt: inputURL, options: [], error: &coordinatorError) { preparedURL in
            do {
                try copyContents(of: preparedURL, to: output)
            } catch {
                readError = error
            }
        }
        if let readError { throw readError }
        if let coordinatorError { throw coordinatorError }
        try output.write(contentsOf: Data("\r\n".utf8))
    }

    private static func copyContents(of url: URL, to output: FileHandle) throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else { throw TellerAPIError.unsupportedFile }
        if let size = values.fileSize, size > maximumFileBytes { throw TellerAPIError.fileTooLarge }

        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var bytes = 0
        while let chunk = try input.read(upToCount: 256 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            bytes += chunk.count
            guard bytes <= maximumFileBytes else { throw TellerAPIError.fileTooLarge }
            try output.write(contentsOf: chunk)
        }
    }
}
