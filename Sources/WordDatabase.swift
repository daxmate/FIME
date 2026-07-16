import Foundation

/// Manages word dictionary loading, subsequence matching, and dynamic frequency tracking.
final class WordDatabase {
    private var words: [String] = []
    private var frequencies: [String: Int] = [:]
    private let maxWords = 3000

    private let frequencyURL: URL

    // MARK: - Initialization

    init() {
        frequencyURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".fime_frequencies.json")

        loadWordList()
        loadFrequencies()
    }

    // MARK: - Public API

    /// Returns up to 8 candidate words matching `prefix` as a subsequence,
    /// sorted by descending frequency then ascending length.
    func predict(prefix: String) -> [String] {
        let lower = prefix.lowercased()
        guard !lower.isEmpty else { return [] }

        var results = words.filter { isSubsequence(lower, in: $0.lowercased()) }

        results.sort { a, b in
            let fa = frequencies[a.lowercased()] ?? 0
            let fb = frequencies[b.lowercased()] ?? 0
            if fa != fb { return fa > fb }
            return a.count < b.count
        }

        return Array(results.prefix(8))
    }

    /// Record that the user selected a word (bumps frequency).
    func recordSelection(_ word: String) {
        let key = word.lowercased()
        frequencies[key, default: 0] += 1
    }

    /// Persist frequency data to disk.
    func saveFrequencies() {
        guard let data = try? JSONEncoder().encode(frequencies) else { return }
        try? data.write(to: frequencyURL, options: .atomic)
    }

    // MARK: - Private Helpers

    private func loadWordList() {
        // 1) Try bundled resources first
        if let bundled = Bundle.main.path(forResource: "words", ofType: "txt"),
           let content = try? String(contentsOfFile: bundled, encoding: .utf8) {
            parseWords(from: content)
            return
        }

        // 2) Fall back to system dictionary
        let systemPath = "/usr/share/dict/words"
        guard let content = try? String(contentsOfFile: systemPath, encoding: .utf8) else {
            NSLog("[FIME] Could not load word list from any source")
            return
        }
        parseWords(from: content)
    }

    private func parseWords(from content: String) {
        let all = content
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty && $0.allSatisfy(\.isLetter) }

        // Take common-ish words: prefer shorter ones (they tend to be more common),
        // but take at most maxWords.
        words = Array(all.prefix(maxWords))

        // Also seed from words that only contain ASCII letters (common English)
        if words.count < maxWords / 2 {
            let extended = all.filter { $0.allSatisfy { $0.isASCII && $0.isLetter } }
            words = Array(extended.prefix(maxWords))
        }

        NSLog("[FIME] Loaded \(words.count) words")
    }

    private func loadFrequencies() {
        guard let data = try? Data(contentsOf: frequencyURL),
              let freqs = try? JSONDecoder().decode([String: Int].self, from: data)
        else { return }
        frequencies = freqs
        NSLog("[FIME] Loaded \(frequencies.count) frequency entries")
    }

    /// Check if `pattern` appears as a subsequence of `word`.
    /// e.g. "pls" is a subsequence of "please", "plans", "plaster" etc.
    private func isSubsequence(_ pattern: String, in word: String) -> Bool {
        var it = pattern.makeIterator()
        guard var current = it.next() else { return false }

        for wChar in word {
            if wChar == current {
                if let next = it.next() {
                    current = next
                } else {
                    return true // matched all pattern characters
                }
            }
        }
        return false
    }
}
