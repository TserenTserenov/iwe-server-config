#!/usr/bin/env python3
"""wp-session-launch.py — run one headless work session for one phase attempt.

WP-530 F161 (input И-19 from WP-626; peer-session 2026-11-25-12 with Kimi and
Codex, cold review). The WP Manager (WP-626 v0) hands over a task package;
this launcher runs exactly one attempt, sequentially, and leaves a delivery
manifest.

Steps (each is recorded in the manifest before the next one starts):
  1. syntax-check wp and attempt_id, create the attempt directory (mkdir is
     the uniqueness lock), write the first manifest, validate the package;
  2. open a machine session in a private isolated copy of the governance
     repository: session-guard.sh open --isolate --close-path
     machine-publish-only --owner-pid <this pid>, IWE_SESSION_ID=<uuid4>;
  3. run the agent in that copy under a deadline, in its own process group,
     and stop the whole group afterwards;
  4. check the copy is still the same git checkout, then collect changes;
     anything outside allowed_paths, symlinks, submodules, new ignored files
     outside allowed_paths, commits made by the agent or extra files next to
     the decisions file refuse the attempt: the work is kept as a patch, the
     copy is reset to its base and the session is released unpublished;
  5. claim and commit the allowed changes, re-check the real commit, then
     session-guard.sh machine-close publishes it (isolate-push) — once: a
     failed close is never retried here, a lost answer may hide a publication;
  6. look the commit up on origin/main by its Launch-Attempt trailer (blob
     hashes compared with the manifest), patch-id as a fallback:
     publication confirmed / absent / unknown.

Boundary of v0 (agreed with Codex, confirmed by the live probe of 25.11):
the launcher guarantees that only changes inside allowed_paths get published.
It is NOT a process sandbox: Claude Code's acceptEdits mode let the agent
write a file outside the copy. The agent runs with the copy's own
.claude/settings.json; the hooks of ~/IWE/.claude are not assumed to apply.
Paths the commit hooks execute (.githooks, scripts, .claude, git config
files at any depth) can never be allowed, so the agent cannot publish a change
to code run at commit. Every new ignored file refuses the attempt: it would
never be published, so a result written there would be lost silently.

Delivery target of v0 is origin/main. WP-626 revision 2 expects a run branch
(run/<run_id>) instead; until that mode exists the launcher is not used with
the WP Manager (WP-530 F161).

Signals: SIGTERM, SIGHUP and SIGINT stop the agent and release the session.
During machine-close and the publication check a signal is only recorded
(stopped_by_signal) — stopping the guard mid-publication would leave the
outcome unknown. A final manifest with session_open: true means: run
retry_close; the exit code is then never 0.

The manifest (manifest.json in the attempt directory) is rewritten atomically
through a uniquely named temporary file next to it; readers read only
manifest.json. `final: true` appears only in the last write. An attempt
directory without a manifest is an unfinished registration; final:false with
no live launcher (check host + launcher_pid + started_at) means "unknown,
reconcile first", never "start a duplicate". needs_reconcile: true means the
launcher refused to touch the session (copy identity changed, reset failed).

Exit codes: 0 delivered or no-changes · 2 launcher failure, bad package or
commit refused by a hook · 3 rejected (executor broke the contract) ·
4 executor failed or timed out · 5 delivery not confirmed.

Test seams work only with --test-mode: IWE_LAUNCH_SESSION_GUARD (guard path),
IWE_LAUNCH_AGENT_CMD (agent command), IWE_LAUNCH_TEST_TIMEOUT_SEC (agent
deadline), IWE_LAUNCH_TEST_CLOSE_TIMEOUT_SEC (machine-close deadline).
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import re
import signal
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path

CONTRACT_VERSION = "wp-launch/v1"
MANIFEST_SCHEMA = "wp-launch-manifest/v1"
SEMAPHORE_AGENT = "claude-code"
DECISIONS_DIR = ".wp-launch"
DECISIONS_REL = f"{DECISIONS_DIR}/decisions.json"
DECISIONS_MAX_BYTES = 256 * 1024
# Top-level paths the commit hooks run or read: never publishable.
FORBIDDEN_TOP = {DECISIONS_DIR, ".githooks", "scripts", ".claude", ".github"}
# Git's own files: never publishable at any depth.
FORBIDDEN_ANY = {".git", ".gitattributes", ".gitmodules", ".gitignore"}
SAFE_TOKEN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
MODEL_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$")
WP_ID = re.compile(r"^WP-[1-9][0-9]*$")
ONE_LINE = re.compile(r"^[^\x00-\x1f\x7f]{1,200}$")
TIMEOUT_MIN_MAX = 180  # below the session lease (4 h) with room for open, commit and close
CLOSE_TIMEOUT_S = 900
EXIT_OK, EXIT_LAUNCHER, EXIT_REJECTED, EXIT_EXECUTOR, EXIT_DELIVERY = 0, 2, 3, 4, 5
STATUS_EXIT = {
    "delivered": EXIT_OK,
    "no-changes": EXIT_OK,
    "launcher-failed": EXIT_LAUNCHER,
    "commit-refused": EXIT_LAUNCHER,
    "rejected-paths": EXIT_REJECTED,
    "rejected-agent-commit": EXIT_REJECTED,
    "executor-failed": EXIT_EXECUTOR,
    "timeout": EXIT_EXECUTOR,
    "max-turns": EXIT_EXECUTOR,
    "committed-not-published": EXIT_DELIVERY,
    "published-close-failed": EXIT_DELIVERY,
    "delivery-unknown": EXIT_DELIVERY,
    "delivery-failed": EXIT_DELIVERY,
}
# The only permission profile of v0. No git diff/log: their --output writes files.
# git rm/mv only stage; whatever they touch still passes the path checks before publication.
AGENT_TOOLS = ["Read", "Grep", "Glob", "Edit", "Write", "Bash(ls:*)", "Bash(git status:*)",
               "Bash(git rm:*)", "Bash(git mv:*)"]
SCRUBBED_ENV = ("CLAUDE_PID", "CLAUDECODE", "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE",
                "GIT_COMMON_DIR", "GIT_OBJECT_DIRECTORY")


class LaunchError(Exception):
    """A failure with a known status and a machine-readable detail."""

    def __init__(self, status: str, source: str, detail: str, reconcile: bool = False):
        super().__init__(detail)
        self.status, self.source, self.detail, self.reconcile = status, source, detail, reconcile


class Stopped(Exception):
    """The launcher received SIGTERM, SIGHUP or SIGINT."""


class SignalGate:
    """Raises Stopped on a signal, except inside deferred(): there it only records it."""

    def __init__(self):
        self.deferring = False
        self.received: str | None = None

    def handle(self, signum: int, _frame) -> None:
        name = signal.Signals(signum).name
        if self.deferring:
            self.received = self.received or name
            return
        for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
            signal.signal(sig, signal.SIG_IGN)  # let the cleanup below finish
        raise Stopped(f"запускатель получил сигнал {name}")

    def deferred(self, manifest: "Manifest"):
        gate = self

        class _Deferred:
            def __enter__(self):
                gate.deferring = True

            def __exit__(self, *_exc):
                gate.deferring = False
                if gate.received:
                    manifest.stage(stopped_by_signal=gate.received)
                return False

        return _Deferred()


SIGNALS = SignalGate()


def now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    return sha256_bytes(path.read_bytes())


def clean_env() -> dict:
    env = {k: v for k, v in os.environ.items()
           if k not in SCRUBBED_ENV and not k.startswith("CLAUDE_CODE_")}
    env["GIT_LITERAL_PATHSPECS"] = "1"
    return env


def git(repo: Path, *args: str, check: bool = True, binary: bool = False) -> subprocess.CompletedProcess:
    return subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=not binary,
                          check=check, env=clean_env())


class Manifest:
    """The delivery manifest, rewritten atomically at every stage."""

    def __init__(self, attempt_dir: Path, data: dict):
        self.path = attempt_dir / "manifest.json"
        self.data = data

    def stage(self, name: str | None = None, **fields) -> None:
        self.data.update(fields, updated_at=now_iso())
        if name:
            self.data["stage"] = name
        self._write()

    def finish(self, status: str, source: str | None, detail: str | None) -> None:
        self.data.update(status=status, failure_source=source, failure_detail=detail,
                         final=True, finished_at=now_iso(), updated_at=now_iso())
        self._write()

    def _write(self) -> None:
        fd, tmp = tempfile.mkstemp(prefix=".manifest-", dir=self.path.parent)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(self.data, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, self.path)


class Seams:
    """Test-only overrides; empty unless the launcher runs with --test-mode."""

    def __init__(self, test_mode: bool, iwe_root: Path):
        env = os.environ if test_mode else {}
        self.guard = Path(env.get("IWE_LAUNCH_SESSION_GUARD") or iwe_root / "scripts" / "session-guard.sh")
        self.agent_cmd = env.get("IWE_LAUNCH_AGENT_CMD")
        self.agent_timeout = int(env["IWE_LAUNCH_TEST_TIMEOUT_SEC"]) if env.get("IWE_LAUNCH_TEST_TIMEOUT_SEC") else None
        self.close_timeout = int(env.get("IWE_LAUNCH_TEST_CLOSE_TIMEOUT_SEC") or CLOSE_TIMEOUT_S)


# --- package -----------------------------------------------------------------

def normalize_path(raw: object, *, publishable: bool) -> str:
    """Normalize a package path; publishable paths must not touch hook-run or git files."""
    if not isinstance(raw, str) or not raw.strip():
        raise LaunchError("launcher-failed", "launcher", f"путь пакета пуст: {raw!r}")
    path = raw.strip().replace("\\", "/")
    while path.startswith("./"):
        path = path[2:]
    parts = [p for p in path.split("/") if p]
    if path.startswith("/") or not parts or any(p in (".", "..") for p in parts):
        raise LaunchError("launcher-failed", "launcher", f"недопустимый путь пакета {raw!r}")
    if publishable and forbidden(parts):
        raise LaunchError("launcher-failed", "launcher",
                          f"путь {raw!r} запрещён: его исполняют или читают проверки коммита")
    return "/".join(parts)


def forbidden(parts: list[str]) -> bool:
    return parts[0] in FORBIDDEN_TOP or any(p in FORBIDDEN_ANY for p in parts)


def path_allowed(path: str, allowed: list[str]) -> bool:
    return any(path == prefix or path.startswith(prefix + "/") for prefix in allowed)


def validate_package(pkg: dict, iwe_root: Path) -> dict:
    def need(cond: bool, detail: str) -> None:
        if not cond:
            raise LaunchError("launcher-failed", "launcher", f"пакет: {detail}")

    need(pkg.get("contract_version") == CONTRACT_VERSION, f"contract_version должен быть {CONTRACT_VERSION}")
    for key in ("phase_id", "launched_by"):
        need(isinstance(pkg.get(key), str) and ONE_LINE.match(pkg[key]) is not None,
             f"{key}: одна строка до 200 знаков без управляющих символов")
    governance = os.environ.get("IWE_GOVERNANCE_REPO") or "DS-my-strategy"
    need(pkg.get("repo") == governance, f"repo: в v0 только хранилище управления {governance}")
    repo_dir = iwe_root / governance
    need((repo_dir / ".git").exists(), f"хранилище {governance} не найдено в {iwe_root}")
    need(pkg.get("agent") == "claude", "agent: в v0 поддерживается только claude")
    need(isinstance(pkg.get("model"), str) and MODEL_NAME.match(pkg["model"]) is not None, "model обязателен")
    need(isinstance(pkg.get("prompt"), str) and pkg["prompt"].strip() != "", "prompt пуст")
    for key, upper in (("timeout_min", TIMEOUT_MIN_MAX), ("max_turns", 500)):
        value = pkg.get(key)
        need(isinstance(value, int) and not isinstance(value, bool) and 1 <= value <= upper,
             f"{key}: целое 1..{upper}")
    need(pkg.get("permission_profile", "edit-only") == "edit-only", "permission_profile: в v0 только edit-only")
    allowed = pkg.get("allowed_paths")
    need(isinstance(allowed, list) and allowed, "allowed_paths: непустой список")
    inputs = pkg.get("inputs", [])
    need(isinstance(inputs, list), "inputs: список путей")
    return {
        "repo_dir": repo_dir,
        "governance": governance,
        "allowed": sorted({normalize_path(a, publishable=True) for a in allowed}),
        "inputs": [normalize_path(i, publishable=False) for i in inputs],
    }


# --- session-guard ------------------------------------------------------------

def session_env(iwe_root: Path, governance: str, session_id: str) -> dict:
    env = clean_env()
    env.update(IWE_ROOT=str(iwe_root), IWE_GOVERNANCE_REPO=governance, IWE_SESSION_ID=session_id,
               IWE_AGENT=SEMAPHORE_AGENT, OWNER_PID=str(os.getpid()))
    return env


def open_session(ctx: dict, pkg: dict, manifest: Manifest) -> Path | None:
    task = f"wp-launch {pkg['wp']} {pkg['phase_id']} attempt {pkg['attempt_id']} by {pkg['launched_by']}"
    proc = subprocess.run(
        ["bash", str(ctx["guard"]), "open", "--wp", pkg["wp"], "--agent", SEMAPHORE_AGENT,
         "--task", task, "--slug", ctx["slug"], "--isolate", "--owner-pid", str(os.getpid()),
         "--close-path", "machine-publish-only"],
        cwd=ctx["repo_dir"], env=ctx["env"], capture_output=True, text=True)
    (ctx["attempt_dir"] / "session-open.log").write_text(
        f"rc={proc.returncode}\n{proc.stdout}\n--- stderr ---\n{proc.stderr}", encoding="utf-8")
    if proc.returncode != 0:
        raise LaunchError("launcher-failed", "launcher",
                          f"session-guard open вернул {proc.returncode}: {proc.stderr.strip()[-400:]}")
    # From here the session may exist even if the answer below is unusable.
    manifest.stage("opened", session_open=True,
                   retry_close={"operation": "machine-close", "tool": "scripts/session-guard.sh",
                                "agent": SEMAPHORE_AGENT, "session_id": ctx["session_id"],
                                "target": "origin/main"})
    info = next((json.loads(line) for line in reversed(proc.stdout.splitlines())
                 if line.strip().startswith("{") and line.strip().endswith("}")), {})
    worktree = Path(info["worktree_path"]) if info.get("worktree_path") else None
    if info.get("session_id") != ctx["session_id"] or worktree is None or not worktree.is_dir():
        raise LaunchError("launcher-failed", "launcher", "session-guard open: в ответе нет копии этой сессии")
    manifest.stage(worktree_path=str(worktree))
    return worktree


def run_owned(cmd: list[str], *, cwd: Path, env: dict, timeout_s: int, out, err,
              on_start=None) -> int | None:
    """Run in its own process group; on deadline stop the group. None = deadline passed."""
    proc = subprocess.Popen(cmd, cwd=cwd, env=env, stdout=out, stderr=err,
                            stdin=subprocess.DEVNULL, start_new_session=True)
    try:
        if on_start:
            on_start(proc.pid)
        return proc.wait(timeout=timeout_s)
    except subprocess.TimeoutExpired:
        return None
    finally:
        stop_group(proc)  # also on Stopped: nothing of the group outlives the launcher


def group_alive(proc: subprocess.Popen) -> bool:
    """True while any process of the group exists; reaps the leader first,
    because an unreaped (zombie) leader keeps killpg(…, 0) succeeding.
    macOS answers EPERM for a group left with zombies only; the group is ours
    (same user), so EPERM means it has finished."""
    proc.poll()
    try:
        os.killpg(proc.pid, 0)
    except (ProcessLookupError, PermissionError):
        return False
    return True


def stop_group(proc: subprocess.Popen) -> None:
    for sig, grace in ((signal.SIGTERM, 30), (signal.SIGKILL, 10)):
        if not group_alive(proc):
            return
        try:
            os.killpg(proc.pid, sig)
        except (ProcessLookupError, PermissionError):  # see group_alive
            return
        deadline = time.monotonic() + grace
        while time.monotonic() < deadline and group_alive(proc):
            time.sleep(0.2)
    if group_alive(proc):
        raise LaunchError("launcher-failed", "launcher", f"группа процессов {proc.pid} не остановилась",
                          reconcile=True)


def machine_close(ctx: dict) -> tuple[int, str]:
    """rc 124 = deadline passed (the guard's group was stopped; publication unknown)."""
    log_path = ctx["attempt_dir"] / "machine-close.log"
    with log_path.open("ab") as log:
        log.write(f"[{now_iso()}] machine-close\n".encode())
        log.flush()
        rc = run_owned(["bash", str(ctx["guard"]), "machine-close", "--agent", SEMAPHORE_AGENT,
                        "--session-id", ctx["session_id"]],
                       cwd=ctx["iwe_root"], env=ctx["env"], timeout_s=ctx["seams"].close_timeout,
                       out=log, err=log)
    rc = 124 if rc is None else rc
    tail = log_path.read_text(encoding="utf-8", errors="replace").strip()[-400:]
    return rc, tail


def claim_paths(ctx: dict, worktree: Path, paths: list[str]) -> None:
    listing = ctx["attempt_dir"] / "claim-paths.nul"
    listing.write_bytes(b"".join(p.encode() + b"\0" for p in paths))
    proc = subprocess.run(
        ["bash", str(ctx["guard"]), "note-file", "--paths-from0", str(listing), "--repo-root", str(worktree),
         "--wp", ctx["wp"], "--slug", ctx["slug"], "--agent", SEMAPHORE_AGENT],
        cwd=worktree, env=ctx["env"], capture_output=True, text=True)
    if proc.returncode != 0:
        raise LaunchError("commit-refused", "launcher",
                          f"заявка путей (note-file) вернула {proc.returncode}: {proc.stderr.strip()[-300:]}")


# --- agent ----------------------------------------------------------------------

def build_prompt(pkg: dict, allowed: list[str]) -> str:
    allowed_text = "\n".join(f"  - {a}" for a in allowed)
    return f"""Автономная рабочая сессия (запускатель РП-530, контракт {CONTRACT_VERSION}).
Пилот согласовал эту работу заранее через Менеджера РП — Ритуал не нужен, работай сразу.
РП: {pkg['wp']} · фаза: {pkg['phase_id']} · попытка: {pkg['attempt_id']}

Рамка (нарушение = попытка отклонена, работа пропадёт):
- Текущий каталог — отдельная копия хранилища только для этой попытки. Работай только в нём.
- Писать можно только в эти пути (относительно текущего каталога):
{allowed_text}
  и в один служебный файл {DECISIONS_REL} (исключение из списка выше; в публикацию не попадёт).
- Не коммить, не публикуй, не открывай и не закрывай сессии IWE — это сделает запускатель.
- Свои решения запиши в файл {DECISIONS_REL} (JSON-список объектов: id, kind И|Ф|Ц,
  question, options, choice, basis, right auto|confirm|pilot-only, depends_on).
  Развилку, которая требует решения пилота, запиши с right "pilot-only" и choice null и не решай её сам.
- Последним сообщением дай краткий итог: что сделано, что не сделано и почему.

Задание:
{pkg['prompt']}
"""


def agent_command(ctx: dict, pkg: dict, prompt_file: Path) -> list[str]:
    if ctx["seams"].agent_cmd:
        return [ctx["seams"].agent_cmd, str(prompt_file)]
    return ["claude", "-p", prompt_file.read_text(encoding="utf-8"), "--session-id", ctx["session_id"],
            "--model", pkg["model"], "--max-turns", str(pkg["max_turns"]), "--output-format", "json",
            "--permission-mode", "acceptEdits", "--allowedTools", *AGENT_TOOLS]


def read_agent_result(attempt_dir: Path) -> dict:
    """claude --output-format json prints one JSON object; anything else is kept raw."""
    raw = (attempt_dir / "agent.out").read_text(encoding="utf-8", errors="replace").strip()
    try:
        data = json.loads(raw) if raw else {}
    except json.JSONDecodeError:
        data = None
    if not isinstance(data, dict):
        return {"summary": raw[-2000:], "parsed": False}
    return {"parsed": True, "subtype": data.get("subtype"), "is_error": data.get("is_error"),
            "num_turns": data.get("num_turns"), "cost_usd": data.get("total_cost_usd"),
            "summary": (data.get("result") or "")[-4000:]}


# --- the copy -------------------------------------------------------------------------

def copy_identity(worktree: Path) -> dict:
    """What makes the copy this session's own checkout; re-checked after the agent."""
    git_file = worktree / ".git"
    return {
        "git_file_sha256": sha256_file(git_file) if git_file.is_file() and not git_file.is_symlink() else None,
        "git_dir": git(worktree, "rev-parse", "--absolute-git-dir").stdout.strip(),
        "branch": git(worktree, "rev-parse", "--abbrev-ref", "HEAD").stdout.strip(),
    }


def verify_copy(worktree: Path, expected: dict) -> None:
    try:
        actual = copy_identity(worktree)
    except (OSError, subprocess.CalledProcessError) as exc:
        actual = {"error": str(exc)}
    if actual != expected:
        raise LaunchError("launcher-failed", "executor",
                          f"копия подменена во время работы агента: было {expected}, стало {actual}",
                          reconcile=True)


def changed_paths(worktree: Path) -> list[tuple[str, str]]:
    """(change, path) for every uncommitted change, renames split into delete + add."""
    out = git(worktree, "status", "--porcelain=v1", "-z", "--untracked-files=all", "--no-renames").stdout
    result = []
    for entry in filter(None, out.split("\0")):
        code, path = entry[:2], entry[3:]
        if "D" in code:
            change = "deleted"
        elif code == "??" or "A" in code:
            change = "added"
        else:
            change = "modified"
        result.append((change, path))
    return result


def ignored_paths(worktree: Path) -> set[str]:
    out = git(worktree, "status", "--porcelain=v1", "-z", "--ignored=matching", "--untracked-files=all").stdout
    return {entry[3:] for entry in filter(None, out.split("\0")) if entry.startswith("!!")}


def take_decisions(worktree: Path, attempt_dir: Path) -> tuple[object, str | None, str | None]:
    """Move the executor's decisions out of the copy; it is untrusted data.

    Returns (decisions, note, refusal). A refusal leaves the folder in place so
    the caller keeps it in the rejected patch and resets the copy.
    """
    folder = worktree / DECISIONS_DIR
    if not os.path.lexists(folder):
        return None, "исполнитель не записал файл решений", None
    if folder.is_symlink() or not folder.is_dir():
        return None, None, f"{DECISIONS_DIR} не обычный каталог"
    extra = sorted(p.name for p in folder.iterdir() if p.name != "decisions.json")
    if extra:
        return None, None, f"посторонние файлы в {DECISIONS_DIR}: {extra[:10]}"
    path = folder / "decisions.json"
    if path.is_symlink() or not path.is_file():
        return None, None, f"{DECISIONS_REL} не обычный файл"
    if path.stat().st_size > DECISIONS_MAX_BYTES:
        return None, None, f"{DECISIONS_REL} больше {DECISIONS_MAX_BYTES} байт"
    data = path.read_bytes()
    (attempt_dir / "decisions.json").write_bytes(data)
    path.unlink()
    folder.rmdir()
    try:
        return json.loads(data.decode("utf-8")), None, None
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        return None, f"файл решений не JSON: {exc}", None


def unsafe_path(worktree: Path, path: str) -> str | None:
    """Reason to refuse publishing `path`, or None. Symlinks and submodules are out of v0."""
    parts = path.split("/")
    if forbidden(parts) or any(p in ("", ".", "..") for p in parts):
        return "служебный или неоднозначный путь"
    current = worktree
    for part in parts:
        current = current / part
        if current.is_symlink():
            return "символическая ссылка"
    if current.is_dir():
        return "каталог или подмодуль"
    return None


def refusals(worktree: Path, paths: list[str], new_ignored: set[str], allowed: list[str]) -> list[str]:
    found = [f"{p} ({why})" for p in paths
             if (why := "вне allowed_paths" if not path_allowed(p, allowed) else unsafe_path(worktree, p))]
    found += [f"{p} (новый игнорируемый файл: он не публикуется)" for p in sorted(new_ignored)]
    return found


def pathspec_file(attempt_dir: Path, name: str, paths: list[str]) -> Path:
    listing = attempt_dir / name
    listing.write_bytes(b"".join(p.encode() + b"\0" for p in paths))
    return listing


def stage_changes(worktree: Path, attempt_dir: Path, changes: list[tuple[str, str]]) -> None:
    """Stage exactly these changes; a deletion may already be staged (git mv)."""
    removed = [p for c, p in changes if c == "deleted"]
    kept = [p for c, p in changes if c != "deleted"]
    if removed:
        spec = pathspec_file(attempt_dir, "stage-removed.nul", removed)
        git(worktree, "rm", "--cached", "-q", "--ignore-unmatch", f"--pathspec-from-file={spec}",
            "--pathspec-file-nul")
    if kept:
        spec = pathspec_file(attempt_dir, "stage-kept.nul", kept)
        git(worktree, "add", f"--pathspec-from-file={spec}", "--pathspec-file-nul")


def discard_attempt(worktree: Path, base: str, attempt_dir: Path) -> None:
    """Keep the refused work as a patch against base, then return the copy to base.

    The copy belongs to this attempt only; resetting it lets machine-close
    release the session without publishing anything.
    """
    changes = changed_paths(worktree)
    # A directory entry is a nested repository: git cannot stage it; name it, clean removes it.
    nested = [p for _, p in changes if p.endswith("/")]
    if nested:
        (attempt_dir / "rejected-nested-repos.txt").write_text("\n".join(nested) + "\n", encoding="utf-8")
    stage_changes(worktree, attempt_dir, [(c, p) for c, p in changes if not p.endswith("/")])
    patch = git(worktree, "diff", "--binary", "--cached", base, binary=True).stdout
    (attempt_dir / "rejected.patch").write_bytes(patch)
    git(worktree, "reset", "-q", "--hard", base)
    git(worktree, "clean", "-ffdq")


def commit_changes(ctx: dict, worktree: Path, changes: list[tuple[str, str]], pkg: dict) -> str:
    paths = [p for _, p in changes]
    claim_paths(ctx, worktree, paths)
    stage_changes(worktree, ctx["attempt_dir"], changes)
    message = ctx["attempt_dir"] / "commit-message.txt"
    message.write_text(
        f"wp-launch({pkg['wp']}): {pkg['phase_id']} attempt {pkg['attempt_id']}\n\n"
        f"Launch-Attempt: {pkg['attempt_id']}\nLaunch-WP: {pkg['wp']}\nLaunch-Contract: {CONTRACT_VERSION}\n"
        f"Launched-By: {pkg['launched_by']}\n", encoding="utf-8")
    spec = pathspec_file(ctx["attempt_dir"], "commit-paths.nul", paths)
    proc = subprocess.run(["git", "-C", str(worktree), "commit", "-F", str(message),
                           f"--pathspec-from-file={spec}", "--pathspec-file-nul"],
                          env=ctx["env"], capture_output=True, text=True)
    (ctx["attempt_dir"] / "commit.log").write_text(proc.stdout + proc.stderr, encoding="utf-8")
    if proc.returncode != 0:
        raise LaunchError("commit-refused", "launcher",
                          f"git commit вернул {proc.returncode}: {(proc.stderr or proc.stdout).strip()[-400:]}")
    return git(worktree, "rev-parse", "HEAD").stdout.strip()


def commit_violations(worktree: Path, base: str, commit: str, allowed: list[str]) -> list[str]:
    """Check what would really be published: commit hooks may change the index."""
    count = git(worktree, "rev-list", "--count", f"{base}..{commit}").stdout.strip()
    problems = [] if count == "1" else [f"между базой и коммитом {count} коммитов, ожидался 1"]
    raw = git(worktree, "diff", "--raw", "-z", "--no-renames", base, commit).stdout.split("\0")
    for meta, path in zip(raw[0::2], raw[1::2]):
        if not meta:
            continue
        if not path_allowed(path, allowed) or forbidden(path.split("/")):
            problems.append(f"{path} (вне allowed_paths)")
        elif meta.split()[1] in ("120000", "160000"):
            problems.append(f"{path} (ссылка или подмодуль)")
    return problems


# --- publication -------------------------------------------------------------------

def check_publication(ctx: dict, commit: str, artifacts: list[dict]) -> dict:
    """Is this attempt on origin/main? confirmed / absent / unknown.

    Delivery is a cherry-pick that may be rebuilt on moved files, so the SHA and
    even the patch-id may differ. First the trailer Launch-Attempt (with blob
    hashes compared to the manifest), then patch-id since the attempt started.
    A failed fetch or a trailer commit with other content is "unknown".
    """
    repo, attempt = ctx["repo_dir"], ctx["attempt_id"]
    record = {"remote": "origin", "branch": "main", "checked_at": now_iso()}
    if git(repo, "fetch", "-q", "origin", "main", check=False).returncode != 0:
        return {**record, "state": "unknown", "detail": "git fetch origin main не прошёл"}
    head = git(repo, "rev-parse", "origin/main").stdout.strip()
    since = ["--since", ctx["started_at"]]
    hits = git(repo, "log", "origin/main", *since, "--format=%H", "--fixed-strings",
               "--grep", f"Launch-Attempt: {attempt}").stdout.split()
    for sha in hits:
        trailers = git(repo, "log", "-1", "--format=%(trailers:only,unfold)", sha).stdout.splitlines()
        if f"Launch-Attempt: {attempt}" in trailers and f"Launch-WP: {ctx['wp']}" in trailers:
            mismatch = content_mismatch(repo, sha, artifacts)
            if mismatch:
                return {**record, "state": "unknown", "method": "trailer", "published_commit": sha,
                        "checked_head": head, "detail": f"коммит попытки найден, но содержимое другое: {mismatch}"}
            return {**record, "state": "confirmed", "method": "trailer", "published_commit": sha,
                    "checked_head": head}
    want = patch_id(repo, commit)
    if want is None:
        return {**record, "state": "unknown", "detail": f"patch-id коммита {commit} не вычислен"}
    for sha in git(repo, "log", "origin/main", *since, "--format=%H").stdout.split():
        if patch_id(repo, sha) == want:
            return {**record, "state": "confirmed", "method": "patch-id", "published_commit": sha,
                    "checked_head": head}
    return {**record, "state": "absent", "checked_head": head}


def content_mismatch(repo: Path, sha: str, artifacts: list[dict]) -> str | None:
    for item in artifacts:
        shown = git(repo, "show", f"{sha}:{item['path']}", check=False, binary=True)
        if item["change"] == "deleted":
            if shown.returncode == 0:
                return f"{item['path']} не удалён"
        elif shown.returncode != 0 or sha256_bytes(shown.stdout) != item["sha256"]:
            return f"{item['path']} отличается"
    return None


def patch_id(repo_dir: Path, sha: str) -> str | None:
    show = git(repo_dir, "show", "--format=", sha, check=False, binary=True).stdout
    proc = subprocess.run(["git", "-C", str(repo_dir), "patch-id", "--stable"], input=show,
                          capture_output=True)
    return proc.stdout.split()[0].decode() if proc.stdout.strip() else None


def deliver(ctx: dict, commit: str, artifacts: list[dict], manifest: Manifest) -> str:
    """One machine-close, never repeated here: a lost answer may hide a done publication."""
    manifest.stage("closing", close_attempted=True)
    with SIGNALS.deferred(manifest):  # stopping the guard mid-publication hides the outcome
        rc_close, detail = machine_close(ctx)
        if rc_close == 0:
            manifest.stage("closed", session_open=False)
        publication = check_publication(ctx, commit, artifacts)
        manifest.stage("verified", publication=publication)
    state = publication["state"]
    if state == "unknown" or (rc_close == 124 and state == "absent"):
        raise LaunchError("delivery-unknown", "delivery",
                          f"machine-close вернул {rc_close}; публикация не установлена: "
                          f"{publication.get('detail', 'закрытие прервано по сроку')}")
    if rc_close != 0:
        status = "published-close-failed" if state == "confirmed" else "committed-not-published"
        raise LaunchError(status, "delivery", f"machine-close вернул {rc_close}: {detail}")
    if state == "absent":
        raise LaunchError("delivery-failed", "delivery", "machine-close прошёл, но попытки нет на origin/main")
    return "delivered"


# --- main flow ---------------------------------------------------------------------

def run(pkg: dict, iwe_root: Path, attempt_dir: Path, manifest: Manifest, seams: Seams) -> str:
    checked = validate_package(pkg, iwe_root)
    session_id = str(uuid.uuid4())
    ctx = {
        "iwe_root": iwe_root, "repo_dir": checked["repo_dir"], "attempt_dir": attempt_dir,
        "guard": seams.guard, "seams": seams, "session_id": session_id, "wp": pkg["wp"],
        "attempt_id": pkg["attempt_id"], "started_at": manifest.data["started_at"],
        "slug": f"launch-{pkg['wp'].lower()}-{pkg['attempt_id']}"[:96],
        "env": session_env(iwe_root, checked["governance"], session_id),
    }
    manifest.stage("validated", allowed_paths=checked["allowed"], session_id=session_id,
                   slug=ctx["slug"], repo=pkg["repo"])
    worktree = None
    try:
        worktree = open_session(ctx, pkg, manifest)
        return work(ctx, pkg, checked, worktree, manifest)
    except LaunchError as exc:
        if exc.reconcile:
            manifest.stage(needs_reconcile=True)
        raise
    finally:
        if manifest.data.get("session_open") and not manifest.data.get("close_attempted") \
                and not manifest.data.get("needs_reconcile"):
            release_unpublished(ctx, worktree, manifest)


def release_unpublished(ctx: dict, worktree: Path | None, manifest: Manifest) -> None:
    """Release a session that must not publish: reset its copy to base, then close.

    If the copy cannot be shown to be back at base, the session is left open
    for reconciliation: closing it would publish whatever is there. Without a
    recorded base the failure came before the agent ran, so the copy is still
    as session-guard created it.
    """
    base = manifest.data.get("isolated_base")
    try:
        if worktree is not None and base:
            dirty = git(worktree, "status", "--porcelain", "--untracked-files=all").stdout.strip()
            if dirty or git(worktree, "rev-parse", "HEAD").stdout.strip() != base:
                discard_attempt(worktree, base, ctx["attempt_dir"])
                manifest.stage(copy_reset_after_failure=True)
            if git(worktree, "rev-parse", "HEAD").stdout.strip() != base \
                    or git(worktree, "status", "--porcelain", "--untracked-files=all").stdout.strip():
                raise LaunchError("launcher-failed", "launcher", "копия не вернулась к базе")
    except (LaunchError, OSError, subprocess.CalledProcessError) as exc:
        manifest.stage(needs_reconcile=True, reconcile_reason=f"сброс копии не удался: {exc}")
        return
    manifest.stage(close_attempted=True)
    with SIGNALS.deferred(manifest):
        rc, detail = machine_close(ctx)
    if rc == 0:
        manifest.stage(session_open=False)
    else:
        manifest.stage(session_close_error=f"{rc}: {detail}")


def work(ctx: dict, pkg: dict, checked: dict, worktree: Path, manifest: Manifest) -> str:
    repo_common = git(ctx["repo_dir"], "rev-parse", "--path-format=absolute", "--git-common-dir").stdout.strip()
    common = git(worktree, "rev-parse", "--path-format=absolute", "--git-common-dir").stdout.strip()
    toplevel = git(worktree, "rev-parse", "--show-toplevel").stdout.strip()
    if Path(toplevel).resolve() != worktree.resolve() or Path(common).resolve() != Path(repo_common).resolve():
        raise LaunchError("launcher-failed", "launcher", f"копия {worktree} не принадлежит {ctx['repo_dir']}")
    identity = copy_identity(worktree)
    base = git(worktree, "rev-parse", "HEAD").stdout.strip()
    ignored_before = ignored_paths(worktree)
    inputs = [{"path": p, "sha256": sha256_file(worktree / p) if (worktree / p).is_file() else None}
              for p in checked["inputs"]]
    manifest.stage("prepared", isolated_base=base, copy_identity=identity, inputs=inputs)

    attempt_dir, allowed = ctx["attempt_dir"], checked["allowed"]
    prompt_file = attempt_dir / "prompt.md"
    prompt_file.write_text(build_prompt(pkg, allowed), encoding="utf-8")
    timeout_s = ctx["seams"].agent_timeout or pkg["timeout_min"] * 60
    with (attempt_dir / "agent.out").open("wb") as out, (attempt_dir / "agent.err").open("wb") as err:
        rc = run_owned(agent_command(ctx, pkg, prompt_file), cwd=worktree, env=ctx["env"],
                       timeout_s=timeout_s, out=out, err=err,
                       on_start=lambda pid: manifest.stage("agent-running", agent_pid=pid))
    verify_copy(worktree, identity)  # before any git command trusts the copy
    result = read_agent_result(attempt_dir)
    manifest.stage("agent-done", agent_exit=rc, agent_timed_out=rc is None, agent_result=result)

    head = git(worktree, "rev-parse", "HEAD").stdout.strip()
    decisions, decisions_note, decisions_refusal = take_decisions(worktree, attempt_dir)
    changes = changed_paths(worktree)
    paths = [p for _, p in changes]
    new_ignored = ignored_paths(worktree) - ignored_before
    if new_ignored:
        (attempt_dir / "rejected-ignored.txt").write_text("\n".join(sorted(new_ignored)) + "\n", encoding="utf-8")
    manifest.stage("collected", decisions=decisions, decisions_note=decisions_note,
                   changes_present=bool(paths),
                   agent_commits=git(worktree, "rev-list", f"{base}..{head}").stdout.split())

    if head != base:
        raise LaunchError("rejected-agent-commit", "executor",
                          f"исполнитель сам сделал коммит(ы) {base[:12]}..{head[:12]}; рамка запрещает")
    refused = refusals(worktree, paths, new_ignored, allowed)
    if decisions_refusal:
        refused.insert(0, decisions_refusal)
    if refused:
        raise LaunchError("rejected-paths", "executor", "нельзя публиковать: " + "; ".join(refused[:20]))
    if rc is None:
        raise LaunchError("timeout", "executor", f"исполнитель не уложился в {timeout_s} с")
    if rc != 0 or result.get("is_error"):
        status = "max-turns" if result.get("subtype") == "error_max_turns" else "executor-failed"
        raise LaunchError(status, "executor", f"исполнитель завершился кодом {rc}, {result.get('subtype')}")
    if not paths:
        return "no-changes"

    artifacts = [{"path": p, "change": c, "sha256": sha256_file(worktree / p) if c != "deleted" else None}
                 for c, p in changes]
    manifest.stage("committing", artifacts=artifacts)
    commit = commit_changes(ctx, worktree, changes, pkg)
    manifest.stage("committed", commit=commit)
    problems = commit_violations(worktree, base, commit, allowed)
    if problems:
        manifest.stage(commit=None, discarded_commit=commit)
        raise LaunchError("launcher-failed", "launcher",
                          "коммит после проверок отличается от проверенного набора: " + "; ".join(problems[:20]))
    return deliver(ctx, commit, artifacts, manifest)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Запустить одну рабочую сессию по пакету задания")
    parser.add_argument("--package", required=True, type=Path, help="JSON-пакет задания от Менеджера РП")
    parser.add_argument("--runtime-dir", type=Path,
                        help="каталог попыток (по умолчанию $IWE_ROOT/.iwe-runtime/wp-launch)")
    parser.add_argument("--test-mode", action="store_true", help="разрешить тестовые подмены (только сценарии)")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    iwe_root = Path(os.environ.get("IWE_ROOT") or Path.home() / "IWE")
    try:
        pkg = json.loads(args.package.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        print(f"wp-session-launch: пакет не прочитан: {exc}", file=sys.stderr)
        return EXIT_LAUNCHER
    wp, attempt = (pkg.get("wp"), pkg.get("attempt_id")) if isinstance(pkg, dict) else (None, None)
    if not (isinstance(wp, str) and WP_ID.match(wp) and isinstance(attempt, str) and SAFE_TOKEN.match(attempt)):
        print("wp-session-launch: пакет без корректных wp (WP-N) и attempt_id (латиница, цифры, ._-)",
              file=sys.stderr)
        return EXIT_LAUNCHER
    runtime_dir = (args.runtime_dir or iwe_root / ".iwe-runtime" / "wp-launch").expanduser().resolve()
    attempt_dir = runtime_dir / wp / attempt
    attempt_dir.parent.mkdir(parents=True, exist_ok=True)
    try:
        attempt_dir.mkdir()
    except FileExistsError:
        print(f"wp-session-launch: попытка {attempt} для {wp} уже была ({attempt_dir}); новая попытка — новый attempt_id",
              file=sys.stderr)
        return EXIT_LAUNCHER
    manifest = Manifest(attempt_dir, {
        "schema": MANIFEST_SCHEMA, "contract_version": pkg.get("contract_version"),
        "wp": wp, "phase_id": pkg.get("phase_id"), "attempt_id": attempt,
        "agent": pkg.get("agent"), "model": pkg.get("model"), "launched_by": pkg.get("launched_by"),
        "launcher_pid": os.getpid(), "host": os.uname().nodename,
        "started_at": now_iso(), "final": False, "session_open": False,
    })
    manifest.stage("created")
    (attempt_dir / "package.json").write_text(json.dumps(pkg, ensure_ascii=False, indent=2), encoding="utf-8")
    for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
        signal.signal(sig, SIGNALS.handle)
    try:
        status, source, detail = run(pkg, iwe_root, attempt_dir, manifest, Seams(args.test_mode, iwe_root)), None, None
    except LaunchError as exc:
        status, source, detail = exc.status, exc.source, exc.detail
    except Stopped as exc:
        status, source, detail = "launcher-failed", "launcher", str(exc)
        if manifest.data.get("commit") and manifest.data.get("close_attempted") \
                and not manifest.data.get("publication"):
            status, source = "delivery-unknown", "delivery"
    except Exception as exc:  # the manifest must still say what happened
        status, source, detail = "launcher-failed", "launcher", f"{type(exc).__name__}: {exc}"
    code = STATUS_EXIT[status]
    if code == EXIT_OK and manifest.data.get("session_open"):
        code = EXIT_DELIVERY  # the session is still open: retry_close is owed
    manifest.data["exit_code"] = code
    manifest.finish(status, source, detail)
    print(json.dumps({"status": status, "exit_code": code, "manifest": str(manifest.path)}, ensure_ascii=False))
    return code


if __name__ == "__main__":
    sys.exit(main())
