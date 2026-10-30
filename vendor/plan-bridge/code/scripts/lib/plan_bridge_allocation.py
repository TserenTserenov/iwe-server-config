"""Versioned v2 admission over the DR-03 resource projection, without WAL writes.

The trusted host factory supplies rules_version, a whole-plan budget callback,
and PlanView.ordered_accepted from first publications at the pinned base. The
generic origin reader does not establish that order. No order is inferred from
dict insertion, filenames, timestamps, or the per-element parent alone.

All six resource events require payload.resource_id and generation_claimed.
allocation_confirmed claims the NEXT generation; the other five claim the
current one. The semantic request, including its parent, is never rewritten.
"""

from collections.abc import Callable
from copy import deepcopy

import plan_allocation as allocation
from plan_bridge_decisions import BridgeError, PlanView
from plan_event_intake import validate_request

ALLOCATION_VALIDATOR_VERSION = "plan-allocation/2"
RESOURCE_EVENTS = frozenset(
    {
        "allocation_confirmed",
        "action_started",
        "change_rejected",
        "allocation_expired",
        "outcome_confirmed",
        "cancellation_compensated",
    }
)
_RESULT_STATES = {
    "allocation_confirmed": "confirmed",
    "action_started": "started",
    "change_rejected": "cancelled_before_start",
    "allocation_expired": "expired",
    "outcome_confirmed": "completed",
    "cancellation_compensated": "compensated",
}
_REQUIRED_STATES = {
    "action_started": "confirmed",
    "change_rejected": "confirmed",
    "allocation_expired": "confirmed",
    "outcome_confirmed": "started",
    "cancellation_compensated": "started",
}
_HOLDER_EVENTS = frozenset(
    {"action_started", "outcome_confirmed", "cancellation_compensated"}
)
_RESOURCE_FIELDS = frozenset({"resource_id", "resource_type", "generation_claimed"})
_EMPTY = allocation.AllocationState(0, None, None)


def _text(value):
    return isinstance(value, str) and bool(value.strip())


def _touches_resource(request):
    payload = request["payload"]
    return (
        request["event_type"] in RESOURCE_EVENTS
        or bool(_RESOURCE_FIELDS.intersection(payload))
        or (
            "claims_exclusive_resource" in payload
            and payload["claims_exclusive_resource"] is not False
        )
    )


def _resource_id(request):
    value = request["payload"].get("resource_id")
    return value if _text(value) else None


def _admissible(request, state):
    event_type, payload = request["event_type"], request["payload"]
    if event_type not in RESOURCE_EVENTS or _resource_id(request) is None:
        return False
    if (
        "claims_exclusive_resource" in payload
        and type(payload["claims_exclusive_resource"]) is not bool
    ):
        return False
    claimed = payload.get("generation_claimed")
    if type(claimed) is not int or claimed < 1:
        return False
    if (
        "resource_type" in payload
        and payload["resource_type"] != allocation.RESOURCE_TYPE_PLAN_HOUR
    ):
        return False
    if event_type == "allocation_confirmed":
        return (
            allocation.resolve_resource_type(request)
            == allocation.RESOURCE_TYPE_PLAN_HOUR
            and state.state not in {"confirmed", "started"}
            and claimed == state.generation + 1
        )
    return (
        claimed == state.generation
        and state.state == _REQUIRED_STATES[event_type]
        and (event_type not in _HOLDER_EVENTS or request["producer_id"] == state.holder)
    )


def _expected_effect(request, state):
    """Audit each declared transition; project_all remains the returned projection."""
    confirmed = request["event_type"] == "allocation_confirmed"
    return allocation.AllocationState(
        state.generation + 1 if confirmed else state.generation,
        _RESULT_STATES[request["event_type"]],
        request["producer_id"] if confirmed else state.holder,
    )


def _project_checked_history(view: PlanView):
    # Revalidate supplied mappings/order as callers can mutate PlanView after init.
    view = view.copy()
    if view.ordered_accepted is None:
        raise BridgeError(
            "RESOURCE_ORDER_UNAVAILABLE",
            "trusted pinned-base publication order is required",
        )
    records, expected = [], {}
    for event_id in view.ordered_accepted:
        request = view.accepted[event_id]
        records.append({"envelope": request})
        if not _touches_resource(request):
            continue
        resource = _resource_id(request)
        state = expected.get(resource, _EMPTY)
        if not _admissible(request, state):
            raise BridgeError(
                "INVALID_ALLOCATION_HISTORY",
                f"accepted resource transition {event_id!r} violates DR-03",
            )
        expected[resource] = _expected_effect(request, state)
    if allocation.scan_invariant_violations(records):
        raise BridgeError(
            "INVALID_ALLOCATION_HISTORY", "DR-03 observer found an invariant violation"
        )
    projected = allocation.project_all(records)
    if projected != expected:
        raise BridgeError(
            "ALLOCATION_PROJECTION_MISMATCH",
            "DR-03 projection differs from validated transition effects",
        )
    return projected


class AllocationPlanValidator:
    """Compose actual DR-03 semantics with an explicitly installed plan budget.

    The callback receives (candidate, pre-transition PlanView), as in the kernel
    validator protocol, and must return bool. Test fixtures may supply a test
    budget; production has no fallback that grants capacity. This class neither
    installs a live identity boundary nor chooses the numeric production budget.
    """

    version = ALLOCATION_VALIDATOR_VERSION

    def __init__(
        self,
        *,
        rules_version: str,
        whole_plan_budget: Callable[[dict, PlanView], bool] | None = None,
    ):
        if not _text(rules_version):
            raise BridgeError(
                "VALIDATOR_VERSION_MISMATCH",
                "explicit trusted rules_version is required",
            )
        if whole_plan_budget is None or not callable(whole_plan_budget):
            raise BridgeError(
                "BUDGET_VALIDATOR_UNAVAILABLE",
                "whole-plan budget callback is not installed",
            )
        self.rules_version = rules_version
        self._budget = whole_plan_budget

    def validate(self, request: dict, view: PlanView) -> bool:
        validate_request(request)
        if view.rules_version != self.rules_version:
            raise BridgeError(
                "VALIDATOR_VERSION_MISMATCH",
                "budget and resource rules do not match this plan",
            )
        if request["rules_version"] != self.rules_version:
            return False
        states = _project_checked_history(view)
        if _touches_resource(request) and not _admissible(
            request, states.get(_resource_id(request), _EMPTY)
        ):
            return False
        try:
            allowed = self._budget(deepcopy(request), view.copy())
        except Exception as exc:
            raise BridgeError(
                "BUDGET_VALIDATOR_FAILED", "whole-plan budget callback failed"
            ) from exc
        if type(allowed) is not bool:
            raise BridgeError(
                "INVALID_BUDGET_RESULT", "whole-plan budget callback must return bool"
            )
        return allowed
