#if os(iOS) || os(visionOS)
import Foundation

/// Pure Hangul syllable transformation used by the iOS IME bridge.
public enum SwiftTermHangulInput {
    private static let syllableBase = 0xAC00
    private static let syllableEnd = 0xD7A3
    private static let vowelCount = 21
    private static let finalCount = 28

    private static let vowelIndexByJamo: [Character: Int] = [
        "ㅏ": 0, "ㅐ": 1, "ㅑ": 2, "ㅒ": 3,
        "ㅓ": 4, "ㅔ": 5, "ㅕ": 6, "ㅖ": 7,
        "ㅗ": 8, "ㅘ": 9, "ㅙ": 10, "ㅚ": 11,
        "ㅛ": 12, "ㅜ": 13, "ㅝ": 14, "ㅞ": 15,
        "ㅟ": 16, "ㅠ": 17, "ㅡ": 18, "ㅢ": 19, "ㅣ": 20
    ]

    // Maps a final-consonant index to the final that remains on the previous
    // syllable and the initial-consonant index that moves to the next one.
    private static let splitFinal: [Int: (remainingFinal: Int, nextInitial: Int)] = [
        1: (0, 0), 2: (0, 1), 3: (1, 9),
        4: (0, 2), 5: (4, 12), 6: (4, 18),
        7: (0, 3),
        8: (0, 5), 9: (8, 0), 10: (8, 6), 11: (8, 7),
        12: (8, 9), 13: (8, 16), 14: (8, 17), 15: (8, 18),
        16: (0, 6), 17: (0, 7), 18: (17, 9),
        19: (0, 9), 20: (0, 10), 21: (0, 11),
        22: (0, 12), 23: (0, 14), 24: (0, 15),
        25: (0, 16), 26: (0, 17), 27: (0, 18)
    ]

    public static func resyllabifyFinalConsonant(
        base: Character,
        followingVowel: Character
    ) -> String? {
        guard let vowelIndex = vowelIndexByJamo[followingVowel],
              base.unicodeScalars.count == 1,
              let scalar = base.unicodeScalars.first else { return nil }

        let scalarValue = Int(scalar.value)
        guard scalarValue >= syllableBase, scalarValue <= syllableEnd else { return nil }

        let syllableIndex = scalarValue - syllableBase
        let initialIndex = syllableIndex / (vowelCount * finalCount)
        let previousVowelIndex = (syllableIndex % (vowelCount * finalCount)) / finalCount
        let finalIndex = syllableIndex % finalCount
        guard let split = splitFinal[finalIndex] else { return nil }

        let previousValue = syllableBase
            + (initialIndex * vowelCount + previousVowelIndex) * finalCount
            + split.remainingFinal
        let nextValue = syllableBase
            + (split.nextInitial * vowelCount + vowelIndex) * finalCount

        guard let previousScalar = UnicodeScalar(previousValue),
              let nextScalar = UnicodeScalar(nextValue) else { return nil }
        return String(Character(previousScalar)) + String(Character(nextScalar))
    }
}
#endif
