#!/usr/bin/env python3
"""Build the bundled offline vocabulary from local, attributed upstream files."""
import argparse
import csv
import hashlib
import json
import re
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
POS = {"n": "名词", "v": "动词", "vt": "及物动词", "vi": "不及物动词", "a": "形容词", "adj": "形容词", "ad": "副词", "adv": "副词", "prep": "介词", "pron": "代词", "conj": "连词", "num": "数词", "interj": "感叹词", "art": "冠词", "det": "限定词"}

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def word(identity, language, text, reading, difficulty, definition="", pos="", tags=None):
    return dict(id=identity, language=language, text=text, pronunciation=reading,
                chinese_def=definition, difficulty=difficulty, part_of_speech=pos,
                examples=[], tags=tags or [])

def build(english, japanese, output):
    selection = json.loads((ROOT / "tools/dictionary-selection.json").read_text())
    wanted = {entry["text"]: entry for entry in selection}
    result = {}
    with english.open(newline="", encoding="utf-8-sig") as stream:
        for row in csv.DictReader(stream):
            text = row["word"]
            if text not in wanted:
                continue
            source = wanted[text]
            senses = row["translation"].replace("\\n", "\n").splitlines()
            first = next((line.strip() for line in senses if line.strip()), "")
            match = re.match(r"^([a-z]+)\.\s*", first)
            pos = POS.get(match[1], "") if match else ""
            definition = first[match.end():] if match else first
            if len(definition) > 160:
                pieces = re.split(r"[;,；，]", definition)
                definition = "；".join(pieces[:3]).strip()
            reading = row["phonetic"].strip()
            if reading and reading[0] not in "/[":
                reading = "/" + reading + "/"
            result[text] = word("ecdict-" + text, "en", text, reading, source["difficulty"], definition, pos, source["tags"])
    if set(result) != set(wanted):
        raise ValueError("The ECDICT source is missing selected entries")
    english_words = [result[entry["text"]] for entry in selection]
    japanese_words = []
    occurrences = Counter()
    for text, entries in json.loads(japanese.read_text()).items():
        for entry in entries:
            level, reading = entry["level"], entry["reading"]
            identity = hashlib.sha256((text + "\0" + reading + "\0" + str(level)).encode()).hexdigest()[:24]
            # Retain all upstream records, including five exact repetitions.
            # An occurrence suffix avoids collapsing their stable identities.
            occurrences[identity] += 1
            if occurrences[identity] > 1:
                identity += f"-{occurrences[identity]}"
            difficulty = 1 if level >= 4 else 2 if level == 3 else 3
            japanese_words.append(word(f"jlpt-{6-level}-{identity}", "ja", text, reading, difficulty, tags=[f"JLPT-N{level}"]))
    output.mkdir(parents=True, exist_ok=True)
    for language, words, count in [("en", english_words, 12126), ("ja", japanese_words, 8505)]:
        assert len(words) == count and len({item["id"] for item in words}) == count
        assert all(item["text"] and item["pronunciation"] and len(item["chinese_def"]) <= 4000 for item in words)
        payload = dict(version="1.0", language=language, words=words)
        (output / f"dictionary-{language}.json").write_text(json.dumps(payload, ensure_ascii=False, separators=(",", ":")) + "\n")
        print(f"{language}: {count} entries")
    metadata = {"version": "2026-10-28", "sources": [
        {"name": "ECDICT", "url": "https://github.com/skywind3000/ECDICT", "revision": "ab22ad36302cafc6349a050e2b60894855208055", "file": "ecdict.csv", "sha256": digest(english), "entries": 12126},
        {"name": "JLPT Vocabulary", "url": "https://github.com/Bluskyo/JLPT_Vocabulary", "revision": "4358f932937ad0232194a36e9f4f875094910c6b", "file": "data/vocab/results/JLPT_vocab_ALL.json", "sha256": digest(japanese), "entries": 8505}]}
    (output / "dictionary-sources.json").write_text(json.dumps(metadata, indent=2) + "\n")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("english", type=Path)
    parser.add_argument("japanese", type=Path)
    parser.add_argument("--output", type=Path, default=ROOT / "Sources/StudyRuntime/Resources")
    args = parser.parse_args()
    build(args.english, args.japanese, args.output)
