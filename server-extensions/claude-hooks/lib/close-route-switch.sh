# Close route switch (WP-561 F61 stage 2), shared by the close hooks.
#
# On: IWE_CLOSE_ROUTE_ENFORCE=1, or the host flag file <iwe root>/.iwe-runtime/close-route-enforce.
# The flag file may carry one optional line `expires_at: <unix seconds, 1-12 digits>` (a timed window):
# after that moment the file counts as absent. An empty file, or one without a well-formed line,
# stays on indefinitely (the durable switch). The environment never turns the file off.
# The environment cannot turn the file off; rollback on a host is removing the file.
# The same rule lives in scripts/session-guard.sh (_close_route_enforced) and in
# DS-my-strategy scripts/close_obligation.py (_close_route_enforced); the test
# scripts/tests/close-route-switch-agreement-smoke.sh keeps the copies in step.
# When the switch is on, a declared `close_path: peer-session` no longer exempts a
# conversation from the quick-close runner (pilot decision 15.11, one close path).
close_route_flag_active() {  # <iwe root>
  local flag="$1/.iwe-runtime/close-route-enforce" until_ts
  [ -f "$flag" ] || return 1
  until_ts=$(sed -n 's/^expires_at:[[:space:]]*\([0-9]\{1,12\}\)[[:space:]]*$/\1/p' "$flag" 2>/dev/null | head -n 1)
  [ -z "$until_ts" ] || [ "$(date +%s)" -lt "$until_ts" ]
}

close_route_enforced() {  # <iwe root>
  [ "${IWE_CLOSE_ROUTE_ENFORCE:-}" = 1 ] || close_route_flag_active "$1"
}
