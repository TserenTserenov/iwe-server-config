"""Inner IWE words in a reply to the pilot (РП-388 Ф39, pack rule 9).

The source of truth is the dictionary table of rule 9 in
PACK-digital-platform/.../communication-style-base.md. WORDS below is its copy
for the hooks: the first column of every row, in the same order.
tests/test-iwe-jargon.py checks the labels against the pack table, so a new
row in the pack fails the test until it is added here.

Each row has one pattern per word form (lexeme): the rule 9 exception «the
pilot used this word himself» is checked per lexeme, so «страж» from the pilot
does not excuse «хук» in the answer. A word that is ordinary Russian in other
senses («канон» in church, «боевой характер», «производная функции») is only
reported when the answer is about IWE work at all (CONTEXT below); the hint
only nudges, so a missed case is cheaper than a false one.
"""
import re

# (label = first column of the pack table, lexeme patterns, ambiguous outside IWE talk)
WORDS = [
    ("корень (IWE)", [r"\bкор(?:ень|ня|не|нем|ню)\b(?!\s+(?:уравнени|числ|квадратн|слов|проблем|зла))"], True),
    ("канон, каноническая копия", [r"\bканон(?:а|е|ом|у|ы|ов)?\b", r"\bканоническ\w*"], True),
    ("производная (копия)", [r"\bпроизводн(?:ая|ой|ую|ые|ых|ое|ого|ым)\b"], True),
    ("боевой", [r"\bбоев(?:ой|ого|ом|ая|ую|ые|ых|ым)\b"], True),
    ("изолированная копия, изолированное дерево", [r"\bизолированн\w*\s+(?:копи|дерев)\w*"], False),
    ("холодная проверка", [r"\bхолодн\w*\s+(?:проверк|ревью|рецензи)\w*"], False),
    ("пир-проверка", [r"\bпир-(?:проверк|ревью)\w*"], False),
    ("реестр владения", [r"\bреестр\w*\s+владени\w*"], False),
    ("конвейер доставки", [r"\bконвейер\w*\s+доставки\b"], False),
    ("каталог исполнителей", [r"\bкаталог\w*\s+исполнител\w*"], False),
    ("маршрутизатор задач", [r"\bмаршрутизатор\w*"], True),
    ("семафор сессии", [r"\bсемафор\w*"], True),
    ("заморозка", [r"\bзаморозк\w*", r"\bзаморож\w*"], True),
    ("страж, хук", [r"\bстраж(?:а|у|ом|е|и|ей|ам|ами|ах)?\b", r"\bхук(?:а|у|ом|е|и|ов|ам|ами|ах)?\b"], True),
    ("баг-файл", [r"\bбаг-файл\w*"], False),
    ("байт-в-байт", [r"\bбайт-в-байт\b"], False),
    ("отстаёт на N коммитов", [r"\bотста[её]т\s+на\s+\d+\s+коммит\w*"], False),
]

# Signs that the answer talks about IWE work, which makes an ambiguous word jargon.
CONTEXT = re.compile(
    r"\b(?:коммит\w*|ветк\w*|репозитори\w*|скрипт\w*|сесси\w*|РП-?\d+|origin|IWE|шаблон\w*|агент\w*)",
    re.IGNORECASE,
)

_COMPILED = [
    (label, [re.compile(p, re.IGNORECASE) for p in patterns], ambiguous)
    for label, patterns, ambiguous in WORDS
]


def find_jargon(answer, pilot_texts):
    """Matched words of `answer` as written there, in dictionary order.

    A lexeme the pilot used in any of `pilot_texts` is skipped; ambiguous rows
    count only when the answer has an IWE work context.
    """
    pilot = "\n".join(pilot_texts)
    in_context = bool(CONTEXT.search(answer))
    found = []
    for _label, lexemes, ambiguous in _COMPILED:
        if ambiguous and not in_context:
            continue
        for rx in lexemes:
            m = rx.search(answer)
            if m and not rx.search(pilot):
                found.append(m.group(0))
    return found
