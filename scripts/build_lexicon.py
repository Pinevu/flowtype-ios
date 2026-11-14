#!/usr/bin/env python3
"""
Builds a compact, high-frequency Chinese Pinyin + English SQLite lexicon
for the FlowType iOS Keyboard Extension from MIT-licensed open datasets:
  - mozillazg/pinyin-data (MIT)
  - mozillazg/phrase-pinyin-data (MIT)
  - fxsjy/jieba (MIT)
  - hermitdave/FrequencyWords (MIT)
"""

import os
import re
import sqlite3
import unicodedata
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CACHE_DIR = ROOT / ".cache_dict"
OUT_DB = ROOT / "FlowTypeKeyboard" / "Resources" / "lexicon.sqlite"

SOURCES = {
    "char_pinyin.txt": "https://raw.githubusercontent.com/mozillazg/pinyin-data/master/pinyin.txt",
    "phrase_pinyin.txt": "https://raw.githubusercontent.com/mozillazg/phrase-pinyin-data/master/pinyin.txt",
    "large_phrase_pinyin.txt": "https://raw.githubusercontent.com/mozillazg/phrase-pinyin-data/master/large_pinyin.txt",
    "jieba_dict.txt": "https://raw.githubusercontent.com/fxsjy/jieba/master/jieba/dict.txt",
    "en_50k.txt": "https://raw.githubusercontent.com/hermitdave/FrequencyWords/master/content/2018/en/en_50k.txt",
}

UMLAUT_CHARS = set("ǖǘǚǜü")


def normalize_syllable(raw: str) -> str:
    # Normalize to NFC first so precomposed ü/tones are consistent,
    # replace ü variants carefully, then strip remaining combining tone marks.
    s = unicodedata.normalize("NFC", raw.strip().lower())
    if not s:
        return ""
    out = []
    for i, ch in enumerate(s):
        if ch in UMLAUT_CHARS:
            prev = s[i - 1] if i > 0 else ""
            out.append("v" if prev in ("l", "n") else "u")
        else:
            # Decompose this character alone to strip tone mark while checking diaeresis
            nfd = unicodedata.normalize("NFD", ch)
            base = nfd[0]
            has_diaeresis = "\u0308" in nfd[1:]
            if base == "u" and has_diaeresis:
                prev = s[i - 1] if i > 0 else ""
                out.append("v" if prev in ("l", "n") else "u")
            elif "a" <= base <= "z":
                out.append(base)
    res = "".join(out)
    if res in ("hm", "hng"):
        return ""
    return res


def download_all():
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    for name, url in SOURCES.items():
        dest = CACHE_DIR / name
        if dest.exists() and dest.stat().st_size > 0:
            print(f"[cache] {name} ({dest.stat().st_size} bytes)")
            continue
        print(f"[download] {url} -> {dest}")
        req = urllib.request.Request(url, headers={"User-Agent": "FlowTypeLexiconBuilder/1.0"})
        with urllib.request.urlopen(req, timeout=30) as resp:
            dest.write_bytes(resp.read())


def is_cjk(ch: str) -> bool:
    code = ord(ch)
    return 0x4E00 <= code <= 0x9FFF


def load_char_pinyin():
    char_readings = {}
    path = CACHE_DIR / "char_pinyin.txt"
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        # Format: U+4E00: yī  # 一
        m = re.match(r"^U\+([0-9A-Fa-f]+):\s*([^#\s]+)", line)
        if not m:
            continue
        cp = int(m.group(1), 16)
        ch = chr(cp)
        if not is_cjk(ch):
            continue
        readings = []
        for r in m.group(2).split(","):
            norm = normalize_syllable(r)
            if norm and norm not in readings:
                readings.append(norm)
        if readings:
            char_readings[ch] = readings
    print(f"[chars] loaded {len(char_readings)} CJK char pinyin mappings")
    return char_readings


def load_phrase_pinyin():
    phrase_map = {}
    for fname in ("phrase_pinyin.txt", "large_phrase_pinyin.txt"):
        path = CACHE_DIR / fname
        for line in path.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line or line.startswith("#") or ":" not in line:
                continue
            word, py_str = line.split(":", 1)
            word = word.strip()
            if not (2 <= len(word) <= 6) or not all(is_cjk(c) for c in word):
                continue
            if word in phrase_map:
                continue
            syllables = [normalize_syllable(p) for p in py_str.strip().split()]
            if len(syllables) == len(word) and all(syllables):
                phrase_map[word] = syllables
    print(f"[phrases] loaded {len(phrase_map)} phrase pinyin mappings")
    return phrase_map


def load_jieba_frequencies():
    freq_map = {}
    path = CACHE_DIR / "jieba_dict.txt"
    for line in path.read_text(encoding="utf-8").splitlines():
        parts = line.strip().split()
        if len(parts) < 2:
            continue
        word = parts[0]
        try:
            freq = int(float(parts[1]))
        except ValueError:
            continue
        if word and all(is_cjk(c) for c in word):
            if freq > freq_map.get(word, 0):
                freq_map[word] = freq
    print(f"[jieba] loaded {len(freq_map)} CJK word frequencies")
    return freq_map


def load_english_words(limit=25000):
    words = []
    seen = set()
    path = CACHE_DIR / "en_50k.txt"
    for line in path.read_text(encoding="utf-8").splitlines():
        parts = line.strip().split()
        if len(parts) < 2:
            continue
        w = parts[0].lower()
        if not re.match(r"^[a-z]+(?:'[a-z]+)?$", w):
            continue
        if w in seen:
            continue
        try:
            freq = int(parts[1])
        except ValueError:
            continue
        seen.add(w)
        words.append((w, freq))
        if len(words) >= limit:
            break
    print(f"[english] loaded {len(words)} English words")
    return words


# Curated primary pinyin overrides so common function/polyphone characters
# always rank first under their everyday Mandarin reading.
PRIMARY_CHAR_PINYIN = {
    "的": "de", "地": "de", "得": "de", "了": "le", "着": "zhe", "过": "guo",
    "和": "he", "与": "yu", "还": "hai", "都": "dou", "会": "hui", "为": "wei",
    "行": "xing", "长": "chang", "重": "zhong", "只": "zhi", "发": "fa", "没": "mei",
    "要": "yao", "好": "hao", "看": "kan", "乐": "le", "少": "shao", "种": "zhong",
    "分": "fen", "干": "gan", "当": "dang", "中": "zhong", "间": "jian", "空": "kong",
    "应": "ying", "教": "jiao", "觉": "jue", "数": "shu", "可": "ke", "那": "na",
    "哪": "na", "读": "du", "投": "tou", "个": "ge", "哥": "ge", "吗": "ma",
    "呢": "ne", "吧": "ba", "啊": "a", "哦": "o", "嗯": "en", "女": "nv",
    "绿": "lv", "旅": "lv", "率": "lv", "律": "lv", "略": "lve",
}

COMMON_PHRASE_BOOST = {
    "你好": 250000, "谢谢": 200000, "不客气": 90000, "没关系": 120000,
    "可以": 220000, "没有": 240000, "什么": 230000, "怎么": 180000,
    "为什么": 150000, "今天": 180000, "明天": 150000, "昨天": 120000,
    "现在": 210000, "时候": 190000, "大家": 160000, "我们": 260000,
    "你们": 180000, "他们": 190000, "这个": 240000, "那个": 170000,
    "这里": 150000, "那里": 130000, "如果": 190000, "因为": 200000,
    "所以": 200000, "但是": 200000, "虽然": 150000, "而且": 160000,
    "或者": 150000, "觉得": 160000, "知道": 180000, "明白": 120000,
    "确定": 110000, "完成": 120000, "发送": 110000, "修改": 110000,
    "翻译": 110000, "打开": 120000, "关闭": 100000, "语音": 120000,
    "输入法": 130000, "手机": 150000, "微信": 140000, "电脑": 120000,
    "朋友": 140000, "工作": 160000, "问题": 180000, "一起": 150000,
    "吃饭": 110000, "回家": 110000, "早上": 100000, "晚上": 120000,
    "下午": 110000, "上午": 100000, "非常": 170000, "比较": 150000,
    "应该": 160000, "需要": 170000, "希望": 140000, "喜欢": 150000,
    "开始": 160000, "结束": 120000, "人工智能": 110000,
}


def build_sqlite():
    download_all()
    char_readings = load_char_pinyin()
    phrase_map = load_phrase_pinyin()
    jieba_freq = load_jieba_frequencies()
    en_words = load_english_words(25000)

    OUT_DB.parent.mkdir(parents=True, exist_ok=True)
    if OUT_DB.exists():
        OUT_DB.unlink()

    conn = sqlite3.connect(str(OUT_DB))
    cur = conn.cursor()
    cur.executescript("""
        PRAGMA journal_mode = OFF;
        PRAGMA synchronous = OFF;
        PRAGMA page_size = 4096;

        CREATE TABLE chars (
            pinyin TEXT NOT NULL,
            hanzi TEXT NOT NULL,
            freq INTEGER NOT NULL
        );

        CREATE TABLE phrases (
            pinyin TEXT NOT NULL,
            syllables TEXT NOT NULL,
            initials TEXT NOT NULL,
            word TEXT NOT NULL,
            length INTEGER NOT NULL,
            freq INTEGER NOT NULL
        );

        CREATE TABLE en_words (
            word TEXT NOT NULL,
            freq INTEGER NOT NULL
        );
    """)

    # 1. Insert single characters (all CJK chars in jieba + remaining common chars from pinyin-data)
    char_rows = []
    for ch, readings in char_readings.items():
        base_freq = jieba_freq.get(ch, 1)
        if base_freq < 2 and ord(ch) > 0x9FA5:
            continue
        preferred = PRIMARY_CHAR_PINYIN.get(ch)
        ordered = readings
        if preferred and preferred in readings:
            ordered = [preferred] + [r for r in readings if r != preferred]
        for idx, py in enumerate(ordered):
            if idx == 0:
                w = max(base_freq, 1)
            elif idx == 1:
                # Common secondary readings (like 得 dei, 地 di, 长 zhang, 行 hang)
                w = max(base_freq // 12, 1)
            else:
                # Rare readings scaled down sharply to avoid polluting common syllables
                w = max(base_freq // 80, 1)
            char_rows.append((py, ch, w))

    cur.executemany("INSERT INTO chars (pinyin, hanzi, freq) VALUES (?, ?, ?)", char_rows)
    print(f"[db] inserted {len(char_rows)} char entries")

    # 2. Insert phrases (2..6 chars), prioritizing jieba frequency + phrase_pinyin
    phrase_candidates = []
    seen_phrases = set()

    # Ensure curated conversational words are included even if jieba frequency is low
    merged_jieba = dict(jieba_freq)
    for w, boost in COMMON_PHRASE_BOOST.items():
        merged_jieba[w] = max(merged_jieba.get(w, 0), boost)

    for word, freq in merged_jieba.items():
        if not (2 <= len(word) <= 6):
            continue
        syllables = phrase_map.get(word)
        if not syllables:
            synth = []
            ok = True
            for ch in word:
                pref = PRIMARY_CHAR_PINYIN.get(ch)
                if pref:
                    synth.append(pref)
                    continue
                r = char_readings.get(ch)
                if not r:
                    ok = False
                    break
                synth.append(r[0])
            if ok:
                syllables = synth
        if not syllables:
            continue
        joined = "".join(syllables)
        spaced = " ".join(syllables)
        initials = "".join(s[0] for s in syllables)
        phrase_candidates.append((joined, spaced, initials, word, len(word), freq))
        seen_phrases.add(word)

    # Sort by frequency descending and keep top 75,000 jieba phrases
    phrase_candidates.sort(key=lambda x: x[5], reverse=True)
    phrase_candidates = phrase_candidates[:75000]

    # Add curated extra common idioms/phrases from phrase_pinyin not in jieba top 75k (cap +5,000)
    extra_added = 0
    for word, syllables in phrase_map.items():
        if word in seen_phrases or len(word) > 4:
            continue
        joined = "".join(syllables)
        spaced = " ".join(syllables)
        initials = "".join(s[0] for s in syllables)
        phrase_candidates.append((joined, spaced, initials, word, len(word), 5))
        extra_added += 1
        if extra_added >= 5000:
            break

    cur.executemany(
        "INSERT INTO phrases (pinyin, syllables, initials, word, length, freq) VALUES (?, ?, ?, ?, ?, ?)",
        phrase_candidates,
    )
    print(f"[db] inserted {len(phrase_candidates)} phrase entries")

    # 3. Insert English words
    cur.executemany("INSERT INTO en_words (word, freq) VALUES (?, ?)", en_words)
    print(f"[db] inserted {len(en_words)} English entries")

    # 4. Create indexes & vacuum
    cur.executescript("""
        CREATE INDEX idx_chars_pinyin ON chars(pinyin, freq DESC);
        CREATE INDEX idx_phrases_pinyin ON phrases(pinyin, freq DESC);
        CREATE INDEX idx_phrases_initials ON phrases(initials, freq DESC);
        CREATE INDEX idx_en_word ON en_words(word);
        ANALYZE;
        VACUUM;
    """)
    conn.commit()
    conn.close()

    size_mb = OUT_DB.stat().st_size / (1024 * 1024)
    print(f"[done] built {OUT_DB} ({size_mb:.2f} MB)")


if __name__ == "__main__":
    build_sqlite()
