#!/usr/bin/env bash
# Regression for WP-484 Ф275 предусловие 3 (S-33): 4-field note-commit claims
# and `note-commit --promote-intent` in scripts/session-guard.sh.
#
# Phase 1 (commit-push.sh) made a durable commit intent before `git commit`;
# this test covers phase 2, the guard side:
#   - plain note-commit accepts --source-checkout/--branch only together, only
#     for a checkout that is a worktree sibling OR a clone with the same origin
#     URL, and stores the 4-field claim "commit: <repo> <sha> <checkout> <branch>";
#   - a 2-field and a 4-field claim for the same (repo,sha) never coexist -- the
#     new spelling replaces the old one in place;
#   - --promote-intent finds the commit by its "Iwe-Intent: <uuid>" trailer,
#     re-checks parent/message/paths against the intent record, appends the
#     claim, marks the intent completed and prints exactly "PROMOTED <sha>";
#   - re-promotion with the claim already present is idempotent;
#   - any mismatch (parent moved, message/paths differ) refuses with NO writes.
#
# Handler-side scenarios (commit-push.sh session_claimed_shas accepting an
# independent clone of the same origin as the fetch source) live in the
# DS-my-strategy repo: scripts/tests/commit-push-claim-fetch-smoke.sh.
#
# Usage: bash scripts/tests/note-commit-promote-intent-smoke.sh  (exit 0 = all green)
set -uo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SG="$ROOT_DIR/scripts/session-guard.sh"
[ -f "$SG" ] || { echo "не найден проверяемый скрипт: $SG"; exit 1; }

T=$(mktemp -d "${TMPDIR:-/tmp}/note-commit-promote-intent.XXXXXX")
trap 'rm -rf "$T"' EXIT
export IWE_ROOT="$T/iwe"
mkdir -p "$IWE_ROOT/.iwe-runtime/sessions"
AGENT=kimi-test
SID=smoke-session-1
SEM="$IWE_ROOT/.iwe-runtime/sessions/${AGENT}-${SID}.open"
cat > "$SEM" <<EOF
agent: $AGENT
session_id: $SID
wp: 999
slug: 2026-10-31-smoke
task: smoke
opened_at: 2026-10-31T00:00:00Z
EOF

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

# Repo inside IWE_ROOT so _resolve_repo_checkout finds it.
REPO="$IWE_ROOT/myrepo"
mkdir -p "$REPO"
ORIGIN="$T/origin.git"
git init -q --bare "$ORIGIN"
git -C "$REPO" init -q
git -C "$REPO" remote add origin "$ORIGIN"
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name test
echo a > "$REPO/f.txt"
git -C "$REPO" add f.txt
git -C "$REPO" commit -qm init
git -C "$REPO" branch -M main
REPO_REAL=$(realpath "$REPO")

note() { (cd "$REPO" && bash "$SG" note-commit "$@" --agent "$AGENT" --session-id "$SID" 2>&1); }

echo "== note-commit: 4-field claim и (repo,sha)-дедуп =="
echo b >> "$REPO/f.txt"
git -C "$REPO" commit -qam second
SHA2=$(git -C "$REPO" rev-parse HEAD)

out=$(note "$SHA2" --repo myrepo --source-checkout "$REPO" --branch main); rc=$?
{ [ $rc -eq 0 ] && grep -qx "commit: myrepo $SHA2 $REPO_REAL main" "$SEM"; } \
  && ok "4-field note-commit stored" || bad "4-field note-commit (rc=$rc out=$out sem=$(grep 'commit:' "$SEM"))"

out=$(note "$SHA2" --repo myrepo); rc=$?
n=$(grep -c "^commit: myrepo $SHA2" "$SEM")
{ [ $rc -eq 0 ] && [ "$n" -eq 1 ] && grep -qx "commit: myrepo $SHA2" "$SEM"; } \
  && ok "2-field re-note replaces 4-field, single line" \
  || bad "2-field re-note (rc=$rc count=$n lines=$(grep 'commit:' "$SEM"))"

out=$(note "$SHA2" --repo myrepo --source-checkout "$REPO" --branch main); rc=$?
n=$(grep -c "^commit: myrepo $SHA2" "$SEM")
{ [ $rc -eq 0 ] && [ "$n" -eq 1 ] && grep -qx "commit: myrepo $SHA2 $REPO_REAL main" "$SEM"; } \
  && ok "4-field re-note upgrades in place" || bad "4-field re-note (rc=$rc lines=$(grep 'commit:' "$SEM"))"

out=$(note "$SHA2" --repo myrepo --source-checkout /tmp --branch main); rc=$?
[ $rc -ne 0 ] && ok "non-repo --source-checkout refused" || bad "non-repo checkout accepted"
OTHER_ORIGIN="$T/other.git"
git -C "$T" init -q --bare "$OTHER_ORIGIN"
git -C "$T" clone -q "$OTHER_ORIGIN" otherclone 2>/dev/null
out=$(note "$SHA2" --repo myrepo --source-checkout "$T/otherclone" --branch main); rc=$?
[ $rc -ne 0 ] && ok "different-origin checkout refused" || bad "different-origin checkout accepted"

echo "== note-commit --promote-intent: round-trip, idempotency, fail-closed =="
INTDIR="$IWE_ROOT/.iwe-runtime/commit-intents/$SID"
mkdir -p "$INTDIR"
# The intent file name carries the repo-id key (first 12 of sha256 of the
# realpath'd git-common-dir) -- compute it exactly like the guard and the
# handler do.
COMMON=$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir)
COMMON=$(realpath "$COMMON" 2>/dev/null || (cd "$COMMON" && pwd -P))
REPOKEY=$(printf '%s' "$COMMON" | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest()[:12])')
IFILE="$INTDIR/myrepo-$REPOKEY.jsonl"
UUID="11111111-2222-3333-4444-555555555555"
PARENT=$(git -C "$REPO" rev-parse HEAD)
MSG="intent commit

Iwe-Intent: $UUID"
MSGSHA=$(printf '%s' "$MSG" | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')
echo c > "$REPO/g.txt"
git -C "$REPO" add g.txt
git -C "$REPO" commit -qm "$MSG"
CSHA=$(git -C "$REPO" rev-parse HEAD)
python3 - "$IFILE" "$UUID" "$PARENT" "$MSGSHA" "$REPO" <<'PY'
import json, sys, datetime
path, uuid, parent, msgsha, checkout = sys.argv[1:6]
rec = {"v": 1, "uuid": uuid, "repo": "myrepo", "expected_parent": parent,
       "message_sha256": msgsha, "paths": ["g.txt"], "source_checkout": checkout,
       "branch": "main",
       "created_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
       "status": "prepared"}
open(path, "w").write(json.dumps(rec) + "\n")
PY
out=$(note --promote-intent "$UUID" --repo myrepo); rc=$?
promoted=$(printf '%s\n' "$out" | grep -aoE 'PROMOTED [0-9a-f]{40}' | head -1 | cut -d' ' -f2)
{ [ $rc -eq 0 ] && [ "$promoted" = "$CSHA" ] \
  && grep -qx "commit: myrepo $CSHA $REPO main" "$SEM"; } \
  && ok "promote round-trip prints PROMOTED and writes the claim" \
  || bad "promote round-trip (rc=$rc promoted=$promoted out=$out sem=$(grep 'commit:' "$SEM"))"
grep -q '"status": "completed"' "$IFILE" \
  && ok "intent marked completed" || bad "intent completion record missing"

out=$(note --promote-intent "00000000-0000-0000-0000-000000000000" --repo myrepo); rc=$?
{ [ $rc -eq 1 ] && printf '%s' "$out" | grep -q "intent-not-found"; } \
  && ok "unknown uuid -> intent-not-found" || bad "unknown uuid (rc=$rc out=$out)"

out=$(note --promote-intent "$UUID" --repo myrepo); rc=$?
n=$(grep -c "^commit: myrepo $CSHA" "$SEM")
{ [ $rc -eq 0 ] && printf '%s' "$out" | grep -q "PROMOTED $CSHA" && [ "$n" -eq 1 ]; } \
  && ok "second promote idempotent" || bad "second promote (rc=$rc out=$out n=$n)"

UUID2="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
git -C "$REPO" checkout -qb other
echo d > "$REPO/h.txt"
git -C "$REPO" add h.txt
git -C "$REPO" commit -qm "other

Iwe-Intent: $UUID2"
python3 - "$IFILE" "$UUID2" "$PARENT" "$REPO" <<'PY'
import json, sys, datetime
path, uuid, parent, checkout = sys.argv[1:5]
rec = {"v": 1, "uuid": uuid, "repo": "myrepo", "expected_parent": parent,
       "message_sha256": "0" * 64, "paths": ["h.txt"], "source_checkout": checkout,
       "branch": "other",
       "created_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
       "status": "prepared"}
open(path, "a").write(json.dumps(rec) + "\n")
PY
before=$(grep -c '^commit:' "$SEM")
out=$(note --promote-intent "$UUID2" --repo myrepo); rc=$?
after=$(grep -c '^commit:' "$SEM")
# E2: the commit EXISTS, so the claim is written for the actual sha and the
# mismatch is visible debt (INTENT-DEBT + nonzero), never a silent orphan.
OSHAFAIL=$(git -C "$REPO" log --all --format=%H --grep="Iwe-Intent: $UUID2" | head -1)
{ [ $rc -eq 2 ] && [ $((after-before)) -eq 1 ] \
  && printf '%s' "$out" | grep -q "PROMOTED $OSHAFAIL" \
  && printf '%s' "$out" | grep -q "INTENT-DEBT intent-parent-moved" \
  && grep -qx "commit: myrepo $OSHAFAIL $REPO other" "$SEM"; } \
  && ok "parent-moved: claim-and-flag (claim written, INTENT-DEBT, exit 2)" \
  || bad "parent-moved (rc=$rc out=$out $before->$after sha=$OSHAFAIL sem=$(grep 'commit:' "$SEM"))"

UUID3="99999999-8888-7777-6666-555555555555"
git -C "$REPO" checkout -q main
P3=$(git -C "$REPO" rev-parse HEAD)
echo e > "$REPO/i.txt"
git -C "$REPO" add i.txt
git -C "$REPO" commit -qm "real message

Iwe-Intent: $UUID3"
DSHA=$(git -C "$REPO" rev-parse HEAD)
python3 - "$IFILE" "$UUID3" "$P3" "$REPO" <<'PY'
import json, sys, datetime
path, uuid, parent, checkout = sys.argv[1:5]
rec = {"v": 1, "uuid": uuid, "repo": "myrepo", "expected_parent": parent,
       "message_sha256": "f" * 64, "paths": ["i.txt"], "source_checkout": checkout,
       "branch": "main",
       "created_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
       "status": "prepared"}
open(path, "a").write(json.dumps(rec) + "\n")
PY
out=$(note --promote-intent "$UUID3" --repo myrepo); rc=$?
{ [ $rc -eq 2 ] && printf '%s' "$out" | grep -q "INTENT-DEBT intent-content-mismatch" \
  && grep -qx "commit: myrepo $DSHA $REPO main" "$SEM"; } \
  && ok "content-mismatch: claim-and-flag (4-field claim kept, exit 2)" \
  || bad "content-mismatch (rc=$rc out=$out sem=$(grep 'commit:' "$SEM"))"

echo "== promote: валидация полей 3/4 intent-записи, чужой trailer в теле =="

# Whitespace-bearing source_checkout must fail promote with content-mismatch
# and write no claim (cold review, Ф275 phase 2: medium).
UUID4="55555555-6666-7777-8888-999999999999"
P4=$(git -C "$REPO" rev-parse HEAD)
echo f > "$REPO/j.txt"
git -C "$REPO" add j.txt
MSG4="ws checkout test

Iwe-Intent: $UUID4"
git -C "$REPO" commit -qm "$MSG4"
WSHA=$(git -C "$REPO" rev-parse HEAD)
MSGSHA4=$(printf '%s' "$MSG4" | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')
python3 - "$IFILE" "$UUID4" "$P4" "$MSGSHA4" <<'PY'
import json, sys, datetime
path, uuid, parent, msgsha = sys.argv[1:5]
rec = {"v": 1, "uuid": uuid, "repo": "myrepo", "expected_parent": parent,
       "message_sha256": msgsha, "paths": ["j.txt"],
       "source_checkout": "/tmp/ev il-checkout", "branch": "main",
       "created_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
       "status": "prepared"}
open(path, "a").write(json.dumps(rec) + "\n")
PY
before=$(grep -c '^commit:' "$SEM")
out=$(note --promote-intent "$UUID4" --repo myrepo); rc=$?
after=$(grep -c '^commit:' "$SEM")
{ [ $rc -eq 2 ] && [ $((after-before)) -eq 1 ] \
  && printf '%s' "$out" | grep -q "INTENT-DEBT intent-content-mismatch" \
  && grep -qx "commit: myrepo $WSHA - -" "$SEM"; } \
  && ok "whitespace checkout: claim degraded to '- -' with debt, exit 2" \
  || bad "whitespace checkout (rc=$rc out=$out $before->$after)"

# A commit whose BODY merely mentions another intent's trailer text must not
# promote against that intent: grep finds it, the content check must refuse.
UUID5="abababab-baba-dcdc-eded-efefefefefef"
UUIDX="12345678-1234-1234-1234-1234567890ab"
P5=$(git -C "$REPO" rev-parse HEAD)
echo g > "$REPO/k.txt"
git -C "$REPO" add k.txt
git -C "$REPO" commit -qm "notes mention Iwe-Intent: $UUIDX in passing

Iwe-Intent: $UUID5"
BSHA=$(git -C "$REPO" rev-parse HEAD)
python3 - "$IFILE" "$UUIDX" "$P5" <<'PY'
import json, sys, datetime
path, uuid, parent = sys.argv[1:4]
rec = {"v": 1, "uuid": uuid, "repo": "myrepo", "expected_parent": parent,
       "message_sha256": "e" * 64, "paths": ["k.txt"],
       "source_checkout": None, "branch": None,
       "created_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
       "status": "prepared"}
open(path, "a").write(json.dumps(rec) + "\n")
PY
before=$(grep -c '^commit:' "$SEM")
out=$(note --promote-intent "$UUIDX" --repo myrepo); rc=$?
after=$(grep -c '^commit:' "$SEM")
# The trailer-block parse rejects the body mention: the commit is not a valid
# carrier of UUIDX at all, so the failure is intent-commit-missing (a body
# line is not a trailer).
{ [ $rc -eq 1 ] && printf '%s' "$out" | grep -q "intent-commit-missing" \
  && [ "$before" = "$after" ]; } \
  && ok "body-mentions-trailer commit cannot promote against that intent" \
  || bad "body-trailer negative (rc=$rc out=$out $before->$after)"

echo "== promote: crash matrix (blocker B) =="
# completed ∧ claim missing -> re-append the claim, PROMOTED, exit 0.
# Simulate by deleting the claim line of the round-tripped intent (UUID).
sed -i '' "/^commit: myrepo $CSHA /d" "$SEM"
grep -q "^commit: myrepo $CSHA" "$SEM" && bad "crash-matrix fixture (claim still present)" || {
  out=$(note --promote-intent "$UUID" --repo myrepo); rc=$?
  { [ $rc -eq 0 ] && printf '%s' "$out" | grep -q "PROMOTED $CSHA" \
    && grep -qx "commit: myrepo $CSHA $REPO main" "$SEM"; } \
    && ok "completed ∧ claim missing: claim re-appended, PROMOTED" \
    || bad "completed ∧ claim missing (rc=$rc out=$out sem=$(grep 'commit:' "$SEM"))"
}
# claim exists ∧ intent still prepared -> completed record appended, PROMOTED.
# (Round-trip case above already asserted the completed record; assert the
# no-op side: re-promote now that everything is in place.)
out=$(note --promote-intent "$UUID" --repo myrepo); rc=$?
n=$(grep -c "^commit: myrepo $CSHA" "$SEM")
{ [ $rc -eq 0 ] && [ "$n" -eq 1 ] && grep -q '"status": "completed"' "$IFILE"; } \
  && ok "claim present ∧ intent completed: stable no-op, single claim" \
  || bad "matrix no-op (rc=$rc n=$n)"

echo "== promote: cherry-pick ambiguity (blocker B matrix edge) =="
UUID6="cafecafe-0000-0000-0000-000000000006"
git -C "$REPO" checkout -q main
P6=$(git -C "$REPO" rev-parse HEAD)
echo h > "$REPO/h.txt"
git -C "$REPO" add h.txt
git -C "$REPO" commit -qm "original

Iwe-Intent: $UUID6"
ORIG6=$(git -C "$REPO" rev-parse HEAD)
# A second object carrying the SAME trailer (what a cherry-pick produces),
# but with the trailer still in the trailer block -- a real cherry-pick
# appends "(cherry picked from ...)" AFTER the trailer, which ends the block;
# commit-tree builds the ambiguous pair directly.
PICK6=$(git -C "$REPO" commit-tree "$P6^{tree}" -p "$P6" -m "original

Iwe-Intent: $UUID6")
git -C "$REPO" update-ref refs/heads/pick "$PICK6"
python3 - "$IFILE" "$UUID6" "$P6" <<'PY'
import json, sys, datetime
path, uuid, parent = sys.argv[1:4]
rec = {"v": 1, "uuid": uuid, "repo": "myrepo", "expected_parent": parent,
       "message_sha256": "0" * 64, "paths": ["h.txt"],
       "source_checkout": None, "branch": None,
       "created_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
       "status": "prepared"}
open(path, "a").write(json.dumps(rec) + "\n")
PY
before=$(grep -c '^commit:' "$SEM")
out=$(note --promote-intent "$UUID6" --repo myrepo); rc=$?
after=$(grep -c '^commit:' "$SEM")
{ [ $rc -eq 1 ] && printf '%s' "$out" | grep -q "intent-ambiguous" \
  && [ "$before" = "$after" ]; } \
  && ok "cherry-picked duplicate trailer -> intent-ambiguous, no claim" \
  || bad "cherry-pick ambiguity (rc=$rc out=$out $before->$after)"
git -C "$REPO" checkout -q main

echo "== promote: sha-recorded intent survives dangling commit (blocker D) =="
UUID7="dddddddd-0000-0000-0000-000000000007"
P7=$(git -C "$REPO" rev-parse HEAD)
echo i > "$REPO/i.txt"
git -C "$REPO" add i.txt
git -C "$REPO" commit -qm "dangling candidate

Iwe-Intent: $UUID7"
DANGLING=$(git -C "$REPO" rev-parse HEAD)
DGL_TREE=$(git -C "$REPO" rev-parse "$DANGLING^{tree}")
DGL_MSG=$(git -C "$REPO" cat-file commit "$DANGLING" | python3 -c 'import sys,hashlib; raw=sys.stdin.buffer.read(); print(hashlib.sha256(raw.split(b"\n\n",1)[1]).hexdigest())')
python3 - "$IFILE" "$UUID7" "$P7" "$DANGLING" "$DGL_TREE" "$DGL_MSG" "$REPO" <<'PY'
import json, sys, datetime
path, uuid, parent, sha, tree, msgsha, checkout = sys.argv[1:8]
rec = {"v": 1, "uuid": uuid, "repo": "myrepo", "expected_parent": parent,
       "message_sha256": msgsha, "tree": tree, "paths": ["i.txt"],
       "sha": sha, "status": "committed",
       "source_checkout": checkout, "branch": "main",
       "created_at": datetime.datetime.now(datetime.timezone.utc).isoformat()}
open(path, "a").write(json.dumps(rec) + "\n")
PY
git -C "$REPO" reset -q --hard "$P7"
out=$(note --promote-intent "$UUID7" --repo myrepo); rc=$?
{ [ $rc -eq 0 ] && printf '%s' "$out" | grep -q "PROMOTED $DANGLING" \
  && grep -qx "commit: myrepo $DANGLING $REPO main" "$SEM"; } \
  && ok "sha-recorded dangling commit promotes via cat-file" \
  || bad "sha-record path (rc=$rc out=$out)"

echo "== promote: tree fingerprint mismatch (blocker E) =="
UUID8="eeeeeeee-0000-0000-0000-000000000008"
P8=$(git -C "$REPO" rev-parse HEAD)
echo j2 > "$REPO/j.txt"
git -C "$REPO" add j.txt
git -C "$REPO" commit -qm "tree tamper target

Iwe-Intent: $UUID8"
TSHA=$(git -C "$REPO" rev-parse HEAD)
TMSG=$(git -C "$REPO" cat-file commit "$TSHA" | python3 -c 'import sys,hashlib; raw=sys.stdin.buffer.read(); print(hashlib.sha256(raw.split(b"\n\n",1)[1]).hexdigest())')
python3 - "$IFILE" "$UUID8" "$P8" "$TSHA" "$TMSG" <<'PY'
import json, sys, datetime
path, uuid, parent, sha, msgsha = sys.argv[1:6]
rec = {"v": 1, "uuid": uuid, "repo": "myrepo", "expected_parent": parent,
       "message_sha256": msgsha,
       "tree": "1" * 40,  # wrong fingerprint: staged content moved under us
       "paths": ["j.txt"], "sha": sha, "status": "committed",
       "created_at": datetime.datetime.now(datetime.timezone.utc).isoformat()}
open(path, "a").write(json.dumps(rec) + "\n")
PY
before=$(grep -c '^commit:' "$SEM")
out=$(note --promote-intent "$UUID8" --repo myrepo); rc=$?
after=$(grep -c '^commit:' "$SEM")
{ [ $rc -eq 2 ] && [ $((after-before)) -eq 1 ] \
  && printf '%s' "$out" | grep -q "INTENT-DEBT intent-content-mismatch" \
  && grep -qx "commit: myrepo $TSHA - -" "$SEM"; } \
  && ok "tree fingerprint mismatch: claim-and-flag (exit 2)" \
  || bad "tree tamper (rc=$rc out=$out $before->$after)"
# P1 tuple consistency: the debt completion record carries the ACTUAL commit
# tree and message hash (only degraded when the object cannot be read).
TACTUAL_TREE=$(git -C "$REPO" rev-parse "$TSHA^{tree}")
python3 - "$IFILE" "$UUID8" "$TACTUAL_TREE" "$TMSG" <<'PY'
import json, sys
path, uuid, actual_tree, actual_msg = sys.argv[1:5]
latest = {}
for line in open(path):
    try:
        rec = json.loads(line)
    except ValueError:
        continue
    if rec.get("uuid") == uuid:
        latest = dict(latest, **rec)
ok = (latest.get("debt") == "intent-content-mismatch"
      and latest.get("tree") == actual_tree
      and latest.get("message_sha256") == actual_msg)
sys.exit(0 if ok else 1)
PY
[ $? -eq 0 ] && ok "P1: debt record tree/message match the actual commit" \
  || bad "P1: debt record tuple mismatch"
out=$(note --promote-intent "$UUID8" --repo myrepo); rc=$?
n=$(grep -c "^commit: myrepo $TSHA" "$SEM")
{ [ $rc -eq 0 ] && printf '%s' "$out" | grep -q "PROMOTED $TSHA" && [ "$n" -eq 1 ]; } \
  && ok "P1: re-promote after debt is a stable no-op (merged actual tree wins)" \
  || bad "P1 re-promote (rc=$rc n=$n out=$out)"

echo "== promote: truncated last jsonl line is ignored (robustness) =="
printf '{"uuid": "zzzz-truncated", "status": "prepa' >> "$IFILE"
out=$(note --promote-intent "$UUID" --repo myrepo); rc=$?
{ [ $rc -eq 0 ] && printf '%s' "$out" | grep -q "PROMOTED $CSHA"; } \
  && ok "truncated tail line ignored, file still usable" \
  || bad "truncated tail (rc=$rc out=$out)"

echo "== close: promote-pass before cleanup (blocker C) =="
SG="$ROOT_DIR/scripts/session-guard.sh"
FINISH_FUNCS=$(python3 - "$SG" <<'PY'
import re, subprocess, sys
src = open(sys.argv[1]).read()
out = []
for name in ("_promote_commit_intent", "_cleanup_session_commit_intents",
             "_finish_session_commit_intents"):
    start = re.search(r"(?m)^" + re.escape(name) + r"\(\) \{", src)
    if not start:
        sys.exit("missing " + name)
    for end in re.finditer(r"(?m)^\}[ \t]*(?:#.*)?$", src[start.start():]):
        cand = src[start.start():start.start() + end.end()] + "\n"
        if subprocess.run(["/bin/bash", "-n"], input=cand, text=True,
                          capture_output=True).returncode == 0:
            out.append(cand)
            break
    else:
        sys.exit("cannot parse " + name)
print("\n".join(out))
PY
)
# fresh fixture: same repo, fresh semaphore, a valid prepared intent.
SEM2="$IWE_ROOT/.iwe-runtime/sessions/${AGENT}-close-pass.open"
cat > "$SEM2" <<EOF
agent: $AGENT
session_id: close-pass
wp: 999
slug: 2026-10-31-close
task: smoke
opened_at: 2026-10-31T00:00:00Z
EOF
UUIDC="faceface-0000-0000-0000-0000000000c0"
PC=$(git -C "$REPO" rev-parse HEAD)
echo cc > "$REPO/cc.txt"
git -C "$REPO" add cc.txt
git -C "$REPO" commit -qm "close-pass commit

Iwe-Intent: $UUIDC"
CSHAC=$(git -C "$REPO" rev-parse HEAD)
MSGSHAC=$(git -C "$REPO" cat-file commit "$CSHAC" | python3 -c 'import sys,hashlib; raw=sys.stdin.buffer.read(); print(hashlib.sha256(raw.split(b"\n\n",1)[1]).hexdigest())')
INTDIR2="$IWE_ROOT/.iwe-runtime/commit-intents/close-pass"
mkdir -p "$INTDIR2"
IFILE2="$INTDIR2/myrepo-$REPOKEY.jsonl"
python3 - "$IFILE2" "$UUIDC" "$PC" "$MSGSHAC" "$REPO" <<'PY'
import json, sys, datetime
path, uuid, parent, msgsha, checkout = sys.argv[1:6]
rec = {"v": 1, "uuid": uuid, "repo": "myrepo", "expected_parent": parent,
       "message_sha256": msgsha, "paths": ["cc.txt"],
       "source_checkout": checkout, "branch": "main",
       "created_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
       "status": "prepared"}
open(path, "w").write(json.dumps(rec) + "\n")
PY
out=$(IWE_ROOT="$IWE_ROOT" REPO="$REPO" bash -c '
  _resolve_repo_checkout() { printf "%s\n" "$REPO"; }
  '"$FINISH_FUNCS"'
  _finish_session_commit_intents "$1" "$2"' _ "$SEM2" "close-pass" 2>&1); rc=$?
{ [ $rc -eq 0 ] && grep -qx "commit: myrepo $CSHAC $REPO main" "$SEM2" \
  && [ ! -d "$INTDIR2" ]; } \
  && ok "close promote-pass: claim written, intents dir cleaned" \
  || bad "close promote-pass (rc=$rc out=$out sem=$(grep 'commit:' "$SEM2"))"

# unpromotable intent: dir KEPT, WARN debt printed, close still succeeds.
SEM3="$IWE_ROOT/.iwe-runtime/sessions/${AGENT}-close-keep.open"
cat > "$SEM3" <<EOF
agent: $AGENT
session_id: close-keep
wp: 999
slug: 2026-10-31-keep
task: smoke
opened_at: 2026-10-31T00:00:00Z
EOF
UUIDK="1ace1ace-0000-0000-0000-0000debt0001"
INTDIR3="$IWE_ROOT/.iwe-runtime/commit-intents/close-keep"
mkdir -p "$INTDIR3"
python3 - "$INTDIR3/myrepo-$REPOKEY.jsonl" "$UUIDK" "$PC" <<'PY'
import json, sys, datetime
path, uuid, parent = sys.argv[1:4]
rec = {"v": 1, "uuid": uuid, "repo": "myrepo", "expected_parent": parent,
       "message_sha256": "0" * 64, "paths": ["nope.txt"],
       "source_checkout": None, "branch": None,
       "created_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
       "status": "prepared"}
open(path, "w").write(json.dumps(rec) + "\n")
PY
out=$(IWE_ROOT="$IWE_ROOT" REPO="$REPO" bash -c '
  _resolve_repo_checkout() { printf "%s\n" "$REPO"; }
  '"$FINISH_FUNCS"'
  _finish_session_commit_intents "$1" "$2"' _ "$SEM3" "close-keep" 2>&1); rc=$?
# C2: unresolved intent at close -> NONZERO (close must refuse; the harness
# stands at the finish-pass), dir kept, WARN names the retry.
{ [ $rc -ne 0 ] && [ -d "$INTDIR3" ] \
  && printf '%s' "$out" | grep -q "prepared-intent-left: myrepo $UUIDK"; } \
  && ok "close with unresolved intent: nonzero, dir kept, debt WARN" \
  || bad "close keep-debt (rc=$rc out=$out dir=$([ -d "$INTDIR3" ] && echo yes || echo no))"
# Retry contract: fix the condition (a matching commit appears), the same
# finish-pass promotes (claim present) and cleanup removes the directory.
echo fixed > "$REPO/nope.txt"
git -C "$REPO" add nope.txt
git -C "$REPO" commit -qm "close-keep fixed

Iwe-Intent: $UUIDK"
KSHA=$(git -C "$REPO" rev-parse HEAD)
KMSG=$(git -C "$REPO" cat-file commit "$KSHA" | python3 -c 'import sys,hashlib; raw=sys.stdin.buffer.read(); print(hashlib.sha256(raw.split(b"\n\n",1)[1]).hexdigest())')
python3 - "$INTDIR3/myrepo-$REPOKEY.jsonl" <<PYEOF
import json
path = "$INTDIR3/myrepo-$REPOKEY.jsonl"
rec = {"uuid": "$UUIDK", "status": "prepared", "repo": "myrepo",
       "expected_parent": "$PC", "message_sha256": "$KMSG",
       "paths": ["nope.txt"], "source_checkout": "$REPO", "branch": "main"}
open(path, "a").write(json.dumps(rec) + "\n")
PYEOF
out=$(IWE_ROOT="$IWE_ROOT" REPO="$REPO" bash -c '
  _resolve_repo_checkout() { printf "%s\n" "$REPO"; }
  '"$FINISH_FUNCS"'
  _finish_session_commit_intents "$1" "$2"' _ "$SEM3" "close-keep" 2>&1); rc=$?
{ [ $rc -eq 0 ] && grep -qx "commit: myrepo $KSHA $REPO main" "$SEM3" \
  && [ ! -d "$INTDIR3" ]; } \
  && ok "retry close: promote-pass completes, claim written, dir removed" \
  || bad "close retry (rc=$rc out=$out sem=$(grep 'commit:' "$SEM3"))"

echo "== B2: completed-stub never erases sha; restore-claim; concurrency =="

# B2-1: committed record (sha carrier) + completed; claim deleted -> promote
# restores the claim on the SAME sha (resolved via the recorded sha, not the
# trailer grep), then a stable no-op.
UUIDB1="b1b1b1b1-0000-0000-0000-0000000000b1"
git -C "$REPO" checkout -q main
PB1=$(git -C "$REPO" rev-parse HEAD)
echo b1 > "$REPO/b1.txt"
git -C "$REPO" add b1.txt
git -C "$REPO" commit -qm "b1 carrier

Iwe-Intent: $UUIDB1"
B1SHA=$(git -C "$REPO" rev-parse HEAD)
B1MSG=$(git -C "$REPO" cat-file commit "$B1SHA" | python3 -c 'import sys,hashlib; raw=sys.stdin.buffer.read(); print(hashlib.sha256(raw.split(b"\n\n",1)[1]).hexdigest())')
python3 - "$IFILE" "$UUIDB1" "$PB1" "$B1SHA" "$B1MSG" <<'PY'
import json, sys, datetime
path, uuid, parent, sha, msgsha = sys.argv[1:6]
now = datetime.datetime.now(datetime.timezone.utc).isoformat()
recs = [
    {"v": 1, "uuid": uuid, "repo": "myrepo", "expected_parent": parent,
     "message_sha256": msgsha, "paths": ["b1.txt"],
     "source_checkout": None, "branch": None, "created_at": now,
     "status": "prepared"},
    {"uuid": uuid, "status": "committed", "sha": sha,
     "message_sha256_actual": msgsha, "created_at": now},
    {"uuid": uuid, "status": "completed", "created_at": now},
]
# A torn tail (robustness pin) leaves no trailing newline: appending directly
# would glue the first record onto it and the reader would skip the pair.
import os
prefix = ""
if os.path.exists(path) and os.path.getsize(path) > 0:
    with open(path, "rb") as check:
        check.seek(-1, os.SEEK_END)
        if check.read(1) != b"\n":
            prefix = "\n"
with open(path, "a") as stream:
    stream.write(prefix)
    for rec in recs:
        stream.write(json.dumps(rec) + "\n")
PY
# The completion sweep in the HANDLER must not have erased the sha carrier;
# here the file was written directly with all three records. Delete the claim
# (none was written yet) and re-add one to simulate a crash after claim-write:
echo "commit: myrepo $B1SHA - -" >> "$SEM"
sed -i '' "/^commit: myrepo $B1SHA - \-$/d" "$SEM"
echo "DEBUG IFILE=$IFILE"; tail -4 "$IFILE"; ls -la "$(dirname "$IFILE")"
out=$(note --promote-intent "$UUIDB1" --repo myrepo); rc=$?
out2=$(note --promote-intent "$UUIDB1" --repo myrepo); rc2=$?
n=$(grep -c "^commit: myrepo $B1SHA" "$SEM")
{ [ $rc -eq 0 ] && [ $rc2 -eq 0 ] \
  && printf '%s' "$out" | grep -q "PROMOTED $B1SHA" \
  && [ "$n" -eq 1 ]; } \
  && ok "B2-1: claim restored on recorded sha, then stable no-op" \
  || bad "B2-1 (rc=$rc rc2=$rc2 n=$n out=[$out] debt=$(grep -a INTENT-DEBT <<<"$out" | head -1))"

# B2-2: completed-stub ONLY (no prepared/committed record, no claim) -- the
# sha is unrecoverable: visible debt (intent-not-found), NO PROMOTED, nonzero.
UUIDB2="b2b2b2b2-0000-0000-0000-0000000000b2"
python3 - "$IFILE" "$UUIDB2" <<'PY'
import json, sys
open(sys.argv[1], "a").write(json.dumps({"uuid": sys.argv[2], "status": "completed"}) + "\n")
PY
before=$(grep -c '^commit:' "$SEM")
out=$(note --promote-intent "$UUIDB2" --repo myrepo); rc=$?
after=$(grep -c '^commit:' "$SEM")
{ [ $rc -ne 0 ] && ! printf '%s' "$out" | grep -q "PROMOTED" \
  && printf '%s' "$out" | grep -q "intent-completed-without-sha" \
  && [ "$before" = "$after" ]; } \
  && ok "B2-2: completed-stub alone -> distinct class, no PROMOTED, nonzero" \
  || bad "B2-2 (rc=$rc out=$out $before->$after)"
# The stub record must remain in jsonl (guard never erases debt) and every
# sweep keeps completed-without-sha records.
grep -q '"status": "completed"' "$IFILE" \
  && ok "B2-2b: stub record kept in jsonl until the debt is fixed separately" \
  || bad "B2-2b: stub record vanished"

# B2-3: two concurrent promotes of one uuid -> exactly one claim line, both
# runs exit compatibly (second is a no-op PROMOTED).
UUIDB3="b3b3b3b3-0000-0000-0000-0000000000b3"
PB3=$(git -C "$REPO" rev-parse HEAD)
echo b3 > "$REPO/b3.txt"
git -C "$REPO" add b3.txt
git -C "$REPO" commit -qm "b3 race

Iwe-Intent: $UUIDB3"
B3SHA=$(git -C "$REPO" rev-parse HEAD)
B3MSG=$(git -C "$REPO" cat-file commit "$B3SHA" | python3 -c 'import sys,hashlib; raw=sys.stdin.buffer.read(); print(hashlib.sha256(raw.split(b"\n\n",1)[1]).hexdigest())')
python3 - "$IFILE" "$UUIDB3" "$PB3" "$B3MSG" "$REPO" <<'PY'
import json, sys, datetime
path, uuid, parent, msgsha, checkout = sys.argv[1:6]
rec = {"v": 1, "uuid": uuid, "repo": "myrepo", "expected_parent": parent,
       "message_sha256": msgsha, "paths": ["b3.txt"],
       "source_checkout": checkout, "branch": "main",
       "created_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
       "status": "prepared"}
open(path, "a").write(json.dumps(rec) + "\n")
PY
PROMOTE_FUNCS=$(python3 - "$SG" <<'PY'
import re, subprocess, sys
src = open(sys.argv[1]).read()
start = re.search(r"(?m)^_promote_commit_intent\(\) \{", src)
for end in re.finditer(r"(?m)^\}[ \t]*(?:#.*)?$", src[start.start():]):
    cand = src[start.start():start.start() + end.end()] + "\n"
    if subprocess.run(["/bin/bash", "-n"], input=cand, text=True,
                      capture_output=True).returncode == 0:
        print(cand)
        break
PY
)
B3F1="$T/b3-run1.log"; B3F2="$T/b3-run2.log"
( IWE_ROOT="$IWE_ROOT" REPO="$REPO" bash -c '
  '"$PROMOTE_FUNCS"'
  _promote_commit_intent "$1" "$2" myrepo "$3" "$4" "$5"' _ "$SEM" "$REPO" "$UUIDB3" "$SID" "$IWE_ROOT/.iwe-runtime/commit-intents" > "$B3F1" 2>&1 ) &
P1=$!
( IWE_ROOT="$IWE_ROOT" REPO="$REPO" bash -c '
  '"$PROMOTE_FUNCS"'
  _promote_commit_intent "$1" "$2" myrepo "$3" "$4" "$5"' _ "$SEM" "$REPO" "$UUIDB3" "$SID" "$IWE_ROOT/.iwe-runtime/commit-intents" > "$B3F2" 2>&1 ) &
P2=$!
wait "$P1" 2>/dev/null; r1=$?
wait "$P2" 2>/dev/null; r2=$?
out1=$(cat "$B3F1" 2>/dev/null)
out2=$(cat "$B3F2" 2>/dev/null)
n=$(grep -c "^commit: myrepo $B3SHA" "$SEM")
{ [ "$n" -eq 1 ] \
  && printf '%s' "$out1" | grep -q "PROMOTED $B3SHA" \
  && printf '%s' "$out2" | grep -q "PROMOTED $B3SHA" \
  && [ $r1 -eq 0 -o $r1 -eq 2 ] && [ $r2 -eq 0 -o $r2 -eq 2 ]; } \
  && ok "B2-3: concurrent promotes -> exactly one claim, both PROMOTED" \
  || bad "B2-3 (r1=$r1 r2=$r2 n=$n out1=$out1 out2=$out2)"


echo "== P4: recorded sha wins over duplicate trailer carriers =="
UUID9="d9d9d9d9-0000-0000-0000-000000000009"
P9=$(git -C "$REPO" rev-parse HEAD)
echo nine > "$REPO/nine.txt"
git -C "$REPO" add nine.txt
git -C "$REPO" commit -qm "original carrier

Iwe-Intent: $UUID9"
ORIG9=$(git -C "$REPO" rev-parse HEAD)
MSG9=$(git -C "$REPO" cat-file commit "$ORIG9" | python3 -c 'import sys,hashlib; raw=sys.stdin.buffer.read(); print(hashlib.sha256(raw.split(b"\n\n",1)[1]).hexdigest())')
TREE9=$(git -C "$REPO" rev-parse "$ORIG9^{tree}")
# A duplicate object carrying the SAME trailer (what a cherry-pick or re-commit
# produces) -- ambiguity for the grep fallback, irrelevant for sha resolution.
DUP9=$(git -C "$REPO" commit-tree "$P9^{tree}" -p "$P9" -m "original carrier

Iwe-Intent: $UUID9")
git -C "$REPO" update-ref refs/heads/dup "$DUP9"
python3 - "$IFILE" "$UUID9" "$P9" "$ORIG9" "$TREE9" "$MSG9" <<'PY'
import json, sys, datetime
path, uuid, parent, sha, tree, msgsha = sys.argv[1:7]
rec = {"v": 1, "uuid": uuid, "repo": "myrepo", "expected_parent": parent,
       "message_sha256": msgsha, "tree": tree, "paths": ["nine.txt"],
       "sha": sha, "status": "committed",
       "created_at": datetime.datetime.now(datetime.timezone.utc).isoformat()}
open(path, "a").write(json.dumps(rec) + "\n")
PY
out=$(note --promote-intent "$UUID9" --repo myrepo); rc=$?
{ [ $rc -eq 0 ] && printf '%s' "$out" | grep -q "PROMOTED $ORIG9" \
  && ! printf '%s' "$out" | grep -q "intent-ambiguous" \
  && grep -qx "commit: myrepo $ORIG9 - -" "$SEM"; } \
  && ok "P4: recorded sha resolves past duplicate carriers (original sha)" \
  || bad "P4 (rc=$rc out=$out)"
git -C "$REPO" update-ref -d refs/heads/dup

echo "== P3: both close terminal entries run the finish-pass before rename =="
python3 - "$SG" <<'PY'
import re, sys
lines = open(sys.argv[1]).read().split("\n")
def first(pattern, start=0):
    for i in range(start, len(lines)):
        if re.search(pattern, lines[i]):
            return i
    return None
fn = first(r"^_close_delivery_and_transition\(\)")
# The function body contains heredocs whose Python dicts close with a
# column-0 "}" -- so use the first rename after the function start as the
# boundary instead of parsing the function end.
fins = [i for i, l in enumerate(lines)
        if re.search(r'_finish_session_commit_intents "\$SEM_FILE"', l)]
rens = [i for i, l in enumerate(lines)
        if re.search(r'_rename_open_to_closed "\$SEM_FILE"', l)]
preps = [i for i, l in enumerate(lines)
         if re.search(r'_prepare_close_receipt "\$SEM_FILE"', l)]
r0 = min((i for i in rens if i > fn), default=None)
fin1 = [i for i in fins if fn <= i < r0]
site1_ok = bool(fin1) and r0 is not None and min(fin1) < r0
# Entry 2 (non-isolated): a finish call AFTER the delivery function's first
# rename, preceding a _prepare_close_receipt + rename pair that follows it.
site2_ok = False
for f2 in [i for i in fins if i > r0]:
    later_preps = [i for i in preps if i > f2]
    later_rens = [i for i in rens if i > f2]
    if later_preps and later_rens and f2 < min(later_preps) < min(later_rens):
        site2_ok = True
        break
sys.exit(0 if site1_ok and site2_ok else 1)
PY
[ $? -eq 0 ] && ok "P3: finish-pass precedes the first rename on both terminal entries" \
  || bad "P3: close entry ordering broken"

echo "== P1b: promote-with-debt counts as processed for close/finish =="
UUIDD="deb1deb1-0000-0000-0000-00000000deb1"
PD=$(git -C "$REPO" rev-parse HEAD)
echo deb > "$REPO/deb.txt"
git -C "$REPO" add deb.txt
git -C "$REPO" commit -qm "debt finish case

Iwe-Intent: $UUIDD"
DSHA2=$(git -C "$REPO" rev-parse HEAD)
DMSG=$(git -C "$REPO" cat-file commit "$DSHA2" | python3 -c 'import sys,hashlib; raw=sys.stdin.buffer.read(); print(hashlib.sha256(raw.split(b"\n\n",1)[1]).hexdigest())')
SEMD="$IWE_ROOT/.iwe-runtime/sessions/${AGENT}-debt-fin.open"
cat > "$SEMD" <<EOF
agent: $AGENT
session_id: debt-fin
wp: 999
slug: 2026-10-31-debt
task: smoke
opened_at: 2026-10-31T00:00:00Z
EOF
DINTDIR="$IWE_ROOT/.iwe-runtime/commit-intents/debt-fin"
mkdir -p "$DINTDIR"
python3 - "$DINTDIR/myrepo-$REPOKEY.jsonl" "$UUIDD" "$PD" "$DSHA2" "$DMSG" <<'PY'
import json, sys
path, uuid, parent, sha, msgsha = sys.argv[1:6]
rec = {"v": 1, "uuid": uuid, "repo": "myrepo", "expected_parent": parent,
       "message_sha256": msgsha, "tree": "2" * 40, "paths": ["deb.txt"],
       "sha": sha, "status": "committed"}
open(path, "w").write(json.dumps(rec) + "\n")
PY
out=$(IWE_ROOT="$IWE_ROOT" REPO="$REPO" bash -c '
  _resolve_repo_checkout() { printf "%s\n" "$REPO"; }
  '"$FINISH_FUNCS"'
  _finish_session_commit_intents "$1" "$2"' _ "$SEMD" "debt-fin" 2>&1); rc=$?
{ [ $rc -eq 0 ] \
  && printf '%s' "$out" | grep -q "INTENT-DEBT intent-content-mismatch" \
  && grep -qx "commit: myrepo $DSHA2 - -" "$SEMD" \
  && [ ! -d "$DINTDIR" ]; } \
  && ok "P1b: exit-2 debt counts as processed -- cleanup proceeds" \
  || bad "P1b finish-with-debt (rc=$rc out=$out dir=$([ -d "$DINTDIR" ] && echo kept || echo removed))"


echo
if [ "$FAIL" -eq 0 ]; then
  echo "PASS: note-commit promote-intent smoke ($PASS checks)"
  exit 0
else
  echo "FAIL: note-commit promote-intent smoke ($FAIL failed, $PASS passed)"
  exit 1
fi
