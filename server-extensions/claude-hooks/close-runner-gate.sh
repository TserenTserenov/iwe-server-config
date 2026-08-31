#!/bin/bash
# Close Runner Gate (PreToolUse, WP-482 «Reflex-принуждение к раннеру», 25.07.2026)
#
# Проблема, которую решает: protocol-close.md с 17.07 прямо называет раннер
# «обязательным драйвером Quick Close, первое действие» — 24.07 LLM прочитал
# эту фразу буквально и всё равно выполнил шаги Close вручную (git commit,
# WP-context, MEMORY.md) в обход process-runner.py. Текстовая инструкция
# внутри протокола, который сам же LLM интерпретирует, не была механизмом
# принуждения — LLM может рационализировать замену собственными шагами, когда
# конечный результат по фактам совпадает. Этот хук — сам вход в раннер как
# рефлекс: не текст, а структурная проверка перед прямым git commit.
#
# Что НЕ делает: не блокирует прохождение ai-контрактных шагов раннера
# (wp-context-update и т.п.) — им по-прежнему нужен LLM. Блокирует только
# путь «Close объявлен в этой сессии, но карточка раннера ещё не создана,
# а LLM уже пытается закоммитить руками».
#
# Известные обходы (не закрыты этой версией, задокументированы намеренно —
# фикс регэкспа под каждый вариант git-инвокации даёт гонку вооружений, не
# решение; системный барьер — автомат обязательства Ф74б, АрхГейт):
# `sudo git commit`, `eval "git commit"`, alias/функция-обёртка, вызов git
# из вложенного скрипта. Ф74а (07.08.2026) закрыл: `git -C <repo> commit/push`,
# `git -c x=y commit`, `--git-dir/--work-tree/--namespace/--exec-path` в обеих
# формах, `(git commit)` / `$(git commit)`, `command git commit`, мультипробел,
# многострочные команды, прямой `git push`; заодно снят ложный позитив первой
# версии на `git commit-tree`/`git commit-graph` (после субкоманды теперь
# требуется пробел или конец строки).
#
# Контракт PreToolUse hook (Claude Code):
# - Stdin: JSON {"tool_name", "tool_input", "session_id", ...}
# - Exit 0 = allow; exit 2 = block (stderr = причина, показывается LLM).

set -uo pipefail

# Ф42 (peer-session with Codex, 16.08): was "${CLAUDE_PROJECT_DIR:-$HOME/IWE}" --
# wrong whenever a session's project dir IS the DS-my-strategy checkout itself
# (a worktree, now the norm since WP-520's freeze), because the two paths built
# below then double-append DS-my-strategy and point at a directory that doesn't
# exist. close_obligation.py already rejected this exact class of bug for the
# same reason (see its own IWE_ROOT comment) and settled on the IWE_ROOT env var
# with a $HOME/IWE fallback; session-guard.sh uses the same convention. Matching
# it here instead of inventing a third resolution strategy.
IWE_ROOT="${IWE_ROOT:-$HOME/IWE}"

INPUT=$(cat)
[ -z "$INPUT" ] && exit 0

TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
[ "$TOOL_NAME" = "Bash" ] || exit 0

COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -n "$COMMAND" ] || exit 0

SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
# Fallback (bug-2026-08-31-close-runner-gate-empty-session-id-breaks-witness-mapping,
# peer-session with Codex+Kimi 31.08): PreToolUse payload .session_id came back
# empty twice in a row in the same conversation, even though CLAUDE_CODE_SESSION_ID
# was present and matched payload on every other call in that same conversation
# (confirmed live: temporary probe logged both values across 3 real hook
# invocations, always identical). Same env var is already the trusted harness-id
# source elsewhere in this repo (session-guard.sh:1630,
# session-reflection-append.sh) -- reusing an existing pattern, not inventing one.
if [ -z "$SESSION_ID" ] && [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then
  SESSION_ID="$CLAUDE_CODE_SESSION_ID"
fi
[ -n "$SESSION_ID" ] || exit 0
# Reject on disallowed characters instead of silently stripping them (WP-484
# Ф148, Codex review 31.08): the old `tr -cd | [-n ...]` pair let two distinct
# session_id values collide onto the same sanitized string. `case` gives the
# identical allowed-charset check without an intermediate lossy value.
case "$SESSION_ID" in
  *[!A-Za-z0-9._-]*) exit 0 ;;
esac
SESSION_ID_SAFE="$SESSION_ID"

# WP-484 Ф118 (19.08, пир-сессия с Codex, живой рецидив: пир-сессия закрывалась
# через "close_obligation.py cancel --action close-override" + "git commit
# --no-verify" КАЖДЫЙ раз — этот гейт требовал process-runner.py, который не
# имеет отношения к протоколу закрытия пир-сессии, DP.SC.154 Шаг 4.5.1 годами
# закрывает прямым git commit). Сессия, открытая с "session-guard open
# --close-path peer-session", объявила протокол закрытия заранее — этому гейту
# больше нечего проверять для неё: раннер здесь структурно не применим, не
# забытое действие. Молчаливый пропуск, не warn (peer-session — штатный путь,
# не подозрительное отклонение).
# Matched by content, not by filename prefix -- the acting agent (claude-code/
# kimi/codex/hermes) is not known here, and this hook only ever runs under
# claude-code's own PreToolUse anyway (harness_session_id is unique per host
# session regardless of which semaphore file it ended up in).
#
# bug-2026-08-31 (найдено cold-review, тот же класс дефекта, что чинили в
# close_obligation.py::_is_peer_session_close_path() в тот же день, пир-сессия
# 2026-08-31-37 с Codex+Kimi): смотрели только "*.open" и брали первый файл в
# порядке glob() -- этот порядок лексикографический (не связан со свежестью
# семафора), см. регрессию в тестах -- session-guard.sh close переименовывает
# семафор "<id>.open" -> "<id>.open.closed" при штатном закрытии, поэтому ровно
# в момент штатного закрытия дочерней пир-сессии гейт переставал видеть её
# признак. Один harness_session_id (постоянный на весь CLI-процесс,
# session-guard.sh:1630) может встретиться на нескольких семафорах подряд за
# долгую сессию -- значит нужен не "любой первый", а самый свежий кандидат
# среди ОБОИХ состояний по (opened_at/created_at, filename), с точным
# совпадением поля harness_session_id (не подстрокой). Реализовано через
# python3-хелпер (тот же приём, что уже используется в этом файле ниже для
# NONCE-подстановки) -- в bash это была бы либо хрупкая сортировка через awk,
# либо повторный проход циклом; один python3-вызов читает каждый файл ровно
# один раз и печатает "MATCH" только если выбранный (freshest) кандидат несёт
# close_path: peer-session.
CLOSE_PATH_MATCH=$(python3 - "$IWE_ROOT/.iwe-runtime/sessions" "$SESSION_ID" <<'PYEOF'
import sys, glob, os

def field(text, name):
    prefix = name + ": "
    for line in text.splitlines():
        if line.startswith(prefix):
            return line[len(prefix):]
    return None

sessions_dir, session_id = sys.argv[1], sys.argv[2]
candidates = glob.glob(os.path.join(sessions_dir, "*.open")) + \
             glob.glob(os.path.join(sessions_dir, "*.open.closed"))
best_key = None
best_text = None
for path in candidates:
    try:
        with open(path, encoding="utf-8") as f:
            text = f.read()
    except (OSError, UnicodeDecodeError):
        # UnicodeDecodeError не подкласс OSError -- битый/частично записанный
        # семафор не должен ронять весь гейт, только пропускается как нечитаемый
        # (тот же контракт, что close_obligation.py:566-570).
        continue
    if field(text, "harness_session_id") != session_id:
        continue
    ts = field(text, "opened_at") or field(text, "created_at")
    if ts is None:
        # Кандидат без timestamp не может быть признан "самым свежим" --
        # fail-closed: просто не участвует в выборе (не становится default-
        # победителем при отсутствии других кандидатов).
        continue
    key = (ts, os.path.basename(path))
    if best_key is None or key > best_key:
        best_key, best_text = key, text
if best_text is not None and "close_path: peer-session" in best_text.splitlines():
    print("MATCH")
PYEOF
)
if [ "$CLOSE_PATH_MATCH" = "MATCH" ]; then
  echo "[close-runner-gate] session=$SESSION_ID_SAFE close_path=peer-session — раннер не требуется, гейт пропускает" >&2
  exit 0
fi

RUNNER_MARKER_DIR="/tmp/iwe-close-runner-started"
RUNNER_MARKER="$RUNNER_MARKER_DIR/$SESSION_ID_SAFE.flag"

# Наблюдаем ЛЮБОЙ Bash-вызов этой сессии, стартующий quick-close через раннер.
# WP-484 Ф74б (07.08.2026, консенсус пир-сессии 2026-08-07-08): session-bound
# маркер «раннер запущен» больше НЕ ставится по подстроке в тексте команды —
# это подделывалось банальным `echo 'process-runner.py start quick-close'`.
# Теперь хук выпускает одноразовый pending-ticket (nonce) и внедряет его в
# команду через updatedInput; маркер пишет только САМ раннер при атомарном
# потреблении ticket (close_obligation.consume_ticket) — причинно, после
# реального старта. Подделка echo создаёт максимум бесполезный ticket.
if echo "$COMMAND" | grep -qE 'process-runner\.py[[:space:]]+start[[:space:]]+quick-close'; then
  # WP-484 Ф74б: новый запуск раннера = новое поколение. Старый runner-маркер
  # этой же сессии (если остался от прошлого поколения/проактивного старта)
  # должен считаться недействительным, иначе stop-check мог бы принять его за
  # маркер текущего obligation. Сам consume-ticket запишет новый маркер.
  rm -f "$RUNNER_MARKER" 2>/dev/null
  # WP-484 Ф56: session-reflection-append.sh (reflex handler) needs to know which
  # Claude Code session_id this quick-close run belongs to, to find the matching
  # pilot-witness/<session_id>.jsonl -- reflex handlers only receive {results,
  # input, run_id} on stdin (process-runner.py run_reflex_handler), never the
  # harness session_id directly. This hook is the one place that legitimately has
  # both facts at once (PreToolUse payload has session_id; the observed command has
  # --slug), so it writes the mapping the handler will read back by run_id.
  # run_id is PREDICTED here (mirrors process-runner.py:_generate_run_id's common
  # path, "<process_id>-<slug>") -- if `start` actually fell back to the
  # nanosecond-suffixed collision path (rare: two quick-close starts with the same
  # slug in the same run), the mapping simply won't match anything and the append
  # handler fails closed (witness_unavailable), never silently trusts the caller.
  #
  # Bug found live 2026-08-05 (pilot report from a separate session, same day):
  # the mapping silently never got created for a real session -- root cause was
  # this regex only matching `--slug VALUE` (space), not the equally-valid
  # argparse form `--slug=VALUE` (equals sign), which some callers used. No error
  # anywhere -- `[ -n "$SLUG" ]` below just quietly skipped the write. Character
  # class widened to [[:space:]=]+ to accept both forms. `head -1` added because
  # $COMMAND can be multi-line (e.g. a Bash call whose text merely *quotes* this
  # substring, like a test script) -- without it, multiple matched lines get
  # newline-joined by command substitution into one corrupted multi-line SLUG,
  # self-reproduced live via 2026-08-05-11-wp484-f56-quick-close-witness's own
  # test tooling (a stray file with an embedded newline in its name was found).
  SLUG=$(echo "$COMMAND" | grep -oE -- '--slug[[:space:]=]+"?[A-Za-z0-9._-]+' | head -1 | grep -oE '[A-Za-z0-9._-]+$')
  if [ -n "$SLUG" ]; then
    HARNESS_MAP_DIR="$IWE_ROOT/.iwe-runtime/quick-close-harness-session"
    mkdir -p "$HARNESS_MAP_DIR" 2>/dev/null
    chmod 700 "$HARNESS_MAP_DIR" 2>/dev/null
    HARNESS_MAP_FILE="$HARNESS_MAP_DIR/quick-close-$SLUG.session_id"
    printf '%s' "$SESSION_ID" > "$HARNESS_MAP_FILE" 2>/dev/null
    chmod 600 "$HARNESS_MAP_FILE" 2>/dev/null
  fi

  # Ф74б: выпуск ticket + инъекция nonce. Fail-closed: если ticket не выпущен
  # (ledger недоступен и пр.), инъекции нет — раннер пойдёт ticketless-веткой,
  # а armed obligation при этом останется неудовлетворённой и Stop-гейт
  # заблокирует тихое завершение (не молчаливый обход).
  if [ -n "$SLUG" ]; then
    TOOL_USE_ID=$(printf '%s' "$INPUT" | jq -r '.tool_use_id // empty' 2>/dev/null)
    OBLIGATION_CLI="$IWE_ROOT/${IWE_GOVERNANCE_REPO:-DS-my-strategy}/scripts/close_obligation.py"
    NONCE=$(python3 "$OBLIGATION_CLI" issue-ticket --session-id "$SESSION_ID" --slug "$SLUG" --tool-use-id "$TOOL_USE_ID" 2>/dev/null)
    if [ -z "$NONCE" ]; then
      echo "[close-runner-gate] session=$SESSION_ID_SAFE issue-ticket returned empty (obligation_cli=$OBLIGATION_CLI) — proceeding ticketless, Stop gate will still enforce" >&2
    fi
    if [ -n "$NONCE" ]; then
      NEW_COMMAND=$(NONCE="$NONCE" python3 -c '
import os, re, sys
cmd = sys.stdin.read()
nonce = os.environ["NONCE"]
sys.stdout.write(re.sub(r"(process-runner\.py\s+start\s+quick-close)", r"\1 --close-ticket " + nonce, cmd, count=1))
' <<<"$COMMAND")
      if [ "$NEW_COMMAND" != "$COMMAND" ]; then
        jq -nc --arg cmd "$NEW_COMMAND" \
          '{hookSpecificOutput:{hookEventName:"PreToolUse",updatedInput:{command:$cmd}}}'
        exit 0
      fi
    fi
  fi
fi

# Применимо к блокировке только прямой git commit/push. process-runner.py сам
# вызывает git commit внутри commit-push.sh как subprocess — PreToolUse видит
# только верхний Bash-вызов LLM (`python3 process-runner.py ...`), не увидит
# вложенный git commit отдельным tool call, поэтому раннер этим гейтом не
# блокируется независимо от маркера выше.
#
# WP-484 Ф74а (07.08.2026, пир-сессия 2026-08-07-08-quick-close-runner-bypass):
# прежний regex ловил только буквальный `git commit` после оператора — стандартная
# для этого workspace форма `git -C <repo> commit` (а также `-c`, `--git-dir`,
# `command`, subshell, мультипробел, многострочные команды и любой `git push`)
# проходила мимо; 07.08 Quick Close был выполнен полностью в обход раннера.
# Это defence-in-depth, НЕ системный фикс (гонка вооружений признана; системный
# барьер — автомат обязательства Ф74б, АрхГейт).
# Нормализация: newline — тот же разделитель команд, что `;` → заменяем на `;`,
# затем схлопываем повторные пробелы, чтобы `git   commit` не ускользал.
NORMALIZED_COMMAND=$(printf '%s' "$COMMAND" | tr '\n' ';' | tr -s '[:space:]' ' ')
# Глобальные флаги git: со значением (-C path, -c k=v, --git-dir/--work-tree/
# --namespace/--exec-path в форме `=value` или через пробел) и булевы
# (-P/--paginate/--no-pager, pathspecs-флаги и пр.). После субкоманды требуем
# пробел или конец строки — поэтому plumbing `commit-tree`/`commit-graph`
# (ложный позитив первой версии) больше не блокируются.
# WP-484 Ф74а дополнение (07.08.2026): переменные окружения перед git
# (`GIT_EDITOR=cat git commit`) тоже ловим, иначе это обход.
GIT_GLOBAL_FLAGS_RE='(-C [^ ]+|-c [^ ]+|--(git-dir|work-tree|namespace|exec-path)(=[^ ]+| [^ ]+)|--(literal-pathspecs|glob-pathspecs|noglob-pathspecs|icase-pathspecs|no-optional-locks|no-lazy-fetch|no-replace-objects|no-pager|paginate|bare)|-P)'
echo "$NORMALIZED_COMMAND" | grep -qE "(^|[;&|(]) *(([A-Za-z_][A-Za-z0-9_]*=[^ ]+ *)*)(command |builtin |exec )?git( $GIT_GLOBAL_FLAGS_RE)* (commit|push)( |$)" || exit 0

SENTINEL="/tmp/iwe-close-intent/$SESSION_ID_SAFE.flag"
# Close не объявлен в этой сессии (или sentinel не создан) — не мешать штатной работе.
[ -f "$SENTINEL" ] || exit 0

# WP-484 Ф74б-фикс (08.08, Claude Code): широкая эвристика («заливай/запуши» —
# mode=warn) не должна ЖЁСТКО блокировать git commit/push здесь — иначе сегодняшний
# фикс close-gate-reminder.sh («⚠️ ПРЕДУПРЕЖДЕНИЕ, а не блокировка») не выполняет
# свою цель: prompt отвечает warn, а этот PreToolUse-гейт минутой позже всё равно
# блокирует commit exit 2. Живой репрод: substring-ложный-позитив «запуши» внутри
# «запушился» (прошедшее время в цитате отчёта, не команда) заармировал mode=warn
# и заблокировал обычный правочный commit. Fail-closed: любая неопределённость
# (obligation нечитаем, CLI недоступен, mode пуст/не "warn") — блокируем как раньше,
# точный close-intent (mode=block) не затронут.
OBLIGATION_CLI="$IWE_ROOT/${IWE_GOVERNANCE_REPO:-DS-my-strategy}/scripts/close_obligation.py"
if [ -f "$OBLIGATION_CLI" ]; then
  OBLIGATION_MODE=$(python3 "$OBLIGATION_CLI" mode --session-id "$SESSION_ID" 2>/dev/null)
  if [ "$OBLIGATION_MODE" = "warn" ]; then
    echo "[close-runner-gate] session=$SESSION_ID_SAFE close-intent mode=warn — прямой git commit/push пропущен без блокировки (широкая эвристика, не точный close-intent)" >&2
    exit 0
  fi
fi

# TTL: Quick Close — сессия ~3 мин, но между «закрывай» и commit могут быть
# уточняющие ходы. 30 минут — с запасом, не session-lifetime (файл не растёт
# бесконечно: одна сессия перезаписывает свой sentinel при повторном «закрывай»).
case "$(uname)" in
  Darwin) MTIME=$(stat -f %m "$SENTINEL" 2>/dev/null) ;;
  *)      MTIME=$(stat -c %Y "$SENTINEL" 2>/dev/null) ;;
esac
[ -n "$MTIME" ] || exit 0
NOW=$(date +%s)
if [ $((NOW - MTIME)) -gt 1800 ]; then
  rm -f "$SENTINEL" 2>/dev/null
  exit 0
fi

# session-bound маркер — не общий каталог карточек. Гонка с параллельными
# сессиями невозможна: маркер лежит по session_id ЭТОЙ сессии, никакая другая
# сессия не может его создать или случайно совпасть именем.
[ -f "$RUNNER_MARKER" ] && exit 0

SENTINEL_CREATED=$(jq -r '.created_at // empty' "$SENTINEL" 2>/dev/null)
echo "[close-runner-gate] session=$SESSION_ID_SAFE close-intent=$SENTINEL_CREATED no process-runner.py start quick-close observed in this session — blocking direct git commit/push" >&2

cat >&2 <<EOF
🚫 Reflex-принуждение к раннеру (WP-482): прямой git commit/push в обход process-runner.py заблокирован.

В этой сессии объявлено намерение закрыть сессию ($SENTINEL_CREATED), но вызова
"process-runner.py start quick-close" в этой же сессии не наблюдалось.

protocol-close.md называет раннер обязательным первым действием Quick Close — этот
гейт делает требование механическим, не полагаясь на то, что текст был прочитан
буквально (найдено живьём 24.07: LLM продублировал шаги Close руками, несмотря на
прямую инструкцию в тексте протокола).

Сначала:
  cd DS-my-strategy && python3 scripts/process-runner.py start quick-close --slug <slug> \\
    --input '{"agent":"<agent>","slug":"<slug>","session_file":"<путь или null>","repos":["<repo1>", ...]}'

Раннер сам вызовет commit-push через свой хендлер — этот git commit тогда не потребуется напрямую.
EOF
exit 2
