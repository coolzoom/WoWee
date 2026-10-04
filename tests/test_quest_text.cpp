// Which of a quest's strings holds the line a finished quest shows.
//
// SMSG_QUEST_QUERY_RESPONSE carries Title, Objectives, Details, EndText and -
// since 3.3.0 - CompletedText. Two of those can hold "what to do now", and the
// rule used to be "whichever is longer", which is a different question: a quest
// carrying both got the wrong one whenever the wrong one ran longer, and a
// quest whose fifth string was empty got a blank line rather than its fourth.
#include <catch_amalgamated.hpp>

#include "game/quest_text.hpp"

#include <string>

using wowee::game::questCompletedText;
using wowee::game::questTextIsReadable;

TEST_CASE("the fifth string wins when it says anything", "[quest][text]") {
    CHECK(questCompletedText("Return to Marshal Dughan at Goldshire in Elwynn Forest.",
                             "Speak with Marshal Dughan.") ==
          "Speak with Marshal Dughan.");
}

TEST_CASE("the fourth stands in when the fifth is empty", "[quest][text]") {
    // Which is every quest on a client that has no fifth string, and most
    // vanilla-era quests on one that does.
    CHECK(questCompletedText("Return to Bath'rah the Windwatcher.", "") ==
          "Return to Bath'rah the Windwatcher.");
}

TEST_CASE("a quest with neither has no completed line", "[quest][text]") {
    CHECK(questCompletedText("", "").empty());
}

TEST_CASE("packet bytes are not a completed line", "[quest][text]") {
    // The strings are read at an offset this client works out, so a read that
    // lands on the numbers after them must be dropped rather than shown.
    const std::string binary("\x01\x02\x00\x40\x05\x00\x00\x00\x0f", 9);
    CHECK(questCompletedText(binary, binary).empty());
    // Nor is a run of digits with no letter in it.
    CHECK_FALSE(questTextIsReadable("12345678", 8, 600));
    // And a sentence shorter than the minimum is not one either - the bound is
    // what keeps a stray two-byte read out of the tracker.
    CHECK_FALSE(questTextIsReadable("Go.", 8, 600));
}

TEST_CASE("a localized line is text", "[quest][text]") {
    // UTF-8 lead and continuation bytes are allowed; one ASCII letter is all
    // that is asked for, which "Rückkehr" has.
    CHECK(questTextIsReadable("R\xc3\xbc""ckkehr zu Marschall Dughan.", 8, 600));
}

TEST_CASE("a Chinese title is text", "[quest][text]") {
    // A zhCN query has no Latin letters. Asking for one left every title as
    // "Quest #id" and dropped the description beside it.
    CHECK(questTextIsReadable("清剿狗头人营地", 6, 72));
    CHECK(questTextIsReadable("返回闪金镇，向治安官杜汉复命。", 8, 600));
    CHECK_FALSE(questTextIsReadable("········", 8, 600));
}
