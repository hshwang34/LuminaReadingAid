#if DEBUG
import Foundation

/// Test words for verifying DefinitionService / dictionaryapi.dev integration.
/// Use these in the debug menu or unit tests to exercise various API response shapes.
enum TestWords {

    // MARK: - Should succeed (200) with definition + example

    /// Common words — guaranteed hits with both definition and example sentence
    static let easyHits: [String] = [
        "ubiquitous",   // (adjective) has example
        "benevolent",   // (adjective) has example
        "pragmatic",    // (adjective) has example
        "read",         // (verb) multiple meanings/parts of speech
        "light",        // (noun/verb/adjective) many meanings
    ]

    // MARK: - Should succeed (200) with definition only (no example)

    /// Words that return a definition but no example sentence — tests the empty-example path
    static let noExample: [String] = [
        "serendipity",  // (noun) definition only
        "ephemeral",    // (adjective) definition only
        "luminous",     // (adjective) definition only
    ]

    // MARK: - Should succeed (200) — edge case formatting

    /// Words with special characters, casing, or whitespace that the service must handle
    static let edgeCases: [String] = [
        "  hello  ",    // leading/trailing whitespace — trimmed by service
        "HELLO",        // uppercase — lowercased by service
        "café",         // accented character
        "naïve",        // diaeresis
        "résumé",       // multiple accents
        "well-read",    // hyphenated compound
        "don't",        // contraction with apostrophe
    ]

    // MARK: - Should fail (404 / notFound)

    /// Nonsense or invalid inputs — should throw DefinitionError.notFound
    static let shouldFail: [String] = [
        "asdfghjkl",    // gibberish
        "xyzzyplugh",   // not a word
        "1984",         // number, not in dictionary
        "",             // empty string
        "won't",        // some contractions return 404 on this API
        "can't",        // same — 404
    ]

    /// All test words combined
    static let all: [String] = easyHits + noExample + edgeCases + shouldFail
}
#endif
