#!/bin/bash
# Protocol Artifact Validation Hook
# Event: PreToolUse (matcher: Bash)
# Intercepts `git commit` in protocol-managed repos to validate artifacts.
# Returns block decision if artifact fails validation.
# Read-only: only returns JSON, does not modify files.
#
# Validated artifacts:
#   - DayPlan: 11 required sections + collapsible + non-empty key sections + carry-over
#   - DayClose: итоги, carry-over (day-close protocol) [future]
#
# Parameterized: sections list is a variable, not hardcoded per format.
# Ф3 WP-229: добавлены проверки структуры (collapsible, непустые секции, мультипликатор, carry-over)

INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty')
TOOL_INPUT=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# Only trigger on Bash tool with git commit command
if [ "$TOOL" != "Bash" ]; then
  echo '{}'
  exit 0
fi

# Trigger only on an actual git commit invocation (git as command word after a
# command separator), not on any occurrence of the substring "git commit" —
# e.g. inside a grep pattern, echo text, or commit message being searched for.
# Same anchoring principle as close-runner-gate.sh:150 (WP-484 Ф74а).
if ! echo "$TOOL_INPUT" | grep -qE '(^|[;&|(]) *(([A-Za-z_][A-Za-z0-9_]*=[^ ]+ *)*)(command |builtin |exec )?git ([^;&|]* )?commit( |$)'; then
  echo '{}'
  exit 0
fi

# Repo-scope fix (bug-2026-08-26/27, hardened in peer-session
# 2026-08-27-11-wp452-external-developer-access turns 3-6 with Codex):
# resolve the repo(s) the intercepted command's `git ... commit` invocation(s)
# actually run in, instead of always checking the hardcoded governance path.
# Without this, a commit staged in any OTHER repo gets blocked whenever some
# unrelated agent happens to have a DayPlan/WeekPlan staged in the governance
# repo at the same time (live incident, twice).
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')

# Same anchoring principle as close-runner-gate.sh (WP-484 Ф74а): normalize
# newlines to `;` first (a multi-line command is command-separator-joined,
# same as `;`), then require any global flag between the `git` token and the
# `commit` it belongs to — not a bare substring search across the whole
# command, which would grab `-C` from an unrelated `git ... rev-parse` call
# earlier in the same command, or from inside a commit message like
# `-m "... -C ..."` (both found live in cold-context review of the first
# draft of this fix).
NORMALIZED_COMMAND=$(printf '%s' "$TOOL_INPUT" | tr '\n' ';' | tr -s '[:space:]' ' ')
# Unquoted flag values exclude shell separators too (`[^[:space:];&|]+`, not
# just `[^ ]+`) — `git -C /foreign&&git commit` has no space around `&&`, so
# a value class that only excludes spaces would swallow `&&git` into the
# path and merge two distinct invocations into one (found in peer review).
GIT_GLOBAL_FLAGS_RE='(-C ("[^"]*"|'"'"'[^'"'"']*'"'"'|[^[:space:];&|]+)|-c [^[:space:];&|]+|--(git-dir|work-tree|namespace|exec-path)(=[^[:space:];&|]+| [^[:space:];&|]+)|--(literal-pathspecs|glob-pathspecs|noglob-pathspecs|icase-pathspecs|no-optional-locks|no-lazy-fetch|no-replace-objects|no-pager|paginate|bare)|-P)'

# `--git-dir=`/`--work-tree=` are matched (so they don't break the anchor
# for OTHER flags in the same invocation) but not parsed into a target
# path — no real call site in this codebase uses them for `commit`, and
# resolving a bare `--git-dir` back to a worktree adds complexity for a
# case that doesn't occur.

# Governance-репо: из env $IWE_GOVERNANCE_REPO (по умолчанию DS-my-strategy —
# fallback был "DS-strategy", репо переименовано, см. bug-2026-07-11).
# Workspace: $IWE_WORKSPACE или $IWE_ROOT (синонимы), default ~/IWE. Computed
# once — it's an invariant of this hook run, not per candidate invocation.
GOV_REPO="${IWE_GOVERNANCE_REPO:-DS-my-strategy}"
WORKSPACE="${IWE_WORKSPACE:-${IWE_ROOT:-$HOME/IWE}}"
GOV_CANONICAL_PATH="$WORKSPACE/$GOV_REPO"
# Worktree-aware match: compare the shared git dir, not the working-tree
# path — an isolated worktree of the governance repo (freeze fallback) has
# a different toplevel path but the same git-common-dir as the canonical
# checkout.
GOV_COMMON_DIR=$(git -C "$GOV_CANONICAL_PATH" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
if [ -z "$GOV_COMMON_DIR" ]; then
  # Governance repo itself doesn't resolve — a real misconfiguration
  # (IWE_WORKSPACE/IWE_GOVERNANCE_REPO or the checkout itself), not "this
  # commit is unrelated". Surface it instead of silently skipping forever
  # (the same silent-regression shape as the bug this fix addresses).
  jq -n --arg reason "⚠️ protocol-artifact-validate: governance-репозиторий ($GOV_CANONICAL_PATH) не резолвится — DayPlan/WeekPlan не проверены. Проверь IWE_WORKSPACE/IWE_GOVERNANCE_REPO." \
    '{"additionalContext": $reason}'
  exit 0
fi

COMMIT_INVOCATIONS=$(printf '%s\n' "$NORMALIZED_COMMAND" | grep -oE "git( $GIT_GLOBAL_FLAGS_RE)* commit")

# WP-484 F313 (peer session 2026-11-18-04 with Codex): a commit spelled
# `cd <repo> && git commit` or `(cd <repo> && git commit)` from a cwd outside
# that repo used to resolve to no repository and pass unvalidated. Bounded
# grammar: the last `cd [-L|-P|-e|-@|--]... <path>` that starts a command
# (after start, `;`, `&`, `|` or `(`) before the first commit invocation; the
# path is double-quoted, single-quoted or a bare token with `\`-escapes; a
# leading `~` is $HOME. Known limit: one base directory for all invocations.
# A path we cannot evaluate from text (`$`, backtick, `cd -`) or that does
# not exist marks the target UNRESOLVED.
TARGET_UNRESOLVED=false
BASE_DIR="$CWD"
FIRST_INVOCATION=$(printf '%s\n' "$COMMIT_INVOCATIONS" | head -1)
if [ -n "$FIRST_INVOCATION" ]; then
  COMMAND_PREFIX=${NORMALIZED_COMMAND%%"$FIRST_INVOCATION"*}
  cd_word=$(printf '%s' "$COMMAND_PREFIX" \
    | grep -oE '(^|[;&|(]) *cd +((-[LPe@]+|--) +)*("[^"]*"|'"'"'[^'"'"']*'"'"'|([^[:space:];&|()\\]|\\.)+)' | tail -1 \
    | sed -E 's/^[;&|(]? *cd +((-[LPe@]+|--) +)*//')
  case "$cd_word" in
    \"*\" | \'*\') cd_arg=${cd_word:1:${#cd_word}-2} ;;
    *) cd_arg=$(printf '%s' "$cd_word" | sed -E 's/\\(.)/\1/g') ;;
  esac
  case "$cd_arg" in
    '~') cd_arg="$HOME" ;;
    '~/'*) cd_arg="$HOME/${cd_arg#'~/'}" ;;
  esac
  case "$cd_arg" in
    "") ;;
    *'$'* | *'`'* | '-' | '~'*) TARGET_UNRESOLVED=true ;;
    *)
      cd_resolved=$(cd "${CWD:-.}" 2>/dev/null && cd "$cd_arg" 2>/dev/null && pwd)
      if [ -n "$cd_resolved" ]; then BASE_DIR="$cd_resolved"; else TARGET_UNRESOLVED=true; fi
      ;;
  esac
fi

RESOLVE_FROM=""
# Walk every `git <flags>* commit` invocation in the (possibly compound)
# command — a single Bash call can chain commits to more than one repo, and
# the one that matters may not be the first (found in peer review).
while IFS= read -r invocation; do
  [ -n "$invocation" ] || continue
  candidate="$BASE_DIR"
  c_arg=$(printf '%s' "$invocation" | grep -oE -- '-C ("[^"]*"|'"'"'[^'"'"']*'"'"'|[^[:space:];&|]+)' | head -1 | sed -E 's/^-C //; s/^"(.*)"$/\1/; s/^'"'"'(.*)'"'"'$/\1/')
  case "$c_arg" in
    *'$'*)
      # A literal shell expansion we cannot resolve from text alone (e.g.
      # `-C "$REPO_ROOT"`) — fall back to .cwd for THIS invocation rather
      # than giving up entirely. This hook is a formatting/hygiene gate, not
      # a security boundary: treating "can't resolve -C" as "assume it's the
      # governance repo, block" would recreate the exact false-positive bug
      # this fix removes, just one level deeper. The unresolved mark below
      # only blocks when a plan is actually staged in the governance repo.
      TARGET_UNRESOLVED=true
      ;;
    "") ;;
    *)
      resolved=$(cd "${BASE_DIR:-.}" 2>/dev/null && cd "$c_arg" 2>/dev/null && pwd)
      [ -n "$resolved" ] && candidate="$resolved"
      ;;
  esac
  [ -n "$candidate" ] || continue
  candidate_repo=$(git -C "$candidate" rev-parse --show-toplevel 2>/dev/null)
  [ -n "$candidate_repo" ] || continue
  candidate_common_dir=$(git -C "$candidate_repo" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
  [ -n "$candidate_common_dir" ] || continue
  if [ "$candidate_common_dir" = "$GOV_COMMON_DIR" ]; then
    RESOLVE_FROM="$candidate_repo"
    break
  fi
done <<EOF
$COMMIT_INVOCATIONS
EOF

if [ -z "$RESOLVE_FROM" ]; then
  # Unresolved target while a plan is staged in the governance repo: a
  # warning, not a block. A block here falsely stopped commits to other repos
  # spelled `git -C "$R" commit` (cold review 18.11) — the 28e7eff incident
  # class. The governance repo's own git pre-commit hook still checks a staged
  # DayPlan whatever the command spelling.
  if [ "$TARGET_UNRESOLVED" = true ] \
     && git -C "$GOV_CANONICAL_PATH" -c core.quotePath=false diff --cached --name-only 2>/dev/null \
        | grep -qE '^current/(DayPlan|WeekPlan).*\.md$'; then
    jq -n --arg ctx "⚠️ protocol-artifact-validate: не смог определить, в каком репозитории выполняется этот коммит, а в $GOV_CANONICAL_PATH подготовлен к коммиту план дня или недели — он этой проверкой не проверен. Если коммит в этот репозиторий, укажи его явно: git -C <путь> commit ..." \
      '{"additionalContext": $ctx}'
    exit 0
  fi
  echo '{}'
  exit 0
fi
GOV_PATH="$RESOLVE_FROM"

# R4.5 fix (WP-273): trigger ТОЛЬКО по staged files, НЕ по тексту команды.
# Старая логика грепала TOOL_INPUT на «DayPlan|day-close» — false positive
# на любой коммит файла `day-close/SKILL.md` или сообщения с «day-close».
# Принцип: «hook trigger = artifact (staged file), не TOOL_INPUT текст» (memory/hooks-design.md).
# `core.quotePath=false` keeps non-ASCII paths literal, so the pathspec
# narrowing below compares the same spelling the command uses.
STAGED=$(cd "$GOV_PATH" 2>/dev/null && git -c core.quotePath=false diff --cached --name-only 2>/dev/null || echo "")
STAGED_PLANS=$(echo "$STAGED" | grep -E '^current/DayPlan.*\.md$|^current/WeekPlan.*\.md$' || true)
if [ -z "$STAGED_PLANS" ]; then
  echo '{}'
  exit 0
fi

# Pathspec-scope fix (WP-7 Ф107, bug-2026-08-26/27/09-05 class): the index read
# above belongs to the whole repo, but `git commit -- <paths>` commits only the
# listed paths. On the shared Mac checkout several sessions stage into the same
# index at once, so a DayPlan/WeekPlan staged by ANOTHER agent would otherwise
# block a commit that does not contain it.
# The helper only ever answers NARROW when the command text PROVES every commit
# invocation excludes the staged plan files; a missing helper, a broken python3
# or any doubt falls back to validating the whole index, exactly as before.
PATHSPEC_HELPER="$(dirname "${BASH_SOURCE[0]}")/git-commit-pathspec.py"
if [ -f "$PATHSPEC_HELPER" ]; then
  PLAN_ARGS=()
  while IFS= read -r staged_plan; do
    [ -n "$staged_plan" ] && PLAN_ARGS+=("$staged_plan")
  done <<< "$STAGED_PLANS"
  PATHSPEC_DECISION=$(printf '%s' "$TOOL_INPUT" | python3 "$PATHSPEC_HELPER" "${PLAN_ARGS[@]}" 2>/dev/null || echo "KEEP")
  if [ "$PATHSPEC_DECISION" = "NARROW" ]; then
    echo '{}'
    exit 0
  fi
fi

# WP-484 Ф342 (bug-2026-09-14-artifact-validate-hook-blocks-unrelated-commits-on-stale-dayplan):
# each plan is validated only when that plan itself is in the commit, and the
# staged plan is validated, not whichever plan lies on disk. A staged path that
# no longer exists (archived or deleted) has nothing to validate.
staged_plan() { # <grep pattern> -> absolute path of the newest staged existing plan, or ""
  local rel
  rel=$(printf '%s\n' "$STAGED_PLANS" | grep -E "$1" | sort | tail -1)
  if [ -n "$rel" ] && [ -f "$GOV_PATH/$rel" ]; then printf '%s\n' "$GOV_PATH/$rel"; fi
}

# --- DayPlan Validation (only when a DayPlan is in this commit) ---
DAYPLAN=$(staged_plan '^current/DayPlan.*\.md$')
MISSING=()
ERRORS=()

if [ -n "$DAYPLAN" ]; then

# Required sections, by stable id; each id accepts the heading in any shipped
# language (recognition.dayplan.section.<id> in .claude/lib/locale/*.json,
# release 0.42). A catalog failure is reported as an error, never as "all present".
# Scout раздел опционален: проверяется отдельно ниже (см. блок "Scout").
SECTIONS=()
if . "$(dirname "${BASH_SOURCE[0]}")/../lib/i18n.sh"; then
  for section_id in plan_today calendar overnight notes_review yesterday; do
    section=$(i18n_pattern "recognition.dayplan.section.$section_id") || { ERRORS+=("i18n: нет шаблона секции $section_id"); continue; }
    SECTIONS+=("$section")
  done
else
  ERRORS+=("i18n: не загружается .claude/lib/i18n.sh")
fi

for section in "${SECTIONS[@]}"; do
  if ! grep -qE "$section" "$DAYPLAN"; then
    MISSING+=("$section")
  fi
done

# Check mandatory format elements

# --- Ф3 Check 1: collapsible <details> блоки ---
DETAILS_COUNT=$(grep -c '<details' "$DAYPLAN" 2>/dev/null || true); DETAILS_COUNT=${DETAILS_COUNT:-0}
if [ "$DETAILS_COUNT" -lt 3 ]; then
  ERRORS+=("Collapsible секции (<details>) < 3 найдено: $DETAILS_COUNT. DayPlan должен иметь collapsible-структуру")
fi

# --- Ф3 Check 2: непустые обязательные секции ---
# Календарь: должна содержать хотя бы одну строку с | (таблица) или "нет событий"
CALENDAR_CONTENT=$(awk '/Календарь|Calendar/,/^<\/details>/' "$DAYPLAN" 2>/dev/null | wc -l || echo 0)
if [ "$CALENDAR_CONTENT" -lt 3 ]; then
  ERRORS+=("Секция 'Календарь' пустая или слишком короткая (${CALENDAR_CONTENT} строк)")
fi

# Scout: проверяется только если секция вообще присутствует в DayPlan (опциональный компонент,
# зависит от DS-agent-workspace). Если секции нет — Scout не сконфигурирован, валидатор не блокирует.
if grep -q "Наработки Scout" "$DAYPLAN" 2>/dev/null; then
  if ! awk '/Наработки Scout/,/^<\/details>/' "$DAYPLAN" 2>/dev/null | grep -iqE 'наход|capture|статус|нет|find|disabled|not configured'; then
    ERRORS+=("Секция 'Наработки Scout' пустая (допустимы маркеры 'нет находок', 'disabled', 'not configured')")
  fi
fi

# --- Ф3 Check 3: секция «Портфель в работе» (было «Бюджет дня») заполнена ---
# WP-484 Ф148 (01.09) переименовал лейбл «Бюджет дня» → «Портфель в работе» и
# отвязал точный формат числа от единого шаблона — day-open-scaffold.sh с тех
# пор оставляет содержание строки на усмотрение дневного LLM (наблюдались:
# полный "~Xh РП / ~Yh физ / Плановый мультипликатор ~N.Nx", голое "115h",
# сумма по РП "1h + 12h + ... = 19.5h" — все они реальные, принятые дни, ни
# один пилот не отклонял). Прежний жёсткий regex на "~Xh РП" + отдельный
# мультипликатор проверял конкретную грамматику одного из этих вариантов, а
# не сам факт «бюджет посчитан» — ложно блокировал минимум 4 раза подряд
# (inbox/bugs/bug-2026-08-26-.../-08-27-.../-09-05-.../-09-11-...-fourth-recurrence.md).
# Проверяем то, что действительно является инвариантом после переименования:
# секция существует и не осталась незаполненным `<!-- PENDING -->` плейсхолдером
# самого шаблона (см. `scripts/day-open-scaffold.sh` — заготовка перед тем, как
# LLM дня подставит реальное содержимое).
PORTFOLIO_LINE=$(grep -E '^\*\*(Портфель в работе|Бюджет дня):\*\*' "$DAYPLAN" | head -1)
if [ -z "$PORTFOLIO_LINE" ]; then
  ERRORS+=("Секция «Портфель в работе» (было «Бюджет дня») не найдена")
elif printf '%s' "$PORTFOLIO_LINE" | grep -q '<!-- *PENDING'; then
  ERRORS+=("Секция «Портфель в работе» осталась незаполненным PENDING-плейсхолдером")
fi

# --- Ф3 Check 5: Carry-over цитата (если есть предыдущий DayPlan) ---
PREV_DAYPLAN=$(ls "$GOV_PATH"/current/DayPlan\ *.md 2>/dev/null | sort | tail -2 | head -1)
if [ -n "$PREV_DAYPLAN" ] && [ "$PREV_DAYPLAN" != "$DAYPLAN" ]; then
  # Предыдущий DayPlan существует — текущий должен содержать Carry-over
  if ! grep -qiE 'carry.over|carry_over' "$DAYPLAN"; then
    ERRORS+=("Carry-over цитата из предыдущего Day Close отсутствует (предыдущий DayPlan: $(basename "$PREV_DAYPLAN"))")
  fi
fi

fi  # endif [ -n "$DAYPLAN" ]

# --- WeekPlan Validation (Ф6.1 WP-265; only when a WeekPlan is in this commit, Ф342) ---
WEEKPLAN=$(staged_plan '^current/WeekPlan.*\.md$')
if [ -n "$WEEKPLAN" ]; then
  WP_LINES=$(wc -l < "$WEEKPLAN" | tr -d ' ')
  WP_ERRORS=()
  WP_MISSING_LIST=()

  # Детектор (а): >80 строк без достаточного числа <details>
  WP_DETAILS_COUNT=$(grep -c '<details' "$WEEKPLAN" 2>/dev/null || true); WP_DETAILS_COUNT=${WP_DETAILS_COUNT:-0}
  if [ "$WP_LINES" -gt 80 ] && [ "$WP_DETAILS_COUNT" -lt 3 ]; then
    WP_ERRORS+=("WeekPlan >80 строк ($WP_LINES) но collapsible секций < 3 ($WP_DETAILS_COUNT). Используй <details>/<summary> (formatting.md)")
  fi

  # Детектор (б): баланс <details> / </details>
  DETAILS_OPEN=$(grep -c '<details' "$WEEKPLAN" 2>/dev/null || true); DETAILS_OPEN=${DETAILS_OPEN:-0}
  DETAILS_CLOSE=$(grep -c '</details>' "$WEEKPLAN" 2>/dev/null || true); DETAILS_CLOSE=${DETAILS_CLOSE:-0}
  if [ "$DETAILS_OPEN" != "$DETAILS_CLOSE" ]; then
    WP_ERRORS+=("WeekPlan: несбалансированные <details> (открытий=$DETAILS_OPEN, закрытий=$DETAILS_CLOSE)")
  fi

  # Детектор (в): обязательные секции WeekPlan (по templates-dayplan.md)
  # ОПТ-5 (WP-297, 8 май): «Итоги» переехали в WeekReport — больше не required в WeekPlan
  WP_REQUIRED=(
    "Повестка|Agenda"
    "Inbox Triage"
    "План на неделю|Week Plan"
    "Контент-план|Content Plan"
  )
  for wp_section in "${WP_REQUIRED[@]}"; do
    if ! grep -qE "$wp_section" "$WEEKPLAN"; then
      WP_MISSING_LIST+=("$wp_section")
    fi
  done

  # Детектор (г): WeekReport валидация (ОПТ-5 WP-297)
  WEEKREPORT=$(ls "$GOV_PATH"/current/WeekReport\ *.md 2>/dev/null | sort | tail -1)
  if [ -n "$WEEKREPORT" ]; then
    if ! grep -q "Итоги" "$WEEKREPORT"; then
      WP_MISSING_LIST+=("Итоги (в WeekReport)")
    fi
  fi

  if [ ${#WP_MISSING_LIST[@]} -gt 0 ] || [ ${#WP_ERRORS[@]} -gt 0 ]; then
    WP_MISSING_STR=$(IFS=', '; echo "${WP_MISSING_LIST[*]:-}")
    WP_ERRORS_STR=$(IFS=', '; echo "${WP_ERRORS[*]:-}")
    WP_MSG="⛔ WEEKPLAN VALIDATION FAILED."
    [ ${#WP_MISSING_LIST[@]} -gt 0 ] && WP_MSG="$WP_MSG Пропущены секции (${#WP_MISSING_LIST[@]}): $WP_MISSING_STR."
    [ ${#WP_ERRORS[@]} -gt 0 ] && WP_MSG="$WP_MSG Ошибки структуры: $WP_ERRORS_STR."
    WP_MSG="$WP_MSG Исправь WeekPlan перед коммитом."
    jq -n --arg reason "$WP_MSG" '{"decision": "block", "reason": $reason}'
    exit 0
  fi
fi

# Report results
if [ ${#MISSING[@]} -gt 0 ] || [ ${#ERRORS[@]} -gt 0 ]; then
  MISSING_STR=$(printf ', %s' "${MISSING[@]}")
  MISSING_STR=${MISSING_STR:2}
  ERRORS_STR=$(printf ', %s' "${ERRORS[@]}")
  ERRORS_STR=${ERRORS_STR:2}

  MSG="⛔ DAYPLAN VALIDATION FAILED."
  [ ${#MISSING[@]} -gt 0 ] && MSG="$MSG Пропущены секции (${#MISSING[@]}): $MISSING_STR."
  [ ${#ERRORS[@]} -gt 0 ] && MSG="$MSG Ошибки формата/структуры: $ERRORS_STR."
  MSG="$MSG Исправь DayPlan перед коммитом."

  jq -n --arg reason "$MSG" '{"decision": "block", "reason": $reason}'
elif [ -n "$DAYPLAN" ]; then
  cat <<'EOF'
{"additionalContext": "✅ DayPlan прошёл валидацию: секции, collapsible, непустые блоки, мультипликатор, carry-over."}
EOF
else
  # Ф342: no DayPlan in this commit -> nothing was validated, say nothing.
  echo '{}'
fi

exit 0
