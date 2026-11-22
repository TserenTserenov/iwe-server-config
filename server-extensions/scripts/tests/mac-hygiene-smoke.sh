#!/usr/bin/env bash
# Smoke test for scripts/mac-hygiene.sh (WP-545 F39).
# Real directories, real guarded-rm, stub notifier: checks observable results only.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${HERE}/../mac-hygiene.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/mac-hygiene-smoke.XXXXXX")"
FAILS=0

check() { # check <description> <command...>
  local desc="$1"; shift
  if "$@"; then echo "ok   ${desc}"; else echo "FAIL ${desc}"; FAILS=$((FAILS + 1)); fi
}

ROOT="${WORK}/sessions"; STATE="${WORK}/state"; LOG="${WORK}/notify.log"
mkdir -p "${ROOT}/old-plain" "${ROOT}/old-with-git/repo" "${ROOT}/old-running" "${ROOT}/fresh"
echo data > "${ROOT}/old-plain/f"; echo data > "${ROOT}/old-with-git/repo/.git"
echo data > "${ROOT}/old-running/f"; echo data > "${ROOT}/fresh/f"
# backdate everything except "fresh" by 10 days
find "${ROOT}/old-plain" "${ROOT}/old-with-git" "${ROOT}/old-running" -exec touch -t 202611010000 {} +

cat > "${WORK}/notify-stub.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${LOG}"
EOF
chmod +x "${WORK}/notify-stub.sh"

export IWE_HYGIENE_TMP_ROOT="${ROOT}" IWE_HYGIENE_STATE_DIR="${STATE}" IWE_HYGIENE_NOTIFY="${WORK}/notify-stub.sh"
export IWE_HYGIENE_SWAP_MB=100 IWE_HYGIENE_DISK_FREE_GB=100 IWE_HYGIENE_FORCE_HOUR=12

# a live process that mentions the id of "old-running" in its command line
bash -c 'sleep 30; :' old-running &
SLEEP_PID=$!
sleep 0.5

bash "${SCRIPT}" sweep --dry-run >/dev/null
check "dry-run deletes nothing" test -d "${ROOT}/old-plain"

bash "${SCRIPT}" sweep >/dev/null
check "old plain dir removed" test ! -e "${ROOT}/old-plain"
check "old dir with a git checkout kept" test -d "${ROOT}/old-with-git"
check "old dir with a running process kept" test -d "${ROOT}/old-running"
check "fresh dir kept" test -d "${ROOT}/fresh"
kill "${SLEEP_PID}" 2>/dev/null

# thresholds: below limits -> silence
bash "${SCRIPT}" check >/dev/null
check "no alert below thresholds" test ! -s "${LOG}"

# swap above limit -> one alert, second run suppressed by cooldown
IWE_HYGIENE_SWAP_MB=5000 bash "${SCRIPT}" check >/dev/null
check "swap alert sent once" test "$(grep -c 'подкачка' "${LOG}")" -eq 1
IWE_HYGIENE_SWAP_MB=5000 bash "${SCRIPT}" check >/dev/null
check "cooldown suppresses repeat" test "$(grep -c 'подкачка' "${LOG}")" -eq 1

# disk below limit -> alert; quiet hour -> none
IWE_HYGIENE_DISK_FREE_GB=5 bash "${SCRIPT}" check >/dev/null
check "disk alert sent" grep -q 'свободно 5 ГБ' "${LOG}"
rm -f "${STATE}"/last-notify-*; : > "${LOG}"
IWE_HYGIENE_DISK_FREE_GB=5 IWE_HYGIENE_FORCE_HOUR=3 bash "${SCRIPT}" check >/dev/null
check "no alert in quiet hours" test ! -s "${LOG}"

rm -rf "${WORK}" 2>/dev/null
if [ "${FAILS}" -eq 0 ]; then echo "mac-hygiene smoke: all passed"; else echo "mac-hygiene smoke: ${FAILS} failed"; exit 1; fi
