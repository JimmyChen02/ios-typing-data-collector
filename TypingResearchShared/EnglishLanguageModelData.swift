import Foundation
import CryptoKit

/// Provenance for the frozen SymSpell English lexicon used in every keyboard condition.
public enum EnglishLanguageModelData {
    public static let modelIdentifier = "symspell-en-30k-c239062"
    public static let artifactResourceName = "symspell_en_30k"
    public static let sourceCommit = "c239062ae02961df18ab7da1671d01b4388204e0"
    public static let sourceBlob = "3682dedea3400a7f3ff34d521844c9c0c427ed74"
    public static let sourceSHA256 =
        "c604e1121e398ae7c7fbf777f11e0a0f2fa66eda932cb9fba1321466cf3acd7b"
    public static let generatedModelSHA256 =
        "843eeab1fec16df7699851a52cf97be8ec71e429cd6148fb0a21ce464a0293c8"
    public static let expectedUnigramCount = 30_000
    public static let expectedCorrectionCount = 5

    static let shared = EnglishLexiconModel.load()

    public static var isLoaded: Bool {
        shared.isLoaded
    }

    public static var loadedUnigramCount: Int {
        shared.wordsByNormalizedForm.count
    }

    public static var eventMetadata: [String: String] {
        [
            "languageModel": modelIdentifier,
            "languageModelSourceCommit": sourceCommit,
            "languageModelSourceBlob": sourceBlob,
            "languageModelSourceSHA256": sourceSHA256,
            "languageModelArtifactSHA256": generatedModelSHA256,
            "languageModelLoaded": isLoaded ? "true" : "false"
        ]
    }
}

struct EnglishLexiconWord: Hashable, Sendable {
    let text: String
    let normalized: String
    let frequency: Int
}

final class EnglishLexiconModel: @unchecked Sendable {
    let wordsByNormalizedForm: [String: EnglishLexiconWord]
    let prefixBuckets: [Character: [EnglishLexiconWord]]
    let correctionBuckets: [Int: [EnglishLexiconWord]]
    let directCorrections: [String: String]
    let globallyRankedWords: [EnglishLexiconWord]
    let isLoaded: Bool

    private init(
        wordsByNormalizedForm: [String: EnglishLexiconWord],
        directCorrections: [String: String],
        isLoaded: Bool
    ) {
        self.wordsByNormalizedForm = wordsByNormalizedForm
        self.directCorrections = directCorrections
        self.isLoaded = isLoaded

        let words = Array(wordsByNormalizedForm.values)
        prefixBuckets = Dictionary(grouping: words) { $0.normalized.first ?? Character("\0") }
        correctionBuckets = Dictionary(grouping: words) {
            $0.normalized.count
        }
        globallyRankedWords = words.sorted(by: Self.ranksBefore)
    }

    static func load() -> EnglishLexiconModel {
        guard let url = modelURL(),
              let data = try? Data(contentsOf: url),
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined()
                == EnglishLanguageModelData.generatedModelSHA256,
              let contents = String(data: data, encoding: .utf8) else {
            return EnglishLexiconModel(
                wordsByNormalizedForm: [:],
                directCorrections: [:],
                isLoaded: false
            )
        }

        var words: [String: EnglishLexiconWord] = [:]
        var corrections: [String: String] = [:]
        for line in contents.split(separator: "\n") where !line.hasPrefix("#") {
            let columns = line.split(
                separator: "\t",
                maxSplits: 2,
                omittingEmptySubsequences: false
            )
            guard columns.count == 3 else { continue }
            switch columns[0] {
            case "W":
                guard let frequency = Int(columns[1]) else { continue }
                let text = String(columns[2])
                let normalized = text.lowercased()
                words[normalized] = EnglishLexiconWord(
                    text: text,
                    normalized: normalized,
                    frequency: frequency
                )
            case "S":
                corrections[String(columns[1]).lowercased()] = String(columns[2])
            default:
                continue
            }
        }

        let hasExpectedContents =
            words.count == EnglishLanguageModelData.expectedUnigramCount
            && corrections.count == EnglishLanguageModelData.expectedCorrectionCount
        return EnglishLexiconModel(
            wordsByNormalizedForm: words,
            directCorrections: corrections,
            isLoaded: hasExpectedContents
        )
    }

    private static func modelURL() -> URL? {
        let resource = EnglishLanguageModelData.artifactResourceName
        let bundles = [Bundle.main] + Bundle.allBundles + Bundle.allFrameworks
        return bundles.lazy.compactMap {
            $0.url(forResource: resource, withExtension: "tsv")
        }.first
    }

    static func ranksBefore(_ lhs: EnglishLexiconWord, _ rhs: EnglishLexiconWord) -> Bool {
        if lhs.frequency != rhs.frequency {
            return lhs.frequency > rhs.frequency
        }
        return lhs.normalized < rhs.normalized
    }
}
