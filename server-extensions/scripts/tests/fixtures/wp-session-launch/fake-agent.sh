#!/usr/bin/env bash
# Stand-in for the claude CLI in wp-session-launch-smoke.sh. Runs in the
# isolated copy (cwd); behaviour is chosen by FAKE_AGENT_SCENARIO.
set -euo pipefail
decide() {
  mkdir -p .wp-launch
  printf '[{"id": "d1", "kind": "И", "question": "q", "options": ["a"], "choice": "a", "basis": "rule", "right": "auto", "depends_on": []}]\n' \
    > .wp-launch/decisions.json
}
result() { printf '{"type": "result", "subtype": "%s", "is_error": %s, "num_turns": 3, "result": "fake summary"}\n' "$1" "$2"; }
case "${FAKE_AGENT_SCENARIO:?}" in
  write-allowed) printf 'new\n' > allowed/new.md; printf 'changed\n' >> allowed/existing.md; decide; result success false ;;
  odd-names) printf 'x\n' > "allowed/с пробелом и кириллицей.md"; printf 'y\n' > 'allowed/*'; decide; result success false ;;
  nothing) decide; result success false ;;
  delete-allowed) git rm -q allowed/to-delete.md; decide; result success false ;;
  write-outside) printf 'x\n' > allowed/ok.md; mkdir -p other; printf 'x\n' > other/bad.md; decide; result success false ;;
  prefix-trick) mkdir -p allowedx; printf 'x\n' > allowedx/bad.md; decide; result success false ;;
  symlink) ln -s /etc/hosts allowed/link; decide; result success false ;;
  rename-out) mkdir -p other; git mv allowed/existing.md other/existing.md; decide; result success false ;;
  agent-commit) printf 'x\n' > allowed/c.md; git add allowed/c.md; git -c user.name=t -c user.email=t@t commit -qm agent; decide; result success false ;;
  extra-in-wp-launch) decide; printf 'x\n' > .wp-launch/other.txt; printf 'x\n' > allowed/a.md; result success false ;;
  ignored-outside) printf 'x\n' > allowed/ok.md; mkdir -p other; printf 'x\n' > other/trace.log; decide; result success false ;;
  nested-repo) mkdir -p allowed/sub && git init -q allowed/sub; decide; result success false ;;
  hook-refuses) printf 'x\n' > allowed/refuse-me.md; decide; result success false ;;
  tamper-git) printf 'gitdir: /nonexistent/elsewhere\n' > .git; result success false ;;
  fail) printf 'x\n' > allowed/partial.md; result error_during_execution true; exit 1 ;;
  max-turns) printf 'x\n' > allowed/partial.md; result error_max_turns true ;;
  hang-with-child)
    ( sleep 300; printf 'late\n' > allowed/late.md ) &
    printf 'x\n' > allowed/early.md
    sleep 300 ;;
  orphan-child)
    ( sleep 3; printf 'late\n' > allowed/late.md ) &
    decide; result success false ;;
  *) echo "unknown scenario" >&2; exit 2 ;;
esac
