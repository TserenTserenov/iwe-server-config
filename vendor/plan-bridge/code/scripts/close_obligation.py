#!/usr/bin/env python3
"""close_obligation.py — автомат обязательства Quick Close (WP-484 Ф74б/в, 07.08.2026).

Консенсус пир-сессии 2026-08-07-08-quick-close-runner-bypass (Kimi+Codex, ход 7).
Рецидив 07.08: Quick Close выполнен полностью в обход process-runner.py, пилоту
подан отчёт «Закрытие сессии» без карточки RUN-*. Этот модуль — единственный
владелец состояния обязательства Close и ticket'ов запуска.

Модель:
  obligation: .iwe-runtime/close-obligation/<sha256(session_id)[:32]>.json
    {obligation_id, session_id, state: armed|running, mode: block|warn,
     slug, run_id, ticket_nonce, needs_user_action, created_at, updated_at,
     armed_under_peer_session: open|closed|null  (снимок cmd_arm, WP-484 п.22;
     отсутствует у поколений, взведённых до 16.09.2026 -- легаси)}
  ticket: .iwe-runtime/close-tickets/<nonce>.json
    {nonce, obligation_id|null, session_id, slug, tool_use_id, created_at}
  consumed ticket: .iwe-runtime/close-tickets/<nonce>.consumed-<run_id>
  expired ticket:  .iwe-runtime/close-tickets/<nonce>.expired
  voided ticket:   .iwe-runtime/close-tickets/<nonce>.voided-<reason>
    Every issued ticket ends in exactly one terminal file; the file is the
    truth, the ledger events (close_ticket_expired / close_ticket_voided) are
    best-effort mirrors.
  runner marker: /tmp/iwe-close-runner-started/<session_safe>.flag
    {obligation_id, run_id, nonce, at}
  close-intent record: .iwe-runtime/close-intent-records/<sha256(session_id)[:32]>.json
    {session_id, tail_present, raw_text, skip_reflection,
     technical_authorized, technical_scope, sentinel_ts, consumed}
    Отдельная сущность от obligation (WP-484, пир-сессия 2026-08-11-05 с Codex):
    неизменяемое доказательство текста после триггерной фразы закрытия, не
    состояние gate. Пишет close-gate-reminder.sh в момент фразы; читает
    session-reflection-render.sh по своему session_id (resolve через тот же
    harness-mapping, что session-reflection-append.sh уже использует).

Переходы:
  armed  — создаёт close-gate-reminder.sh (UserPromptSubmit, фраза закрытия пилота)
  running — ЭТОТ модуль по вызову из process-runner.py start --close-ticket,
            одной критической секцией под per-session lock после ревалидации
  очистка — ТОЛЬКО stop-check после полной машинной верификации completed-карточки
            (раннер сам obligation не удаляет — иначе судья и нарушитель совпадают)
  cancel/override — явные фразы пилота, аудируемые ledger-событием close_obligation

Граница гарантии (зафиксирована консенсусом): предотвращение НЕУМЫШЛЕННОГО обхода
+ детекция фабрикации (пара close_ticket_issued/consumed в ledger; consumed без
issued = подозрение на подделку). Криптографическая защита от умышленной
согласованной подделки ticket и ledger НЕ заявляется — кандидат на отдельный РП
(privilege-separated broker).

Команды:
  arm            --session-id SID --mode block|warn
  cancel         --session-id SID --action cancel-close|close-override|peer-session-close --actor A --reason R [--force]
                 (peer-session-close: no-op if state=="running" -- see cmd_cancel docstring-comment)
  record-intent  --session-id SID --raw-text TEXT   (текст после триггерной фразы, может быть пустым)
  read-intent    --session-id SID   (одноразово потребляет raw_text; флаги сессии сохраняются)
  issue-ticket   --session-id SID --slug SLUG --tool-use-id TUID   (stdout: nonce)
  consume-ticket --nonce N --slug SLUG --run-id RID [--process-id quick-close]
  stop-check     --session-id SID   (stdout: {"action": allow|block|warn, ...})
  cancel-status  --session-id SID   (read-only, stdout: {"cancelled": bool, "action"?, "actor"?, "reason"?, "ts"?})
"""

from __future__ import annotations

import argparse
import contextlib
import fcntl
import hashlib
import json
import os
import re
import secrets
import stat
import subprocess
import sys
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent))
from close_expect import expect_value_matches  # noqa: E402
from lib.ledger_path import read_ledger_document  # noqa: E402

# `IWE_ROOT`/`IWE_GOVERNANCE_REPO` follow the same explicit-env convention used
# across the rest of the repo (grep IWE_GOVERNANCE_REPO under ~/IWE/scripts/) --
# NOT derived from __file__. The old `DS_ROOT = Path(__file__).resolve().parent.parent`
# looked canonical but wasn't: this script is git-tracked and exists identically in
# every worktree, so __file__ resolves to whichever worktree happens to run it. That
# silently broke shared coordination state (semaphores/ledger/tickets) the moment the
# script ran from a non-base worktree (WP-520 Ф8, live incidents 2-6: commit-push.sh
# and this module both hardcoded a path that assumed a single working directory).
IWE_ROOT = Path(os.environ.get("IWE_ROOT", str(Path.home() / "IWE")))
GOVERNANCE_REPO = os.environ.get("IWE_GOVERNANCE_REPO", "DS-my-strategy")
DS_ROOT = IWE_ROOT / GOVERNANCE_REPO
RUNTIME_DIR = Path(os.environ.get("IWE_RUNTIME_DIR", str(IWE_ROOT / ".iwe-runtime")))
OBLIGATION_DIR = RUNTIME_DIR / "close-obligation"
TICKET_DIR = RUNTIME_DIR / "close-tickets"
INTENT_DIR = RUNTIME_DIR / "close-intent-records"
MARKER_DIR = Path("/tmp/iwe-close-runner-started")
# Sentinel close-intent: пишет close-gate-reminder.sh (UserPromptSubmit), читает
# close-runner-gate.sh (PreToolUse). cancel обязан убирать и его — иначе после
# cancel-close гейт продолжает блокировать git по осиротевшему sentinel
# (найдено живьём 14.08.2026, WP-520: «закрывай» внутри цитаты пилота).
INTENT_SENTINEL_DIR = Path("/tmp/iwe-close-intent")


def _resolve_cards_dir() -> Path:
    """RUN-*.md cards are written to the CWD the runner is actually invoked from,
    not to the canonical governance repo (WP-520 Ф8 third live incident: a card
    created inside a worktree was invisible to a stop-check run from DS_ROOT).
    Priority: explicit env override > git top-level of the current process's CWD >
    canonical DS_ROOT fallback (unchanged behavior when not inside a git worktree,
    e.g. cron/CI invocations).

    The CWD toplevel must be DS_ROOT itself or a worktree checked out FROM it --
    not just any git repo. A CWD that drifts to a repo higher up the tree (e.g.
    the IWE root itself, which is its own git repo) previously made this resolve
    to a path that never held any cards, and stop-check reported "card not found"
    for a card that existed at the canonical location (bug 2026-08-14)."""
    env = os.environ.get("IWE_PROCESS_CARDS_DIR")
    if env:
        return Path(env)
    try:
        result = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, cwd=os.getcwd(), timeout=5,
        )
        if result.returncode == 0 and result.stdout.strip():
            toplevel = Path(result.stdout.strip()).resolve()
            if toplevel == DS_ROOT.resolve() or _is_worktree_of(toplevel, DS_ROOT):
                return toplevel / "inbox" / "agent" / "tasks"
            # A real git repo, just not this one (or one of its worktrees) --
            # same silent fallback as "no git tree here": DS_ROOT is correct.
        # returncode != 0 here just means CWD isn't inside a git tree (e.g.
        # cron/CI) -- that's the expected, silent fallback case, not an error.
    except (OSError, subprocess.TimeoutExpired) as exc:
        # A real failure to run git (not "no git tree here") -- log it so a
        # future incident isn't left guessing whether the fallback fired
        # because of this or because of the expected non-git-tree case.
        print(f"[close_obligation] CARDS_DIR auto-detect failed ({exc!r}), "
              f"falling back to canonical DS_ROOT", file=sys.stderr)
    return DS_ROOT / "inbox" / "agent" / "tasks"


def _is_worktree_of(candidate: Path, base: Path) -> bool:
    """True if `candidate` is a git worktree checked out from `base`'s repo --
    its `.git` is a file pointing at `base/.git/worktrees/<name>`, not a real
    `.git` directory of its own."""
    git_file = candidate / ".git"
    if not git_file.is_file():
        return False
    try:
        first_line = git_file.read_text(encoding="utf-8").splitlines()[0]
    except (OSError, IndexError):
        return False
    if not first_line.startswith("gitdir:"):
        return False
    pointed = Path(first_line.split(":", 1)[1].strip())
    try:
        pointed = pointed.resolve()
    except OSError:
        return False
    return str(pointed).startswith(str((base / ".git" / "worktrees").resolve()) + os.sep)


CARDS_DIR = _resolve_cards_dir()
LEDGER_APPEND = DS_ROOT / "scripts" / "ledger-append.sh"
_LEDGER_DIR_OVERRIDE = os.environ.get("IWE_LEDGER_DIR")
LEDGER_DIR = Path(_LEDGER_DIR_OVERRIDE or str(DS_ROOT / "machine" / "ledger"))
LEDGER_ARCHIVE_DIR = os.environ.get("IWE_LEDGER_ARCHIVE_DIR")
if LEDGER_ARCHIVE_DIR is None and _LEDGER_DIR_OVERRIDE is None:
    LEDGER_ARCHIVE_DIR = str(DS_ROOT / "archive" / "ledger")
QUICK_CLOSE_YAML = Path(os.environ.get("IWE_QUICK_CLOSE_YAML", str(DS_ROOT / "scripts" / "processes" / "quick-close.yaml")))

TICKET_TTL_S = 600  # 10 минут — ticket одноразовый и короткоживущий

# WP-484 (bug-2026-09-06-reflection-append-misses-pre-stated-skip.md): значение,
# которое close-runner-gate.sh подставляет вместо --slug, когда его регэксп не
# смог извлечь литерал (например, --slug "$VAR" — shell-переменная в тексте
# команды). cmd_consume_ticket() пропускает строгую проверку slug только для
# этого sentinel — билет по-прежнему выпускается и по-прежнему проверяется по
# nonce (единственный реальный ключ), просто без сверки поля slug внутри него.
UNRESOLVED_SLUG_SENTINEL = "unresolved-slug"

_SAFE_NAME_RE = re.compile(r"^[A-Za-z0-9_.-]+$")
_NONCE_RE = re.compile(r"^[0-9a-f]{32}$")


class ObligationError(Exception):
    """Ожидаемая ошибка валидации/перехода — печатается без traceback."""


def now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _validated_name(value: str, label: str) -> str:
    """Строгая лексическая валидация имён, которые становятся путями/ключами."""
    if not isinstance(value, str) or not _SAFE_NAME_RE.fullmatch(value):
        raise ObligationError(f"недопустимый {label}: {value!r}")
    return value


def _validated_nonce(value: str) -> str:
    if not isinstance(value, str) or not _NONCE_RE.fullmatch(value):
        raise ObligationError(f"недопустимый nonce: {value!r}")
    return value


def _session_hash(session_id: str) -> str:
    return hashlib.sha256(session_id.encode("utf-8")).hexdigest()[:32]


def _session_safe(session_id: str) -> str:
    return _validated_name(
        "".join(c for c in session_id if c.isascii() and (c.isalnum() or c in "._-")),
        "session_id"
    )


def _obligation_path(session_id: str) -> Path:
    return OBLIGATION_DIR / f"{_session_hash(session_id)}.json"


def _check_path_safe(path: Path) -> None:
    """Запрет symlink, проверка owner и недостаточно строгих mode."""
    if path.is_symlink():
        raise ObligationError(f"отказ: {path} — symlink")
    if path.exists():
        st = path.stat()
        if st.st_uid != os.getuid():
            raise ObligationError(f"отказ: {path} принадлежит uid {st.st_uid}")
        if not path.is_file():
            raise ObligationError(f"отказ: {path} не обычный файл")
        mode = st.st_mode
        # Запрещаем только group/other write; чтение разрешено, executable — подозрителен
        if mode & 0o022:
            raise ObligationError(f"отказ: {path} mode разрешает запись группе/другим ({oct(mode & 0o777)})")


@contextlib.contextmanager
def _session_lock(session_id: str):
    """Единый per-session lock для ВСЕХ переходов obligation/ticket."""
    OBLIGATION_DIR.mkdir(parents=True, exist_ok=True)
    lock_path = OBLIGATION_DIR / f"{_session_hash(session_id)}.lock"
    fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


def _atomic_write_json(path: Path, obj: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.parent / f".{path.name}.{os.getpid()}.tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(obj, fh, ensure_ascii=False, indent=2)
        fh.flush()
        os.fsync(fh.fileno())
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def _load_json(path: Path) -> dict | None:
    try:
        _check_path_safe(path)
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except FileNotFoundError:
        return None
    except (json.JSONDecodeError, OSError) as exc:
        raise ObligationError(f"повреждён state-файл {path}: {exc}") from exc


# --- ledger helpers -------------------------------------------------------------


def _ledger_file_for_date(dt: datetime) -> Path:
    return LEDGER_DIR / "day" / dt.strftime("%Y") / dt.strftime("%m") / f"day-{dt.strftime('%Y-%m-%d')}.yaml"


def _load_ledger_day(day: datetime) -> dict:
    """Read published and buffered events; an absent day is an empty document.

    A malformed file or unavailable buffer must still block close checks rather
    than look like an absent ticket. In particular, a leftover git conflict in
    the published YAML is a damaged ledger, not a missing runner call.
    """
    ledger_file = _ledger_file_for_date(day)
    try:
        return read_ledger_document(
            "day", day.strftime("%Y-%m-%d"), str(LEDGER_DIR), LEDGER_ARCHIVE_DIR
        )
    except ValueError as exc:
        if str(exc).startswith("ledger buffer "):
            raise ObligationError(f"ledger {ledger_file} не читается: {exc}") from exc
        raise ObligationError(f"ledger {ledger_file} повреждён: {exc}") from exc
    except (OSError, RuntimeError) as exc:
        raise ObligationError(f"ledger {ledger_file} не читается: {exc}") from exc


def _ledger_append(kind: str, data: dict, fail_closed: bool = False) -> bool:
    """Событие в дневной ledger. issued/consumed/obligation — fail-closed,
    т.к. это доказательства аудита."""
    _validate_ledger_data(data)
    today = datetime.now().strftime("%Y-%m-%d")
    payload = json.dumps(data, ensure_ascii=False)
    try:
        proc = subprocess.run(
            ["bash", str(LEDGER_APPEND), "day", today, kind, payload, "close-obligation.py"],
            capture_output=True, text=True, timeout=30,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        if fail_closed:
            raise ObligationError(f"ledger append {kind} не выполнен: {exc}") from exc
        print(f"[close-obligation] WARN: ledger append {kind} failed: {exc}", file=sys.stderr)
        return False
    if proc.returncode != 0:
        if fail_closed:
            raise ObligationError(f"ledger append {kind} отклонён: {proc.stderr.strip()}")
        print(f"[close-obligation] WARN: ledger append {kind} rc={proc.returncode}: {proc.stderr.strip()}", file=sys.stderr)
        return False
    return True


def _validate_ledger_data(data: dict) -> None:
    """Проверка, что значения в событии не порвут YAML/JSON или пути."""
    if not isinstance(data, dict):
        raise ObligationError("ledger data must be dict")
    for key, value in data.items():
        if isinstance(value, str) and not _SAFE_NAME_RE.fullmatch(value):
            # Разрешаем пустые строки для reason/tool_use_id, но не пути
            if key not in {"reason", "tool_use_id", "actor"}:
                raise ObligationError(f"ledger field {key}={value!r} не проходит лексическую проверку")


def _ledger_event_matches(event: dict, kind: str, match: dict) -> bool:
    """Проверка, что событие kind в ledger содержит все пары из match."""
    if not isinstance(event, dict) or event.get("kind") != kind:
        return False
    data = event.get("data") or {}
    if not isinstance(data, dict):
        return False
    for key, value in match.items():
        if data.get(key) != value:
            return False
    return True


def _ledger_has_event(kind: str, match: dict) -> bool:
    """Поиск события в сегодняшнем и вчерашнем ledger."""
    for delta in (0, 1):
        day = datetime.now() - timedelta(days=delta)
        doc = _load_ledger_day(day)
        for event in doc.get("events", []) or []:
            if _ledger_event_matches(event, kind, match):
                return True
    return False


def _find_cancel_event(session_id: str) -> dict | None:
    """Самое свежее cancel-close/close-override событие для session_id, если оно
    есть в сегодняшнем или вчерашнем ledger. Используется session-guard.sh close
    (WP-537), чтобы признавать явную аудируемую отмену пилота таким же терминальным
    состоянием, что и completed-карточка раннера — session_id здесь harness-овый
    (совпадает с тем, что видит protocol-stop-gate.sh), не epoch-based id семафора."""
    latest_event: dict | None = None
    latest_at: datetime | None = None
    # The reader keeps published order and appends unpublished buffer events.
    # That combined position is not chronological; compare event timestamps.
    # Yesterday comes first so today's event wins an exact timestamp tie.
    for delta in (1, 0):
        day = datetime.now() - timedelta(days=delta)
        doc = _load_ledger_day(day)
        for event in doc.get("events", []) or []:
            if not isinstance(event, dict) or event.get("kind") != "close_obligation":
                continue
            data = event.get("data") or {}
            if not isinstance(data, dict):
                continue
            if data.get("session_id") != session_id:
                continue
            if data.get("action") not in ("cancel-close", "close-override"):
                continue
            try:
                event_at = datetime.fromisoformat(str(event.get("ts")).replace("Z", "+00:00"))
            except ValueError as exc:
                raise ObligationError(f"ledger close_obligation содержит неверный ts: {event.get('ts')!r}") from exc
            if event_at.tzinfo is None or event_at.utcoffset() is None:
                raise ObligationError(f"ledger close_obligation содержит ts без часового пояса: {event.get('ts')!r}")
            event_at = event_at.astimezone(timezone.utc)
            if latest_at is not None and event_at < latest_at:
                continue
            latest_at = event_at
            latest_event = {
                "action": data.get("action"),
                "actor": data.get("actor"),
                "reason": data.get("reason"),
                "ts": event.get("ts"),
            }
    return latest_event


# --- pending reconciliation -----------------------------------------------------


def _pending_ticket_path(nonce: str) -> Path:
    return TICKET_DIR / f".pending-{nonce}.json"


def _pending_consume_marker_path(nonce: str, session_id: str) -> Path:
    return TICKET_DIR / f"{nonce}.pending-consume-{_session_safe(session_id)}"


def _find_pending_consume_marker(nonce: str) -> Path | None:
    """Находит pending consume-маркер для nonce (любой session)."""
    pattern = f"{nonce}.pending-consume-*"
    candidates = list(TICKET_DIR.glob(pattern))
    if not candidates:
        return None
    return candidates[0]


def _consumed_ticket_path(nonce: str, run_id: str) -> Path:
    return TICKET_DIR / f"{nonce}.consumed-{_validated_name(run_id, 'run_id')}"


def _ticket_paths(nonce: str) -> tuple[Path, Path]:
    """Возвращает (pending, final) для ticket."""
    return _pending_ticket_path(nonce), TICKET_DIR / f"{nonce}.json"


def _reconcile_issued_ticket(nonce: str) -> bool:
    """Если pending ticket существует и есть issued-ledger — promote в final.
    Если pending есть, а issued-ledger нет — удалить pending (crash до ledger)."""
    pending, final = _ticket_paths(nonce)
    if not pending.exists():
        return final.exists()
    if _ledger_has_event("close_ticket_issued", {"nonce": nonce}):
        try:
            os.replace(pending, final)
        except OSError as exc:
            raise ObligationError(f"не удалось promote pending ticket: {exc}") from exc
        return True
    # Crash до успешного ledger — удаляем несвидетельствованный pending
    try:
        pending.unlink()
    except OSError:
        pass
    return final.exists()


def _reconcile_pending_consume_marker(marker_path: Path) -> bool:
    """Если marker_path pending consume существует и есть consumed-ledger — promote в final.
    Если consumed-ledger нет — пытаемся дописать ledger (idempotent) и promote.
    Если не удалось, оставляем маркер для повторной попытки."""
    if not marker_path.exists():
        return False
    marker = _load_json(marker_path)
    if not marker or not isinstance(marker, dict):
        # Нечитаемый маркер — не оставляем бесконечно, но не удаляем внутри lock,
        # чтобы вызвавший мог решить. Здесь считаем неудачей reconcile.
        return False
    nonce = marker.get("nonce")
    run_id = marker.get("run_id")
    session_id = marker.get("session_id")
    slug = marker.get("slug")
    obligation_id = marker.get("obligation_id")
    if not nonce or not run_id or not session_id:
        return False
    final = _consumed_ticket_path(nonce, run_id)
    if final.exists():
        try:
            marker_path.unlink()
        except OSError:
            pass
        return True
    if _ledger_has_event("close_ticket_consumed", {"nonce": nonce, "run_id": run_id}):
        try:
            os.replace(marker_path, final)
        except OSError as exc:
            raise ObligationError(f"не удалось promote pending consume marker: {exc}") from exc
        return True
    if slug and _ledger_append(
        "close_ticket_consumed",
        {
            "nonce": nonce,
            "obligation_id": obligation_id,
            "session_id": session_id,
            "run_id": run_id,
            "slug": slug,
        },
        fail_closed=False,
    ):
        try:
            os.replace(marker_path, final)
        except OSError as exc:
            raise ObligationError(f"не удалось promote pending consume marker после retry: {exc}") from exc
        return True
    return False


def _reconcile_session_pending_tickets(session_id: str) -> None:
    """Подчищает все pending issue-файлы для сессии (crash recovery)."""
    for pending in TICKET_DIR.glob(".pending-*.json"):
        ticket = _load_json(pending)
        if not ticket or ticket.get("session_id") != session_id:
            continue
        nonce = ticket.get("nonce")
        if not nonce:
            continue
        if _ledger_has_event("close_ticket_issued", {"nonce": nonce, "session_id": session_id}):
            try:
                os.replace(pending, TICKET_DIR / f"{nonce}.json")
            except OSError as exc:
                raise ObligationError(f"не удалось reconcile pending ticket {nonce}: {exc}") from exc
        else:
            # Несвидетельствованный pending — безопасно удалить
            try:
                pending.unlink()
            except OSError:
                pass


def _reconcile_session_pending_consumes(session_id: str) -> None:
    """Подчищает все pending consume-маркеры для сессии (crash recovery)."""
    safe = _session_safe(session_id)
    pattern = f"*.pending-consume-{safe}"
    for marker_path in TICKET_DIR.glob(pattern):
        _reconcile_pending_consume_marker(marker_path)


# --- arm / cancel ---------------------------------------------------------------


def _marker_path(session_id: str) -> Path:
    return MARKER_DIR / f"{_session_safe(session_id)}.flag"


def _clear_runner_marker(session_id: str) -> None:
    MARKER_DIR.mkdir(parents=True, exist_ok=True)
    try:
        _marker_path(session_id).unlink()
    except FileNotFoundError:
        pass
    except OSError as exc:
        raise ObligationError(f"не удалось удалить runner-маркер: {exc}") from exc


def _semaphore_field(text: str, field: str) -> str | None:
    """Достаёт значение простого `field: value` поля из session-guard
    semaphore (не YAML-парсер — семафор пишется как плоский frontmatter,
    этого достаточно и не тянет зависимость)."""
    prefix = f"{field}: "
    for line in text.splitlines():
        if line.startswith(prefix):
            return line[len(prefix):]
    return None


def _peer_session_semaphore_state(session_id: str) -> str | None:
    """Состояние САМОГО СВЕЖЕГО session-guard semaphore этого
    harness_session_id, если он объявил `close_path: peer-session`:
    "open" (файл `*.open`) | "closed" (`*.open.closed`) | None (свежайший
    не peer-session, семафоров нет или каталог нечитаем). Никогда не
    поднимает исключений из-за файловой системы -- нечитаемый файл или
    каталог даёт None, и cmd_arm() записывает его как снимок «не под
    открытой пир-сессией».

    Тот же признак и источник, что close-runner-gate.sh проверяет в
    PreToolUse (Ф42/Ф118): пир-сессия закрывается прямым `git commit`
    (DP.SC.154 Шаг 4.5.1), раннер quick-close ей не нужен.

    bug-2026-08-30: `session-guard.sh close` переименовывает семафор
    `<id>.open` -> `<id>.open.closed` при штатном закрытии -- если смотреть
    только на `*.open`, ровно момент штатного закрытия пир-сессии выбивает
    её из-под собственного exemption. Значит нужно смотреть оба состояния.

    Один `harness_session_id` (CLAUDE_CODE_SESSION_ID — постоянный на весь
    CLI-процесс, `session-guard.sh:1630`) может встретиться на НЕСКОЛЬКИХ
    семафорах подряд за долгую сессию (несколько open/close циклов под
    разные WP). Поэтому нельзя брать первый попавшийся файл в произвольном
    порядке `glob()` -- нужно явно выбрать САМЫЙ СВЕЖИЙ по
    `opened_at`/`created_at` кандидат и смотреть `close_path` только у него
    (пир-сессия с Codex 2026-08-31, WP-484).

    WP-484 п.22 (пир-сессия 2026-09-16-03 с Kimi): `process-runner.py start`
    не открывает своего семафора, поэтому закрытый peer-семафор остаётся
    свежайшим до конца разговора -- bool «свежайший = peer-session» без
    различения open/closed давал Stop-гейту бессрочную поблажку. Состояние
    нужно cmd_arm(), чтобы снять снимок в момент взведения obligation."""
    sessions_dir = RUNTIME_DIR / "sessions"
    try:
        candidates = list(sessions_dir.glob("*.open")) + list(sessions_dir.glob("*.open.closed"))
    except OSError:
        return None
    best_key: tuple[str, str] | None = None
    best_path: Path | None = None
    best_text: str | None = None
    for path in candidates:
        try:
            text = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            # UnicodeDecodeError не подкласс OSError (cold-review Ф133,
            # Medium) -- битый/частично записанный .open-файл не должен
            # ронять весь stop-check, только пропускается как нечитаемый.
            continue
        if _semaphore_field(text, "harness_session_id") != session_id:
            continue
        ts = _semaphore_field(text, "opened_at") or _semaphore_field(text, "created_at")
        if ts is None:
            continue
        # Секундная точность ISO-8601 может совпасть у двух семафоров,
        # открытых в одну секунду -- path.name (несёт epoch создания)
        # вторым ключом делает выбор детерминированным независимо от
        # порядка glob(), даже при коллизии timestamp (Codex, ход 3).
        key = (ts, path.name)
        if best_key is None or key > best_key:
            best_key, best_path, best_text = key, path, text
    if best_text is None or "close_path: peer-session" not in best_text.splitlines():
        return None
    return "closed" if best_path.name.endswith(".open.closed") else "open"


def _is_peer_session_close_path(session_id: str) -> bool:
    """True если свежайший семафор этого harness_session_id объявил
    `close_path: peer-session` -- в любом состоянии (open/closed). Прежнее
    правило поблажки Stop-гейта (Ф133); после WP-484 п.22 применяется только
    к легаси-поколениям obligation без снимка `armed_under_peer_session` и
    к пояснительной ноте при отсутствии obligation (см. cmd_stop_check)."""
    return _peer_session_semaphore_state(session_id) is not None


def cmd_arm(session_id: str, mode: str) -> dict:
    _validated_name(session_id, "session_id")
    if mode not in ("block", "warn"):
        raise ObligationError(f"недопустимый mode: {mode!r}")
    with _session_lock(session_id):
        from session_local_release import harness_fenced
        if harness_fenced(session_id):
            return {"status": "locally_released", "armed": False}
        existing = _load_obligation(session_id)
        # bug-2026-08-31: фраза закрытия, произнесённая ПОКА предыдущее
        # obligation-поколение уже в state=="running" (раннер физически
        # стартовал под ним, ticket-handshake его связал), не должна
        # выбрасывать эту identity. Раньше re-arm безусловно создавал новое
        # поколение с run_id=None -- stop-check потом видел только новое
        # поколение и блокировал ход, хотя раннер под старым run_id либо ещё
        # работал, либо уже успешно завершился. Легитимный путь эвакуации из
        # застрявшего running (cancel-close/close-override, cmd_cancel) не
        # зависит от state и этим фиксом не затрагивается. Найдено пир-сессией
        # с Codex 2026-08-31 (WP-484), консенсус ход 5 -- намеренно НЕ вводим
        # новый переход running->armed для аварийно брошенного запуска: это
        # отдельное архитектурное решение вне рамок точечного фикса.
        if existing is not None and existing.get("state") == "running":
            existing["mode"] = mode
            existing["updated_at"] = now_iso()
            existing.setdefault("rearm_intents", []).append(now_iso())
            _atomic_write_json(_obligation_path(session_id), existing)
            return {
                "status": "armed",
                "mode": mode,
                "obligation_id": existing["obligation_id"],
                "note": "existing running obligation preserved (mid-flight rearm)",
            }
        # re-arm = новое поколение: старые ticket'ы по старому obligation_id мертвы,
        # и старый runner-маркер тоже не должен засчитываться.
        _clear_runner_marker(session_id)
        obligation = {
            "obligation_id": uuid.uuid4().hex,
            "session_id": session_id,
            "state": "armed",
            "mode": mode,
            "slug": None,
            "run_id": None,
            "ticket_nonce": None,
            "needs_user_action": False,
            "created_at": now_iso(),
            "updated_at": now_iso(),
            # WP-484 п.22: снимок «взведено ли под ОТКРЫТОЙ пир-сессией» -- в
            # той же транзакции, что и запись. Фраза закрытия ловится хуком на
            # UserPromptSubmit до хода агента, а `session-guard.sh close`
            # переименовывает семафор позже в том же ходу: обязательство
            # самой пир-сессии всегда видит "open". Обязательство, взведённое
            # уже над закрытым семафором, -- намерение следующей работы, оно
            # обязано идти через раннер (см. cmd_stop_check).
            "armed_under_peer_session": _peer_session_semaphore_state(session_id),
        }
        if existing:
            obligation["rearmed_from"] = existing.get("obligation_id")
        _atomic_write_json(_obligation_path(session_id), obligation)
    return {"status": "armed", "mode": mode, "obligation_id": obligation["obligation_id"]}


def _has_pending_ticket_for_obligation(obligation_id: str) -> bool:
    """True if a close-ticket exists, still within `TICKET_TTL_S`, for this
    exact obligation generation -- i.e. one `cmd_consume_ticket()` could
    still legally accept (it rejects anything older as "просрочен", line
    ~986). `Path.glob("*.json")`, unlike shell glob, DOES match dotfiles --
    this also catches `.pending-<nonce>.json` (the brief window between
    `cmd_issue_ticket()` releasing its lock and the out-of-lock ledger+
    rename finishing), which is load-bearing: excluding dotfiles would miss
    that sub-window and reopen the race this guard exists to close.

    `obligation_id` is usually a fresh UUID per `cmd_arm()`, but
    `_transition_running_to_armed()` (running->armed on a reap/retry) reuses
    the SAME id -- so an old, never-consumed ticket (e.g. one issued for a
    start whose runner never reached `cmd_consume_ticket`) can in
    principle still match after such a cycle. The TTL bound caps how long
    that ONE ticket can block cleanup. It does not prove an upper bound
    against continuous re-issuance (`cmd_issue_ticket()` has no dedup guard,
    and `close-runner-gate.sh` issues a ticket on every observed
    `start quick-close` retry) -- that residual case is accepted, not
    fixed here: this guard only ever affects the automatic
    `peer-session-close` path, never a pilot's explicit `cancel-close`/
    `close-override` (line ~701), so a human is never actually stuck."""
    for path in TICKET_DIR.glob("*.json"):
        try:
            ticket = _load_json(path)
        except ObligationError as exc:
            print(f"[close_obligation] пропускаю повреждённый тикет {path}: {exc}", file=sys.stderr)
            continue  # can't prove it's live, don't let a corrupt file block cancel
        if not ticket or ticket.get("obligation_id") != obligation_id:
            continue
        try:
            created = _parse_ticket_timestamp(ticket.get("created_at"))
        except ObligationError as exc:
            print(f"[close_obligation] тикет {path} с нечитаемым created_at: {exc}", file=sys.stderr)
            continue  # same reasoning: unparseable timestamp can't prove liveness
        if (datetime.now(timezone.utc) - created).total_seconds() <= TICKET_TTL_S:
            return True
    return False


def cmd_cancel(session_id: str, action: str, actor: str, reason: str, force: bool = False) -> dict:
    _validated_name(session_id, "session_id")
    if action not in ("cancel-close", "close-override", "peer-session-close"):
        raise ObligationError(f"недопустимый action: {action!r}")
    with _session_lock(session_id):
        obligation = _load_obligation(session_id)
        if obligation is None:
            return {"status": "no_obligation"}
        if action == "peer-session-close" and obligation.get("state") == "running":
            # harness_session_id is process-lifetime and one long conversation
            # routinely covers several WPs in sequence (WP-484 "Восьмой
            # случай" cold-review, 03.09) -- a `running` obligation here can
            # belong to an EARLIER, still in-flight Quick Close for a
            # different WP that merely hit a `waiting` step (Stop is legally
            # allowed to end the turn there, per cmd_stop_check's own
            # `waiting` branch). Only the automatic peer-session-close path
            # needs this guard: a real pilot invoking cancel-close/close-
            # override explicitly still clears `running` unconditionally,
            # same as before this action was added.
            return {"status": "skipped_running", "obligation_id": obligation["obligation_id"]}
        if (
            action == "peer-session-close"
            and obligation.get("state") == "armed"
            and _has_pending_ticket_for_obligation(obligation["obligation_id"])
        ):
            # Symmetric with the `running` skip above: a ticket is issued
            # (close-runner-gate.sh:263) before the runner calls
            # cmd_consume_ticket() to flip armed->running, so deleting here
            # would fail an unrelated in-flight Quick Close for a different
            # WP under the same harness_session_id. Sentinel-armed false
            # positives (close-gate-reminder.sh:166) never issue a ticket,
            # so this guard doesn't reopen that hole.
            return {"status": "skipped_ticket_pending", "obligation_id": obligation["obligation_id"]}
        if (action == "peer-session-close"
                and "armed_under_peer_session" in obligation
                and obligation["armed_under_peer_session"] != "open"):
            # A retry of an older terminal guard must not cancel a newly armed
            # generation. cmd_arm snapshots this under the same obligation
            # lock: arming after the peer closes belongs to the next work.
            return {"status": "skipped_next_work", "obligation_id": obligation["obligation_id"]}
        ledger_ok = _ledger_append("close_obligation", {
            "action": action,
            "obligation_id": obligation["obligation_id"],
            "session_id": session_id,
            "actor": actor,
            "reason": reason,
        }, fail_closed=False)
        if not ledger_ok and not force:
            # Fail-closed: оставляем obligation на месте, чтобы Stop-гейт всё ещё блокировал
            raise ObligationError(
                f"cancel {action} не удалось записать в ledger; obligation остаётся активным. "
                f"Повторите или используйте --force при ясном понимании риска."
            )
        path = _obligation_path(session_id)
        _check_path_safe(path)
        path.unlink()
        _clear_runner_marker(session_id)
        try:
            (INTENT_SENTINEL_DIR / f"{_session_safe(session_id)}.flag").unlink()
        except FileNotFoundError:
            pass
        except OSError as exc:
            raise ObligationError(f"не удалось удалить close-intent sentinel: {exc}") from exc
    return {"status": action, "obligation_id": obligation["obligation_id"], "ledger_ok": ledger_ok}


# --- close-intent records --------------------------------------------------------
#
# Отдельная сущность от obligation (пир-сессия 2026-08-11-05-quick-close-session-
# reflection, консенсус с Codex): obligation — изменяемое состояние gate/ticket/
# sentinel; close-intent record — неизменяемое доказательство того, что пилот
# сказал в момент срабатывания триггерной фразы. Смешение полей в один объект
# путает семантику при re-arm (obligation пересоздаётся, доказательство реплики
# пилота должно пережить это пересоздание нетронутым).
#
# Отличие от reflection-anchor (Ф75, соседняя фаза той же проблемы): anchor
# защищает УЖЕ ОПУБЛИКОВАННЫЙ вопрос от потери ответа при retry внутри одной
# рефлексии (rendered_at сдвигается вперёд, anchor держит самый ранний). Эта
# запись решает более раннюю точку — пилот называет рефлексию ДО того, как
# render вообще опубликовал вопрос (в одной фразе с самим триггером закрытия),
# то есть до появления любого rendered_at/anchor этого запуска. Оба механизма
# нужны одновременно, не заменяют друг друга.
#
# Путь по session_id, не run_id: hook, детектирующий фразу закрытия, не знает
# run_id — тот появляется только когда process-runner.py start реально стартует,
# позже. render (который свой run_id уже знает) резолвит session_id тем же
# harness-mapping файлом, что уже использует session-reflection-append.sh, и
# читает САМУЮ СВЕЖУЮ непотреблённую запись для этой сессии.


def _intent_path(session_id: str) -> Path:
    return INTENT_DIR / f"{_session_hash(session_id)}.json"


def _validated_technical_intent_fields(
    technical_authorized: object,
    technical_scope: object,
    skip_reflection: object,
) -> tuple[bool, str | None]:
    """Validate the persisted WP-520 technical-close attribution.

    ``bool(value)`` is unsafe here: a legacy/corrupt JSON value such as the
    string ``"false"`` is truthy and would silently acquire authorization.
    Missing fields remain valid for records written before WP-520 and are
    supplied by callers as the safe ``False``/``None`` defaults.
    """
    if type(technical_authorized) is not bool:
        raise ObligationError(
            "technical_authorized должен быть JSON boolean true|false"
        )
    if type(skip_reflection) is not bool:
        raise ObligationError("skip_reflection должен быть JSON boolean true|false")
    if technical_scope is not None:
        _validated_name(technical_scope, "technical_scope")
    if technical_authorized:
        if technical_scope is None:
            raise ObligationError(
                "technical_authorized=true требует непустой technical_scope"
            )
        if not skip_reflection:
            raise ObligationError(
                "technical_authorized=true требует skip_reflection=true"
            )
    elif technical_scope is not None:
        raise ObligationError(
            "technical_scope допустим только при technical_authorized=true"
        )
    return technical_authorized, technical_scope


def cmd_record_intent(
    session_id: str,
    raw_text: str,
    skip_reflection: bool = False,
    technical_authorized: bool = False,
    technical_scope: str | None = None,
) -> dict:
    """Вызывается close-gate-reminder.sh на каждое срабатывание триггерной фразы
    закрытия. raw_text — текст ПОСЛЕ триггерного слова, как есть, без интерпретации
    (может быть пустым — голое "закрывай" без хвоста). skip_reflection (WP-484,
    прямое поручение пилота 2026-08-11) — отдельный явный сигнал "закрывай без
    рефлексии": пилот просит пропустить вопрос вообще, не сохранять raw_text как
    ответ для показа обратно — разные вещи, не редукция одного к другому.

    technical_authorized/technical_scope (WP-520 К2a) фиксируют отдельное
    основание для технического закрытия: process-runner уже проверил точный
    allowlist репозитория и diff. Этот слой сохраняет атрибуцию и строго
    проверяет её типы/лексическую форму; старые вызовы без этих аргументов
    получают безопасные False/None."""
    _validated_name(session_id, "session_id")
    technical_authorized, technical_scope = _validated_technical_intent_fields(
        technical_authorized, technical_scope, skip_reflection
    )
    with _session_lock(session_id):
        record = {
            "session_id": session_id,
            "tail_present": bool(raw_text.strip()),
            "raw_text": raw_text,
            "skip_reflection": skip_reflection,
            "technical_authorized": technical_authorized,
            "technical_scope": technical_scope,
            "sentinel_ts": now_iso(),
            "consumed": False,
        }
        _atomic_write_json(_intent_path(session_id), record)
    return {
        "status": "recorded",
        "tail_present": record["tail_present"],
        "skip_reflection": record["skip_reflection"],
        "technical_authorized": record["technical_authorized"],
        "technical_scope": record["technical_scope"],
    }


def cmd_read_intent(session_id: str) -> dict:
    """Вызывается session-reflection-render.sh. Атомарно читает и помечает
    consumed=true (не удаляет файл — audit-трейл остаётся на диске, в отличие от
    witness, который раньше стирался физически). Уже consumed или отсутствует ->
    tail_present: false, raw_text: "" (тот же путь, что "пилот ничего не сказал
    заранее" — render идёт по обычному interactive-пути).

    Исключение (прямое поручение пилота 14.08.2026, WP-520): skip_reflection
    переживает потребление. Содержимое рефлексии (raw_text) остаётся одноразовым
    (анти-replay: старый ответ нельзя переиспользовать в следующем закрытии), но
    отказ от рефлексии — волеизъявление на всю сессию: перезапуск прогона после
    технического провала (неверный формат вердикта, билет без леджера) не должен
    переспрашивать пилота то, что тот уже сказал."""
    _validated_name(session_id, "session_id")
    with _session_lock(session_id):
        path = _intent_path(session_id)
        record = _load_json(path)
        if record is None:
            return {
                "tail_present": False,
                "raw_text": "",
                "skip_reflection": False,
                "technical_authorized": False,
                "technical_scope": None,
                "sentinel_ts": "",
                "fresh": False,
            }
        technical_authorized, technical_scope = _validated_technical_intent_fields(
            record.get("technical_authorized", False),
            record.get("technical_scope"),
            record.get("skip_reflection", False),
        )
        if record.get("consumed"):
            return {
                "tail_present": False,
                "raw_text": "",
                "skip_reflection": bool(record.get("skip_reflection")),
                "technical_authorized": technical_authorized,
                "technical_scope": technical_scope,
                "sentinel_ts": record.get("sentinel_ts", ""),
                "fresh": False,
            }
        record["consumed"] = True
        _atomic_write_json(path, record)
    return {
        "tail_present": bool(record.get("tail_present")),
        "raw_text": record.get("raw_text", ""),
        "skip_reflection": bool(record.get("skip_reflection")),
        "technical_authorized": technical_authorized,
        "technical_scope": technical_scope,
        "sentinel_ts": record.get("sentinel_ts", ""),
        "fresh": True,
    }


# --- tickets --------------------------------------------------------------------

# File-name suffixes are a closed set: a free-text reason must never reach a path.
VOID_REASONS = ("start_rejected",)
VOID_DETAIL_MAX = 300
# Long opaque runs are nonces, tokens and keys; the detail must not carry them even
# into the runtime ticket file. ASCII only: Russian refusal text stays readable.
_VOID_DETAIL_TOKEN_RE = re.compile(r"[A-Za-z0-9_+=-]{20,}")
# Only these names reach the git ledger: no pattern can tell a class name from a key
# of the same shape. A new runner exception reads as "unknown" until it is listed here.
_VOID_KNOWN_CLASSES = frozenset({
    "ProcessError", "ReleaseCardRelocationBlocked", "SemanticVerificationFailed",
    "ProcessConfigError", "HandlerRejected", "CardCorruptError", "ObligationError",
    "OSError", "FileNotFoundError", "PermissionError", "TimeoutError", "ValueError",
    "KeyError", "TypeError", "AttributeError", "RuntimeError", "UnicodeError",
    "UnicodeEncodeError", "UnicodeDecodeError", "CalledProcessError", "TimeoutExpired",
    "JSONDecodeError", "YAMLError",
})


def _masked_void_detail(detail: str) -> str:
    """One masked line for the runtime ticket file; never goes to the git ledger."""
    # errors="replace": an undecodable path in the message must not fail the void itself.
    text = " ".join(str(detail).encode("utf-8", "replace").decode("utf-8").split())
    text = text.replace(str(Path.home()), "~")
    class_name = _void_detail_class(text)
    prefix = class_name if class_name != "unknown" else ""
    return (prefix + _VOID_DETAIL_TOKEN_RE.sub("<masked>", text[len(prefix):]))[:VOID_DETAIL_MAX]


def _void_detail_class(detail: str) -> str:
    """Exception class name from "Class: message": the only part safe for the ledger."""
    name = str(detail).partition(":")[0]
    return name if name in _VOID_KNOWN_CLASSES else "unknown"


def _expired_ticket_path(nonce: str) -> Path:
    return TICKET_DIR / f"{nonce}.expired"


def _voided_ticket_path(nonce: str, reason: str) -> Path:
    return TICKET_DIR / f"{nonce}.voided-{reason}"  # reason is already normalized


def _retire_pending_ticket(ticket: dict, terminal_path: Path, event: str, extra: dict) -> bool:
    """Move a pending ticket to its terminal file. Caller holds the ticket's session lock.

    The rename is the truth (atomic); the ledger event is a best-effort mirror, so a
    ledger outage can never leave a dead ticket looking alive.
    """
    nonce = ticket["nonce"]
    try:
        os.replace(TICKET_DIR / f"{nonce}.json", terminal_path)
    except OSError as exc:
        print(f"[close-obligation] WARN: ticket {nonce} not retired: {exc}", file=sys.stderr)
        return False
    _ledger_append(event, {
        "nonce": nonce,
        "obligation_id": ticket.get("obligation_id"),
        "session_id": ticket.get("session_id"),
        "slug": ticket.get("slug"),
        **extra,
    }, fail_closed=False)
    return True


def _ticket_is_stale(ticket: dict) -> bool:
    created = _parse_ticket_timestamp(ticket.get("created_at"))
    return (datetime.now(timezone.utc) - created).total_seconds() > TICKET_TTL_S


def _expire_stale_tickets(session_id: str) -> None:
    """Retire this session's pending tickets older than TTL. Caller holds the session lock.

    Consume checks the same TTL under the same lock, so a ticket is either consumed
    or expired, never both. One unreadable file must not block issuing a new ticket.
    """
    for path in TICKET_DIR.glob("*.json"):
        if path.name.startswith(".") or len(path.stem) != 32:
            continue
        try:
            ticket = _load_json(path)
            if (ticket and ticket.get("session_id") == session_id
                    and ticket.get("nonce") == path.stem and _ticket_is_stale(ticket)):
                _retire_pending_ticket(ticket, _expired_ticket_path(path.stem),
                                       "close_ticket_expired", {})
        except ObligationError as exc:
            print(f"[close-obligation] WARN: ticket {path.name} skipped: {exc}", file=sys.stderr)


def cmd_void_ticket(nonce: str, reason: str = "start_rejected", detail: str = "") -> dict:
    """Void a still-pending ticket (the runner refused to start). No-op when the
    ticket is not pending: already consumed, expired, voided or never issued.
    "void_failed" means the ticket is still pending because the rename failed.

    `detail` ("Class: message") explains the refusal: the masked text stays in the
    runtime ticket file, the ledger (published to git) gets only the class name."""
    _validated_nonce(nonce)
    reason = reason if reason in VOID_REASONS else "other"
    ticket_path = TICKET_DIR / f"{nonce}.json"
    ticket = _load_json(ticket_path)
    session_id = str((ticket or {}).get("session_id") or "")
    if not session_id:
        return {"status": "not_pending", "nonce": nonce}
    _validated_name(session_id, "session_id")
    with _session_lock(session_id):
        ticket = _load_json(ticket_path)  # re-read: consume may have won the lock first
        if ticket is None:
            return {"status": "not_pending", "nonce": nonce}
        extra = {"reason": reason}
        if detail:
            extra["detail_class"] = _void_detail_class(detail)
            try:
                _atomic_write_json(ticket_path, {**ticket, "void_detail": _masked_void_detail(detail)})
            except OSError as exc:  # the explanation must not keep a dead ticket alive
                print(f"[close-obligation] WARN: ticket {nonce} void detail not saved: {exc}", file=sys.stderr)
        voided = _retire_pending_ticket(
            ticket, _voided_ticket_path(nonce, reason), "close_ticket_voided", extra,
        )
    return {"status": "voided" if voided else "void_failed", "nonce": nonce}


def cmd_issue_ticket(session_id: str, slug: str, tool_use_id: str) -> str:
    """Выпуск ticket. Двухфазный commit: pending → ledger issued (fail-closed) → final."""
    _validated_name(session_id, "session_id")
    _validated_name(slug, "slug")
    nonce = secrets.token_hex(16)
    with _session_lock(session_id):
        from session_local_release import harness_fenced
        if harness_fenced(session_id):
            raise ObligationError("session locally released; new close ticket refused")
        obligation = _load_obligation(session_id)
        # Убираем мусор от предыдущих крэшей этой сессии
        _reconcile_issued_ticket(nonce)
        _reconcile_session_pending_tickets(session_id)
        _reconcile_session_pending_consumes(session_id)
        _expire_stale_tickets(session_id)
        ticket = {
            "nonce": nonce,
            "obligation_id": obligation["obligation_id"] if obligation else None,
            "session_id": session_id,
            "slug": slug,
            "tool_use_id": tool_use_id,
            "created_at": now_iso(),
        }
        _atomic_write_json(_pending_ticket_path(nonce), ticket)
    # Ledger вне lock — допустимо, т.к. pending уникален по nonce и lock защищает
    # от повторной выдачи того же nonce. При неудаче pending удаляется.
    ledger_ok = _ledger_append("close_ticket_issued", {
        "nonce": nonce,
        "obligation_id": ticket["obligation_id"],
        "session_id": session_id,
        "slug": slug,
    }, fail_closed=True)
    if not ledger_ok:
        try:
            _pending_ticket_path(nonce).unlink()
        except OSError:
            pass
        raise ObligationError("ledger close_ticket_issued не записан — ticket отозван")
    try:
        os.replace(_pending_ticket_path(nonce), TICKET_DIR / f"{nonce}.json")
    except OSError as exc:
        raise ObligationError(f"не удалось finalize ticket: {exc}") from exc
    return nonce


def peek_ticket(nonce: str) -> dict:
    """Чтение ticket БЕЗ потребления — для ключа идемпотентности в cmd_start."""
    _validated_nonce(nonce)
    _reconcile_issued_ticket(nonce)
    ticket = _load_json(TICKET_DIR / f"{nonce}.json")
    if ticket is None:
        raise ObligationError("ticket не найден (уже потреблён или не выпущен хуком)")
    if not ticket.get("session_id"):
        raise ObligationError("ticket без session_id")
    return ticket


def _parse_ticket_timestamp(ts: str) -> datetime:
    try:
        return datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except (ValueError, TypeError) as exc:
        raise ObligationError(f"ticket malformed timestamp: {ts!r}: {exc}") from exc


def _close_override_hint(session_id: str) -> str:
    return (
        "Выход, только по слову пилота и если прошлый прогон действительно терминален: "
        f"python3 scripts/close_obligation.py cancel --session-id {session_id} "
        "--action close-override --actor <агент> --reason \"<обоснование>\""
    )


def _stuck_run_rearm_problems(card: dict, obligation: dict, session_id: str) -> list[str]:
    """Проблемы, мешающие считать прошлый (терминальный) прогон основанием для нового.

    failed/cancelled: пилоту ошибка уже показана (та же логика, что в stop-check) --
    проблем нет. completed: та же машинная проверка полноты и ledger-записи прошлого
    ticket, что stop-check требует перед очисткой обязательства."""
    if card.get("status") != "completed":
        return []
    problems = _verify_completed_card(card, obligation)
    nonce = obligation.get("ticket_nonce")
    if nonce is not None:
        slug = obligation.get("slug")
        obligation_id = obligation.get("obligation_id")
        problems.extend(_ticket_issued_in_ledger(nonce, session_id, slug, obligation_id)[1])
        problems.extend(
            _ticket_consumed_in_ledger(nonce, obligation.get("run_id"), session_id, slug, obligation_id)[1]
        )
    return problems


def cmd_consume_ticket(nonce: str, slug: str, run_id: str, process_id: str) -> dict:
    """Потребление ticket реально исполняющимся раннером. Двухфазный commit:
    validate → rename to pending-consume marker → update obligation + runner marker
    → ledger consumed → rename to final consumed."""
    _validated_nonce(nonce)
    _validated_name(slug, "slug")
    _validated_name(run_id, "run_id")
    if process_id != "quick-close":
        raise ObligationError("--close-ticket допустим только для quick-close")

    ticket_path = TICKET_DIR / f"{nonce}.json"
    _reconcile_issued_ticket(nonce)
    ticket = _load_json(ticket_path)
    if ticket is None:
        # Возможно, крэш оставил pending-consume — попробуем reconcile
        marker_path = _find_pending_consume_marker(nonce)
        if marker_path:
            _reconcile_pending_consume_marker(marker_path)
        if _consumed_ticket_path(nonce, run_id).exists():
            return {"status": "already_consumed", "nonce": nonce, "run_id": run_id}
        raise ObligationError("ticket не найден (уже потреблён или не выпущен хуком)")
    session_id = str(ticket.get("session_id") or "")
    if not session_id:
        raise ObligationError("ticket без session_id")
    _validated_name(session_id, "session_id")

    with _session_lock(session_id):
        # Ревалидация под lock + crash recovery этой сессии
        from session_local_release import harness_fenced
        if harness_fenced(session_id):
            raise ObligationError("session locally released; ticket consumption refused")
        _reconcile_issued_ticket(nonce)
        _reconcile_session_pending_consumes(session_id)
        ticket = _load_json(ticket_path)
        if ticket is None:
            marker_path = _find_pending_consume_marker(nonce)
            if marker_path:
                _reconcile_pending_consume_marker(marker_path)
            if _consumed_ticket_path(nonce, run_id).exists():
                return {"status": "already_consumed", "nonce": nonce, "run_id": run_id}
            raise ObligationError("ticket уже потреблён параллельным запуском")
        if ticket.get("nonce") != nonce:
            raise ObligationError("ticket не совпадает с запрошенным nonce")
        created = _parse_ticket_timestamp(ticket.get("created_at"))
        age = (datetime.now(timezone.utc) - created).total_seconds()
        if age > TICKET_TTL_S:
            _retire_pending_ticket(ticket, _expired_ticket_path(nonce), "close_ticket_expired", {})
            raise ObligationError(f"ticket просрочен ({int(age)}с > {TICKET_TTL_S}с)")
        ticket_slug = str(ticket.get("slug") or "")
        if ticket_slug != UNRESOLVED_SLUG_SENTINEL and ticket_slug != slug:
            raise ObligationError(f"slug ticket ({ticket.get('slug')!r}) не совпадает с запрошенным ({slug!r})")

        obligation = _load_obligation(session_id)
        obligation_updated = False
        if ticket.get("obligation_id"):
            if obligation is None:
                raise ObligationError("obligation, указанная в ticket, уже не существует")
            if obligation["obligation_id"] != ticket["obligation_id"]:
                raise ObligationError("ticket выпущен для прежнего поколения obligation (re-arm)")
            if obligation["state"] != "armed":
                # WP-484 V(a) (01.09, пир-сессия с Kimi+Codex): obligation "running"
                # не всегда сломана -- если она осталась от прогона, который сессия
                # сама отменила при close (V(c) ниже помечает такие карточки
                # cancel_reason=session_closed), это штатный переходный случай, не
                # аномалия. Источник истины -- карточка, не obligation.state: полю
                # state не обязательно уже успеть обновиться до cancelled (V(c)
                # эвакуирует его под этим же _session_lock отдельным вызовом,
                # порядок относительно этого чтения не гарантирован и не важен --
                # см. reconcile_terminal_running_obligation для случая, когда
                # эвакуация вообще не произошла из-за краша).
                if obligation["state"] == "running":
                    stuck_run_id = obligation.get("run_id")
                    stuck_card = _read_card(
                        stuck_run_id, session_id, obligation.get("slug"),
                    ) if stuck_run_id else None
                    stuck_status = stuck_card.get("status") if stuck_card else None
                    stuck_terminal = stuck_status in ("completed", "failed", "cancelled")
                    # WP-484 Ф272: session_closed-карточка идёт общим путём переармирования
                    # (прежний ранний возврат не потреблял ticket, а раннер всё равно стартовал).
                    # WP-484 Ф268: прошлый прогон терминален, обязательство осталось running
                    # (две сессии подряд в одной беседе) -> новый прогон берёт то же поколение.
                    # Всё под _session_lock; ниже obligation.update меняет run_id, поэтому
                    # поздний reconcile по старому run_id на сверке run_id ничего не переведёт.
                    # Инвариант ослаблен намеренно: одно поколение (obligation_id) может принять
                    # несколько consume, ledger ищется по nonce+run_id, не по obligation_id.
                    # Политика «терминальная карточка -> можно ли переармировать» продублирована
                    # в cmd_stop_check (ветки failed/cancelled/completed): меняя одну, сверь другую.
                    if stuck_terminal:
                        problems = _stuck_run_rearm_problems(stuck_card, obligation, session_id)
                        if not problems:
                            obligation["state"] = "armed"
                        else:
                            raise ObligationError(
                                f"obligation в состоянии running, прошлый прогон {stuck_run_id} "
                                f"{stuck_status}, но проверка не прошла:\n- " + "\n- ".join(problems)
                                + "\n" + _close_override_hint(session_id)
                            )
                    else:
                        raise ObligationError(
                            f"obligation в состоянии running (прогон {stuck_run_id}, карточка "
                            f"{stuck_status or 'не найдена'}), ожидалось armed. "
                            + _close_override_hint(session_id)
                        )
                if obligation["state"] != "armed":  # guard: unknown future states stay fail-closed
                    raise ObligationError(f"obligation в состоянии {obligation['state']}, ожидалось armed")
            obligation.update({
                "state": "running",
                "slug": slug,
                "run_id": run_id,
                "ticket_nonce": nonce,
                "needs_user_action": False,
                "updated_at": now_iso(),
            })
            _atomic_write_json(_obligation_path(session_id), obligation)
            obligation_updated = True

        # consume = rename ticket → pending-consume marker (фаза 1)
        marker_path = _pending_consume_marker_path(nonce, session_id)
        marker_obj = {
            "nonce": nonce,
            "obligation_id": ticket.get("obligation_id"),
            "session_id": session_id,
            "run_id": run_id,
            "slug": slug,
            "started_at": now_iso(),
        }
        os.replace(ticket_path, marker_path)
        _atomic_write_json(marker_path, marker_obj)

        # runner-маркер, привязанный к текущему obligation_id
        MARKER_DIR.mkdir(parents=True, exist_ok=True)
        marker = _marker_path(session_id)
        runner_marker_obj = {
            "obligation_id": (obligation["obligation_id"] if obligation else None),
            "run_id": run_id,
            "nonce": nonce,
            "at": now_iso(),
        }
        _atomic_write_json(marker, runner_marker_obj)

    # Ledger consumed вне lock, но pending-consume маркер уже не позволяет повторное consume
    ledger_data = {
        "nonce": nonce,
        "obligation_id": ticket.get("obligation_id"),
        "session_id": session_id,
        "run_id": run_id,
        "slug": slug,
    }
    # Если consumed ledger уже есть (idempotent retry), не дублируем
    if _ledger_has_event("close_ticket_consumed", {"nonce": nonce, "run_id": run_id}):
        ledger_ok = True
    else:
        ledger_ok = _ledger_append("close_ticket_consumed", ledger_data, fail_closed=True)
    if not ledger_ok:
        # Оставляем pending-consume и obligation running; retry позже продолжит
        raise ObligationError("ledger close_ticket_consumed не записан — consume не завершён")
    try:
        os.replace(marker_path, _consumed_ticket_path(nonce, run_id))
    except OSError as exc:
        raise ObligationError(f"не удалось finalize consumed ticket: {exc}") from exc
    return {"status": "ok", "session_id": session_id, "obligation_updated": obligation_updated}


# --- stop-check -----------------------------------------------------------------


def _load_obligation(session_id: str) -> dict | None:
    return _load_json(_obligation_path(session_id))


def cmd_mode(session_id: str) -> str:
    """Read-only режим текущей obligation ("armed"/"running" mode: block|warn, или
    пустая строка при отсутствии). Без побочных эффектов — для PreToolUse-гейтов,
    которым нужно решение block/warn ДО того, как штатный Stop-check это увидит.
    Никогда не мутирует state и не проверяет карточку (в отличие от stop-check)."""
    obligation = _load_obligation(session_id)
    return obligation.get("mode", "") if obligation else ""


def _resolve_ref(results: dict, ref: str):
    step, _, field = ref.partition(".")
    value = results.get(step)
    if not isinstance(value, dict):
        return None
    return value.get(field)


# eq/ne через _expect_value_matches (WP-520): та же терпимость к регистру
# LLM-строк, что у close_check expect ниже, — один класс дефекта, одна политика.
_OPS = {
    "eq": lambda a, b: _expect_value_matches(a, b),
    "ne": lambda a, b: not _expect_value_matches(a, b),
    "exists": lambda a, b: (a is not None) == b,
}


def _owned_semaphore_text(path: Path) -> str:
    """Read and validate one descriptor; never follow a substituted symlink/FIFO."""
    if path.resolve(strict=True) != path:
        raise ValueError("путь семафора содержит symlink")
    with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK), "rb") as stream:
        before = os.fstat(stream.fileno())
        if (not stat.S_ISREG(before.st_mode) or before.st_uid != os.getuid()
                or before.st_nlink != 1 or before.st_mode & 0o022
                or not 0 < before.st_size <= 1024 * 1024):
            raise ValueError("небезопасный файл семафора")
        raw = stream.read(1024 * 1024 + 1)
        after = path.stat(follow_symlinks=False)
        if (before.st_dev, before.st_ino, before.st_mtime_ns, before.st_size) != (
                after.st_dev, after.st_ino, after.st_mtime_ns, after.st_size):
            raise ValueError("семафор изменился во время чтения")
    if len(raw) != before.st_size or b"\0" in raw:
        raise ValueError("повреждённый снимок семафора")
    return raw.decode("utf-8")


def _card_owner_metadata(session_id: str, slug: str | None) -> dict | None:
    """Resolve the exact guard/harness owner; a slug is never ownership proof."""
    matches = []
    for path in (RUNTIME_DIR / "sessions").glob("*.open*"):
        if not path.name.endswith((".open", ".open.closed")):
            continue
        filename_claim = any(path.name.endswith(f"-{session_id}{suffix}")
                             for suffix in (".open", ".open.closed"))
        try:
            text = _owned_semaphore_text(path)
            # Claim detection precedes parsing: a malformed duplicate must not
            # disappear merely because another valid guard claims this owner.
            filename_claim = filename_claim or bool(re.search(
                rf"(?m)^(?:session_id|harness_session_id):[ \t]*(['\"]?){re.escape(session_id)}\1[ \t]*(?:#.*)?$",
                text,
            ))
            lines = text.splitlines()
            if not lines or lines[0] != "---":
                raise ValueError("нет frontmatter")
            node = yaml.compose("\n".join(lines[1:lines.index("---", 1)]), Loader=yaml.SafeLoader)
            if not isinstance(node, yaml.MappingNode):
                raise ValueError("frontmatter не mapping")
            claims = {value.value for key, value in node.value
                      if isinstance(key, yaml.ScalarNode) and isinstance(value, yaml.ScalarNode)
                      and key.value in ("session_id", "harness_session_id")}
            if session_id not in claims and not filename_claim:
                continue
            filename_claim = True
            fields = {}
            for key, value in node.value:
                if (not isinstance(key, yaml.ScalarNode) or not isinstance(value, yaml.ScalarNode)
                        or key.value in fields or key.value == "<<"):
                    raise ValueError("неоднозначные поля семафора")
                fields[key.value] = value.value
            housekeeping_reason = fields.get("housekeeping")
            if housekeeping_reason is not None:
                # A housekeeping semaphore (Day/Week/Month Close) is never a wp/guard
                # owner: it has no `wp:` field and its own session_id, not the caller's.
                # Name and content must agree before either is trusted -- a mismatch
                # (e.g. housekeeping-looking name carrying a `wp:` field) stays on the
                # existing fail-closed path below, not a silent skip.
                expected_housekeeping = f"{fields.get('agent', '')}-housekeeping-{housekeeping_reason}.open"
                if (_SAFE_NAME_RE.fullmatch(housekeeping_reason)
                        and fields.get("slug") == housekeeping_reason
                        and "wp" not in fields
                        and path.name in (expected_housekeeping, expected_housekeeping + ".closed")):
                    continue  # well-formed housekeeping semaphore -- never an owner candidate
                raise ValueError("housekeeping-семафор не согласован по имени/содержимому")
            for key in ("agent", "session_id", "harness_session_id", "slug"):
                if key == "harness_session_id" and key not in fields:
                    continue
                if not _SAFE_NAME_RE.fullmatch(fields.get(key, "")):
                    raise ValueError(f"недопустимый {key}")
            expected = f"{fields['agent']}-{fields['session_id']}.open"
            if path.name not in (expected, expected + ".closed") or session_id not in claims:
                raise ValueError("путь семафора не подтверждает владельца")
            if slug is None or fields["slug"] == slug:
                matches.append({**fields, "_closed": path.name.endswith(".closed")})
        except (OSError, UnicodeError, ValueError, yaml.YAMLError, ObligationError) as exc:
            if filename_claim:
                raise ObligationError(f"не удалось подтвердить владельца карточки: {exc}") from exc
    opened = [item for item in matches if not item["_closed"]]
    candidates = opened or matches
    if len(candidates) > 1 and not opened:
        # Closed semaphores own no live work. One long harness session may run several peer sessions in a row, so
        # several closed ones share its id: the latest opened one is the owner, the rest are history. Several OPEN
        # semaphores stay a genuine ambiguity below.
        candidates = [max(candidates, key=lambda item: (item.get("opened_at", ""), item.get("created_at", ""),
                                                         item["session_id"]))]
    if len(candidates) > 1:
        raise ObligationError("неоднозначный владелец карточки: несколько семафоров")
    return candidates[0] if candidates else None


def _confirmed_governance_worktree(value: str) -> Path:
    """Accept only an existing, registered checkout of the governance repository."""
    root = Path(value)
    try:
        if not root.is_absolute() or root.resolve(strict=True) != root:
            raise ValueError("требуется абсолютный путь без symlink")
        def git(directory: Path, *args: str) -> str:
            return subprocess.run(
                ["git", "-C", str(directory), *args], capture_output=True, text=True,
                check=True, timeout=5, env={**os.environ, "GIT_OPTIONAL_LOCKS": "0"},
            ).stdout.strip()

        canonical = DS_ROOT.resolve(strict=True)
        common = (canonical / git(canonical, "rev-parse", "--git-common-dir")).resolve()
        candidate_common = (root / git(root, "rev-parse", "--git-common-dir")).resolve()
        registered = git(canonical, "worktree", "list", "--porcelain", "-z").split("\0")
        if candidate_common != common or registered.count(f"worktree {root}") != 1:
            raise ValueError("worktree не зарегистрирован в governance-репозитории")
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        raise ObligationError(f"не подтверждён governance_worktree владельца: {exc}") from exc
    return root


def _owner_card_identity(session_id: str | None, slug: str | None) -> tuple[dict | None, set[str], str | None]:
    if session_id is None:
        return None, set(), None
    _validated_name(session_id, "session_id")
    metadata = _card_owner_metadata(session_id, slug)
    if metadata is None or "governance_worktree" not in metadata:
        return None, {session_id}, None
    owners = {metadata[key] for key in ("session_id", "harness_session_id") if key in metadata}
    return metadata, owners, metadata["slug"]


def _owner_card_directory(metadata: dict | None) -> Path:
    if metadata is None:
        return CARDS_DIR
    if metadata.get("_closed"):
        retired = Path(metadata["governance_worktree"])
        try:
            retired.lstat()
        except FileNotFoundError:
            if not retired.is_absolute() or retired.resolve() != retired:
                raise ObligationError("путь закрытой рабочей копии не подтверждён")
            # Relocation survives worktree removal and a caller in another checkout.
            directory = Path(os.environ.get(
                "IWE_PROCESS_CARDS_DIR", str(DS_ROOT / "inbox" / "agent" / "tasks")))
            if directory.resolve() != directory:
                raise ObligationError("каталог перенесённых карточек содержит symlink")
            return directory
        except OSError as exc:
            raise ObligationError(f"не удалось проверить закрытую рабочую копию: {exc}") from exc
    root = _confirmed_governance_worktree(metadata["governance_worktree"])
    directory = root / "inbox" / "agent" / "tasks"
    if directory.resolve() != directory:
        raise ObligationError("каталог карточек владельца содержит symlink")
    return directory


def _read_card_at(path: Path) -> dict | None:
    run_id = path.stem.removeprefix("RUN-")
    try:
        _check_path_safe(path)
        text = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        return None
    except OSError as exc:
        raise ObligationError(f"не удалось прочитать карточку {run_id}: {exc}") from exc
    if not text.startswith("---"):
        raise ObligationError(f"карточка {run_id} без frontmatter")
    try:
        lines = text.splitlines()
        close_idx = None
        for i in range(1, len(lines)):
            if lines[i].rstrip("\r") == "---":
                close_idx = i
                break
        if close_idx is None:
            raise ObligationError("не найдена закрывающая граница ---")
        fm = "\n".join(lines[1:close_idx])
        card = yaml.safe_load(fm)
        if not isinstance(card, dict):
            raise ObligationError(f"карточка {run_id} не mapping")
        return card
    except (yaml.YAMLError, IndexError) as exc:
        raise ObligationError(f"карточка {run_id} повреждена: {exc}") from exc


def _read_card(run_id: str, session_id: str | None = None, slug: str | None = None) -> dict | None:
    _validated_name(run_id, "run_id")
    metadata, owners, expected_slug = _owner_card_identity(session_id, slug)
    card = _read_card_at(CARDS_DIR / f"RUN-{run_id}.md")
    # relocate-card returns the terminal card before deleting the isolate.
    # A closed guard's historical worktree need not still exist to verify it.
    if (card is not None and expected_slug is not None
            and isinstance(card.get("owner_session_id"), str)
            and card["owner_session_id"] in owners
            and card.get("requested_slug") == expected_slug
            and not _verify_card_identity(card, run_id)):
        return card
    directory = _owner_card_directory(metadata)
    if directory != CARDS_DIR:
        card = _read_card_at(directory / f"RUN-{run_id}.md")
    if card is None:
        return None
    # Existing local legacy cards may have no owner. Cross-worktree discovery
    # always needs both immutable ownership and the exact guard's slug.
    owner = card.get("owner_session_id")
    if owners and (owner is not None or expected_slug is not None) and (
            not isinstance(owner, str) or owner not in owners):
        raise ObligationError(f"карточка {run_id} принадлежит другому владельцу")
    if expected_slug is not None and card.get("requested_slug") != expected_slug:
        raise ObligationError(f"карточка {run_id} относится к другому slug")
    if expected_slug is not None and _verify_card_identity(card, run_id):
        raise ObligationError(f"карточка {run_id} не подтверждает идентичность прогона")
    return card


def _find_active_card_for_session(session_id: str, process_id: str = "quick-close") -> dict | None:
    """Fallback for the `armed` state below: obligation has no run_id yet (the
    ticket/consume handshake never linked one), so _read_card() can't be
    reached at all — but a runner might still be genuinely executing on this
    session's behalf if the PreToolUse hook that issues/injects the ticket
    missed this particular Bash invocation (bug-2026-08-18-close-runner-gate-
    marker-not-set-despite-active-card.md: raннер ran 11 steps to completion,
    /tmp marker never appeared). Scan the confirmed owner's worktree, matching
    immutable owner and slug. A corrupt card is skipped; ambiguous ownership
    or multiple active runs fail closed."""
    metadata, owners, expected_slug = _owner_card_identity(session_id, None)
    directory = _owner_card_directory(metadata)
    matches = []
    for path in directory.glob("RUN-*.md"):
        try:
            card = _read_card_at(path)
        except ObligationError:
            continue
        if card is None:
            continue
        if card.get("kind") != "process-run":
            continue
        if card.get("process_id") != process_id:
            continue
        if card.get("status") not in ("running", "waiting"):
            continue
        owner = card.get("owner_session_id")
        if not isinstance(owner, str) or owner not in owners:
            continue
        if expected_slug is not None and card.get("requested_slug") != expected_slug:
            continue
        if expected_slug is not None and (
                card.get("id") != path.stem or card.get("run_id") != path.stem.removeprefix("RUN-")):
            continue
        matches.append(card)
    if len(matches) > 1:
        raise ObligationError("неоднозначный активный прогон владельца")
    return matches[0] if matches else None


def _verify_card_identity(card: dict, run_id: str) -> list[str]:
    """Проверка, что карточка — именно тот прогон quick-close, который мы ожидаем."""
    problems: list[str] = []
    expected_id = f"RUN-{run_id}"
    if card.get("id") != expected_id:
        problems.append(f"id карточки {card.get('id')!r} ≠ ожидаемому {expected_id!r}")
    if card.get("kind") != "process-run":
        problems.append(f"kind={card.get('kind')!r}, ожидался process-run")
    if card.get("process_id") != "quick-close":
        problems.append(f"process_id={card.get('process_id')!r}, ожидался quick-close")
    if card.get("run_id") != run_id:
        problems.append(f"run_id карточки {card.get('run_id')!r} ≠ {run_id!r}")
    return problems


def _verify_completed_card(card: dict, obligation: dict) -> list[str]:
    """Машинная проверка обязательных результатов. Возвращает список нарушений."""
    problems: list[str] = []
    problems.extend(_verify_card_identity(card, obligation.get("run_id", "")))
    if problems:
        # Если идентичность не сходится, дальнейшая сверка бессмысленна
        return problems

    try:
        desc = yaml.safe_load(QUICK_CLOSE_YAML.read_text(encoding="utf-8"))
    except (OSError, yaml.YAMLError) as exc:
        return [f"не удалось прочитать quick-close.yaml: {exc}"]

    expected_version = desc.get("close_check_version")
    if card.get("close_check_version") != expected_version:
        problems.append(
            f"карточка создана без close_check_version={expected_version} "
            f"(в карточке: {card.get('close_check_version')!r}) — старая схема не удовлетворяет новую obligation"
        )
        return problems

    results = card.get("results") or {}
    if not isinstance(results, dict):
        problems.append("results карточки не словарь")
        return problems

    for step_id, step in (desc.get("steps") or {}).items():
        check = step.get("close_check")
        if not check:
            continue
        when = check.get("when")
        if when:
            ref = when.get("ref", "")
            if not ref:
                problems.append(f"schema violation: шаг {step_id} when без ref")
                continue
            actual = _resolve_ref(results, ref)
            if actual is None:
                # Невалидный/отсутствующий ref — это ошибка, не повод для skip
                problems.append(f"schema violation: шаг {step_id} when.ref={ref!r} не разрешён в результатах карточки")
                continue
            op = _OPS.get(when.get("op", "eq"))
            if op is None:
                problems.append(f"шаг {step_id}: неизвестный when.op={when.get('op')!r}")
                continue
            if not op(actual, when.get("value")):
                continue  # условие ложно — шаг не требуется
        expect_present = check.get("expect_present")
        if expect_present:
            if results.get(step_id) is None:
                problems.append(f"обязательный шаг {step_id} отсутствует в результатах")
            continue
        result = results.get(step_id)
        if result is None:
            problems.append(f"обязательный шаг {step_id} отсутствует в результатах")
            continue
        if not isinstance(result, dict):
            problems.append(f"шаг {step_id}: результат не словарь ({type(result).__name__})")
            continue
        for field, expected in (check.get("expect") or {}).items():
            actual = result.get(field)
            if not _expect_value_matches(actual, expected):
                problems.append(f"шаг {step_id}: поле {field} = {actual!r}, ожидалось {expected!r}")
    return problems


# WP-520 (case-insensitive string tokens) and WP-484 F250 (list = "any of") live in the
# shared module, the runner's AI-step intake uses the same function.
_expect_value_matches = expect_value_matches


def _ledger_find_events(kind: str, match: dict) -> list[dict]:
    """Вернуть все события kind в ledger, соответствующие match (равенство)."""
    events: list[dict] = []
    for delta in (0, 1):
        day = datetime.now() - timedelta(days=delta)
        doc = _load_ledger_day(day)
        for event in doc.get("events", []) or []:
            if _ledger_event_matches(event, kind, match):
                events.append(event)
    return events


def _ticket_issued_in_ledger(nonce: str, session_id: str, slug: str | None, obligation_id: str | None) -> tuple[bool, list[str]]:
    """Детекция фабрикации: consumed обязан иметь issued с совпадением nonce/session/slug/obligation_id.
    Возвращает (ok, список проблем)."""
    problems: list[str] = []
    base_match = {"nonce": nonce}
    events = _ledger_find_events("close_ticket_issued", base_match)
    if not events:
        problems.append(f"ticket {nonce[:8]}… потреблён без зарегистрированной выдачи в ledger — подозрение на фабрикацию")
        return False, problems
    for event in events:
        data = event.get("data") or {}
        if data.get("session_id") != session_id:
            problems.append(f"issued-ledger: session_id mismatch ({data.get('session_id')!r} ≠ {session_id!r})")
        # The hook issues the ticket before the runner starts, so it may carry the
        # unresolved-slug sentinel; cmd_consume_ticket already accepts it and keys on
        # the nonce. The completeness check must accept the same value, otherwise a
        # genuinely completed close is reported as incomplete (03.10.2026).
        if slug and data.get("slug") not in (slug, UNRESOLVED_SLUG_SENTINEL):
            problems.append(f"issued-ledger: slug mismatch ({data.get('slug')!r} ≠ {slug!r})")
        if obligation_id and data.get("obligation_id") != obligation_id:
            problems.append(f"issued-ledger: obligation_id mismatch ({data.get('obligation_id')!r} ≠ {obligation_id!r})")
    return (not problems), problems


def _ticket_consumed_in_ledger(nonce: str, run_id: str, session_id: str, slug: str | None, obligation_id: str | None) -> tuple[bool, list[str]]:
    """Проверка consumed-ledger. Возвращает (ok, список проблем)."""
    problems: list[str] = []
    base_match = {"nonce": nonce, "run_id": run_id}
    events = _ledger_find_events("close_ticket_consumed", base_match)
    if not events:
        problems.append(f"ticket {nonce[:8]}… нет consumed-записи в ledger")
        return False, problems
    for event in events:
        data = event.get("data") or {}
        if data.get("session_id") != session_id:
            problems.append(f"consumed-ledger: session_id mismatch ({data.get('session_id')!r} ≠ {session_id!r})")
        if slug and data.get("slug") != slug:
            problems.append(f"consumed-ledger: slug mismatch ({data.get('slug')!r} ≠ {slug!r})")
        if obligation_id and data.get("obligation_id") != obligation_id:
            problems.append(f"consumed-ledger: obligation_id mismatch ({data.get('obligation_id')!r} ≠ {obligation_id!r})")
    return (not problems), problems


def _read_runner_marker(session_id: str) -> dict | None:
    """Возвращает runner-маркер, если он существует, валиден и безопасен."""
    marker = _marker_path(session_id)
    return _load_json(marker)


def cmd_cancel_status(session_id: str) -> dict:
    """Read-only запрос (WP-537): признаёт ли ledger явную аудируемую отмену
    close-обязательства для этого session_id. Не мутирует состояние — в отличие
    от cmd_cancel, эта команда безопасна вызывать многократно (session-guard.sh
    close вызывает её на каждой попытке закрытия, не только на финальной).

    Обязательна проверка текущего obligation ПЕРЕД ledger: session_id не меняется
    между re-arm (cmd_arm допускает повторный arm того же session_id сколько
    угодно раз — каждый re-arm создаёт новый obligation_id, старый ledger-событие
    cancel-close остаётся). Без этой проверки отмена ПРЕДЫДУЩЕГО, уже закрытого
    цикла close (obligation A) засчиталась бы за ТЕКУЩИЙ, ещё не разрешённый
    re-armed цикл (obligation B) — тот же класс риска, которого ради
    obligation_id-сверки уже избегают _ticket_issued_in_ledger/
    _ticket_consumed_in_ledger (найдено cold-context review, WP-537, 18.08)."""
    _validated_name(session_id, "session_id")
    if _load_obligation(session_id) is not None:
        return {"cancelled": False}
    event = _find_cancel_event(session_id)
    if event is None:
        return {"cancelled": False}
    return {"cancelled": True, **event}


# --- running->armed evacuation (WP-484, peer-session 2026-08-31-43-close-
# obligation-orphan-recovery, consensus with Codex) -------------------------
#
# Origin: session 2026-08-31-37 fixed cmd_arm() to preserve a "running"
# obligation's identity across rearm instead of silently bulldozing it (bug
# fixed same day: mid-flight rearm used to orphan a completed run). Side
# effect, left open on purpose: if the runner underneath a "running"
# obligation crashes/hangs and process-runner.py's own idempotency lookup
# (_find_existing_run) fails to match the old card back (e.g. its
# harness-session mapping file is missing because the runner died before
# writing it), cmd_start() mints a NEW run_id and cmd_consume_ticket() then
# refuses forever with "obligation в состоянии running, ожидалось armed" --
# no automatic way out, only a pilot-driven cancel-close.
#
# This closes that loop using machinery that already exists and is already
# deployed, instead of a new watcher/PID-check/opt-in flag (four variants
# were on the table and deliberately not decided in session 37; this session
# designed and implemented a fifth with Codex): process-runner.py's
# _is_orphan()/reap machinery already retires a stuck card (same age +
# owner-session-closed evidence already trusted in production); this module
# already knows how to move a "running" obligation whose card turned out
# terminal back to "armed" (cmd_stop_check's failed/cancelled branch below).
# The two just never talked to each other outside the Stop event. cmd_start()
# now closes that gap on retry (see process-runner.py), calling the function
# below once it has confirmed (or just caused) the stale card to be
# terminal.
def _transition_running_to_armed(session_id: str, obligation: dict) -> None:
    """Mutates and persists `obligation` (running -> armed,
    needs_user_action=True). Caller MUST already hold
    _session_lock(session_id) -- this performs no locking of its own, so it
    can be shared between cmd_stop_check() (already inside that lock) and
    reconcile_terminal_running_obligation() below (a fresh external entry
    point that acquires the lock itself). Do not call this without the lock
    held -- see reconcile_terminal_running_obligation()'s docstring for why a
    nested acquire here would deadlock instead of just being redundant.

    Deliberately does NOT clear the runner marker (WP-484 "Второй случай"
    peer-session, 05.09): the only caller that reaches process-runner.py's
    cmd_start() afterward always re-consumes a ticket there, and
    cmd_consume_ticket() unconditionally overwrites the marker regardless of
    what it held before. Any future path to "armed" must preserve this same
    invariant (either clear the marker itself, like cmd_arm(), or guarantee
    an unconditional marker rewrite downstream, like this one)."""
    obligation["state"] = "armed"
    obligation["needs_user_action"] = True
    obligation["updated_at"] = now_iso()
    _atomic_write_json(_obligation_path(session_id), obligation)


def obligation_running_run_id(session_id: str) -> str | None:
    """Read-only: the run_id of the current obligation for `session_id` if
    and only if its state is "running", else None. Used by
    process-runner.py::cmd_start() to notice a stale running-generation whose
    card its own idempotency lookup (_find_existing_run) did NOT match --
    the caller decides whether that run_id's card is now terminal or
    orphan-eligible (process-runner.py's own _is_orphan()) before calling
    reconcile_terminal_running_obligation() with it as expected_run_id."""
    _validated_name(session_id, "session_id")
    obligation = _load_obligation(session_id)
    if obligation is None or obligation.get("state") != "running":
        return None
    return obligation.get("run_id")


def reconcile_terminal_running_obligation(session_id: str, expected_run_id: str) -> bool:
    """CAS-style running->armed evacuation for a caller OUTSIDE this module's
    own lock (process-runner.py::cmd_start()). Re-reads the obligation under
    _session_lock and only transitions it if BOTH state=="running" AND
    run_id==expected_run_id still hold at write time -- a mismatch means some
    other generation already replaced this one between the caller's read and
    this call, so this returns False and leaves the (different) current
    obligation untouched rather than overwriting a stale snapshot (found by
    Codex, session turn 1: a plain dict-in/dict-out interface would let a
    stale snapshot re-arm an already-replaced generation).

    Callers that already hold _session_lock(session_id) (cmd_stop_check, in
    this same module) must NOT call this -- flock() locks are per open file
    description, not reentrant within a process; a nested acquire here on a
    second fd would block forever waiting for the first to release. They call
    _transition_running_to_armed() directly instead, inside their own lock.
    """
    _validated_name(session_id, "session_id")
    _validated_name(expected_run_id, "run_id")
    with _session_lock(session_id):
        obligation = _load_obligation(session_id)
        if obligation is None or obligation.get("state") != "running":
            return False
        if obligation.get("run_id") != expected_run_id:
            return False
        _transition_running_to_armed(session_id, obligation)
        return True


def cmd_stop_check(session_id: str) -> dict:
    """Stop-матрица (консенсус ход 7). Вызывается protocol-stop-gate.sh."""
    _validated_name(session_id, "session_id")
    try:
        with _session_lock(session_id):
            from session_local_release import RECORD_ERRORS, harness_release_status
            try:
                local = harness_release_status(session_id)
            except RECORD_ERRORS as exc:
                return {"action": "block", "reason": "Не удалось проверить собственное локальное освобождение: " + str(exc)}
            if local.get("released"):
                return {"action": "allow", "note": "closed_local; publication pending"}
            if local.get("fenced"):
                return {"action": "block", "reason": "Локальное освобождение не подтверждено; восстанови квитанцию или повтори release-local."}
            obligation = _load_obligation(session_id)
            if obligation is None:
                if _is_peer_session_close_path(session_id):
                    return {
                        "action": "allow",
                        "note": "close_path=peer-session — раннер не требуется, Stop-гейт пропускает",
                    }
                return {"action": "allow"}

            # Поблажка пир-сессии (Ф133) -- только пока раннер obligation не
            # принял (armed без needs_user_action): running/failed обязано
            # пройти свою ветку ниже -- там верификация карточки и очистка,
            # которые ранний выход раньше пропускал (WP-484 п.22: закрытый
            # peer-семафор остаётся свежайшим до конца разговора, bool-поблажка
            # была бессрочной и маскировала новые намерения). Свежайший семафор
            # обязан всё ещё быть peer-session (более новый обычный семафор
            # снимает поблажку, как и до правки); новое поколение дополнительно
            # требует снимка "open" -- obligation взведено ПОКА пир-сессия была
            # открыта. Легаси-поколение без снимка: без этого условия.
            runner_not_engaged = (
                obligation.get("state") == "armed"
                and not obligation.get("needs_user_action")
            )
            exempt = runner_not_engaged and _is_peer_session_close_path(session_id)
            if exempt and "armed_under_peer_session" in obligation:
                exempt = obligation["armed_under_peer_session"] == "open"
            if exempt:
                return {
                    "action": "allow",
                    "note": "close_path=peer-session (obligation взведено внутри пир-сессии) — раннер не требуется, Stop-гейт пропускает",
                }

            state = obligation.get("state")
            mode = obligation.get("mode", "block")
            obligation_id = obligation.get("obligation_id")

            if state == "armed":
                # bug-2026-08-18-close-runner-gate-marker-not-set-despite-active-card.md:
                # если ticket не был инъецирован в конкретный Bash-вызов (нонс/hook
                # miss — гипотеза не подтверждена кодом этого модуля, живёт в
                # close-runner-gate.sh), obligation навсегда остаётся armed без
                # run_id, хотя раннер физически стартовал и работает — блок здесь
                # повторялся на каждом Stop, показывая пилоту неверную картину.
                # Fallback не меняет state (канонический переход armed→running
                # остаётся только через ticket-handshake, см. docstring модуля) --
                # только смягчает СООБЩЕНИЕ, когда независимая улика (активная
                # карточка того же процесса с owner_session_id этой сессии)
                # противоречит «раннер не запускался».
                rescue_card = _find_active_card_for_session(session_id)
                if rescue_card is not None:
                    return {
                        "action": "allow",
                        "note": (
                            f"obligation формально armed (ticket-handshake не завершился), но найдена "
                            f"активная карточка {rescue_card.get('run_id', '?')} этой же сессии на шаге "
                            f"{rescue_card.get('current_step', '?')} — покажи пилоту её реальный статус, "
                            "не заявляй «закрыто» и не игнорируй obligation молча."
                        ),
                    }
                # WP-484 (bug-2026-08-15-close-intent-sentinel-armed-by-quoted-text.md,
                # пир-сессия 2026-09-02-36 с Kimi+Codex, поймано cold-context
                # ревью после первого прохода писателя): "state=='armed' поэтому
                # run_id всегда None" -- НЕВЕРНО. _transition_running_to_armed()
                # (вызывается отсюда же ниже по файлу и из
                # reconcile_terminal_running_obligation) переводит зависший
                # running обратно в armed при терминальной карточке
                # (failed/cancelled), но НЕ трогает run_id/ticket_nonce -- они
                # остаются от завершившегося прогона. needs_user_action=True
                # ставится этим же переходом и с этого момента отличает
                # "реально был прогон, он упал, пилоту нужно показать ошибку" от
                # "раннер для этого obligation не запускался вообще" (свежий arm
                # /re-arm, run_id всегда None, needs_user_action всегда False).
                # Различаем именно по needs_user_action (не по run_id напрямую)
                # -- это то же поле, что уже читает ветка running/failed выше по
                # файлу (строка ~1418), один источник истины для одного факта.
                if obligation.get("needs_user_action"):
                    run_id = obligation.get("run_id", "?")
                    reason = (
                        f"В этой сессии был прогон process-runner.py start quick-close "
                        f"(run_id={run_id}), он завершился с ошибкой, пилоту это уже "
                        "показано — нужен повторный запуск раннера или явный cancel-close/"
                        "close-override от пилота. Это НЕ ложное срабатывание сторожа — "
                        "self-cancel здесь неуместен, раннер реально запускался и упал."
                    )
                else:
                    # Не меняем action на allow/warn (ослабило бы защиту — ровно для
                    # случая "пилот сказал закрывай, агент тихо не сделал этого" гейт
                    # и создан) — только явно уполномочиваем агента на аудируемый
                    # self-cancel вместо молчаливого зависания, если он сам определил
                    # ложное срабатывание (self-cancel уже легитимен и логируется в
                    # ledger, найдено живым прецедентом 02.09).
                    reason = (
                        "В этой сессии объявлено намерение закрыть сессию, но раннер "
                        "process-runner.py start quick-close ни разу не запускался. Если "
                        "это настоящая команда пилота закрыть сессию — запусти раннер. "
                        "Если это ложное срабатывание (слово «закрывай» попало в текст не "
                        "как команда — например, цитата или пересланный лог) — можешь сам "
                        "выполнить `python3 close_obligation.py cancel --session-id <id> "
                        "--action cancel-close --actor claude-code --reason \"<обоснование>\"`, "
                        "не дожидаясь пилота; действие аудируется в ledger."
                    )
                return {"action": "block" if mode == "block" else "warn", "reason": reason}

            if state != "running":
                return {"action": "block", "reason": f"obligation в неизвестном состоянии {state!r}"}

            run_id = obligation.get("run_id")
            if not run_id:
                return {"action": "block", "reason": "obligation running, но run_id не задан"}

            nonce = obligation.get("ticket_nonce")
            card = _read_card(run_id, session_id, obligation.get("slug"))

            # Карточка терминальна (completed/failed/cancelled) -> маркер не нужен: её
            # уже проверяет _verify_completed_card+ledger (ветка "completed" ниже) или
            # она сама признаёт свой финальный статус (ветка "failed"/"cancelled").
            # Маркер живёт в /tmp и не переживает часть путей завершения раннера --
            # требуем его только пока карточка ещё активна (waiting/running) или не
            # найдена вовсе, там он и остаётся доказательством легитимного старта.
            card_status = card.get("status") if card else None
            if card_status not in ("completed", "failed", "cancelled"):
                if nonce is not None:
                    marker = _read_runner_marker(session_id)
                    if marker is None:
                        return {"action": "block", "reason": "obligation running, но runner-маркер не найден"}
                    if marker.get("obligation_id") != obligation_id:
                        return {"action": "block", "reason": "runner-маркер относится к другому поколению obligation"}
                    if marker.get("run_id") != run_id:
                        return {"action": "block", "reason": "runner-маркер содержит другой run_id"}

            if card is None:
                return {"action": "block", "reason": f"obligation running, но карточка {run_id} не найдена"}

            card_status = card.get("status")
            if card_status == "waiting":
                return {
                    "action": "allow",
                    "note": f"quick-close ждёт ввода на шаге {card.get('current_step')} — покажи пилоту pending-вопрос, не заявляй «закрыто»",
                }
            if card_status == "running":
                return {
                    "action": "block",
                    "reason": f"прогон {run_id} брошен в состоянии running на шаге {card.get('current_step')} — продолжи process-runner.py next или попроси пилота о cancel-close",
                }
            if card_status in ("failed", "cancelled"):
                if obligation.get("needs_user_action"):
                    return {
                        "action": "block" if mode == "block" else "warn",
                        "reason": f"прогон {run_id} в статусе {card_status}, пилоту уже показана ошибка — нужен retry (process-runner.py start заново) или явный cancel-close/override пилота",
                    }
                _transition_running_to_armed(session_id, obligation)
                return {
                    "action": "allow",
                    "note": f"quick-close {run_id} завершился со статусом {card_status} — покажи пилоту конкретную ошибку и run_id, не заявляй «закрыто»",
                }
            if card_status == "completed":
                problems = _verify_completed_card(card, obligation)
                if nonce is not None:
                    # armed-generation: обязательны обе ledger-записи с точным match
                    ok, ledger_problems = _ticket_issued_in_ledger(nonce, session_id, obligation.get("slug"), obligation_id)
                    problems.extend(ledger_problems)
                    ok2, ledger_problems2 = _ticket_consumed_in_ledger(nonce, run_id, session_id, obligation.get("slug"), obligation_id)
                    problems.extend(ledger_problems2)
                if problems:
                    return {
                        "action": "block",
                        "reason": "карточка completed, но машинная проверка полноты не прошла:\n- " + "\n- ".join(problems),
                    }
                path = _obligation_path(session_id)
                _check_path_safe(path)
                path.unlink()
                _clear_runner_marker(session_id)
                # WP-520: protocol-stop-gate.sh больше не стирает close-intent sentinel
                # безусловно на каждом Stop (стирало уже после первого ответа агента,
                # хотя Quick Close растягивается на несколько ходов) -- терминальная
                # очистка переехала сюда, к единственному месту, где completed уже
                # прошёл машинную проверку полноты.
                sentinel = Path("/tmp/iwe-close-intent") / f"{_session_safe(session_id)}.flag"
                sentinel.unlink(missing_ok=True)
                return {"action": "allow", "note": "close obligation verified and cleared"}

            return {"action": "block", "reason": f"карточка {run_id} в неизвестном статусе {card_status!r}"}
    except ObligationError as exc:
        # Любая внутренняя ошибка валидации = fail-closed для Stop-гейта
        return {"action": "block", "reason": f"ошибка проверки close-obligation: {exc}"}


# --- cli ------------------------------------------------------------------------


def main(argv: list | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("arm")
    p.add_argument("--session-id", required=True)
    p.add_argument("--mode", required=True, choices=["block", "warn"])

    p = sub.add_parser("cancel")
    p.add_argument("--session-id", required=True)
    p.add_argument("--action", required=True, choices=["cancel-close", "close-override", "peer-session-close"])
    p.add_argument("--actor", default="pilot")
    p.add_argument("--reason", default="")
    p.add_argument("--force", action="store_true", help="удалить obligation даже при отказе ledger")

    p = sub.add_parser("record-intent")
    p.add_argument("--session-id", required=True)
    p.add_argument("--raw-text", default="")
    p.add_argument("--skip-reflection", choices=["true", "false"], default="false")
    p.add_argument(
        "--technical-authorized",
        choices=["true", "false"],
        default="false",
        help="устанавливать только после repo/diff allowlist-проверки process-runner",
    )
    p.add_argument(
        "--technical-scope",
        default=None,
        help="id проверенной allowlist-записи для аудита",
    )

    p = sub.add_parser("read-intent")
    p.add_argument("--session-id", required=True)

    p = sub.add_parser("issue-ticket")
    p.add_argument("--session-id", required=True)
    p.add_argument("--slug", required=True)
    p.add_argument("--tool-use-id", default="")

    p = sub.add_parser("consume-ticket")
    p.add_argument("--nonce", required=True)
    p.add_argument("--slug", required=True)
    p.add_argument("--run-id", required=True)
    p.add_argument("--process-id", default="quick-close")

    p = sub.add_parser("void-ticket")
    p.add_argument("--detail", default="")
    p.add_argument("--nonce", required=True)
    p.add_argument("--reason", default="start_rejected")

    p = sub.add_parser("stop-check")
    p.add_argument("--session-id", required=True)

    p = sub.add_parser("cancel-status")
    p.add_argument("--session-id", required=True)

    p = sub.add_parser("mode")
    p.add_argument("--session-id", required=True)

    args = parser.parse_args(argv)
    try:
        if args.command == "arm":
            out = cmd_arm(args.session_id, args.mode)
        elif args.command == "cancel":
            out = cmd_cancel(args.session_id, args.action, args.actor, args.reason, force=args.force)
        elif args.command == "record-intent":
            out = cmd_record_intent(
                args.session_id,
                args.raw_text,
                skip_reflection=args.skip_reflection == "true",
                technical_authorized=args.technical_authorized == "true",
                technical_scope=args.technical_scope,
            )
        elif args.command == "read-intent":
            out = cmd_read_intent(args.session_id)
        elif args.command == "issue-ticket":
            print(cmd_issue_ticket(args.session_id, args.slug, args.tool_use_id))
            return 0
        elif args.command == "consume-ticket":
            out = cmd_consume_ticket(args.nonce, args.slug, args.run_id, args.process_id)
        elif args.command == "void-ticket":
            out = cmd_void_ticket(args.nonce, args.reason, args.detail)
        elif args.command == "stop-check":
            out = cmd_stop_check(args.session_id)
        elif args.command == "cancel-status":
            out = cmd_cancel_status(args.session_id)
        elif args.command == "mode":
            print(cmd_mode(args.session_id))
            return 0
        else:  # pragma: no cover
            parser.error("unknown command")
        print(json.dumps(out, ensure_ascii=False))
        return 0
    except ObligationError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
