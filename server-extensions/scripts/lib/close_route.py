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
     an agent's ``publish-only`` declaration gets no route of its own
     (pilot decision 1B, 16.11): it is classified like any other session;
  3. no open mark (semaphore) for the conversation -> ``nothing``;
     several marks -> refuse ``ambiguous``; selectors that miss an open
     mark (``semaphores`` < 0) -> refuse ``unresolved``;
  4. the mark is open and "no changes" is proven -> ``release-empty``;
     proven only in an isolated copy (pilot decision 12.11);
  5. otherwise                                    -> ``close-changes``, plus the
     peer step when the session left peer-session traces.

Stage 2 (pilot decisions 15.11) adds ``execution`` -- what ``close`` does when
the fact-based choice is switched on (``IWE_CLOSE_ROUTE_ENFORCE``):
  ``runner``     -- every close-changes, peer session or not: the quick-close
                    runner with R23, phase/WP archiving and reflection (plus the
                    peer step when there are traces). The pilot chose one close
                    path over a short peer close: that one skipped archiving;
  ``release``    -- release-empty: drop the mark without the runner;
  ``resume``     -- an unfinished close keeps the decision frozen at its first attempt;
  ``legacy``     -- refusals and ``nothing``: close keeps its declared behaviour.

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

EXEC_RUNNER = "runner"
EXEC_RELEASE = "release"
EXEC_RESUME = "resume"
EXEC_LEGACY = "legacy"

EXECUTION_TEXT = {
    EXEC_RUNNER: "обычное закрытие через раннер quick-close с итоговой проверкой R23",
    EXEC_RELEASE: "снять отметку без раннера: изменений нет",
    EXEC_RESUME: "продолжить закрытие тем путём, который выбран при первой попытке",
    EXEC_LEGACY: "прежний порядок по объявлению при открытии",
}

MACHINE_PATHS = {"pipeline", "machine-publish-only"}

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
        "execution": EXEC_LEGACY,
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
        out["execution"] = EXEC_RESUME
        reasons.append(f"незавершённое закрытие в состоянии {resume_state}")
        # A resumed close keeps the kind chosen on the first attempt; no mismatch check.
        return out

    # The day-close protocol opens and closes its own mark with --housekeeping
    # (refused above), never with `--wp day-close`. That label is only "no WP
    # assigned" (the peer skill and hand-opened sessions use it), so it is
    # classified like any other session (WP-561 F61, 17.11: it was a bypass).
    if declared in MACHINE_PATHS:
        out["refuse"] = "out-of-scope"
        reasons.append(f"машинный запуск (close_path={declared}) — свой порядок, вне схемы")
        out["mismatch"] = _expected_route(declared) != "out-of-scope"
        return out

    # A peer session with a journal is not released as empty: the "no changes" proof
    # looks at the isolated copy and the claims, not at an unclaimed journal in the
    # sessions repository, which would then stay unpublished (Fable review 15.11).
    if facts.get("isolated") and facts.get("no_changes") == "proven" and facts.get("peer_evidence") != "yes":
        out["route"] = RELEASE_EMPTY
        out["pilot_phrase"] = PHRASE_RELEASE_EMPTY
        out["execution"] = EXEC_RELEASE
        reasons.append("отдельная копия чистая, HEAD не сдвигался, заявок сверх служебных нет")
    else:
        out["route"] = CLOSE_CHANGES
        if not facts.get("isolated"):
            reasons.append("общая копия: «без изменений» не доказывается (решение пилота 12.11)")
        elif facts.get("no_changes") == "proven":
            reasons.append("отдельная копия чистая, но есть журнал пир-сессии — он публикуется обычным закрытием")
        else:
            detail = facts.get("no_changes_reason") or facts.get("no_changes") or "не проверено"
            reasons.append(f"«без изменений» не доказано: {detail}")
        out["peer_step"] = facts.get("peer_evidence") == "yes"
        if out["peer_step"]:
            reasons.append("есть следы пир-сессии — журнал и отчёт публикуются вместе с работой")
        out["execution"] = EXEC_RUNNER

    expected = _expected_route(declared)
    out["mismatch"] = expected != out["route"] or (declared == "peer-session") != out["peer_step"]
    if out["mismatch"]:
        reasons.append(f"объявлено при открытии: {declared}; по фактам: {out['route']}"
                       + (" с пир-шагом" if out["peer_step"] else ""))
    return out


def render(outcome, enforced=False):
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
    execution = EXECUTION_TEXT[outcome["execution"]]
    if enforced:
        lines.append(f"Исполнение по фактам включено: {execution}.")
    else:
        lines.append(f"Исполнение по фактам выключено: команда close закрывает по объявлению "
                     f"(по фактам было бы: {execution}).")
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
    parser.add_argument("--enforced", choices=("0", "1"), default="0")
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
    outcome["enforced"] = args.enforced == "1"
    if args.format == "text":
        print(render(outcome, enforced=outcome["enforced"]))
    else:
        print(json.dumps(outcome, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
