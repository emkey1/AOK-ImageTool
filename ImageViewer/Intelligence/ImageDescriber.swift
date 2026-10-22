import CoreGraphics
import Foundation
import FoundationModels

// Apple Intelligence (the on-device Foundation Model). All FoundationModels use lives in this file behind
// version-neutral types: the model arrived in macOS 26, and image input in macOS 27. On older systems
// `ImageDescriber.support` reports `.unavailable` and the app hides or explains the features.

@available(macOS 26, *)
@Generable
nonisolated struct GeneratedDescription {
    @Guide(description: "A short, specific title for the image, 2 to 6 words, no ending punctuation")
    var title: String

    @Guide(description: "One or two factual sentences describing the image for someone who cannot see it")
    var caption: String

    @Guide(description: "Lowercase search keywords covering subjects, setting, colors and mood", .count(4...10))
    var keywords: [String]

    @Guide(description: "A descriptive file name of 2 to 6 lowercase words separated by hyphens, without a file extension")
    var fileName: String
}

@available(macOS 26, *)
@Generable
nonisolated struct GeneratedSetting {
    @Guide(description: """
        A short caption of only the photo's surroundings, 6 to 15 words, such as "a harbor with boats and \
        colorful houses on a sunny day". Never mention people, faces, clothing, animals or the main subject.
        """)
    var setting: String
}

@available(macOS 26, *)
@Generable
nonisolated struct GeneratedSubject {
    @Guide(description: """
        The main subject only, as a short phrase of 3 to 12 words: who or what it is, and what stands out \
        (pose, clothing, colors). Nothing about the background or setting.
        """)
    var subject: String
}

nonisolated struct ImageDescription: Codable, Equatable, Sendable {
    var title: String
    var caption: String
    var keywords: [String]
    var fileName: String
    /// True when the model looked at the pixels; false when it only saw Vision labels and OCR text.
    var fromPixels: Bool
}

nonisolated enum ModelSupport: Equatable, Sendable {
    case vision
    case textOnly
    case unavailable(String)

    var isAvailable: Bool {
        if case .unavailable = self { return false }
        return true
    }
}

nonisolated enum DescribeError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason): reason
        }
    }
}

/// Apple Intelligence (on-device Foundation Model) features: captions, keywords, names and Q&A.
nonisolated enum ImageDescriber {
    static let instructions = """
        You are a meticulous photo librarian. Describe images accurately and concisely. \
        Only state what is actually visible; never invent names, places or text.
        """

    static let needsNewerSystem = "Apple Intelligence features need macOS 26 or later."

    static var support: ModelSupport {
        guard #available(macOS 26, *) else { return .unavailable(needsNewerSystem) }
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            if #available(macOS 27, *) {
                return model.capabilities.contains(.vision) ? .vision : .textOnly
            }
            return .textOnly
        case .unavailable(.deviceNotEligible):
            return .unavailable("This Mac doesn't support Apple Intelligence.")
        case .unavailable(.appleIntelligenceNotEnabled):
            return .unavailable("Turn on Apple Intelligence in System Settings to use this.")
        case .unavailable(.modelNotReady):
            return .unavailable("Apple Intelligence is still getting ready. Try again shortly.")
        case .unavailable:
            return .unavailable("Apple Intelligence isn't available right now.")
        }
    }

    static func describe(_ image: CGImage, labels: [String], text: String) async throws -> ImageDescription {
        guard #available(macOS 26, *) else { throw DescribeError.unavailable(needsNewerSystem) }
        return try await describeWithModel(image, labels: labels, text: text)
    }

    @available(macOS 26, *)
    private static func describeWithModel(_ image: CGImage, labels: [String], text: String) async throws -> ImageDescription {
        let support = self.support
        if case .unavailable(let reason) = support { throw DescribeError.unavailable(reason) }
        let session = LanguageModelSession(instructions: instructions)
        let ocr = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if #available(macOS 27, *), support == .vision {
            let response = try await session.respond(generating: GeneratedDescription.self) {
                "Describe this image."
                if !ocr.isEmpty {
                    "For reference, text detected in the image: \(String(ocr.prefix(400)))"
                }
                Attachment(image)
            }
            return ImageDescription(response.content, fromPixels: true)
        }
        let prompt = """
            An image classifier analyzed a photo. Detected labels, most confident first: \(labels.prefix(12).joined(separator: ", ")).
            \(ocr.isEmpty ? "" : "Text detected in the image: \(ocr.prefix(400))")
            Describe the most likely image based only on this evidence.
            """
        let response = try await session.respond(to: prompt, generating: GeneratedDescription.self)
        return ImageDescription(response.content, fromPixels: false)
    }

    /// The photo's surroundings without its subject ("a restaurant with wooden tables, dark chairs and a
    /// light wood floor"), for Extend's generative fill to continue. nil when Apple Intelligence isn't
    /// available or has nothing to say.
    static func describeSetting(_ image: CGImage, labels: [String]) async -> String? {
        guard #available(macOS 26, *) else { return nil }
        return try? await describeSettingWithModel(image, labels: labels)
    }

    @available(macOS 26, *)
    private static func describeSettingWithModel(_ image: CGImage, labels: [String]) async throws -> String? {
        let support = self.support
        if case .unavailable = support { return nil }
        let session = LanguageModelSession(instructions: """
            You describe where photos were taken, for an image generator that continues the scene past the \
            photo's edges. Describe only the surroundings, never people, animals or the main subject.
            """)
        let setting: String
        if #available(macOS 27, *), support == .vision {
            setting = try await session.respond(generating: GeneratedSetting.self) {
                "Describe the setting and background of this photo."
                Attachment(image)
            }.content.setting
        } else {
            guard !labels.isEmpty else { return nil }
            setting = try await session.respond(to: """
                An image classifier found these in a photo, most confident first: \(labels.prefix(12).joined(separator: ", ")).
                Describe the photo's likely setting and background.
                """, generating: GeneratedSetting.self).content.setting
        }
        return cleanedCaption(setting)
    }

    /// A model's caption without punctuation around it, or an echo of its instructions before a colon.
    private static func cleanedCaption(_ text: String) -> String? {
        var text = text
        if let colon = text.lastIndex(of: ":") { text = String(text[text.index(after: colon)...]) }
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return cleaned.isEmpty ? nil : cleaned
    }

    /// The main subject in a short phrase ("a smiling woman with long gray hair in a turquoise shirt"), for
    /// a background generated around it. nil when Apple Intelligence isn't available.
    static func describeSubject(_ image: CGImage, labels: [String]) async -> String? {
        guard #available(macOS 26, *) else { return nil }
        return try? await describeSubjectWithModel(image, labels: labels)
    }

    @available(macOS 26, *)
    private static func describeSubjectWithModel(_ image: CGImage, labels: [String]) async throws -> String? {
        let support = self.support
        if case .unavailable = support { return nil }
        let session = LanguageModelSession(instructions: """
            You describe the main subject of a cut-out photo for an image generator that will paint a new \
            background behind it. Describe only the subject, briefly and factually.
            """)
        let subject: String
        if #available(macOS 27, *), support == .vision {
            subject = try await session.respond(generating: GeneratedSubject.self) {
                "Describe the main subject of this photo."
                Attachment(image)
            }.content.subject
        } else {
            guard !labels.isEmpty else { return nil }
            subject = try await session.respond(to: """
                An image classifier found these in a cut-out photo, most confident first: \(labels.prefix(12).joined(separator: ", ")).
                Describe its likely main subject.
                """, generating: GeneratedSubject.self).content.subject
        }
        return cleanedCaption(subject)
    }

    @available(macOS 26, *)
    static func chatSession() -> LanguageModelSession {
        LanguageModelSession(instructions: """
            You answer questions about the image the user is looking at. Be concise and specific. \
            If something can't be determined from the image, say so.
            """)
    }

    static func friendlyError(_ error: Error) -> String {
        if #available(macOS 27, *), let e = error as? LanguageModelError {
            switch e {
            case .guardrailViolation: return "Apple Intelligence declined to respond to this image or question."
            case .contextSizeExceeded: return "The conversation got too long. Start a new one."
            case .unsupportedLanguageOrLocale: return "This language isn't supported yet."
            case .refusal: return "Apple Intelligence declined to respond."
            case .rateLimited: return "Apple Intelligence is busy. Try again in a moment."
            case .timeout: return "Apple Intelligence took too long to respond."
            default: break
            }
        } else if #available(macOS 26, *), let e = error as? LanguageModelSession.GenerationError {
            switch e {
            case .guardrailViolation: return "Apple Intelligence declined to respond to this image or question."
            case .exceededContextWindowSize: return "The conversation got too long. Start a new one."
            case .unsupportedLanguageOrLocale: return "This language isn't supported yet."
            case .refusal: return "Apple Intelligence declined to respond."
            case .rateLimited: return "Apple Intelligence is busy. Try again in a moment."
            default: break
            }
        }
        return error.localizedDescription
    }
}

/// A conversation about one image. The first question sends the image itself when the model can see
/// (macOS 27), otherwise a text description of it from Vision; follow-ups continue the same session.
nonisolated final class ImageChat: @unchecked Sendable {
    /// A `LanguageModelSession` (macOS 26+), type-erased so this class exists on every supported system.
    private var session: AnyObject?
    /// The image (or its description) has gone with a question that was answered.
    private var contextSent = false

    /// Streams the answer, calling `partial` with the text so far. `describe` produces the text stand-in
    /// for the image when the model can't take images.
    func ask(_ question: String, image: CGImage, describe: () async -> String, partial: (String) -> Void) async throws {
        guard #available(macOS 26, *) else { throw DescribeError.unavailable(ImageDescriber.needsNewerSystem) }
        try await askModel(question, image: image, describe: describe, partial: partial)
    }

    @available(macOS 26, *)
    private func askModel(_ question: String, image: CGImage, describe: () async -> String, partial: (String) -> Void) async throws {
        // Until a question with the image has been answered, each try starts a fresh session with it.
        let isFirst = !contextSent
        let chat = (isFirst ? nil : session as? LanguageModelSession) ?? ImageDescriber.chatSession()
        session = chat
        let stream: LanguageModelSession.ResponseStream<String>
        if isFirst {
            if #available(macOS 27, *), ImageDescriber.support == .vision {
                let small = await VisionServices.downscaled(image, maxDimension: 1024)
                stream = chat.streamResponse {
                    question
                    Attachment(small)
                }
            } else {
                let context = await describe()
                stream = chat.streamResponse(to: "\(context)\nQuestion: \(question)")
            }
        } else {
            stream = chat.streamResponse(to: question)
        }
        for try await snapshot in stream {
            partial(snapshot.content)
        }
        contextSent = true
    }
}

@available(macOS 26, *)
nonisolated extension ImageDescription {
    init(_ generated: GeneratedDescription, fromPixels: Bool) {
        title = generated.title.trimmingCharacters(in: .whitespacesAndNewlines)
        caption = generated.caption.trimmingCharacters(in: .whitespacesAndNewlines)
        keywords = Array(Set(generated.keywords.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }))
            .filter { !$0.isEmpty }
            .sorted()
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        let slug = generated.fileName.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .unicodeScalars.filter { allowed.contains($0) }
        fileName = String(String.UnicodeScalarView(slug))
            .split(separator: "-", omittingEmptySubsequences: true)
            .prefix(8)
            .joined(separator: "-")
        self.fromPixels = fromPixels
    }
}
