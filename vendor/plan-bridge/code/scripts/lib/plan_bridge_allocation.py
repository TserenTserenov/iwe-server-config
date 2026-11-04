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
from dataclasses import dataclass, field
from datetime import date, datetime
import json
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

import plan_allocation as allocation
from plan_bridge_decisions import BridgeError, PlanView
from plan_event_intake import validate_request

ALLOCATION_VALIDATOR_VERSION = "plan-allocation/3"
PERSONAL_TIME_RESOURCE_TYPE = "personal_time"
_RESOURCE_TYPES = frozenset(
    {allocation.RESOURCE_TYPE_PLAN_HOUR, PERSONAL_TIME_RESOURCE_TYPE}
)
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
_TIME_FIELDS = frozenset(
    {
        "plan_date",
        "reserved_minutes",
        "actual_minutes",
        "confirmed_minutes",
        "confirmation_ref",
    }
)
# A terminal carries either a real measurement or the pilot's answer to one
# daily summary (DR-06, 04.11): an estimate the pilot confirmed is not a
# measurement, so it never lands in actual_minutes.
_MEASURED = frozenset({"plan_date", "actual_minutes"})
_PILOT_CONFIRMED = frozenset({"plan_date", "confirmed_minutes", "confirmation_ref"})
_RESOURCE_FIELDS = (
    frozenset({"resource_id", "resource_type", "generation_claimed"}) | _TIME_FIELDS
)
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
    if "resource_type" in payload and (
        not isinstance(payload["resource_type"], str)
        or payload["resource_type"] not in _RESOURCE_TYPES
    ):
        return False
    if event_type == "allocation_confirmed":
        return (
            allocation.resolve_resource_type(request) in _RESOURCE_TYPES
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


def _plan_date(value):
    if not isinstance(value, str):
        return False
    try:
        return date.fromisoformat(value).isoformat() == value
    except ValueError:
        return False


def _minutes(value, *, minimum=0):
    return type(value) is int and minimum <= value <= 1440


def personal_time_resource_id(plan_date, stream_id, element_id):
    """One reservation identity per work and day; no caller-chosen aliases."""
    return "personal_time:" + json.dumps(
        [plan_date, stream_id, element_id], ensure_ascii=True, separators=(",", ":")
    )


@dataclass(frozen=True)
class _TimeReservation:
    day: str
    stream: str
    element: str
    minutes: int


@dataclass
class _TimeLedger:
    """Replay all generations: terminal transitions preserve actual expenditure."""

    reservations: dict = field(default_factory=dict)
    spent: dict = field(default_factory=dict)
    reserved: dict = field(default_factory=dict)

    def total(self, day):
        return self.spent.get(day, 0) + self.reserved.get(day, 0)

    def _confirm(self, request, resource, day):
        payload = request["payload"]
        if (
            payload.get("resource_type") != PERSONAL_TIME_RESOURCE_TYPE
            or _TIME_FIELDS.intersection(payload) != {"plan_date", "reserved_minutes"}
            or not _minutes(payload["reserved_minutes"], minimum=1)
            or resource in self.reservations
        ):
            return False
        self.reservations[resource] = _TimeReservation(
            day,
            request["stream_id"],
            request["element_id"],
            payload["reserved_minutes"],
        )
        self.reserved[day] = self.reserved.get(day, 0) + payload["reserved_minutes"]
        return True

    def apply(self, request, time_zone):
        event, payload = request["event_type"], request["payload"]
        if event not in RESOURCE_EVENTS:
            return not _touches_resource(request)
        day, resource = payload.get("plan_date"), _resource_id(request)
        if not _plan_date(day) or payload.get("resource_type") not in (
            None,
            PERSONAL_TIME_RESOURCE_TYPE,
        ):
            return False
        if resource != personal_time_resource_id(
            day, request["stream_id"], request["element_id"]
        ):
            return False
        if event == "allocation_confirmed":
            return self._confirm(request, resource, day)
        reservation = self.reservations.get(resource)
        if reservation is None or (
            day,
            request["stream_id"],
            request["element_id"],
        ) != (reservation.day, reservation.stream, reservation.element):
            return False
        terminal = event in {"outcome_confirmed", "cancellation_compensated"}
        spent = _terminal_minutes(payload) if terminal else 0
        if spent is None or (
            not terminal and _TIME_FIELDS.intersection(payload) != {"plan_date"}
        ):
            return False
        if event == "action_started":
            return _local_date(request, time_zone) == day
        # A reservation whose day has passed awaits the pilot's daily summary:
        # expiring it would erase participation instead of confirming it.
        if event == "allocation_expired":
            expired_on = _local_date(request, time_zone)
            if expired_on is None or expired_on > day:
                return False
        self.reserved[day] -= reservation.minutes
        del self.reservations[resource]
        if terminal:
            self.spent[day] = self.spent.get(day, 0) + spent
        return True


def _local_date(request, time_zone):
    try:
        occurred = datetime.fromisoformat(request["occurred_at"].replace("Z", "+00:00"))
        return occurred.astimezone(time_zone).date().isoformat()
    except (ValueError, OverflowError):
        return None


def _terminal_minutes(payload):
    """Minutes a terminal spends, or None when the payload is not one exact form."""
    fields = _TIME_FIELDS.intersection(payload)
    if fields == _MEASURED and _minutes(payload["actual_minutes"]):
        return payload["actual_minutes"]
    if (
        fields == _PILOT_CONFIRMED
        and _minutes(payload["confirmed_minutes"])
        and _text(payload["confirmation_ref"])
    ):
        return payload["confirmed_minutes"]
    return None


class PersonalTimeBudget:
    """Daily pilot minutes from pinned rules; no capacity is inferred from work.

    Run through AllocationPlanValidator, which first verifies DR-03 state,
    generation, holder and publication order. Reporting actual overrun and
    releasing reservations remain possible; only reservations and starts need
    available capacity. Historical legacy resource events require migration.
    """

    def __init__(self, time_zone, default_daily_minutes, daily_personal_minutes):
        try:
            self.time_zone = ZoneInfo(time_zone)
        except (TypeError, ValueError, ZoneInfoNotFoundError) as exc:
            raise BridgeError(
                "BUDGET_VALIDATOR_UNAVAILABLE", "invalid budget timezone"
            ) from exc
        if not _minutes(default_daily_minutes):
            raise BridgeError(
                "BUDGET_VALIDATOR_UNAVAILABLE", "invalid default daily minutes"
            )
        if not isinstance(daily_personal_minutes, dict) or not all(
            _plan_date(day) and _minutes(minutes)
            for day, minutes in daily_personal_minutes.items()
        ):
            raise BridgeError(
                "BUDGET_VALIDATOR_UNAVAILABLE", "invalid daily personal minutes"
            )
        self.default_daily_minutes = default_daily_minutes
        self.daily_minutes = dict(daily_personal_minutes)

    @classmethod
    def from_limits(cls, limits):
        return cls(
            limits["timezone"],
            limits["default_daily_minutes"],
            limits["daily_personal_minutes"],
        )

    def capacity(self, day):
        """Every day has a budget: the standing default unless a date overrides it."""
        return self.daily_minutes.get(day, self.default_daily_minutes)

    def check_history(self, view):
        """Stop before any request decisions if accepted time cannot be replayed."""
        if view.ordered_accepted is None:
            raise BridgeError(
                "RESOURCE_ORDER_UNAVAILABLE", "budget needs publication order"
            )
        ledger = _TimeLedger()
        for event_id in view.ordered_accepted:
            if not ledger.apply(view.accepted[event_id], self.time_zone):
                raise BridgeError(
                    "BUDGET_HISTORY_INCOMPATIBLE",
                    f"personal time history needs migration or repair: {event_id}",
                )
        return ledger

    def __call__(self, candidate, view):
        ledger = self.check_history(view)
        if not ledger.apply(candidate, self.time_zone):
            return False
        if candidate["event_type"] not in {"allocation_confirmed", "action_started"}:
            return True
        day = candidate["payload"]["plan_date"]
        return ledger.total(day) <= self.capacity(day)


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

    def check_history(self, view: PlanView):
        if view.rules_version != self.rules_version:
            raise BridgeError(
                "VALIDATOR_VERSION_MISMATCH",
                "budget and resource rules do not match this plan",
            )
        states = _project_checked_history(view)
        check = getattr(self._budget, "check_history", None)
        if check is not None:
            check(view.copy())
        return states

    def validate(self, request: dict, view: PlanView) -> bool:
        validate_request(request)
        states = self.check_history(view)
        if request["rules_version"] != self.rules_version:
            return False
        if _touches_resource(request) and not _admissible(
            request, states.get(_resource_id(request), _EMPTY)
        ):
            return False
        try:
            allowed = self._budget(deepcopy(request), view.copy())
        except BridgeError:
            raise
        except Exception as exc:
            raise BridgeError(
                "BUDGET_VALIDATOR_FAILED", "whole-plan budget callback failed"
            ) from exc
        if type(allowed) is not bool:
            raise BridgeError(
                "INVALID_BUDGET_RESULT", "whole-plan budget callback must return bool"
            )
        return allowed
