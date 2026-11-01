"""A13.1 classifier shared by the style hook and the weekly metric (РП-388 Ф36).

One owner for the rule «address ≠ code name»: response-clarity-hook.sh calls
find_symbols() for its A13.1 log line, scripts/style-symbol-metric.py imports
the same functions to measure replies. Changing the rule here changes both.
"""
import re

# Shared with rule A13 in the hook (РП-388 Ф17): one list of command words.
# ls/cd/rm are excluded: two-letter "commands" collide with Russian prose.
CMD_WORDS = "bash|python3|git|grep|sed|curl|npm|mkdir"
path_re = re.compile(r'[A-Za-z0-9_/.-]+\.(py|md|ts|sh|js|yaml|json)(:[0-9]+)?')
BACKTICK_RE = re.compile(r'`([^`\n]{1,200})`')
FENCE_RE = re.compile(r'```.*?```', re.S)

# --- A13.1 (РП-388 Ф17, 22.10; Ф36 шаг 3, 01.11) ---
# A token in backticks counts when it is an internal code name with no Russian
# explanation nearby. A2 strips backtick spans and A13 needs three hits, so a
# single bare token slipped past both; A13.1 is that separate signal.
cmd_inline_re = re.compile(r'^(' + CMD_WORDS + r')\s+\S')
bt_descriptor_re = re.compile(r'(скрипт|команд|файл|пут[ьи]|ветк|директори|папк|каталог|репозитори|хук|сценари)[а-яё]*', re.IGNORECASE)
# Описатели имени из кода (РП-388 Ф36 шаг 3, 01.11, пир-сессия Claude+Grok
# 2026-11-01-12): полные словоформы с правой границей — голый стебель гасил бы
# символ словами «Ключевой», «Классический», «Пользователь», «Функционал».
# «статус» и «тест» сознательно не описатели: «Тест `x` упал» имя не объясняет.
bt_code_descriptor_re = re.compile(
    r'\b(?:функци(?:я|и|ю|ей|ям|ями|ях|й)'
    r'|переменн(?:ая|ой|ую|ые|ых|ыми|ое|ого|ым)'
    r'|параметр(?:а|у|ом|е|ы|ов|ам|ами)?'
    r'|ошибк(?:а|и|у|е|ой|ами)?'
    r'|модул(?:ь|я|ю|ем|е|и|ей|ями)?'
    r'|класс(?:а|у|ом|е|ы|ов|ам|ами)?'
    r'|пол(?:е|я|ю|ем|ей|ях|ями)'
    r'|ключ(?:а|у|ом|и|ей|ам|ами)?'
    r'|флаг(?:а|у|ом|е|и|ов|ам|ами)?'
    r'|таблиц(?:а|ы|е|у|ей|ами|ах)?'
    r'|колонк(?:а|и|е|у|ой|ами|ах)?'
    r'|состояни(?:е|я|ю|ем|и|ях|ями))\b',
    re.IGNORECASE)
# Пояснение ПОСЛЕ токена: связка (—, :, «это», «как») сразу за токеном и
# описатель сразу за связкой — «`TypeError` — это класс исключения». Свободное
# окно не годится: «вызвали `x()` и ошибка ушла» гасило бы символ чужим словом.
bt_after_link_re = re.compile(r'^\s*(?:(?:—|:)\s*(?:(?:это|как)\s+)?|(?:это|как)\s+)', re.IGNORECASE)
# Форма "русское описание (`термин`)" — та же, что уже разрешена A2 выше.
bt_paren_form_re = re.compile(r'[а-яё][а-яё-]*\s*\($', re.IGNORECASE)
# Ф18 (22.10, живой отчёт пилота про `note-commit --forget-unprovable`,
# `close_delivery_source_commits`, `PREPARED`): список CMD_WORDS не угнаться
# за именами команд, поэтому признак ФОРМЫ — латинский идентификатор без
# кириллицы с дефисом/подчёркиванием/@/точкой между буквами, флагом `--x`,
# ВЕРХНИМ регистром ≥4 букв. Ф36 шаг 3 добавил горб `[A-Z][a-z]+[A-Z]`
# (`TypeError`; `macOS`/`iOS` его не проходят) и вызов `x(`. Зеркальный горб
# (`getUser`) не добавлен: его не отличить от `iPhone`/`eBay`. Голая строчная
# латиница (`main`, `true`, `inbox`) формы не имеет и символом не считается.
bt_cyr_re = re.compile(r'[А-Яа-яЁё]')
bt_shape_re = re.compile(r'[A-Za-z][-_@][A-Za-z0-9]|[A-Za-z]\.[A-Za-z]|(^|\s)--?[A-Za-z]|\b[A-Z]{4,}\b|[A-Z][a-z]+[A-Z]|[A-Za-z0-9_]\(')
# Адрес (Ф36 шаг 3): то, по чему пилот сам что-то откроет или найдёт, —
# допустим рядом с русской фразой и символом не считается. Голое имя файла
# (`ds-publish.sh`) и команда с флагом без пути (`git apply --3way`) — не
# адреса: на обе пилот жаловался 22.10. Имена репозиториев — закрытый список
# полных имён, не префикс: `iwe-safe-pull.sh` и `DS-MODE` остаются символами.
BT_REPO_NAMES = ("iwe-local-config", "iwe-server-config", "DS-my-strategy", "DS-ai-systems",
                 "MC-sessions", "PACK-digital-platform", "PACK-agent-rules", "FMT-exocortex-template")
bt_sha_re = re.compile(r'[0-9a-f]{7,40}')
bt_ref_re = re.compile(r'\S+@[0-9a-f]{7,40}|\S+#\d+')
bt_doc_id_re = re.compile(r'(?:WP|РП|PR)-?\d+|[A-Z]{2,}(?:\.[A-Z0-9]+){1,3}')


def is_address(content):
    if "/" in content or content == "HEAD" or content in BT_REPO_NAMES:
        return True
    if bt_sha_re.fullmatch(content):
        return bool(re.search(r'[a-f]', content))
    if bt_ref_re.fullmatch(content):
        return True
    return bool(bt_doc_id_re.fullmatch(content)) and bool(re.search(r'\d', content))


def is_bare_tech_token(content):
    if is_address(content):
        return False
    if path_re.fullmatch(content) or cmd_inline_re.match(content):
        return True
    return not bt_cyr_re.search(content) and bool(bt_shape_re.search(content))


def is_explained(content, before, after):
    if bt_paren_form_re.search(before):
        return True
    # A flag names the very class of the 22.10 complaints («флаг `x --y`»),
    # so descriptors never excuse a token that carries one.
    if "--" in content:
        return False
    if bt_descriptor_re.search(before) or bt_code_descriptor_re.search(before):
        return True
    link = bt_after_link_re.match(after)
    if not link:
        return False
    rest = after[link.end():]
    return bool(bt_descriptor_re.match(rest) or bt_code_descriptor_re.match(rest))


def log_example(tokens, limit=100):
    # Cut on the " ;; " boundary so the log never shows half a name.
    sep, tail = " ;; ", " ;; …"
    out = []
    for index, token in enumerate(tokens):
        candidate = sep.join(out + [token])
        reserve = len(tail) if index < len(tokens) - 1 else 0
        if len(candidate) + reserve > limit and out:
            return sep.join(out) + tail
        out.append(token)
    return sep.join(out)


def strip_fences(text):
    """Drop fenced code blocks before looking at inline backticks."""
    return FENCE_RE.sub('', text)


def classify_token(content):
    """'address' | 'symbol' | 'other' for one backtick span, context ignored."""
    if is_address(content):
        return "address"
    return "symbol" if is_bare_tech_token(content) else "other"


def find_symbols(text):
    """Unexplained code names in text (fences already stripped), first-seen order."""
    tokens = []
    for match in BACKTICK_RE.finditer(text):
        content = match.group(1)
        if not is_bare_tech_token(content):
            continue
        before = text[max(0, match.start() - 60):match.start()]
        newline_pos = before.rfind("\n")
        if newline_pos != -1:
            before = before[newline_pos + 1:]
        # 40 chars, then drop a word cut by the window edge: a truncated «клю…»
        # must not pass for the descriptor «ключ» (cold review, 01.11).
        after_end = match.end() + 40
        after = text[match.end():after_end]
        if "\n" in after:
            after = after.split("\n", 1)[0]
        elif after_end < len(text) and not text[after_end].isspace():
            after = after.rsplit(None, 1)[0] if after.strip().count(" ") else ""
        if is_explained(content, before, after):
            continue
        if content not in tokens:
            tokens.append(content)
    return tokens


# --- Items (rule item-v2, РП-388 Ф36 шаг 4, пир-сессия Claude+Grok 2026-11-01-12) ---
# The metric's unit is one item of a reply:
#   - a list element (marker `-`, `*` or `N.`) with its continuation lines of
#     deeper indent, also across one blank line; a nested marker starts its
#     own item; `1)` and `+` are not list markers;
#   - a paragraph outside lists;
#   - one data row of a table (a row with `|` followed by a separator row;
#     the header and the separator are not items, with or without outer pipes).
# Not items: fenced blocks, headings `# …`, horizontal rules, the «Дальше:»
# line (it belongs to rule A12, РП-605). Changing this changes the base, so
# the metric records ITEM_RULE next to every result.
ITEM_RULE = "item-v2"
LIST_MARKER_RE = re.compile(r'^(\s*)(?:[-*]|\d{1,3}\.)\s+')
TABLE_SEP_RE = re.compile(r'^\s*\|?\s*:?-{3,}:?\s*(?:\|\s*:?-{3,}:?\s*)*\|?\s*$')
HEADING_RE = re.compile(r'^\s{0,3}#{1,6}\s')
RULE_LINE_RE = re.compile(r'^\s{0,3}(?:-{3,}|\*{3,}|_{3,})\s*$')
NEXT_LINE_RE = re.compile(r'^\s*(?:\*\*)?Дальше:')


def is_table_separator(line):
    return "|" in line and bool(TABLE_SEP_RE.match(line))


def split_items(text):
    lines = strip_fences(text).replace("\r\n", "\n").split("\n")
    items, current = [], []
    list_indent = None  # indent of the open list item's marker
    pending_blank = False
    in_table = False

    def flush():
        body = "\n".join(current).strip()
        if body:
            items.append(body)
        current.clear()

    for index, line in enumerate(lines):
        following = lines[index + 1] if index + 1 < len(lines) else ""
        if in_table:
            if is_table_separator(line):
                continue
            if line.strip() and "|" in line:
                items.append(line.strip())
                continue
            in_table = False
        if "|" in line and is_table_separator(following):
            flush()
            list_indent, pending_blank, in_table = None, False, True
            continue  # header row
        if is_table_separator(line) or HEADING_RE.match(line) or RULE_LINE_RE.match(line) \
                or NEXT_LINE_RE.match(line):
            flush()
            list_indent, pending_blank = None, False
            continue
        if not line.strip():
            if pending_blank or list_indent is None:
                flush()
                list_indent = None
            pending_blank = True
            continue
        marker = LIST_MARKER_RE.match(line)
        indent = len(line) - len(line.lstrip())
        if marker:
            flush()
            list_indent = len(marker.group(1))
        elif list_indent is not None and indent > list_indent:
            pass  # continuation of the open list item
        elif pending_blank or list_indent is not None:
            flush()
            list_indent = None
        current.append(line)
        pending_blank = False
    flush()
    return items
