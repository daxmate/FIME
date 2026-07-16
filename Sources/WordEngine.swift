import Foundation

/// Thin service layer between the input controller and the database.
final class WordEngine {
    private let database: WordDatabase

    init(database: WordDatabase) {
        self.database = database
    }

    // MARK: - Public API

    /// Return candidate words for the current user input.
    func candidates(for input: String) -> [String] {
        guard !input.isEmpty else { return [] }
        return database.predict(prefix: input)
    }

    /// Record that the user picked a word so it ranks higher next time.
    func select(_ word: String) {
        database.recordSelection(word)
        database.saveFrequencies()
    }
}
