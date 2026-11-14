#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 FixDock contributors
"""Makes the word lists of the Korean/English layout fix (docs/typo-switch.md, section 4).

Reads the two FrequencyWords 2018 lists and writes Resources/Lexicon/en.txt and
ko.txt: one word per line, most frequent first, so a line number is a rank.
The outputs are committed; build.sh never runs this and it makes no network
call. Running it twice gives byte-identical files.

    python3 Tools/make-lexicon.py <en_50k.txt> <ko_50k.txt>

The inputs are content/2018/en/en_50k.txt and content/2018/ko/ko_50k.txt of
github.com/hermitdave/FrequencyWords at commit
525f9b560de45753a5ea01069454e72e9aa541c6 (CC BY-SA 4.0). Anything else is
refused. Every filter below is a change NOTICE has to list.
"""

import hashlib
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
PINNED = {
    "en": "5351ff405b1126ef555791dd4d9798a48e3e9a501a9fc481a9da957752cfb458",
    "ko": "8d00401b6728c8d6feeaa5455583c1a33408dd020aae4aa55609b25004d1d99d",
}
CAP = {"en": 30_000, "ko": 50_000}
ENGLISH = re.compile(r"[a-z]+")
ONE_LETTER_WORDS = {"a", "i"}
# Owner decision D9 (2026-11-12): the subtitle list's noise stands in front
# of common Korean words typed on the wrong layout ("rm" is 그, "dl" is 이),
# so English entries with no vowel, or with one letter three times in a row,
# go. Names, profanity and Korean misspellings stay as upstream has them.
VOWEL = re.compile(r"[aeiouy]")
TRIPLED = re.compile(r"(.)\1\1")
HANGUL_SYLLABLES = re.compile(r"[가-힣]+")


def keep(language, word):
    if language == "en":
        return (bool(ENGLISH.fullmatch(word)) and (len(word) >= 2 or word in ONE_LETTER_WORDS)
                and bool(VOWEL.search(word)) and not TRIPLED.search(word))
    return bool(HANGUL_SYLLABLES.fullmatch(word))


def words(language, data):
    """The upstream lines are `word count`, most frequent first."""
    seen = set()
    result = []
    for line in data.decode("utf-8").splitlines():
        word = line.split(" ")[0]
        if language == "en":
            word = word.lower()
        if word in seen or not keep(language, word):
            continue
        seen.add(word)
        result.append(word)
        if len(result) == CAP[language]:
            break
    return result


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    out = ROOT / "Resources" / "Lexicon"
    out.mkdir(parents=True, exist_ok=True)
    for language, source in zip(("en", "ko"), sys.argv[1:]):
        data = pathlib.Path(source).read_bytes()
        digest = hashlib.sha256(data).hexdigest()
        if digest != PINNED[language]:
            sys.exit(f"{source}: SHA-256 {digest} is not the pinned {language} list")
        kept = words(language, data)
        target = out / f"{language}.txt"
        target.write_bytes(("\n".join(kept) + "\n").encode("utf-8"))
        print(f"{target.relative_to(ROOT)}: {len(kept)} words, {target.stat().st_size} bytes, "
              f"SHA-256 {hashlib.sha256(target.read_bytes()).hexdigest()}")


if __name__ == "__main__":
    main()
