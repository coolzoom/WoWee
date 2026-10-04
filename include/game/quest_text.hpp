#pragma once

// The strings in SMSG_QUEST_QUERY_RESPONSE, and which of them is which.
//
// The response carries a run of C-strings after its numeric block - Title,
// Objectives, Details, EndText, CompletedText - and this client reads them at
// an offset it has to work out. So every read is checked for being text at all
// rather than trusted, and the two that can hold the "what to do now" line are
// chosen between rather than merged.
//
// Header-only and free of the packet reader so it can be tested: the choice
// between two strings is the part that was getting answered wrong, and it is
// pure.

#include <cctype>
#include <cstdint>
#include <string>

namespace wowee::game {

/// Whether a UTF-8 scalar is punctuation rather than a letter. Localized
/// titles are often nothing but CJK; the dots and dashes in them are not
/// enough to call the string text.
inline bool questTextCodepointIsPunct(uint32_t cp) {
    return (cp >= 0x2000 && cp <= 0x206F) ||
           (cp >= 0x3000 && cp <= 0x303F) ||
           cp == 0x00B7 ||
           (cp >= 0xFF00 && cp <= 0xFF0F) ||
           (cp >= 0xFF1A && cp <= 0xFF20) ||
           (cp >= 0xFF3B && cp <= 0xFF40) ||
           (cp >= 0xFF5B && cp <= 0xFF65);
}

/// Whether a string read out of the packet is text rather than the numbers on
/// either side of it: inside the length the field allows, free of control
/// characters, and carrying at least one letter.
///
/// A letter is an ASCII alphabetic, or a well-formed UTF-8 scalar that is not
/// punctuation. German "Rückkehr" still passes on its ASCII letters; a zhCN
/// title with no Latin in it used to fail, so the log kept "Quest #id".
inline bool questTextIsReadable(const std::string& s, size_t minLen, size_t maxLen) {
    if (s.size() < minLen || s.size() > maxLen) return false;
    bool hasLetter = false;
    for (size_t i = 0; i < s.size(); ) {
        const unsigned char c = static_cast<unsigned char>(s[i]);
        if (c < 0x20 && c != '\t' && c != '\n' && c != '\r') return false;
        if (c < 0x80) {
            if (std::isalpha(c)) hasLetter = true;
            ++i;
            continue;
        }
        int need = 0;
        uint32_t cp = 0;
        if ((c & 0xE0) == 0xC0) { need = 1; cp = c & 0x1F; }
        else if ((c & 0xF0) == 0xE0) { need = 2; cp = c & 0x0F; }
        else if ((c & 0xF8) == 0xF0) { need = 3; cp = c & 0x07; }
        else { ++i; continue; }
        if (i + 1 + static_cast<size_t>(need) > s.size()) { ++i; continue; }
        bool ok = true;
        for (int k = 1; k <= need; ++k) {
            const unsigned char cc = static_cast<unsigned char>(s[i + static_cast<size_t>(k)]);
            if ((cc & 0xC0) != 0x80) { ok = false; break; }
            cp = (cp << 6) | (cc & 0x3F);
        }
        if (!ok) { ++i; continue; }
        i += 1 + static_cast<size_t>(need);
        if (!questTextCodepointIsPunct(cp)) hasLetter = true;
    }
    return hasLetter;
}

/// The line a finished quest shows, out of the two strings that can hold one.
///
/// CompletedText is the fifth string and is what the game shows for a quest
/// that is done. EndText is the fourth, and on the clients that have no fifth
/// it is where "Return to Marshal Dughan at Goldshire in Elwynn Forest." lives.
/// So the fifth wins whenever it says anything and the fourth stands in when it
/// does not.
///
/// This used to take whichever of the two was longer, which is a different
/// question: a quest carrying both got its EndText wherever that ran longer
/// than its CompletedText, and neither read as text left the line blank rather
/// than falling back.
inline std::string questCompletedText(const std::string& endText,
                                      const std::string& completedText) {
    // The same bounds the reader uses for a one-line string: long enough to be
    // a sentence, short enough that a run of packet bytes cannot pass.
    constexpr size_t kMin = 8;
    constexpr size_t kMax = 600;
    if (questTextIsReadable(completedText, kMin, kMax)) return completedText;
    if (questTextIsReadable(endText, kMin, kMax)) return endText;
    return {};
}

} // namespace wowee::game
