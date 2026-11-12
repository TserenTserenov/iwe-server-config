#!/usr/bin/env python3
"""Close route classifier: facts about a conversation -> how it should close.

WP-561 F61 stage 1 (peer session 2026-11-12-11-wp561-single-close-command,
Claude+Kimi+Codex, Fable review). The close path used to be whatever the agent
declared at open (``--close-path``). Here the program picks it from observed
facts; the declaration is only compared with the choice. Stage 1 only reports:
``session-guard.sh close --explain`` prints the outcome, and a real ``close``
records it next to the declared path without changing behaviour.

The pilot's scheme (WP-484 F304) asks, in order; the first match decides:
  1. an unfinished close of this session exists  -> ``resume`` (same run; a
     machine run is resumed by its own command);
  2. a service protocol or a machine run         -> refuse ``out-of-scope``;
     a ``publish-only`` act is reported as ``service-act`` (its owner is
     decided before stage 2);
  3. no open mark (semaphore) for the conversation -> ``nothing``;
     several marks -> refuse ``ambiguous``; selectors that miss an open
     mark (``semaphores`` < 0) -> refuse ``unresolved``;
  4. the mark is open and "no changes" is proven -> ``release-empty``;
     proven only in an isolated copy (pilot decision 12.11);
  5. otherwise                                    -> ``close-changes``, plus the
     peer step when the session left peer-session traces.

The facts are gathered by session-guard.sh (read-only for ``--explain``);
this module never reads the disk, so every combination is unit-testable.
"""
import argparse
import json
import sys

RESUME = "resume"
NOTHING = "nothing"
RELEASE_EMPTY = "release-empty"
CLOSE_CHANGES = "close-changes"

MACHINE_PATHS = {"pipeline", "machine-publish-only"}
SERVICE_WPS = {"day-close"}

PHRASE_NOTHING = (
    "В этом разговоре отметки открытия нет, программе закрывать нечего — можно закрыть окно. "
    "Правки в обход учёта программа не видит."
)
PHRASE_RELEASE_EMPTY = (
    "В этом разговоре ничего не менялось, сохранять нечего — можно закрыть окно."
)
PHRASE_RESUME = (
    "Закрытие этой сессии уже начиналось — продолжаю тот же прогон. Если не поможет, "
    "назову причину и попрошу одно из двух слов: «отпусти отметку» или "
    "«подтверждаю доставку вручную»."
)


def _expected_route(declared):
    """What the declaration alone would have chosen, for the mismatch flag."""
    if declared in MACHINE_PATHS:
        return "out-of-scope"
    if declared == "publish-only":
        return "service-act"
    if declared == "no-code-changes":
        return RELEASE_EMPTY
    return CLOSE_CHANGES


def classify(facts):
    """Map gathered facts to an outcome dict (see module docstring).

    ``facts`` keys: semaphores (int), declared (str), wp (str), housekeeping
    (bool), resume_state (str, "none" when no close was started), isolated
    (bool), no_changes ("proven" | "refused" | "not-checked"),
    no_changes_reason (str), peer_evidence ("yes" | "no" | "unknown").
    """
    declared = facts.get("declared") or "unknown"
    out = {
        "route": None,
        "refuse": None,
        "owner_command": None,
        "peer_step": False,
        "declared": declared,
        "mismatch": False,
        "reasons": [],
        "pilot_phrase": "",
    }
    reasons = out["reasons"]

    semaphores = int(facts.get("semaphores", 0))
    if semaphores < 0:
        out["refuse"] = "unresolved"
        reasons.append("указанные --wp/--slug/--session-id не выбрали одну открытую сессию — см. сообщение выше")
        return out
    if semaphores > 1:
        out["refuse"] = "ambiguous"
        reasons.append(f"у разговора {semaphores} открытые отметки — уточни сессию (--session-id)")
        return out

    if facts.get("housekeeping"):
        out["refuse"] = "out-of-scope"
        reasons.append("служебное закрытие протокола (--housekeeping) — свой порядок, вне схемы")
        return out

    if semaphores == 0:
        out["route"] = NOTHING
        out["pilot_phrase"] = PHRASE_NOTHING
        reasons.append("отметки открытия нет")
        return out

    resume_state = facts.get("resume_state") or "none"
    if resume_state != "none":
        out["route"] = RESUME
        out["owner_command"] = "machine-close" if declared == "machine-publish-only" else "close"
        out["pilot_phrase"] = PHRASE_RESUME
        reasons.append(f"незавершённое закрытие в состоянии {resume_state}")
        # A resumed close keeps the kind chosen on the first attempt; no mismatch check.
        return out

    if declared in MACHINE_PATHS or facts.get("wp") in SERVICE_WPS:
        out["refuse"] = "out-of-scope"
        reasons.append(f"служебный протокол или машинный запуск (close_path={declared}, wp={facts.get('wp')}) — свой порядок, вне схемы")
        out["mismatch"] = _expected_route(declared) != "out-of-scope"
        return out

    if declared == "publish-only":
        out["refuse"] = "service-act"
        reasons.append("объявлен узкий акт публикации (publish-only); чей это акт — решается до этапа 2")
        return out

    if facts.get("isolated") and facts.get("no_changes") == "proven":
        out["route"] = RELEASE_EMPTY
        out["pilot_phrase"] = PHRASE_RELEASE_EMPTY
        reasons.append("отдельная копия чистая, HEAD не сдвигался, заявок сверх служебных нет")
    else:
        out["route"] = CLOSE_CHANGES
        if not facts.get("isolated"):
            reasons.append("общая копия: «без изменений» не доказывается (решение пилота 12.11)")
        else:
            detail = facts.get("no_changes_reason") or facts.get("no_changes") or "не проверено"
            reasons.append(f"«без изменений» не доказано: {detail}")
        out["peer_step"] = facts.get("peer_evidence") == "yes"
        if out["peer_step"]:
            reasons.append("есть следы пир-сессии — журнал и отчёт публикуются вместе с работой")

    expected = _expected_route(declared)
    out["mismatch"] = expected != out["route"] or (declared == "peer-session") != out["peer_step"]
    if out["mismatch"]:
        reasons.append(f"объявлено при открытии: {declared}; по фактам: {out['route']}"
                       + (" с пир-шагом" if out["peer_step"] else ""))
    return out


def render(outcome):
    """Human-readable explanation for `close --explain`."""
    lines = []
    if outcome["refuse"]:
        lines.append(f"Путь закрытия: отказ ({outcome['refuse']})")
    else:
        step = " + публикация журнала и отчёта пир-сессии" if outcome["peer_step"] else ""
        owner = f" (команда: {outcome['owner_command']})" if outcome["owner_command"] else ""
        lines.append(f"Путь закрытия: {outcome['route']}{step}{owner}")
    lines.append(f"Объявлено при открытии: {outcome['declared']}"
                 + (" — расходится с фактами" if outcome["mismatch"] else ""))
    lines.extend(f"- {reason}" for reason in outcome["reasons"])
    if outcome["pilot_phrase"]:
        lines.append(f"Сказать пилоту: {outcome['pilot_phrase']}")
    lines.append("Этап 1 (наблюдение): команда close пока закрывает по объявлению, не по этому выбору.")
    return "\n".join(lines)


def _parse(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--format", choices=("json", "text"), default="json")
    parser.add_argument("--semaphores", type=int, required=True)
    parser.add_argument("--declared", default="unknown")
    parser.add_argument("--wp", default="")
    parser.add_argument("--housekeeping", action="store_true")
    parser.add_argument("--resume-state", default="none")
    parser.add_argument("--isolated", choices=("0", "1"), default="0")
    parser.add_argument("--no-changes", choices=("proven", "refused", "not-checked"), default="not-checked")
    parser.add_argument("--no-changes-reason", default="")
    parser.add_argument("--peer-evidence", choices=("yes", "no", "unknown"), default="unknown")
    return parser.parse_args(argv)


def main(argv=None):
    args = _parse(sys.argv[1:] if argv is None else argv)
    outcome = classify({
        "semaphores": args.semaphores,
        "declared": args.declared,
        "wp": args.wp,
        "housekeeping": args.housekeeping,
        "resume_state": args.resume_state,
        "isolated": args.isolated == "1",
        "no_changes": args.no_changes,
        "no_changes_reason": args.no_changes_reason,
        "peer_evidence": args.peer_evidence,
    })
    if args.format == "text":
        print(render(outcome))
    else:
        print(json.dumps(outcome, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
