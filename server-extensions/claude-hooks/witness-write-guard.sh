#!/bin/bash
# Witness Write Guard (PreToolUse, WP-484 Ф56, 05.08.2026)
#
# Проблема (холодное ревью, живое PoC воспроизведено): без этого хука закрывающий
# агент мог напрямую записать поддельную строку в файл-свидетель
# (.iwe-runtime/pilot-witness/*.jsonl) или в маппинг сессии
# (.iwe-runtime/quick-close-harness-session/*.session_id) простым Bash/Write —
# обходя цель всей фазы (агент не должен уметь вписать слова, которые потом
# покажут пилоту как "записанный ответ"). Тот же класс гейта, что
# close-runner-gate.sh уже применяет к прямому git commit в обход раннера.
#
# Deny-closed по упоминанию пути, не по классификации read/write: у закрывающего
# агента нет ни одного легитимного сценария ссылаться на эти пути напрямую в
# своих Bash/Write-вызовах вообще (render/append/release читают/пишут их сами,
# как подпроцессы process-runner.py — PreToolUse их не видит, это отдельное
# дерево процессов). Поэтому не нужно перечислять write-глаголы (tee/cp/sed -i/
# python open() и т.п.) — само упоминание пути из основного Bash-вызова агента
# уже аномалия.
#
# НЕ криптозащита (design point 5, WP-484.md §Ф56): агент с shell-доступом и
# достаточной изобретательностью может найти необохваченный примитив (тот же
# класс известных обходов, что close-runner-gate.sh документирует у себя) — это
# рефлекс против казуального/рационализирующего обхода, не гарантия против
# целенаправленно злонамеренного агента.
#
# Защищаемые пути: .iwe-runtime/pilot-witness/**, .iwe-runtime/quick-close-
# harness-session/**, .iwe-runtime/autonomous-run.marker — пишутся ТОЛЬКО
# .claude/hooks/pilot-witness-recorder.sh, .claude/hooks/close-runner-gate.sh
# или доверенным launchd/systemd unit-файлом, никогда закрывающим агентом.
#
# Контракт PreToolUse: stdin JSON {"tool_name","tool_input","session_id",...}.
# Exit 0 = allow; exit 2 = block (stderr показывается LLM).
set -uo pipefail

INPUT=$(cat)
[ -z "$INPUT" ] && exit 0

TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)

PROTECTED_RE='\.iwe-runtime/pilot-witness/|\.iwe-runtime/quick-close-harness-session/|\.iwe-runtime/autonomous-run\.marker'

TARGET=""
case "$TOOL_NAME" in
  Write|Edit|MultiEdit)
    TARGET=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
    ;;
  Bash)
    TARGET=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
    ;;
  *)
    exit 0
    ;;
esac
[ -n "$TARGET" ] || exit 0

echo "$TARGET" | grep -qE "$PROTECTED_RE" || exit 0

echo "[witness-write-guard] заблокировано прямое обращение агента к $PROTECTED_RE -- эти файлы пишутся/читаются только .claude/hooks/pilot-witness-recorder.sh, close-runner-gate.sh или доверенным планировщиком, никогда закрывающим агентом напрямую (WP-484 Ф56, session-reflection-append.sh сам читает witness как подпроцесс раннера). Продолжай через process-runner.py next -- witness обрабатывается внутри хендлера." >&2
exit 2
