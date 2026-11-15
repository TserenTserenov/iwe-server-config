# Close route switch (WP-561 F61 stage 2), shared by the close hooks.
#
# On: IWE_CLOSE_ROUTE_ENFORCE=1, or the host flag file <iwe root>/.iwe-runtime/close-route-enforce.
# The environment cannot turn the file off; rollback on a host is removing the file.
# The same rule lives in scripts/session-guard.sh (_close_route_enforced) and in
# DS-my-strategy scripts/close_obligation.py (_close_route_enforced); the test
# scripts/tests/close-route-switch-agreement-smoke.sh keeps the copies in step.
# When the switch is on, a declared `close_path: peer-session` no longer exempts a
# conversation from the quick-close runner (pilot decision 15.11, one close path).
close_route_enforced() {  # <iwe root>
  [ "${IWE_CLOSE_ROUTE_ENFORCE:-}" = 1 ] || [ -f "$1/.iwe-runtime/close-route-enforce" ]
}
