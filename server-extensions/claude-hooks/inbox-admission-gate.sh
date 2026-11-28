#!/usr/bin/env bash
# inbox-admission-gate.sh -- PreToolUse admission to work on a WP whose inbox
# holds untriaged «новое» entries (WP-561 Ф94 part 2; pilot decision 28.11.2026
# «Включаем, правку разрешаю», which also permits this edit of .claude/hooks/
# under S-33 for this gate only; design agreed with Codex in a peer session).
#
# Why: the 25.11 agreement (WP-561 Ф87) says that at the opening of a session
# on a WP every «новое» entry of its inbox (DS-my-strategy inbox/WP-N/INBOX.md)
# on the server is triaged before work -- moved into the card's «Осталось» or
# marked «учтено», with the pilot's consent. As protocol text alone it was
# skipped (28.11: 41 untriaged entries in 11 inboxes after later sessions).
#
# Scope, same as ritual-hard-gate.sh: only when the pilot himself named a WP
# (РП-NNN / WP-NNN) in his latest message. The WP detection is the shared
# ritual_prompt_names_wp / ritual_prompt_wp_number of lib/ritual-detect.sh,
# run over a view of the transcript that holds only the pilot's own latest
# message (lib/inbox_admission.py: tool results, task notifications, subagent
# and skill text are not the pilot's words; over the raw transcript the shared
# detection resets to "no WP" after the first tool result of a turn).
# Interactive Claude Code sessions only: headless runs (CLAUDE_CODE_ENTRYPOINT
# sdk-*) are skipped. Codex and Kimi do not read this settings file and are
# NOT covered by this gate.
#
# Admitted when (re-checked on every call, so admission stays bound to the
# named WP and to the server snapshot of its inbox):
#   1. the server inbox of the WP has no «новое» entries (no inbox file = 0);
#   2. every server «новое» entry is «учтено» in a working copy of this
#      conversation (governance_worktree of its open session semaphore);
#   3. .iwe-runtime/intent-declarations/<conversation>.json carries an
#      inbox_deferral for this conversation + WP + the current server
#      fingerprint (`declare-intent.sh WP-N --inbox-deferred "<quote>"`) and
#      the quote is found in one of the pilot's own messages of the transcript.
#      A new entry on the server changes the fingerprint and voids it.
# A read error of the server inbox does not admit (deny with the reason).
# Allowed before admission (never denied here): Read/Grep/Glob, the Bash
# allowlist of lib/inbox_admission.py (reads and the triage commands; a chain
# only when every part is allowed) and Edit/Write of this WP's card and INBOX.md.
#
# Failure policy: an internal error of the gate itself (crash, no python or
# jq, unreadable transcript) ALLOWS and writes a line to
# .iwe-runtime/inbox-admission-gate.log -- it must never lock the pilot out.
# Kill switch: file .iwe-runtime/inbox-admission-gate-off or
# IWE_INBOX_ADMISSION_GATE=off -> allow (logged). It is for a broken gate, not
# for skipping triage. Test knob: IWE_INBOX_ADMISSION_PYTHON (interpreter).
# Every protected action reads the current server head. Only the parsed inbox
# for an exact immutable commit is cached; malformed caches are re-read.
#
# Contract (Claude Code PreToolUse): stdin JSON {session_id, transcript_path,
# tool_name, tool_input, cwd, ...}; deny = hookSpecificOutput JSON on stdout
# (built with jq -n --arg), allow = no output, exit 0.

set -uo pipefail
export PATH="/run/current-system/sw/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${HOOK_DIR}/lib"
ROOT_DIR="$(cd "${HOOK_DIR}/../.." && pwd)"
RUNTIME_DIR="${IWE_RUNTIME_DIR:-${HOME:-/nonexistent}/IWE/.iwe-runtime}"
LOG_FILE="${RUNTIME_DIR}/inbox-admission-gate.log"
PY="${IWE_INBOX_ADMISSION_PYTHON:-python3}"
SESSION_ID=""
TOOL_NAME=""

gate_log() {  # <event> <detail>: one line per event; a failed write still reaches stderr
  local line
  line="$(date -u +%Y-%m-%dT%H:%M:%SZ) event=$1 session=${SESSION_ID:-?} tool=${TOOL_NAME:-?} $2"
  { mkdir -p "${RUNTIME_DIR}" && printf '%s\n' "${line}" >> "${LOG_FILE}"; } 2>/dev/null \
    || echo "[inbox-admission-gate] журнал ${LOG_FILE} не записан: ${line}" >&2
}

allow_internal() {  # <detail>: the gate itself failed -- allow, loudly
  gate_log internal_error "allowed: $1"
  echo "[inbox-admission-gate] ВНИМАНИЕ: сбой самой проверки ящика, вызов пропущен без неё: $1 (журнал ${LOG_FILE})" >&2
  exit 0
}

INPUT=$(cat)
[ -n "${INPUT}" ] || exit 0

case "${CLAUDE_CODE_ENTRYPOINT:-}" in
  sdk-*) exit 0 ;;  # headless claude -p / SDK run, not an interactive session
esac

command -v jq >/dev/null 2>&1 || allow_internal "jq не найден"
SESSION_ID=$(printf '%s' "${INPUT}" | jq -r '.session_id // empty' 2>/dev/null) \
  || allow_internal "вход хука не разобран"
TOOL_NAME=$(printf '%s' "${INPUT}" | jq -r '.tool_name // empty' 2>/dev/null)
TRANSCRIPT_PATH=$(printf '%s' "${INPUT}" | jq -r '.transcript_path // empty' 2>/dev/null)

if [ "${IWE_INBOX_ADMISSION_GATE:-}" = "off" ]; then
  gate_log kill_switch "allowed: IWE_INBOX_ADMISSION_GATE=off"
  exit 0
fi
if [ -e "${RUNTIME_DIR}/inbox-admission-gate-off" ]; then
  gate_log kill_switch "allowed: ${RUNTIME_DIR}/inbox-admission-gate-off"
  exit 0
fi

[ -n "${SESSION_ID}" ] && [ -n "${TRANSCRIPT_PATH}" ] && [ -f "${TRANSCRIPT_PATH}" ] || exit 0
# session_id becomes a file name (intent-declarations/<id>.json): same charset
# guard as ritual-hard-gate.sh, before any use.
case "${SESSION_ID}" in
  *[!A-Za-z0-9._-]*) allow_internal "session_id вне допустимых символов" ;;
esac

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/inbox-admission.XXXXXX") || allow_internal "mktemp не удался"
VIEW="${WORK_DIR}/pilot-view.jsonl"
ERR="${WORK_DIR}/stderr"
trap 'rm -f "${VIEW}" "${ERR}"; rmdir "${WORK_DIR}" 2>/dev/null' EXIT

helper_failed() {  # <step> <exit code>
  allow_internal "$1: код $2; $(tail -n 1 "${ERR}" 2>/dev/null | cut -c1-300)"
}

# prepare reads the hook input on stdin; admit gets everything as arguments
# (a writer into a pipe nobody reads would die of SIGPIPE on a large input).
PREP=$(printf '%s' "${INPUT}" | "${PY}" "${LIB_DIR}/inbox_admission.py" prepare --view "${VIEW}" 2>"${ERR}") \
  || helper_failed prepare "$?"
case "$(printf '%s' "${PREP}" | jq -r '.action // empty' 2>/dev/null)" in
  allow) exit 0 ;;
  check) ;;
  *) allow_internal "prepare: ответ не разобран" ;;
esac
TARGET_WP=$(printf '%s' "${PREP}" | jq -r '.target_wp // empty' 2>/dev/null)
BLOCKED=$(printf '%s' "${PREP}" | jq -r '.blocked // empty' 2>/dev/null)

# shellcheck source=lib/ritual-detect.sh
. "${LIB_DIR}/ritual-detect.sh" || allow_internal "lib/ritual-detect.sh не загружен"
NAMES_WP=$(ritual_prompt_names_wp "${VIEW}")
case "${NAMES_WP}" in
  no) exit 0 ;;
  yes) ;;
  *) allow_internal "распознавание номера РП: ${NAMES_WP:-пусто}" ;;
esac
NAMED_WP=$(ritual_prompt_wp_number "${VIEW}")
[ -n "${NAMED_WP}" ] || allow_internal "номер РП не извлечён из сообщения пилота"
# Editing this WP's card or INBOX.md records the triage decisions themselves.
[ "${TARGET_WP}" = "${NAMED_WP}" ] && exit 0

GOV_REPO="${IWE_WORKSPACE:-${HOME:-/nonexistent}/IWE}/${IWE_GOVERNANCE_REPO:-DS-my-strategy}"
SESSIONS_DIR="${IWE_ROOT:-${HOME:-/nonexistent}/IWE}/.iwe-runtime/sessions"
RESULT=$("${PY}" "${LIB_DIR}/inbox_admission.py" admit --wp "${NAMED_WP}" --session "${SESSION_ID}" \
  --transcript "${TRANSCRIPT_PATH}" --gov-repo "${GOV_REPO}" --root "${ROOT_DIR}" \
  --runtime-dir "${RUNTIME_DIR}" --sessions-dir "${SESSIONS_DIR}" --blocked "${BLOCKED}" \
  </dev/null 2>"${ERR}") || helper_failed admit "$?"
case "$(printf '%s' "${RESULT}" | jq -r '.decision // empty' 2>/dev/null)" in
  allow) exit 0 ;;
  deny) ;;
  *) allow_internal "admit: ответ не разобран" ;;
esac
REASON=$(printf '%s' "${RESULT}" | jq -r '.message // empty' 2>/dev/null)
BASIS=$(printf '%s' "${RESULT}" | jq -r '.basis // empty' 2>/dev/null)
[ -n "${REASON}" ] || allow_internal "admit: пустой текст отказа"

gate_log deny "wp=${NAMED_WP} basis=${BASIS}"
jq -n --arg reason "${REASON}" \
  '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}' \
  || allow_internal "jq не собрал ответ отказа"
exit 0
