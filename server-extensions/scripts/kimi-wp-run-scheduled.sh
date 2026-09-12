#!/usr/bin/env bash
# see DP.SC.192, DP.ROLE.086 — WP-487
#
# kimi-wp-run-scheduled.sh <id> — исполнитель отложенного запуска РП.
# Вызывается launchd в заданное время. Шаги:
#   1. прочитать задание из queue.tsv
#   2. session-guard open → preflight (kimi) → headless-запуск агента под таймаутом
#   3. статус (done/failed/timeout) → report.md + queue.tsv
#   4. session-guard close, самоудаление одноразовой задачи launchd
#
# Предохранитель токенов: crash-safe supervisor для Kimi, wall-clock таймаут
# для остальных агентов (default 50 мин) + --max-turns у Claude. Падение одного
# РП не влияет на остальную очередь.

set -uo pipefail  # без -e: любой сбой должен завершаться отчётом, а не тихой смертью

SCHEDULER_SOURCE="${BASH_SOURCE[0]}"
SCHEDULER_DIR="${SCHEDULER_SOURCE%/*}"
[ "$SCHEDULER_DIR" != "$SCHEDULER_SOURCE" ] || SCHEDULER_DIR=.
SCHEDULER_SELF="$(cd "$SCHEDULER_DIR" && pwd)/${SCHEDULER_SOURCE##*/}"

resolve_scheduler_python() {
  local resolver candidate resolved bash_bin find_bin resolver_diagnostic=""
  local python_probe
  python_probe='import fcntl, os, secrets, select, signal, stat; assert all(hasattr(os, n) for n in ("execvpe", "fork", "getpgrp", "pread", "pwrite", "set_blocking", "setpgid", "setsid"))'
  resolver="${IWE_SCHED_PYTHON_RESOLVER:-${IWE_ROOT:-$HOME/IWE}/DS-my-strategy/scripts/lib/find-python3.sh}"
  bash_bin="${BASH:-$(command -v bash 2>/dev/null || true)}"
  if [ -f "$resolver" ] && [ -x "$bash_bin" ]; then
    if resolved=$("$bash_bin" "$resolver" --stdlib-only 2>&1) \
       && [ -n "$resolved" ] \
       && "$resolved" -c "$python_probe" >/dev/null 2>&1; then
      printf '%s\n' "$resolved"
      return 0
    else
      resolver_diagnostic="$resolved"
    fi
  fi
  for candidate in \
    "$(command -v python3 2>/dev/null || true)" \
    /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
    [ -n "$candidate" ] && [ -x "$candidate" ] || continue
    if "$candidate" -c "$python_probe" >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  if [ -d /nix/store ]; then
    find_bin=$(command -v find 2>/dev/null || true)
    [ -n "$find_bin" ] || find_bin=/usr/bin/find
    while IFS= read -r candidate; do
      if [ -x "$candidate" ] \
         && "$candidate" -c "$python_probe" >/dev/null 2>&1; then
        printf '%s\n' "$candidate"
        return 0
      fi
    done < <("$find_bin" /nix/store -maxdepth 3 -name python3 -path '*env*/bin/*' 2>/dev/null)
  fi
  [ -z "$resolver_diagnostic" ] || printf '%s\n' "$resolver_diagnostic" >&2
  echo "ERROR: Python 3 со стандартными модулями fcntl/select не найден; Kimi не запущен." >&2
  return 69
}

# run_kimi_with_oauth_lineage <timeout-s> <stdin-file> <log-file> <command> [args...]
#
# After an explicit quiescent cutover, the legacy pathname is a permanent
# fail-closed fence whose numeric field is -1.  Old and rolled-back schedulers
# therefore never reach their stale check-then-rm branch.  Current lineage
# metadata lives at a separate v4 pathname which only flock-aware producers
# touch.  A controller and its direct sentinel share that permanent flock and
# the exact v4 handles; Kimi cannot pass its launch gate until both have adopted
# its isolated PGID.  Either survivor of one SIGKILL drains the whole group;
# the vendor inherits the flock as the double-fault backstop.
run_oauth_lineage_python() {
  local operation="${1:?operation required}"
  shift
  local timeout_seconds="${1:?timeout required}"
  local stdin_file="${2:?stdin file required}"
  local log_file="${3:?log file required}"
  shift 3
  local oauth_wait_seconds="${IWE_PEER_OAUTH_LOCK_TIMEOUT_SECONDS:-90}"
  local lock_root="${IWE_PEER_LOCK_DIR:-/tmp/kimi-peer-locks}"
  local python_bin

  case "$timeout_seconds" in
    ''|*[!0-9]*|0) return 64 ;;
  esac
  case "$oauth_wait_seconds" in
    ''|*[!0-9]*|0) return 64 ;;
  esac
  if [ "$operation" = run ]; then
    [ "$#" -gt 0 ] || return 64
  elif [ "$operation" != cutover ]; then
    return 64
  fi
  python_bin=$(resolve_scheduler_python) || return $?

  "$python_bin" - "$operation" "$timeout_seconds" "$oauth_wait_seconds" "$lock_root" \
    "$$" "$stdin_file" "$log_file" "$@" <<'PY'
import errno
import fcntl
import os
import secrets
import select
import signal
import stat
import sys
import time

(
    operation,
    timeout_text,
    oauth_wait_text,
    lock_root,
    owner_pid_text,
    stdin_path,
    log_path,
    *command,
) = sys.argv[1:]
timeout_seconds = int(timeout_text)
oauth_wait_seconds = int(oauth_wait_text)
owner_pid = int(owner_pid_text)
oauth_lease_path = os.path.join(lock_root, "kimi-oauth-refresh.lease")
legacy_fence_path = os.path.join(lock_root, "kimi-oauth-refresh.lockdir")
oauth_bridge_path = os.path.join(lock_root, "kimi-oauth-refresh.lineage-v4")
nonce = secrets.token_hex(16)
bridge_target = f"kimi-oauth-refresh.lineage-v4.{nonce}"
bridge_private_path = os.path.join(lock_root, bridge_target)
owner_payload = None
fence_target = None
fence_private_path = None
fence_owner_payload = None
stop_signal = 0
lease_fd = None
lease_value = None
fence_value = None
fence_private_value = None
fence_pid_fd = None
fence_pid_value = None
fence_owner_fd = None
fence_owner_value = None
bridge_value = None
bridge_private_value = None
bridge_pid_fd = None
bridge_pid_value = None
bridge_owner_fd = None
bridge_owner_value = None
bridge_holder_token = None
supervisor_pgid = None
sentinel_pid = None
vendor_pid = None
vendor_status = None

NOFOLLOW = getattr(os, "O_NOFOLLOW", 0)
CLOEXEC = getattr(os, "O_CLOEXEC", 0)
CREATE_FLAGS = os.O_RDWR | os.O_CREAT | NOFOLLOW | CLOEXEC
EXCLUSIVE_FLAGS = os.O_RDWR | os.O_CREAT | os.O_EXCL | NOFOLLOW | CLOEXEC


def emit(message):
    if log_path == "-":
        sys.stderr.write(f"[oauth-lineage] {message}\n")
        return
    try:
        with open(log_path, "a", encoding="utf-8") as stream:
            stream.write(f"[oauth-lineage] {message}\n")
    except OSError as exc:
        sys.stderr.write(f"WARN: cannot append OAuth-lineage diagnostic: {exc}\n")


def same_inode(left, right):
    return (left.st_dev, left.st_ino) == (right.st_dev, right.st_ino)


def path_names_inode(path, value):
    return same_inode(os.lstat(path), value)


def ensure_owned_directory(path):
    os.makedirs(path, mode=0o700, exist_ok=True)
    value = os.lstat(path)
    if not stat.S_ISDIR(value.st_mode) or value.st_uid != os.getuid():
        raise RuntimeError(f"unsafe OAuth lock directory: {path}")
    os.chmod(path, 0o700)


def open_owned_regular(path):
    descriptor = os.open(path, CREATE_FLAGS, 0o600)
    value = os.fstat(descriptor)
    if (not stat.S_ISREG(value.st_mode)
            or value.st_uid != os.getuid()
            or value.st_nlink != 1
            or not path_names_inode(path, value)):
        os.close(descriptor)
        raise RuntimeError(f"unsafe OAuth lease file: {path}")
    os.fchmod(descriptor, 0o600)
    return descriptor, value


def open_existing_owned_regular(path):
    descriptor = os.open(path, os.O_RDWR | NOFOLLOW | CLOEXEC)
    value = os.fstat(descriptor)
    if (not stat.S_ISREG(value.st_mode)
            or value.st_uid != os.getuid()
            or value.st_nlink != 1
            or not path_names_inode(path, value)):
        os.close(descriptor)
        raise RuntimeError(f"unsafe OAuth bridge file: {path}")
    return descriptor, value


def publish_owned_regular(path, payload):
    descriptor = os.open(path, EXCLUSIVE_FLAGS, 0o600)
    try:
        os.write(descriptor, (payload + "\n").encode("ascii"))
        os.fsync(descriptor)
        value = os.fstat(descriptor)
        if (not stat.S_ISREG(value.st_mode)
                or value.st_uid != os.getuid()
                or value.st_nlink != 1
                or not path_names_inode(path, value)):
            raise RuntimeError(f"unsafe OAuth bridge file: {path}")
        return descriptor, value
    except Exception:
        os.close(descriptor)
        raise


def read_ascii(descriptor, limit=256):
    # Metadata is an exact protocol payload.  Silently dropping corrupt bytes
    # could turn a tampered file back into the expected token.
    return os.pread(descriptor, limit, 0).decode("ascii", "strict").strip()


def scheduler_gone():
    return os.getppid() != owner_pid


def request_stop(signum, _frame):
    global stop_signal
    stop_signal = signum


def group_alive(pgid):
    try:
        os.killpg(pgid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def poll_vendor():
    global vendor_status
    if vendor_pid is None or vendor_status is not None:
        return vendor_status
    try:
        waited_pid, status_value = os.waitpid(vendor_pid, os.WNOHANG)
    except ChildProcessError:
        return vendor_status
    if waited_pid:
        if os.WIFEXITED(status_value):
            vendor_status = os.WEXITSTATUS(status_value)
        elif os.WIFSIGNALED(status_value):
            vendor_status = -os.WTERMSIG(status_value)
        else:
            raise RuntimeError("unexpected stopped Kimi wait status")
    return vendor_status


def drain_process_group(pgid, reason, reap_vendor=False):
    if pgid is None:
        return
    if reap_vendor:
        poll_vendor()
    if group_alive(pgid):
        emit(f"stopping Kimi process group {pgid}: {reason}")
        try:
            os.killpg(pgid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        except PermissionError:
            emit(f"cannot TERM Kimi process group {pgid}; retaining locks")
        term_deadline = time.monotonic() + 2.0
        while time.monotonic() < term_deadline and group_alive(pgid):
            if reap_vendor:
                poll_vendor()
            time.sleep(0.05)
    if group_alive(pgid):
        # Re-check immediately before KILL.  Once the old group vanishes, do
        # not signal the numeric PGID again: it could later be reused.
        try:
            os.killpg(pgid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        except PermissionError:
            emit(f"cannot KILL Kimi process group {pgid}; retaining locks")
    # No timeout-unlock here.  Permission-unknown or a still-observable group
    # is not proof of death, so both OAuth authorities remain held.
    while group_alive(pgid):
        if reap_vendor:
            poll_vendor()
        time.sleep(0.05)
    if reap_vendor:
        while poll_vendor() is None:
            time.sleep(0.01)


def lease_fault():
    if lease_fd is None:
        return None
    try:
        return None if path_names_inode(oauth_lease_path, lease_value) else "lease-replaced"
    except FileNotFoundError:
        return "lease-missing"


def bridge_fault(expected_holders=None, allow_pid_adoption=False):
    global bridge_pid_fd, bridge_pid_value, bridge_holder_token
    if bridge_value is None:
        return None
    if expected_holders is None:
        expected_holders = (bridge_holder_token,)
    expected_payloads = {str(holder) for holder in expected_holders}
    pid_path = os.path.join(bridge_private_path, "pid")
    owner_path = os.path.join(bridge_private_path, "owner")
    try:
        link_value = os.lstat(oauth_bridge_path)
        if (not same_inode(link_value, bridge_value)
                or not stat.S_ISLNK(link_value.st_mode)
                or link_value.st_uid != os.getuid()
                or os.readlink(oauth_bridge_path) != bridge_target):
            return "bridge-link-changed"
        private_value = os.lstat(bridge_private_path)
        if (bridge_private_value is None
                or not same_inode(private_value, bridge_private_value)
                or not stat.S_ISDIR(private_value.st_mode)
                or private_value.st_uid != os.getuid()
                or stat.S_IMODE(private_value.st_mode) != 0o700):
            return "bridge-private-directory-changed"

        pid_is_current = (
            bridge_pid_fd is not None
            and path_names_inode(pid_path, bridge_pid_value)
            and read_ascii(bridge_pid_fd) in expected_payloads
        )
        if not pid_is_current and allow_pid_adoption:
            candidate_fd, candidate_value = open_existing_owned_regular(pid_path)
            candidate_payload = read_ascii(candidate_fd)
            if candidate_payload in expected_payloads:
                old_fd = bridge_pid_fd
                bridge_pid_fd = candidate_fd
                bridge_pid_value = candidate_value
                bridge_holder_token = candidate_payload
                if old_fd is not None:
                    os.close(old_fd)
                pid_is_current = True
            else:
                os.close(candidate_fd)
        if not pid_is_current:
            return "bridge-pid-changed"
        if (bridge_owner_fd is None
                or not path_names_inode(owner_path, bridge_owner_value)
                or read_ascii(bridge_owner_fd) != owner_payload):
            return "bridge-owner-changed"
    except FileNotFoundError:
        return "bridge-missing"
    except UnicodeError:
        return "bridge-metadata-nonascii"
    return None


def acquire_permanent_lease(deadline):
    global lease_fd, lease_value
    candidate_fd, candidate_value = open_owned_regular(oauth_lease_path)
    while True:
        if scheduler_gone() or stop_signal:
            os.close(candidate_fd)
            return False
        try:
            fcntl.flock(candidate_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except OSError as exc:
            if exc.errno not in (errno.EACCES, errno.EAGAIN):
                os.close(candidate_fd)
                raise
        if time.monotonic() >= deadline:
            os.close(candidate_fd)
            return False
        time.sleep(0.05)
    if not path_names_inode(oauth_lease_path, candidate_value):
        os.close(candidate_fd)
        raise RuntimeError("OAuth lease identity changed during acquisition")
    lease_fd = candidate_fd
    lease_value = candidate_value
    return True


def wait_at_test_barrier(variable_name):
    barrier = os.environ.get(variable_name)
    if not barrier:
        return
    ready_path = f"{barrier}.ready"
    release_path = f"{barrier}.release"
    with open(ready_path, "w", encoding="ascii") as stream:
        stream.write(f"{os.getpid()}\n")
        stream.flush()
        os.fsync(stream.fileno())
    while not os.path.exists(release_path):
        if scheduler_gone() or stop_signal:
            raise RuntimeError(f"abandoned test barrier: {variable_name}")
        time.sleep(0.02)


def publish_test_value(variable_name, value):
    path = os.environ.get(variable_name)
    if not path:
        return
    with open(path, "w", encoding="ascii") as stream:
        stream.write(f"{value}\n")
        stream.flush()
        os.fsync(stream.fileno())


def fsync_directory(path):
    flags = os.O_RDONLY | CLOEXEC | getattr(os, "O_DIRECTORY", 0)
    descriptor = os.open(path, flags)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def prepare_private_bridge():
    global bridge_private_value, bridge_holder_token, owner_payload
    global bridge_pid_fd, bridge_pid_value, bridge_owner_fd, bridge_owner_value
    os.mkdir(bridge_private_path, 0o700)
    bridge_private_value = os.lstat(bridge_private_path)
    if (not stat.S_ISDIR(bridge_private_value.st_mode)
            or bridge_private_value.st_uid != os.getuid()):
        raise RuntimeError("unsafe private OAuth bridge directory")
    os.chmod(bridge_private_path, 0o700)
    wait_at_test_barrier("IWE_SCHED_TEST_OAUTH_PRIVATE_MKDIR_BARRIER")

    bridge_holder_token = f"-{supervisor_pgid}"
    owner_payload = (
        f"iwe-oauth-lineage-v4 {lease_value.st_dev} "
        f"{lease_value.st_ino} {nonce}"
    )
    bridge_pid_fd, bridge_pid_value = publish_owned_regular(
        os.path.join(bridge_private_path, "pid"), bridge_holder_token,
    )
    wait_at_test_barrier("IWE_SCHED_TEST_OAUTH_PRIVATE_PID_BARRIER")
    bridge_owner_fd, bridge_owner_value = publish_owned_regular(
        os.path.join(bridge_private_path, "owner"), owner_payload,
    )
    fsync_directory(bridge_private_path)


def acquire_runtime_bridge(deadline):
    global bridge_value
    private_prepared = False
    while True:
        if scheduler_gone() or stop_signal:
            return False
        fault = lease_fault() or fence_fault()
        if fault:
            raise RuntimeError(f"OAuth authority lost before launch: {fault}")
        try:
            existing = os.lstat(oauth_bridge_path)
        except FileNotFoundError:
            if not private_prepared:
                prepare_private_bridge()
                private_prepared = True
            try:
                os.symlink(bridge_target, oauth_bridge_path)
            except FileExistsError:
                continue
            bridge_value = os.lstat(oauth_bridge_path)
            if (not stat.S_ISLNK(bridge_value.st_mode)
                    or bridge_value.st_uid != os.getuid()
                    or os.readlink(oauth_bridge_path) != bridge_target
                    or bridge_fault()):
                raise RuntimeError("unsafe published OAuth bridge symlink")
            fsync_directory(lock_root)
            return True
        else:
            if stat.S_ISLNK(existing.st_mode):
                recovered = recover_abandoned_v4_bridge()
            elif stat.S_ISDIR(existing.st_mode):
                if existing.st_uid != os.getuid():
                    raise RuntimeError("unsafe OAuth runtime lineage directory")
                # This v4 path is new-only.  A real directory is therefore
                # malformed rather than legacy state and remains fail-closed;
                # no PID or age is terminal proof for deleting it.
                recovered = False
            else:
                raise RuntimeError("unsafe OAuth runtime lineage path")
            if recovered:
                continue
        if time.monotonic() >= deadline:
            return False
        time.sleep(0.05)

def parse_versioned_target(target, prefix):
    if not target.startswith(prefix) or "/" in target:
        return None
    candidate_nonce = target[len(prefix):]
    if (len(candidate_nonce) != 32
            or any(character not in "0123456789abcdef" for character in candidate_nonce)):
        return None
    return candidate_nonce


def load_legacy_fence():
    """Adopt the exact permanent v4 fence or return a fail-closed reason."""
    global fence_target, fence_private_path, fence_owner_payload
    global fence_value, fence_private_value
    global fence_pid_fd, fence_pid_value, fence_owner_fd, fence_owner_value
    candidate_pid_fd = None
    candidate_owner_fd = None
    try:
        candidate_link_value = os.lstat(legacy_fence_path)
        if (not stat.S_ISLNK(candidate_link_value.st_mode)
                or candidate_link_value.st_uid != os.getuid()):
            return "legacy-fence-not-v4-symlink"
        candidate_target = os.readlink(legacy_fence_path)
        candidate_nonce = parse_versioned_target(
            candidate_target, "kimi-oauth-refresh.fence-v4.",
        )
        if candidate_nonce is None:
            return "legacy-fence-target-invalid"
        candidate_private_path = os.path.join(lock_root, candidate_target)
        candidate_private_value = os.lstat(candidate_private_path)
        if (not stat.S_ISDIR(candidate_private_value.st_mode)
                or candidate_private_value.st_uid != os.getuid()
                or stat.S_IMODE(candidate_private_value.st_mode) != 0o700
                or sorted(os.listdir(candidate_private_path)) != ["owner", "pid"]):
            return "legacy-fence-private-directory-invalid"
        candidate_pid_path = os.path.join(candidate_private_path, "pid")
        candidate_owner_path = os.path.join(candidate_private_path, "owner")
        candidate_pid_fd, candidate_pid_value = open_existing_owned_regular(
            candidate_pid_path,
        )
        candidate_owner_fd, candidate_owner_value = open_existing_owned_regular(
            candidate_owner_path,
        )
        candidate_owner_payload = (
            f"iwe-oauth-fence-v4 {lease_value.st_dev} "
            f"{lease_value.st_ino} {candidate_nonce}"
        )
        if read_ascii(candidate_pid_fd) != "-1":
            return "legacy-fence-pid-invalid"
        if read_ascii(candidate_owner_fd) != candidate_owner_payload:
            return "legacy-fence-owner-invalid"
        if (lease_fault()
                or not same_inode(os.lstat(legacy_fence_path), candidate_link_value)
                or os.readlink(legacy_fence_path) != candidate_target
                or not path_names_inode(
                    candidate_private_path, candidate_private_value,
                )
                or not path_names_inode(candidate_pid_path, candidate_pid_value)
                or not path_names_inode(candidate_owner_path, candidate_owner_value)
                or sorted(os.listdir(candidate_private_path)) != ["owner", "pid"]
                or read_ascii(candidate_pid_fd) != "-1"
                or read_ascii(candidate_owner_fd) != candidate_owner_payload):
            return "legacy-fence-changed-during-validation"

        fence_target = candidate_target
        fence_private_path = candidate_private_path
        fence_owner_payload = candidate_owner_payload
        fence_value = candidate_link_value
        fence_private_value = candidate_private_value
        fence_pid_fd = candidate_pid_fd
        fence_pid_value = candidate_pid_value
        fence_owner_fd = candidate_owner_fd
        fence_owner_value = candidate_owner_value
        candidate_pid_fd = None
        candidate_owner_fd = None
        return None
    except FileNotFoundError:
        return "legacy-fence-missing"
    except OSError as exc:
        return f"legacy-fence-io-error-{exc.errno}"
    except UnicodeError:
        return "legacy-fence-metadata-nonascii"
    finally:
        if candidate_owner_fd is not None:
            os.close(candidate_owner_fd)
        if candidate_pid_fd is not None:
            os.close(candidate_pid_fd)


def fence_fault():
    if fence_value is None:
        return "legacy-fence-unvalidated"
    pid_path = os.path.join(fence_private_path, "pid")
    owner_path = os.path.join(fence_private_path, "owner")
    try:
        if (not same_inode(os.lstat(legacy_fence_path), fence_value)
                or os.readlink(legacy_fence_path) != fence_target
                or not path_names_inode(fence_private_path, fence_private_value)
                or not path_names_inode(pid_path, fence_pid_value)
                or not path_names_inode(owner_path, fence_owner_value)
                or sorted(os.listdir(fence_private_path)) != ["owner", "pid"]
                or read_ascii(fence_pid_fd) != "-1"
                or read_ascii(fence_owner_fd) != fence_owner_payload):
            return "legacy-fence-changed"
    except (FileNotFoundError, OSError, UnicodeError):
        return "legacy-fence-missing-or-unreadable"
    return None


def adopt_required_legacy_fence():
    problem = load_legacy_fence()
    if problem:
        emit(f"Kimi admission refused: permanent v4 legacy fence invalid: {problem}")
        return False
    return True


def unlink_exact_v4_bridge(link_value, target, reason):
    """CAS-unlink only the v4 symlink; never remove a replacement directory."""
    if lease_fault() or fence_fault():
        return False
    try:
        current = os.lstat(oauth_bridge_path)
        if (not stat.S_ISLNK(current.st_mode)
                or not same_inode(current, link_value)
                or os.readlink(oauth_bridge_path) != target):
            return False
        os.unlink(oauth_bridge_path)
    except FileNotFoundError:
        return True
    except OSError:
        # unlink(2) rejects a malformed replacement directory.
        return False
    emit(f"unlinked drained OAuth v4 lineage: {reason}")
    return True


def recover_abandoned_v4_bridge():
    """Remove an exact drained v4 symlink; legacy never touches this path."""
    if lease_fd is None or lease_value is None:
        return False
    if lease_fault() or fence_fault():
        raise RuntimeError("cannot recover across a changed OAuth lease inode")
    link_value = os.lstat(oauth_bridge_path)
    if (not stat.S_ISLNK(link_value.st_mode)
            or link_value.st_uid != os.getuid()):
        return False
    target = os.readlink(oauth_bridge_path)
    target_nonce = parse_versioned_target(
        target, "kimi-oauth-refresh.lineage-v4.",
    )
    if target_nonce is None:
        return False
    private_path = os.path.join(lock_root, target)
    pid_path = os.path.join(private_path, "pid")
    owner_path = os.path.join(private_path, "owner")
    pid_fd = None
    owner_fd = None
    try:
        try:
            directory_value = os.lstat(private_path)
        except FileNotFoundError:
            return unlink_exact_v4_bridge(
                link_value, target, "private target missing",
            )
        if (not stat.S_ISDIR(directory_value.st_mode)
                or directory_value.st_uid != os.getuid()
                or stat.S_IMODE(directory_value.st_mode) != 0o700):
            return False
        try:
            pid_fd, pid_value = open_existing_owned_regular(pid_path)
        except FileNotFoundError:
            return unlink_exact_v4_bridge(
                link_value, target, "PID metadata missing",
            )
        holder = read_ascii(pid_fd)
        if (not holder.startswith("-")
                or not holder[1:].isdigit()
                or int(holder[1:]) <= 0):
            return False
        if group_alive(int(holder[1:])):
            return False
        try:
            owner_fd, owner_value = open_existing_owned_regular(owner_path)
        except FileNotFoundError:
            return unlink_exact_v4_bridge(
                link_value, target, "owner metadata missing",
            )
        marker = read_ascii(owner_fd).split(" ")
        if (len(marker) != 4
                or marker[0] != "iwe-oauth-lineage-v4"
                or marker[1] != str(lease_value.st_dev)
                or marker[2] != str(lease_value.st_ino)
                or marker[3] != target_nonce):
            return False
        if (lease_fault()
                or not same_inode(os.lstat(oauth_bridge_path), link_value)
                or os.readlink(oauth_bridge_path) != target
                or not path_names_inode(private_path, directory_value)
                or not path_names_inode(pid_path, pid_value)
                or not path_names_inode(owner_path, owner_value)
                or read_ascii(pid_fd) != holder
                or read_ascii(owner_fd) != " ".join(marker)):
            return False

        if not unlink_exact_v4_bridge(
            link_value, target, f"group {holder} is gone",
        ):
            return False
        if (not path_names_inode(private_path, directory_value)
                or not path_names_inode(pid_path, pid_value)
                or not path_names_inode(owner_path, owner_value)
                or read_ascii(pid_fd) != holder
                or read_ascii(owner_fd) != " ".join(marker)):
            raise RuntimeError("recovered OAuth v4 private lineage changed")
        os.unlink(owner_path)
        os.unlink(pid_path)
        os.rmdir(private_path)
        emit(f"recovered drained OAuth v4 lineage held by group {holder}")
        return True
    except (FileNotFoundError, UnicodeError):
        return False
    finally:
        if owner_fd is not None:
            os.close(owner_fd)
        if pid_fd is not None:
            os.close(pid_fd)


def perform_explicit_cutover():
    """Install the permanent legacy fence after an external quiescence gate."""
    if os.environ.get("IWE_OAUTH_CUTOVER_QUIESCED") != "1":
        emit(
            "cutover refused: set IWE_OAUTH_CUTOVER_QUIESCED=1 only after "
            "all legacy launchers and acquisition loops are disabled and drained"
        )
        return 64
    try:
        os.kill(-1, 0)
    except OSError as exc:
        emit(f"cutover refused: legacy Bash kill -0 -1 fence is unavailable: {exc}")
        return 69

    ensure_owned_directory(lock_root)
    deadline = time.monotonic() + oauth_wait_seconds
    if not acquire_permanent_lease(deadline):
        emit("cutover refused: permanent OAuth lease is busy")
        return 75
    if os.path.lexists(oauth_bridge_path):
        emit("cutover refused: v4 runtime lineage already exists")
        return 75
    if os.path.lexists(legacy_fence_path):
        problem = load_legacy_fence()
        if problem is None:
            emit("OAuth v4 cutover already installed")
            return 0
        emit(f"cutover refused: existing legacy pathname is not the v4 fence: {problem}")
        return 75

    fence_nonce = secrets.token_hex(16)
    candidate_target = f"kimi-oauth-refresh.fence-v4.{fence_nonce}"
    candidate_private_path = os.path.join(lock_root, candidate_target)
    candidate_pid_path = os.path.join(candidate_private_path, "pid")
    candidate_owner_path = os.path.join(candidate_private_path, "owner")
    candidate_owner_payload = (
        f"iwe-oauth-fence-v4 {lease_value.st_dev} "
        f"{lease_value.st_ino} {fence_nonce}"
    )
    candidate_private_value = None
    candidate_pid_fd = None
    candidate_pid_value = None
    candidate_owner_fd = None
    candidate_owner_value = None
    published = False
    try:
        os.mkdir(candidate_private_path, 0o700)
        candidate_private_value = os.lstat(candidate_private_path)
        if (not stat.S_ISDIR(candidate_private_value.st_mode)
                or candidate_private_value.st_uid != os.getuid()):
            raise RuntimeError("unsafe private OAuth fence directory")
        os.chmod(candidate_private_path, 0o700)
        candidate_pid_fd, candidate_pid_value = publish_owned_regular(
            candidate_pid_path, "-1",
        )
        candidate_owner_fd, candidate_owner_value = publish_owned_regular(
            candidate_owner_path, candidate_owner_payload,
        )
        fsync_directory(candidate_private_path)
        wait_at_test_barrier("IWE_SCHED_TEST_CUTOVER_PRE_PUBLISH_BARRIER")
        os.symlink(candidate_target, legacy_fence_path)
        published = True
        fsync_directory(lock_root)
        problem = load_legacy_fence()
        if problem:
            raise RuntimeError(f"published legacy fence failed validation: {problem}")
        emit("installed permanent OAuth v4 legacy fence")
        return 0
    except FileExistsError:
        emit("cutover refused: legacy pathname changed during publication")
        return 75
    finally:
        if not published and candidate_private_value is not None:
            try:
                safe_to_clean = path_names_inode(
                    candidate_private_path, candidate_private_value,
                )
                for path, descriptor, value, expected in (
                    (
                        candidate_owner_path, candidate_owner_fd,
                        candidate_owner_value, candidate_owner_payload,
                    ),
                    (candidate_pid_path, candidate_pid_fd, candidate_pid_value, "-1"),
                ):
                    if not safe_to_clean:
                        break
                    if descriptor is None:
                        if os.path.lexists(path):
                            safe_to_clean = False
                        continue
                    if (not path_names_inode(path, value)
                            or read_ascii(descriptor) != expected):
                        safe_to_clean = False
                if safe_to_clean:
                    if candidate_owner_fd is not None:
                        os.unlink(candidate_owner_path)
                    if candidate_pid_fd is not None:
                        os.unlink(candidate_pid_path)
                if (safe_to_clean and path_names_inode(
                    candidate_private_path, candidate_private_value,
                )):
                    os.rmdir(candidate_private_path)
            except OSError as exc:
                emit(f"cannot clean unpublished OAuth fence staging: {exc}")
        if candidate_owner_fd is not None:
            os.close(candidate_owner_fd)
        if candidate_pid_fd is not None:
            os.close(candidate_pid_fd)


def replace_bridge_holder(new_holder):
    global bridge_pid_fd, bridge_pid_value, bridge_holder_token
    temporary_path = (
        f"{bridge_private_path}.pid-next.{secrets.token_hex(16)}"
    )
    replacement_fd = None
    try:
        replacement_fd, replacement_value = publish_owned_regular(
            temporary_path, str(new_holder),
        )
        os.replace(temporary_path, os.path.join(bridge_private_path, "pid"))
        fsync_directory(bridge_private_path)
        if not path_names_inode(
            os.path.join(bridge_private_path, "pid"), replacement_value,
        ):
            raise RuntimeError("OAuth bridge PID handoff inode changed")
        old_fd = bridge_pid_fd
        bridge_pid_fd = replacement_fd
        bridge_pid_value = replacement_value
        bridge_holder_token = str(new_holder)
        replacement_fd = None
        if old_fd is not None:
            os.close(old_fd)
    finally:
        if replacement_fd is not None:
            os.close(replacement_fd)
        try:
            os.unlink(temporary_path)
        except FileNotFoundError:
            pass


def discard_unpublished_private_bridge():
    """Remove this attempt's private staging only while it is unpublished."""
    if bridge_value is not None or bridge_private_value is None:
        return
    try:
        if not path_names_inode(bridge_private_path, bridge_private_value):
            return
        for name, descriptor, value in (
            ("owner", bridge_owner_fd, bridge_owner_value),
            ("pid", bridge_pid_fd, bridge_pid_value),
        ):
            path = os.path.join(bridge_private_path, name)
            if descriptor is None:
                if os.path.lexists(path):
                    return
                continue
            if not path_names_inode(path, value):
                return
            os.unlink(path)
        os.rmdir(bridge_private_path)
    except (FileNotFoundError, OSError) as exc:
        emit(f"cannot clean unpublished OAuth private bridge: {exc}")


def release_runtime_bridge(expected_holders=None):
    if bridge_value is None:
        return
    if expected_holders is None:
        expected_holders = (bridge_holder_token,)
    expected_payloads = {str(holder) for holder in expected_holders}
    fault = bridge_fault(expected_holders, allow_pid_adoption=True)
    if fault:
        emit(f"preserving unowned OAuth bridge after {fault}")
        return
    actual_holder = read_ascii(bridge_pid_fd)
    if actual_holder not in expected_payloads:
        emit("preserving OAuth bridge with unexpected holder")
        return
    actual_owner = read_ascii(bridge_owner_fd)
    if actual_owner != owner_payload:
        emit("preserving OAuth bridge with unexpected owner token")
        return

    # unlink cannot remove a concurrently installed directory.  The runtime
    # authority is just this exact new-only symlink; its private
    # directory remains unreachable to contenders until all handles validate.
    try:
        if (not same_inode(os.lstat(oauth_bridge_path), bridge_value)
                or os.readlink(oauth_bridge_path) != bridge_target):
            emit("OAuth bridge link changed before release; preserving it")
            return
        os.unlink(oauth_bridge_path)
    except OSError as exc:
        emit(f"cannot atomically unlink OAuth bridge symlink: {exc}")
        return

    try:
        if not path_names_inode(bridge_private_path, bridge_private_value):
            emit("released OAuth private bridge changed; preserving it")
            return
        for name, descriptor, value, expected in (
            ("owner", bridge_owner_fd, bridge_owner_value, actual_owner),
            ("pid", bridge_pid_fd, bridge_pid_value, actual_holder),
        ):
            path = os.path.join(bridge_private_path, name)
            if (descriptor is None
                    or not path_names_inode(path, value)
                    or read_ascii(descriptor) != expected):
                emit(f"released OAuth {name} changed; preserving private bridge")
                return
            os.unlink(path)
        os.rmdir(bridge_private_path)
    except (FileNotFoundError, OSError) as exc:
        emit(f"cannot clean released OAuth private bridge: {exc}")


def normalize_returncode(returncode):
    return 128 + (-returncode) if returncode < 0 else returncode


def send_line(descriptor, message):
    payload = (message + "\n").encode("utf-8", "replace")
    try:
        os.write(descriptor, payload)
        return True
    except (BrokenPipeError, OSError):
        return False


def read_available_lines(descriptor, buffer):
    lines = []
    eof = False
    while True:
        readable, _, _ = select.select([descriptor], [], [], 0)
        if not readable:
            break
        try:
            chunk = os.read(descriptor, 4096)
        except BlockingIOError:
            break
        if not chunk:
            eof = True
            break
        buffer += chunk
        while b"\n" in buffer:
            raw, buffer = buffer.split(b"\n", 1)
            lines.append(raw.decode("utf-8", "replace"))
    return lines, buffer, eof


def close_authority_descriptors():
    for descriptor in (
        bridge_owner_fd,
        bridge_pid_fd,
        fence_owner_fd,
        fence_pid_fd,
        lease_fd,
    ):
        if descriptor is not None:
            try:
                os.close(descriptor)
            except OSError as exc:
                emit(f"cannot close OAuth authority descriptor: {exc}")


def sentinel_main(controller_pid, control_fd, status_fd):
    global stop_signal
    initial_holder = f"-{supervisor_pgid}"
    local_pgid = None
    handoff_armed = False
    control_buffer = b""
    result_code = 1
    reason = "sentinel initialization failed"

    stop_signal = 0
    for watched_signal in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
        signal.signal(watched_signal, request_stop)

    try:
        if fence_fault() or bridge_fault((initial_holder,)):
            raise RuntimeError("cannot validate OAuth authorities in sentinel")
        send_line(status_fd, f"SENTINEL {os.getpid()}")

        started_at = None
        while True:
            if local_pgid is None:
                expected_holders = (initial_holder,)
            elif handoff_armed:
                expected_holders = (f"-{local_pgid}",)
            else:
                expected_holders = (initial_holder, f"-{local_pgid}")
            fault = lease_fault() or fence_fault() or bridge_fault(
                expected_holders,
                allow_pid_adoption=local_pgid is not None,
            )
            if fault:
                result_code = 1
                reason = f"OAuth authority lost: {fault}"
                send_line(status_fd, f"FAULT 1 {reason}")
                break
            if os.getppid() != controller_pid:
                result_code = 143
                reason = "controller process exited"
                break
            if stop_signal:
                result_code = 128 + stop_signal
                reason = f"sentinel received signal {stop_signal}"
                break
            if started_at is not None and time.monotonic() >= started_at + timeout_seconds:
                result_code = 142
                reason = f"deadline {timeout_seconds}s exceeded"
                send_line(status_fd, f"FAULT 142 {reason}")
                break

            lines, control_buffer, control_eof = read_available_lines(
                control_fd, control_buffer,
            )
            release_requested = False
            for line in lines:
                fields = line.split(" ", 2)
                if (fields[0] == "PREPARE"
                        and len(fields) >= 2
                        and fields[1].isdigit()):
                    proposed_pgid = int(fields[1])
                    if local_pgid is not None and local_pgid != proposed_pgid:
                        raise RuntimeError("sentinel PGID changed after publication")
                    if not group_alive(proposed_pgid):
                        raise RuntimeError("prepared Kimi PGID is not alive")
                    local_pgid = proposed_pgid
                    send_line(status_fd, f"PREPARED {local_pgid}")
                elif (fields[0] == "ARM"
                      and len(fields) >= 2
                      and fields[1].isdigit()):
                    proposed_pgid = int(fields[1])
                    if local_pgid != proposed_pgid:
                        raise RuntimeError("sentinel armed an unprepared PGID")
                    fault = bridge_fault(
                        (f"-{local_pgid}",), allow_pid_adoption=True,
                    )
                    if fault:
                        raise RuntimeError(
                            f"OAuth bridge handoff failed: {fault}"
                        )
                    handoff_armed = True
                    started_at = time.monotonic()
                    send_line(status_fd, f"ARMED {local_pgid}")
                elif fields[0] == "RELEASE" and len(fields) >= 2 and fields[1].isdigit():
                    result_code = int(fields[1])
                    reason = fields[2] if len(fields) == 3 else "controller release"
                    release_requested = True
                else:
                    raise RuntimeError(f"invalid sentinel control message: {line!r}")
            if release_requested:
                break
            if control_eof:
                result_code = 143
                reason = "controller control channel closed"
                break
            time.sleep(0.025)
    except Exception as exc:
        result_code = 1
        reason = f"sentinel failure: {type(exc).__name__}: {exc}"
        emit(reason)
        send_line(status_fd, f"FAULT 1 {reason}")
    finally:
        if local_pgid is not None:
            drain_process_group(local_pgid, reason, reap_vendor=False)
        holders = [initial_holder]
        if local_pgid is not None:
            holders.append(f"-{local_pgid}")
        release_runtime_bridge(tuple(holders))
        close_authority_descriptors()
        send_line(status_fd, f"DONE {result_code}")
        try:
            os.close(control_fd)
            os.close(status_fd)
        except OSError:
            pass
    os._exit(result_code & 0xff)


def launch_gated_vendor(control_fd, status_fd):
    global vendor_pid
    gate_read, gate_write = os.pipe()
    child_stdin = os.open(stdin_path, os.O_RDONLY | CLOEXEC)
    child_log = os.open(
        log_path, os.O_WRONLY | os.O_CREAT | os.O_APPEND | CLOEXEC, 0o600,
    )
    try:
        vendor_pid = os.fork()
    except Exception:
        os.close(gate_read)
        os.close(gate_write)
        os.close(child_stdin)
        os.close(child_log)
        raise
    if vendor_pid == 0:
        try:
            for watched_signal in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
                signal.signal(watched_signal, signal.SIG_DFL)
            os.close(gate_write)
            os.close(control_fd)
            os.close(status_fd)
            os.setsid()
            gate_token = os.read(gate_read, 1)
            if gate_token != b"G":
                os._exit(125)
            os.close(gate_read)
            os.dup2(child_stdin, 0)
            os.dup2(child_log, 1)
            os.dup2(child_log, 2)
            os.set_inheritable(lease_fd, True)
            for descriptor in (
                child_stdin,
                child_log,
                bridge_owner_fd,
                bridge_pid_fd,
            ):
                if descriptor not in (0, 1, 2, lease_fd):
                    try:
                        os.close(descriptor)
                    except OSError:
                        pass
            os.execvpe(command[0], command, os.environ)
        except BaseException as exc:
            try:
                os.write(2, f"vendor exec failed: {exc}\n".encode())
            except OSError:
                pass
            os._exit(127)
    os.close(gate_read)
    os.close(child_stdin)
    os.close(child_log)

    pgid_deadline = time.monotonic() + 2.0
    while time.monotonic() < pgid_deadline:
        if poll_vendor() is not None:
            os.close(gate_write)
            raise RuntimeError("gated Kimi child exited before setsid")
        try:
            if os.getpgid(vendor_pid) == vendor_pid:
                return vendor_pid, gate_write
        except ProcessLookupError:
            break
        time.sleep(0.01)
    os.close(gate_write)
    raise RuntimeError("gated Kimi child did not publish its process group")


def read_sentinel_status():
    global sentinel_status_buffer, sentinel_status_eof
    lines, sentinel_status_buffer, sentinel_status_eof = read_available_lines(
        sentinel_status, sentinel_status_buffer,
    )
    return [line.split(" ", 2) for line in lines]


def await_sentinel_ack(kind, value, deadline):
    while time.monotonic() < deadline:
        for fields in read_sentinel_status():
            if fields[0] == kind and len(fields) >= 2 and fields[1] == str(value):
                return
            if fields[0] in ("FAULT", "DONE"):
                raise RuntimeError(
                    f"sentinel failed before {kind.lower()} acknowledgement: "
                    f"{' '.join(fields)}"
                )
        if sentinel_status_eof or scheduler_gone() or stop_signal:
            break
        time.sleep(0.025)
    raise RuntimeError(f"OAuth sentinel did not acknowledge {kind.lower()} {value}")


if operation == "cutover":
    try:
        cutover_result = perform_explicit_cutover()
    except Exception as exc:
        emit(f"cutover failure: {type(exc).__name__}: {exc}")
        cutover_result = 1
    finally:
        close_authority_descriptors()
    raise SystemExit(cutover_result)


for watched_signal in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
    signal.signal(watched_signal, request_stop)

result = 1
sentinel_control = None
sentinel_status = None
vendor_gate = None
sentinel_done = False
sentinel_faulted = False
sentinel_result = None
sentinel_status_buffer = b""
sentinel_status_eof = False
controller_owns_cleanup = True
try:
    try:
        os.setpgid(0, 0)
    except PermissionError:
        # A launcher may already have made this process a session/group
        # leader.  That is the desired topology; any other EPERM is fatal.
        if os.getpgrp() != os.getpid():
            raise
    supervisor_pgid = os.getpgrp()
    if supervisor_pgid != os.getpid():
        raise RuntimeError("cannot isolate OAuth supervisor process group")
    publish_test_value("IWE_SCHED_TEST_CONTROLLER_PID_FILE", os.getpid())
    ensure_owned_directory(lock_root)
    wait_deadline = time.monotonic() + oauth_wait_seconds
    if not acquire_permanent_lease(wait_deadline):
        result = 75 if not (scheduler_gone() or stop_signal) else 143
    elif not adopt_required_legacy_fence():
        result = 75
    elif not acquire_runtime_bridge(wait_deadline):
        result = 75 if not (scheduler_gone() or stop_signal) else 143
    elif scheduler_gone() or stop_signal:
        result = 143
    else:
        controller_pid = os.getpid()
        sentinel_control_child, sentinel_control = os.pipe()
        sentinel_status, sentinel_status_child = os.pipe()
        sentinel_pid = os.fork()
        if sentinel_pid == 0:
            os.close(sentinel_control)
            os.close(sentinel_status)
            sentinel_main(controller_pid, sentinel_control_child, sentinel_status_child)
        publish_test_value("IWE_SCHED_TEST_SENTINEL_PID_FILE", sentinel_pid)
        os.close(sentinel_control_child)
        os.close(sentinel_status_child)
        os.set_blocking(sentinel_status, False)

        # Both controller and sentinel retain the same open authority handles.
        # The old scheduler sees their live negative PGID until both processes
        # have acknowledged the gated vendor group and its atomic PID handoff.
        await_sentinel_ack(
            "SENTINEL", sentinel_pid, time.monotonic() + 5.0,
        )

        vendor_pgid, vendor_gate = launch_gated_vendor(
            sentinel_control, sentinel_status,
        )
        if not send_line(sentinel_control, f"PREPARE {vendor_pgid}"):
            raise RuntimeError("cannot prepare Kimi PGID in OAuth sentinel")
        await_sentinel_ack(
            "PREPARED", vendor_pgid, time.monotonic() + 5.0,
        )
        replace_bridge_holder(f"-{vendor_pgid}")
        if not send_line(sentinel_control, f"ARM {vendor_pgid}"):
            raise RuntimeError("cannot publish Kimi PGID to OAuth sentinel")

        await_sentinel_ack(
            "ARMED", vendor_pgid, time.monotonic() + 5.0,
        )
        os.write(vendor_gate, b"G")
        os.close(vendor_gate)
        vendor_gate = None

        run_deadline = time.monotonic() + timeout_seconds
        reason = "supervisor finalization"
        while True:
            returncode = poll_vendor()
            if returncode is not None:
                reason = "leader exited with descendants still alive"
                result = normalize_returncode(returncode)
                break
            fault = (
                lease_fault()
                or fence_fault()
                or bridge_fault((f"-{vendor_pgid}",))
            )
            if fault:
                reason = f"OAuth authority lost: {fault}"
                result = 1
                break
            if scheduler_gone():
                reason = "scheduler parent exited"
                result = 143
                break
            if stop_signal:
                reason = f"controller received signal {stop_signal}"
                result = 128 + stop_signal
                break
            if time.monotonic() >= run_deadline:
                reason = f"deadline {timeout_seconds}s exceeded"
                result = 142
                break

            for fields in read_sentinel_status():
                if fields[0] == "FAULT":
                    result = int(fields[1]) if len(fields) >= 2 and fields[1].isdigit() else 1
                    reason = fields[2] if len(fields) == 3 else "sentinel fault"
                    sentinel_faulted = True
                    break
                if fields[0] == "DONE":
                    sentinel_result = int(fields[1]) if len(fields) >= 2 and fields[1].isdigit() else 1
                    sentinel_done = True
                    reason = "sentinel exited unexpectedly"
                    result = sentinel_result
                    break
            if sentinel_done or sentinel_faulted or sentinel_status_eof:
                break
            time.sleep(0.025)

        # The sentinel is the normal drain owner.  The controller keeps exact
        # duplicate authorities and takes over only if that child disappears.
        if not sentinel_done and not sentinel_faulted and not sentinel_status_eof:
            send_line(sentinel_control, f"RELEASE {result} {reason}")
        while not sentinel_done and not sentinel_status_eof:
            poll_vendor()
            for fields in read_sentinel_status():
                if fields[0] == "FAULT":
                    result = int(fields[1]) if len(fields) >= 2 and fields[1].isdigit() else 1
                    reason = fields[2] if len(fields) == 3 else "sentinel fault"
                    sentinel_faulted = True
                elif fields[0] == "DONE":
                    sentinel_result = int(fields[1]) if len(fields) >= 2 and fields[1].isdigit() else 1
                    sentinel_done = True
            if not sentinel_done and not sentinel_status_eof:
                time.sleep(0.025)
        if sentinel_done and not group_alive(vendor_pgid):
            controller_owns_cleanup = False
except Exception as exc:
    emit(f"supervisor failure: {type(exc).__name__}: {exc}")
    result = 1
finally:
    if vendor_gate is not None:
        try:
            os.close(vendor_gate)
        except OSError:
            pass
    if vendor_pid is not None and controller_owns_cleanup:
        drain_process_group(vendor_pid, "controller finalization", reap_vendor=True)
    if sentinel_control is not None:
        try:
            os.close(sentinel_control)
        except OSError:
            pass
    if sentinel_pid is not None:
        while True:
            try:
                waited_pid, _sentinel_status = os.waitpid(sentinel_pid, 0)
                if waited_pid == sentinel_pid:
                    break
            except InterruptedError:
                continue
            except ChildProcessError:
                break
    # If the sentinel died, the controller still owns duplicate exact handles
    # and performs the same post-drain CAS.  If the controller dies instead,
    # the sentinel takes this branch in its own process.
    if controller_owns_cleanup:
        expected_holders = [f"-{supervisor_pgid}"]
        if vendor_pid is not None:
            expected_holders.append(f"-{vendor_pid}")
        release_runtime_bridge(tuple(expected_holders))
    discard_unpublished_private_bridge()
    close_authority_descriptors()
    if sentinel_status is not None:
        try:
            os.close(sentinel_status)
        except OSError:
            pass

raise SystemExit(result)
PY
}

run_kimi_with_oauth_lineage() {
  run_oauth_lineage_python run "$@"
}

cutover_oauth_lineage_v4() {
  run_oauth_lineage_python cutover 30 /dev/null -
}

scheduler_self_test_fake_kimi() {
  if [ "${1:-}" = "--help" ]; then
    echo "--agent-file Load an agent definition from a Markdown file"
    exit 0
  fi
  local mode="${IWE_SCHED_SELF_TEST_FAKE_MODE:-normal}"
  local entries="${IWE_SCHED_SELF_TEST_ENTRIES:?self-test entries required}"
  local tag="${IWE_SCHED_SELF_TEST_TAG:-unknown}"
  local ready="${IWE_SCHED_SELF_TEST_READY:-}"
  local vendor_pid_file="${IWE_SCHED_SELF_TEST_VENDOR_PID_FILE:-}"
  local grandchild_pid_file="${IWE_SCHED_SELF_TEST_GRANDCHILD_PID_FILE:-}"
  local grandchild_python
  local grandchild
  printf '%s %s\n' "$tag" "$$" >> "$entries"
  [ -z "$vendor_pid_file" ] || printf '%s\n' "$$" > "$vendor_pid_file"
  case "$mode" in
    resistant|orphan-on-exit)
      grandchild_python=$(resolve_scheduler_python) || exit $?
      "$grandchild_python" - "$grandchild_pid_file" <<'PY' &
import os
import signal
import sys
import time

for watched_signal in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
    signal.signal(watched_signal, signal.SIG_IGN)
if sys.argv[1]:
    with open(sys.argv[1], "w", encoding="ascii") as stream:
        stream.write(f"{os.getpid()}\n")
while True:
    time.sleep(0.05)
PY
      grandchild=$!
      [ -z "$grandchild_pid_file" ] || printf '%s\n' "$grandchild" > "$grandchild_pid_file"
      [ -z "$ready" ] || : > "$ready"
      ;;
    normal)
      [ -z "$ready" ] || : > "$ready"
      /bin/sleep "${IWE_SCHED_SELF_TEST_FAKE_DURATION:-0.4}"
      printf '%s\n' '{"role":"assistant","content":"scheduler lineage self-test complete"}'
      exit 0
      ;;
    *)
      echo "ERROR: unknown scheduler self-test fake mode: $mode" >&2
      exit 64
      ;;
  esac

  case "$mode" in
    resistant)
      trap '' HUP INT TERM
      wait "$grandchild"
      exit $?
      ;;
    orphan-on-exit)
      printf '%s\n' '{"role":"assistant","content":"scheduler lineage self-test complete"}'
      exit 0
      ;;
  esac
}

run_scheduler_self_test_worker() {
  run_kimi_with_oauth_lineage \
    "${IWE_SCHED_SELF_TEST_TIMEOUT:-10}" /dev/null \
    "${IWE_SCHED_SELF_TEST_WORKER_LOG:?worker log required}" \
    /usr/bin/env \
    "IWE_SCHED_SELF_TEST_FAKE_MODE=${IWE_SCHED_SELF_TEST_CHILD_MODE:-normal}" \
    "IWE_SCHED_SELF_TEST_ENTRIES=${IWE_SCHED_SELF_TEST_ENTRIES:?entries required}" \
    "IWE_SCHED_SELF_TEST_TAG=${IWE_SCHED_SELF_TEST_CHILD_TAG:-scheduler}" \
    "IWE_SCHED_SELF_TEST_READY=${IWE_SCHED_SELF_TEST_CHILD_READY:-}" \
    "IWE_SCHED_SELF_TEST_VENDOR_PID_FILE=${IWE_SCHED_SELF_TEST_CHILD_VENDOR_PID_FILE:-}" \
    "IWE_SCHED_SELF_TEST_GRANDCHILD_PID_FILE=${IWE_SCHED_SELF_TEST_CHILD_GRANDCHILD_PID_FILE:-}" \
    "IWE_SCHED_SELF_TEST_FAKE_DURATION=${IWE_SCHED_SELF_TEST_CHILD_DURATION:-0.4}" \
    "$SCHEDULER_SELF"
}

process_is_non_zombie() {
  local process_pid="${1:-}" process_state
  [ -n "$process_pid" ] || return 1
  process_state=$(ps -o stat= -p "$process_pid" 2>/dev/null | tr -d '[:space:]')
  [ -n "$process_state" ] && [[ "$process_state" != Z* ]]
}

wait_for_process_exit() {
  local process_pid="${1:-}" _wait
  for _wait in $(seq 1 160); do
    process_is_non_zombie "$process_pid" || return 0
    sleep 0.05
  done
  return 1
}

wait_for_lineage_fixture() {
  local fixture_root="$1" fixture_name="$2" _wait
  for _wait in $(seq 1 240); do
    [ -s "$fixture_root/$fixture_name.vendor" ] \
      && [ -s "$fixture_root/$fixture_name.grandchild" ] \
      && [ -e "$fixture_root/$fixture_name.ready" ] \
      && [ -s "$fixture_root/locks/kimi-oauth-refresh.lineage-v4/pid" ] \
      && return 0
    sleep 0.025
  done
  return 1
}

run_oauth_lineage_self_test() {
  local test_root lock_root entries adapter add_dir adapter_recovery_dir adapter_stale_dir
  local first_top first_vendor first_grandchild first_holder first_legacy_live
  local first_bridge_was_symlink
  local scheduler_top adapter_top scheduler_rc adapter_rc max_live live
  local timeout_top timeout_rc timeout_vendor timeout_grandchild
  local normal_rc normal_grandchild
  local controller_top controller_pid controller_sentinel controller_vendor
  local controller_grandchild controller_rc controller_next controller_next_rc
  local controller_max_live sentinel_top sentinel_pid_value sentinel_controller
  local sentinel_vendor sentinel_grandchild sentinel_rc sentinel_next_rc
  local tamper_top tamper_vendor tamper_grandchild tamper_rc
  local tamper_drain_ok tamper_recovery_rc
  local fence_tamper_top fence_tamper_vendor fence_tamper_grandchild
  local fence_tamper_rc fence_tamper_next_rc fence_tamper_target fence_owner_saved
  local double_top double_controller double_sentinel double_vendor double_grandchild
  local double_holder double_legacy_live double_bridge_was_symlink
  local double_rc double_blocked_rc double_recovery_rc resolver_rc
  local adapter_stale_top adapter_stale_helper adapter_stale_rc adapter_stale_owner
  local adapter_stale_recovery_rc
  local stage_top stage_controller stage_rc stage_next_rc stage_private
  local stage_canonical_absent stage_shape_ok
  local no_fence_rc cutover_missing_assertion_rc cutover_existing_rc
  local cutover_rc cutover_again_rc cutover_target cutover_target_again
  local aba_legacy rollback_result rollback_target
  local cutover_race_top cutover_race_rc cutover_race_barrier cutover_staging
  local passed=0 failed=0
  test_root=$(mktemp -d "${TMPDIR:-/tmp}/kimi-scheduler-lineage.XXXXXX") || return 1
  lock_root="$test_root/locks"
  entries="$test_root/entries"
  adapter="${IWE_SCHED_SELF_TEST_ADAPTER:-${IWE_ROOT:-$HOME/IWE}/DS-my-strategy/scripts/kimi-peer-adapter.sh}"
  add_dir="$test_root/2026-09-12-wp484-scheduler-adapter"
  adapter_recovery_dir="$test_root/2026-09-12-wp484-scheduler-stale"
  adapter_stale_dir="$test_root/2026-09-12-wp484-adapter-stale"
  mkdir -p "$lock_root" "$test_root/home" "$test_root/iwe" \
    "$add_dir" "$adapter_recovery_dir" "$adapter_stale_dir"
  : > "$entries"

  cleanup_oauth_lineage_self_test() {
    local force_kill="${1:-1}" candidate
    if [ "$force_kill" = "1" ]; then
      for candidate in \
        "${first_top:-}" "${scheduler_top:-}" "${adapter_top:-}" \
        "${timeout_top:-}" "${first_vendor:-}" "${first_grandchild:-}" \
        "${timeout_vendor:-}" "${timeout_grandchild:-}" \
        "${normal_grandchild:-}" "${controller_top:-}" \
        "${controller_pid:-}" "${controller_sentinel:-}" \
        "${controller_vendor:-}" "${controller_grandchild:-}" \
        "${controller_next:-}" "${sentinel_top:-}" \
        "${sentinel_pid_value:-}" "${sentinel_controller:-}" \
        "${sentinel_vendor:-}" "${sentinel_grandchild:-}" \
        "${tamper_top:-}" "${tamper_vendor:-}" \
        "${tamper_grandchild:-}" "${fence_tamper_top:-}" \
        "${fence_tamper_vendor:-}" "${fence_tamper_grandchild:-}" \
        "${double_top:-}" "${double_controller:-}" \
        "${double_sentinel:-}" "${double_vendor:-}" \
        "${double_grandchild:-}" "${adapter_stale_top:-}" \
        "${adapter_stale_helper:-}" "${stage_top:-}" \
        "${stage_controller:-}" "${aba_legacy:-}" \
        "${cutover_race_top:-}"; do
        [ -z "$candidate" ] || kill -9 "$candidate" 2>/dev/null || true
      done
    fi
    case "$test_root" in
      "${TMPDIR:-/tmp}"/kimi-scheduler-lineage.*)
        if [ "${IWE_SCHED_SELF_TEST_KEEP:-0}" = "1" ]; then
          echo "self-test artifacts kept: $test_root"
        else
          rm -rf "$test_root"
        fi
        ;;
    esac
  }
  trap cleanup_oauth_lineage_self_test EXIT HUP INT TERM

  self_test_ok() { echo "  OK  $*"; passed=$((passed + 1)); }
  self_test_bad() { echo "  FAIL $*" >&2; failed=$((failed + 1)); }
  test_legacy_fence() {
    local checked_root="${1:-$lock_root}"
    local target nonce owner lease_identity lease_dev lease_ino
    [ -L "$checked_root/kimi-oauth-refresh.lockdir" ] || return 1
    target=$(readlink "$checked_root/kimi-oauth-refresh.lockdir") || return 1
    case "$target" in
      kimi-oauth-refresh.fence-v4.????????????????????????????????) ;;
      *) return 1 ;;
    esac
    nonce=${target#kimi-oauth-refresh.fence-v4.}
    [ "${#nonce}" -eq 32 ] || return 1
    case "$nonce" in *[!0-9a-f]*) return 1 ;; esac
    [ "$(tr -d '[:space:]' < "$checked_root/$target/pid")" = -1 ] || return 1
    lease_identity=$(stat -c '%d %i' "$checked_root/kimi-oauth-refresh.lease" 2>/dev/null \
      || stat -f '%d %i' "$checked_root/kimi-oauth-refresh.lease")
    lease_dev=${lease_identity%% *}
    lease_ino=${lease_identity#* }
    owner=$(tr -d '\n' < "$checked_root/$target/owner") || return 1
    [ "$owner" = "iwe-oauth-fence-v4 $lease_dev $lease_ino $nonce" ]
  }

  test_oauth_bridge_absent() {
    test_legacy_fence \
      && [ ! -e "$lock_root/kimi-oauth-refresh.lineage-v4" ] \
      && [ ! -L "$lock_root/kimi-oauth-refresh.lineage-v4" ]
  }

  self_test_private_publication_crash() {
  local stage_name="$1" barrier_variable="$2" barrier_path
  barrier_path="$test_root/$stage_name-barrier"
  : > "$entries"
  env IWE_SCHED_SELF_TEST_WORKER=1 \
    IWE_PEER_LOCK_DIR="$lock_root" IWE_PEER_OAUTH_LOCK_TIMEOUT_SECONDS=5 \
    IWE_SCHED_SELF_TEST_TIMEOUT=10 \
    IWE_SCHED_SELF_TEST_WORKER_LOG="$test_root/$stage_name.log" \
    IWE_SCHED_SELF_TEST_ENTRIES="$entries" \
    IWE_SCHED_SELF_TEST_CHILD_MODE=normal \
    IWE_SCHED_SELF_TEST_CHILD_TAG="$stage_name-must-not-run" \
    "$barrier_variable=$barrier_path" \
    bash "$SCHEDULER_SELF" --self-test-oauth-lineage \
      2> "$test_root/$stage_name-top.err" &
  stage_top=$!
  for _wait in $(seq 1 240); do
    [ -s "$barrier_path.ready" ] && break
    sleep 0.025
  done
  stage_controller=$(tr -d '[:space:]' < "$barrier_path.ready" 2>/dev/null || true)
  stage_private=$(find "$lock_root" -maxdepth 1 -type d \
    -name 'kimi-oauth-refresh.lineage-v4.*' -print 2>/dev/null | head -1)
  if [ ! -e "$lock_root/kimi-oauth-refresh.lineage-v4" ] \
     && [ ! -L "$lock_root/kimi-oauth-refresh.lineage-v4" ]; then
    stage_canonical_absent=1
  else
    stage_canonical_absent=0
  fi
  case "$stage_name" in
    private-mkdir)
      if [ -n "$stage_private" ] && [ ! -e "$stage_private/pid" ]; then
        stage_shape_ok=1
      else
        stage_shape_ok=0
      fi
      ;;
    private-pid)
      if [ -n "$stage_private" ] \
         && [ -s "$stage_private/pid" ] \
         && [ ! -e "$stage_private/owner" ]; then
        stage_shape_ok=1
      else
        stage_shape_ok=0
      fi
      ;;
  esac
  [ -z "$stage_controller" ] || kill -9 "$stage_controller" 2>/dev/null || true
  wait "$stage_top" 2>/dev/null
  stage_rc=$?

  env IWE_SCHED_SELF_TEST_WORKER=1 \
    IWE_PEER_LOCK_DIR="$lock_root" IWE_PEER_OAUTH_LOCK_TIMEOUT_SECONDS=5 \
    IWE_SCHED_SELF_TEST_TIMEOUT=5 \
    IWE_SCHED_SELF_TEST_WORKER_LOG="$test_root/$stage_name-next.log" \
    IWE_SCHED_SELF_TEST_ENTRIES="$entries" \
    IWE_SCHED_SELF_TEST_CHILD_MODE=normal \
    IWE_SCHED_SELF_TEST_CHILD_TAG="$stage_name-next" \
    bash "$SCHEDULER_SELF" --self-test-oauth-lineage
  stage_next_rc=$?
  if [ -n "$stage_controller" ] \
     && [ "$stage_canonical_absent" -eq 1 ] \
     && [ "$stage_shape_ok" -eq 1 ] \
     && [ "$stage_rc" -ne 0 ] \
     && [ "$stage_next_rc" -eq 0 ] \
     && [ "$(wc -l < "$entries" | tr -d ' ')" -eq 1 ] \
     && test_oauth_bridge_absent; then
    self_test_ok "SIGKILL at $stage_name leaves only non-blocking private staging"
  else
    self_test_bad "$stage_name SIGKILL controller=$stage_controller canonical=$stage_canonical_absent shape=$stage_shape_ok old=$stage_rc next=$stage_next_rc entries=$(wc -l < "$entries" | tr -d ' ')"
  fi
  if [ -n "$stage_private" ]; then
    rm -f "$stage_private/owner" "$stage_private/pid"
    rmdir "$stage_private" 2>/dev/null || true
  fi
  }

  self_test_top_shell_crash() {
  : > "$entries"
  env IWE_SCHED_SELF_TEST_WORKER=1 \
    IWE_PEER_LOCK_DIR="$lock_root" IWE_PEER_OAUTH_LOCK_TIMEOUT_SECONDS=10 \
    IWE_SCHED_SELF_TEST_TIMEOUT=30 \
    IWE_SCHED_SELF_TEST_WORKER_LOG="$test_root/first.log" \
    IWE_SCHED_SELF_TEST_ENTRIES="$entries" \
    IWE_SCHED_SELF_TEST_CHILD_MODE=resistant \
    IWE_SCHED_SELF_TEST_CHILD_TAG=first \
    IWE_SCHED_SELF_TEST_CHILD_READY="$test_root/first.ready" \
    IWE_SCHED_SELF_TEST_CHILD_VENDOR_PID_FILE="$test_root/first.vendor" \
    IWE_SCHED_SELF_TEST_CHILD_GRANDCHILD_PID_FILE="$test_root/first.grandchild" \
    bash "$SCHEDULER_SELF" --self-test-oauth-lineage \
      2> "$test_root/first-top.err" &
  first_top=$!
  for _wait in $(seq 1 200); do
    [ -s "$test_root/first.vendor" ] \
      && [ -s "$test_root/first.grandchild" ] \
      && [ -e "$test_root/first.ready" ] && break
    sleep 0.025
  done
  first_vendor=$(tr -d '[:space:]' < "$test_root/first.vendor" 2>/dev/null || true)
  first_grandchild=$(tr -d '[:space:]' < "$test_root/first.grandchild" 2>/dev/null || true)
  first_holder=$(tr -d '[:space:]' < "$lock_root/kimi-oauth-refresh.lineage-v4/pid" 2>/dev/null || true)
  [ -L "$lock_root/kimi-oauth-refresh.lineage-v4" ] \
    && first_bridge_was_symlink=1 || first_bridge_was_symlink=0
  if [[ "$first_holder" == -* ]] && kill -0 "$first_holder" 2>/dev/null; then
    first_legacy_live=1
  else
    first_legacy_live=0
  fi
  kill -9 "$first_top" 2>/dev/null || true
  wait "$first_top" 2>/dev/null || true

  env IWE_SCHED_SELF_TEST_WORKER=1 \
    IWE_PEER_LOCK_DIR="$lock_root" IWE_PEER_OAUTH_LOCK_TIMEOUT_SECONDS=10 \
    IWE_SCHED_SELF_TEST_TIMEOUT=10 \
    IWE_SCHED_SELF_TEST_WORKER_LOG="$test_root/second.log" \
    IWE_SCHED_SELF_TEST_ENTRIES="$entries" \
    IWE_SCHED_SELF_TEST_CHILD_MODE=normal \
    IWE_SCHED_SELF_TEST_CHILD_TAG=second-scheduler \
    bash "$SCHEDULER_SELF" --self-test-oauth-lineage \
      2> "$test_root/second-top.err" &
  scheduler_top=$!

  if [ -x "$adapter" ]; then
    env HOME="$test_root/home" CODEX_SANDBOX='' CODEX_SANDBOX_NETWORK_DISABLED='' \
      IWE_ROOT="$test_root/iwe" IWE_PEER_LOCK_DIR="$lock_root" \
      IWE_PEER_OAUTH_LOCK_TIMEOUT_SECONDS=10 IWE_PEER_TIMEOUT_SECONDS=15 \
      IWE_PEER_PLAIN=1 KIMI_BIN="$SCHEDULER_SELF" \
      IWE_SCHED_SELF_TEST_FAKE_MODE=normal \
      IWE_SCHED_SELF_TEST_ENTRIES="$entries" \
      IWE_SCHED_SELF_TEST_TAG=adapter \
      bash "$adapter" --add-dir "$add_dir" \
      < /dev/null > "$test_root/adapter.out" 2> "$test_root/adapter.err" &
    adapter_top=$!
  else
    adapter_top=""
    self_test_bad "adapter not executable: $adapter"
  fi

  max_live=0
  for _sample in $(seq 1 900); do
    live=0
    while read -r _tag _pid; do
      process_is_non_zombie "$_pid" && live=$((live + 1))
    done < "$entries"
    [ "$live" -le "$max_live" ] || max_live="$live"
    sleep 0.01
  done
  wait "$scheduler_top" 2>/dev/null
  scheduler_rc=$?
  if [ -n "$adapter_top" ]; then
    wait "$adapter_top" 2>/dev/null
    adapter_rc=$?
  else
    adapter_rc=1
  fi
  wait_for_process_exit "$first_vendor" || true
  wait_for_process_exit "$first_grandchild" || true

  if [ -n "$first_holder" ] \
     && [ "$first_holder" != "$first_top" ] \
     && [ "$first_legacy_live" -eq 1 ] \
     && [ "$first_bridge_was_symlink" -eq 1 ] \
     && [ "$scheduler_rc" -eq 0 ] \
     && [ "$adapter_rc" -eq 0 ] \
     && [ "$max_live" -le 1 ] \
     && [ "$(wc -l < "$entries" | tr -d ' ')" -eq 3 ] \
     && ! process_is_non_zombie "$first_vendor" \
     && ! process_is_non_zombie "$first_grandchild" \
     && test_oauth_bridge_absent; then
    self_test_ok "SIGKILL top keeps adapter/second scheduler serialized until resistant lineage drains"
  else
    self_test_bad "SIGKILL serialization holder=$first_holder link=$first_bridge_was_symlink legacy-live=$first_legacy_live top=$first_top scheduler=$scheduler_rc adapter=$adapter_rc max_live=$max_live entries=$(tr '\n' ';' < "$entries")"
  fi
  }

  self_test_controller_crash() {
  : > "$entries"
  env IWE_SCHED_SELF_TEST_WORKER=1 \
    IWE_PEER_LOCK_DIR="$lock_root" IWE_PEER_OAUTH_LOCK_TIMEOUT_SECONDS=8 \
    IWE_SCHED_SELF_TEST_TIMEOUT=20 \
    IWE_SCHED_SELF_TEST_WORKER_LOG="$test_root/controller.log" \
    IWE_SCHED_SELF_TEST_ENTRIES="$entries" \
    IWE_SCHED_SELF_TEST_CHILD_MODE=resistant \
    IWE_SCHED_SELF_TEST_CHILD_TAG=controller-old \
    IWE_SCHED_SELF_TEST_CHILD_READY="$test_root/controller.ready" \
    IWE_SCHED_SELF_TEST_CHILD_VENDOR_PID_FILE="$test_root/controller.vendor" \
    IWE_SCHED_SELF_TEST_CHILD_GRANDCHILD_PID_FILE="$test_root/controller.grandchild" \
    IWE_SCHED_TEST_CONTROLLER_PID_FILE="$test_root/controller.controller" \
    IWE_SCHED_TEST_SENTINEL_PID_FILE="$test_root/controller.sentinel" \
    bash "$SCHEDULER_SELF" --self-test-oauth-lineage \
      2> "$test_root/controller-top.err" &
  controller_top=$!
  wait_for_lineage_fixture "$test_root" controller || true
  controller_vendor=$(tr -d '[:space:]' < "$test_root/controller.vendor" 2>/dev/null || true)
  controller_grandchild=$(tr -d '[:space:]' < "$test_root/controller.grandchild" 2>/dev/null || true)
  controller_pid=$(tr -d '[:space:]' < "$test_root/controller.controller" 2>/dev/null || true)
  controller_sentinel=$(tr -d '[:space:]' < "$test_root/controller.sentinel" 2>/dev/null || true)
  [ -z "$controller_pid" ] || kill -9 "$controller_pid" 2>/dev/null || true

  env IWE_SCHED_SELF_TEST_WORKER=1 \
    IWE_PEER_LOCK_DIR="$lock_root" IWE_PEER_OAUTH_LOCK_TIMEOUT_SECONDS=8 \
    IWE_SCHED_SELF_TEST_TIMEOUT=8 \
    IWE_SCHED_SELF_TEST_WORKER_LOG="$test_root/controller-next.log" \
    IWE_SCHED_SELF_TEST_ENTRIES="$entries" \
    IWE_SCHED_SELF_TEST_CHILD_MODE=normal \
    IWE_SCHED_SELF_TEST_CHILD_TAG=controller-next \
    bash "$SCHEDULER_SELF" --self-test-oauth-lineage &
  controller_next=$!
  controller_max_live=0
  for _sample in $(seq 1 500); do
    live=0
    while read -r _tag _pid; do
      process_is_non_zombie "$_pid" && live=$((live + 1))
    done < "$entries"
    [ "$live" -le "$controller_max_live" ] || controller_max_live="$live"
    sleep 0.01
  done
  wait "$controller_top" 2>/dev/null
  controller_rc=$?
  wait "$controller_next" 2>/dev/null
  controller_next_rc=$?
  wait_for_process_exit "$controller_vendor" || true
  wait_for_process_exit "$controller_grandchild" || true
  wait_for_process_exit "$controller_sentinel" || true
  if [ -n "$controller_pid" ] \
     && [ "$controller_pid" != "$controller_top" ] \
     && [ "$controller_sentinel" != "$controller_pid" ] \
     && [ "$controller_rc" -ne 0 ] \
     && [ "$controller_next_rc" -eq 0 ] \
     && [ "$controller_max_live" -le 1 ] \
     && [ "$(wc -l < "$entries" | tr -d ' ')" -eq 2 ] \
     && ! process_is_non_zombie "$controller_vendor" \
     && ! process_is_non_zombie "$controller_grandchild" \
     && ! process_is_non_zombie "$controller_sentinel" \
     && test_oauth_bridge_absent; then
    self_test_ok "SIGKILL controller leaves sentinel authoritative through resistant group drain"
  else
    self_test_bad "controller SIGKILL top=$controller_top controller=$controller_pid sentinel=$controller_sentinel rc=$controller_rc next=$controller_next_rc max_live=$controller_max_live entries=$(wc -l < "$entries" | tr -d ' ')"
  fi
  }

  self_test_sentinel_crash() {
  : > "$entries"
  env IWE_SCHED_SELF_TEST_WORKER=1 \
    IWE_PEER_LOCK_DIR="$lock_root" IWE_PEER_OAUTH_LOCK_TIMEOUT_SECONDS=8 \
    IWE_SCHED_SELF_TEST_TIMEOUT=20 \
    IWE_SCHED_SELF_TEST_WORKER_LOG="$test_root/sentinel.log" \
    IWE_SCHED_SELF_TEST_ENTRIES="$entries" \
    IWE_SCHED_SELF_TEST_CHILD_MODE=resistant \
    IWE_SCHED_SELF_TEST_CHILD_TAG=sentinel-old \
    IWE_SCHED_SELF_TEST_CHILD_READY="$test_root/sentinel.ready" \
    IWE_SCHED_SELF_TEST_CHILD_VENDOR_PID_FILE="$test_root/sentinel.vendor" \
    IWE_SCHED_SELF_TEST_CHILD_GRANDCHILD_PID_FILE="$test_root/sentinel.grandchild" \
    IWE_SCHED_TEST_CONTROLLER_PID_FILE="$test_root/sentinel.controller" \
    IWE_SCHED_TEST_SENTINEL_PID_FILE="$test_root/sentinel.sentinel" \
    bash "$SCHEDULER_SELF" --self-test-oauth-lineage &
  sentinel_top=$!
  wait_for_lineage_fixture "$test_root" sentinel || true
  sentinel_vendor=$(tr -d '[:space:]' < "$test_root/sentinel.vendor" 2>/dev/null || true)
  sentinel_grandchild=$(tr -d '[:space:]' < "$test_root/sentinel.grandchild" 2>/dev/null || true)
  sentinel_controller=$(tr -d '[:space:]' < "$test_root/sentinel.controller" 2>/dev/null || true)
  sentinel_pid_value=$(tr -d '[:space:]' < "$test_root/sentinel.sentinel" 2>/dev/null || true)
  [ -z "$sentinel_pid_value" ] || kill -9 "$sentinel_pid_value" 2>/dev/null || true
  wait "$sentinel_top" 2>/dev/null
  sentinel_rc=$?
  wait_for_process_exit "$sentinel_vendor" || true
  wait_for_process_exit "$sentinel_grandchild" || true
  env IWE_SCHED_SELF_TEST_WORKER=1 \
    IWE_PEER_LOCK_DIR="$lock_root" IWE_PEER_OAUTH_LOCK_TIMEOUT_SECONDS=5 \
    IWE_SCHED_SELF_TEST_TIMEOUT=5 \
    IWE_SCHED_SELF_TEST_WORKER_LOG="$test_root/sentinel-next.log" \
    IWE_SCHED_SELF_TEST_ENTRIES="$entries" \
    IWE_SCHED_SELF_TEST_CHILD_MODE=normal \
    IWE_SCHED_SELF_TEST_CHILD_TAG=sentinel-next \
    bash "$SCHEDULER_SELF" --self-test-oauth-lineage
  sentinel_next_rc=$?
  if [ -n "$sentinel_controller" ] \
     && [ "$sentinel_pid_value" != "$sentinel_controller" ] \
     && [ "$sentinel_rc" -ne 0 ] \
     && [ "$sentinel_next_rc" -eq 0 ] \
     && ! process_is_non_zombie "$sentinel_vendor" \
     && ! process_is_non_zombie "$sentinel_grandchild" \
     && test_oauth_bridge_absent; then
    self_test_ok "SIGKILL sentinel makes live controller drain and exact-CAS clean"
  else
    self_test_bad "sentinel SIGKILL controller=$sentinel_controller sentinel=$sentinel_pid_value rc=$sentinel_rc next=$sentinel_next_rc"
  fi
  }

  self_test_missing_owner_tamper() {
  : > "$entries"
  env IWE_SCHED_SELF_TEST_WORKER=1 \
    IWE_PEER_LOCK_DIR="$lock_root" IWE_PEER_OAUTH_LOCK_TIMEOUT_SECONDS=8 \
    IWE_SCHED_SELF_TEST_TIMEOUT=20 \
    IWE_SCHED_SELF_TEST_WORKER_LOG="$test_root/tamper.log" \
    IWE_SCHED_SELF_TEST_ENTRIES="$entries" \
    IWE_SCHED_SELF_TEST_CHILD_MODE=resistant \
    IWE_SCHED_SELF_TEST_CHILD_TAG=tamper-old \
    IWE_SCHED_SELF_TEST_CHILD_READY="$test_root/tamper.ready" \
    IWE_SCHED_SELF_TEST_CHILD_VENDOR_PID_FILE="$test_root/tamper.vendor" \
    IWE_SCHED_SELF_TEST_CHILD_GRANDCHILD_PID_FILE="$test_root/tamper.grandchild" \
    bash "$SCHEDULER_SELF" --self-test-oauth-lineage &
  tamper_top=$!
  wait_for_lineage_fixture "$test_root" tamper || true
  tamper_vendor=$(tr -d '[:space:]' < "$test_root/tamper.vendor" 2>/dev/null || true)
  tamper_grandchild=$(tr -d '[:space:]' < "$test_root/tamper.grandchild" 2>/dev/null || true)
  rm -f "$lock_root/kimi-oauth-refresh.lineage-v4/owner"
  wait "$tamper_top" 2>/dev/null
  tamper_rc=$?
  wait_for_process_exit "$tamper_vendor" || true
  wait_for_process_exit "$tamper_grandchild" || true
  if [ "$tamper_rc" -ne 0 ] \
     && ! process_is_non_zombie "$tamper_vendor" \
     && ! process_is_non_zombie "$tamper_grandchild" \
     && grep -q 'OAuth authority lost: bridge-missing' "$test_root/tamper.log" \
     && [ -f "$lock_root/kimi-oauth-refresh.lineage-v4/pid" ] \
     && [ ! -e "$lock_root/kimi-oauth-refresh.lineage-v4/owner" ]; then
    tamper_drain_ok=1
  else
    tamper_drain_ok=0
  fi
  env IWE_SCHED_SELF_TEST_WORKER=1 \
    IWE_PEER_LOCK_DIR="$lock_root" IWE_PEER_OAUTH_LOCK_TIMEOUT_SECONDS=5 \
    IWE_SCHED_SELF_TEST_TIMEOUT=5 \
    IWE_SCHED_SELF_TEST_WORKER_LOG="$test_root/tamper-recovery.log" \
    IWE_SCHED_SELF_TEST_ENTRIES="$entries" \
    IWE_SCHED_SELF_TEST_CHILD_MODE=normal \
    IWE_SCHED_SELF_TEST_CHILD_TAG=tamper-recovered \
    bash "$SCHEDULER_SELF" --self-test-oauth-lineage
  tamper_recovery_rc=$?
  if [ "$tamper_drain_ok" -eq 1 ] \
     && [ "$tamper_recovery_rc" -eq 0 ] \
     && [ "$(wc -l < "$entries" | tr -d ' ')" -eq 2 ] \
     && grep -q 'owner metadata missing' "$test_root/tamper-recovery.log" \
     && test_oauth_bridge_absent; then
    self_test_ok "missing owner kills and drains the group, then exact v4 lineage recovers"
  else
    self_test_bad "tamper drain=$tamper_drain_ok rc=$tamper_rc recovery=$tamper_recovery_rc vendor=$tamper_vendor grandchild=$tamper_grandchild"
  fi
  }

  self_test_fence_tamper_fail_closed() {
  local fence_extra_rc
  : > "$entries"
  fence_tamper_target=$(readlink "$lock_root/kimi-oauth-refresh.lockdir" 2>/dev/null || true)
  fence_owner_saved=$(tr -d '\n' \
    < "$lock_root/$fence_tamper_target/owner" 2>/dev/null || true)
  env IWE_SCHED_SELF_TEST_WORKER=1 \
    IWE_PEER_LOCK_DIR="$lock_root" IWE_PEER_OAUTH_LOCK_TIMEOUT_SECONDS=5 \
    IWE_SCHED_SELF_TEST_TIMEOUT=20 \
    IWE_SCHED_SELF_TEST_WORKER_LOG="$test_root/fence-tamper.log" \
    IWE_SCHED_SELF_TEST_ENTRIES="$entries" \
    IWE_SCHED_SELF_TEST_CHILD_MODE=resistant \
    IWE_SCHED_SELF_TEST_CHILD_TAG=fence-tamper-old \
    IWE_SCHED_SELF_TEST_CHILD_READY="$test_root/fence-tamper.ready" \
    IWE_SCHED_SELF_TEST_CHILD_VENDOR_PID_FILE="$test_root/fence-tamper.vendor" \
    IWE_SCHED_SELF_TEST_CHILD_GRANDCHILD_PID_FILE="$test_root/fence-tamper.grandchild" \
    bash "$SCHEDULER_SELF" --self-test-oauth-lineage &
  fence_tamper_top=$!
  wait_for_lineage_fixture "$test_root" fence-tamper || true
  fence_tamper_vendor=$(tr -d '[:space:]' \
    < "$test_root/fence-tamper.vendor" 2>/dev/null || true)
  fence_tamper_grandchild=$(tr -d '[:space:]' \
    < "$test_root/fence-tamper.grandchild" 2>/dev/null || true)
  # Appending an invalid ASCII byte must not be normalized back to the exact
  # owner payload by a permissive decoder.
  printf '%s\377\n' "$fence_owner_saved" \
    > "$lock_root/$fence_tamper_target/owner"
  wait "$fence_tamper_top" 2>/dev/null
  fence_tamper_rc=$?
  wait_for_process_exit "$fence_tamper_vendor" || true
  wait_for_process_exit "$fence_tamper_grandchild" || true

  env IWE_SCHED_SELF_TEST_WORKER=1 \
    IWE_PEER_LOCK_DIR="$lock_root" IWE_PEER_OAUTH_LOCK_TIMEOUT_SECONDS=1 \
    IWE_SCHED_SELF_TEST_TIMEOUT=5 \
    IWE_SCHED_SELF_TEST_WORKER_LOG="$test_root/fence-tamper-next.log" \
    IWE_SCHED_SELF_TEST_ENTRIES="$entries" \
    IWE_SCHED_SELF_TEST_CHILD_MODE=normal \
    IWE_SCHED_SELF_TEST_CHILD_TAG=fence-tamper-must-not-run \
    bash "$SCHEDULER_SELF" --self-test-oauth-lineage
  fence_tamper_next_rc=$?
  printf '%s\n' "$fence_owner_saved" \
    > "$lock_root/$fence_tamper_target/owner"
  : > "$lock_root/$fence_tamper_target/unexpected"
  env IWE_SCHED_SELF_TEST_WORKER=1 \
    IWE_PEER_LOCK_DIR="$lock_root" IWE_PEER_OAUTH_LOCK_TIMEOUT_SECONDS=1 \
    IWE_SCHED_SELF_TEST_TIMEOUT=5 \
    IWE_SCHED_SELF_TEST_WORKER_LOG="$test_root/fence-extra-entry.log" \
    IWE_SCHED_SELF_TEST_ENTRIES="$entries" \
    IWE_SCHED_SELF_TEST_CHILD_MODE=normal \
    IWE_SCHED_SELF_TEST_CHILD_TAG=fence-extra-entry-must-not-run \
    bash "$SCHEDULER_SELF" --self-test-oauth-lineage
  fence_extra_rc=$?
  rm -f "$lock_root/$fence_tamper_target/unexpected"
  if [ -n "$fence_tamper_target" ] \
     && [ -n "$fence_owner_saved" ] \
     && [ "$fence_tamper_rc" -ne 0 ] \
     && [ "$fence_tamper_next_rc" -eq 75 ] \
     && [ "$fence_extra_rc" -eq 75 ] \
     && [ "$(wc -l < "$entries" | tr -d ' ')" -eq 1 ] \
     && ! process_is_non_zombie "$fence_tamper_vendor" \
     && ! process_is_non_zombie "$fence_tamper_grandchild" \
     && grep -q 'legacy-fence' "$test_root/fence-tamper.log" \
     && test_oauth_bridge_absent; then
    self_test_ok "non-ASCII or extra-entry fence tamper blocks admission and drains"
  else
    self_test_bad "fence tamper old=$fence_tamper_rc next=$fence_tamper_next_rc extra=$fence_extra_rc target=$fence_tamper_target entries=$(wc -l < "$entries" | tr -d ' ')"
  fi
  }

  self_test_scheduler_stale_to_adapter() {
  : > "$entries"
  env IWE_SCHED_SELF_TEST_WORKER=1 \
    IWE_PEER_LOCK_DIR="$lock_root" IWE_PEER_OAUTH_LOCK_TIMEOUT_SECONDS=8 \
    IWE_SCHED_SELF_TEST_TIMEOUT=30 \
    IWE_SCHED_SELF_TEST_WORKER_LOG="$test_root/double.log" \
    IWE_SCHED_SELF_TEST_ENTRIES="$entries" \
    IWE_SCHED_SELF_TEST_CHILD_MODE=resistant \
    IWE_SCHED_SELF_TEST_CHILD_TAG=double-old \
    IWE_SCHED_SELF_TEST_CHILD_READY="$test_root/double.ready" \
    IWE_SCHED_SELF_TEST_CHILD_VENDOR_PID_FILE="$test_root/double.vendor" \
    IWE_SCHED_SELF_TEST_CHILD_GRANDCHILD_PID_FILE="$test_root/double.grandchild" \
    IWE_SCHED_TEST_CONTROLLER_PID_FILE="$test_root/double.controller" \
    IWE_SCHED_TEST_SENTINEL_PID_FILE="$test_root/double.sentinel" \
    bash "$SCHEDULER_SELF" --self-test-oauth-lineage \
      2> "$test_root/double-top.err" &
  double_top=$!
  wait_for_lineage_fixture "$test_root" double || true
  double_vendor=$(tr -d '[:space:]' < "$test_root/double.vendor" 2>/dev/null || true)
  double_grandchild=$(tr -d '[:space:]' < "$test_root/double.grandchild" 2>/dev/null || true)
  double_controller=$(tr -d '[:space:]' < "$test_root/double.controller" 2>/dev/null || true)
  double_sentinel=$(tr -d '[:space:]' < "$test_root/double.sentinel" 2>/dev/null || true)
  double_holder=$(tr -d '[:space:]' < "$lock_root/kimi-oauth-refresh.lineage-v4/pid" 2>/dev/null || true)
  [ -L "$lock_root/kimi-oauth-refresh.lineage-v4" ] \
    && double_bridge_was_symlink=1 || double_bridge_was_symlink=0
  if [ -n "$double_controller" ] && [ -n "$double_sentinel" ]; then
    kill -9 "$double_controller" "$double_sentinel" 2>/dev/null || true
  fi
  if [ "$double_holder" = "-$double_vendor" ] \
     && kill -0 "$double_holder" 2>/dev/null; then
    double_legacy_live=1
  else
    double_legacy_live=0
  fi
  wait "$double_top" 2>/dev/null
  double_rc=$?

  env IWE_SCHED_SELF_TEST_WORKER=1 \
    IWE_PEER_LOCK_DIR="$lock_root" IWE_PEER_OAUTH_LOCK_TIMEOUT_SECONDS=1 \
    IWE_SCHED_SELF_TEST_TIMEOUT=5 \
    IWE_SCHED_SELF_TEST_WORKER_LOG="$test_root/double-blocked.log" \
    IWE_SCHED_SELF_TEST_ENTRIES="$entries" \
    IWE_SCHED_SELF_TEST_CHILD_MODE=normal \
    IWE_SCHED_SELF_TEST_CHILD_TAG=double-must-block \
    bash "$SCHEDULER_SELF" --self-test-oauth-lineage
  double_blocked_rc=$?
  double_entry_count=$(wc -l < "$entries" | tr -d ' ')
  if [ -n "$double_vendor" ]; then
    kill -9 "-$double_vendor" 2>/dev/null || true
  fi
  wait_for_process_exit "$double_vendor" || true
  wait_for_process_exit "$double_grandchild" || true

  if [ -x "$adapter" ]; then
    env HOME="$test_root/home" CODEX_SANDBOX='' CODEX_SANDBOX_NETWORK_DISABLED='' \
      IWE_ROOT="$test_root/iwe" IWE_PEER_LOCK_DIR="$lock_root" \
      IWE_PEER_OAUTH_LOCK_TIMEOUT_SECONDS=8 IWE_PEER_TIMEOUT_SECONDS=12 \
      IWE_PEER_PLAIN=1 KIMI_BIN="$SCHEDULER_SELF" \
      IWE_SCHED_SELF_TEST_FAKE_MODE=normal \
      IWE_SCHED_SELF_TEST_ENTRIES="$entries" \
      IWE_SCHED_SELF_TEST_TAG=double-recovered-adapter \
      bash "$adapter" --add-dir "$adapter_recovery_dir" \
      < /dev/null > "$test_root/double-recovery.out" \
      2> "$test_root/double-recovery.err"
    double_recovery_rc=$?
  else
    double_recovery_rc=1
  fi
  if [ "$double_rc" -ne 0 ] \
     && [ "$double_legacy_live" -eq 1 ] \
     && [ "$double_bridge_was_symlink" -eq 1 ] \
     && [ "$double_blocked_rc" -eq 75 ] \
     && [ "$double_entry_count" -eq 1 ] \
     && [ "$double_recovery_rc" -eq 0 ] \
     && [ "$(wc -l < "$entries" | tr -d ' ')" -eq 2 ] \
     && ! process_is_non_zombie "$double_vendor" \
     && ! process_is_non_zombie "$double_grandchild" \
     && test_oauth_bridge_absent; then
    self_test_ok "vendor-held lease blocks overlap, then adapter recovers scheduler-v4 lineage"
  else
    self_test_bad "double fault rc=$double_rc holder=$double_holder link=$double_bridge_was_symlink legacy-live=$double_legacy_live blocked=$double_blocked_rc before=$double_entry_count recovery=$double_recovery_rc entries=$(wc -l < "$entries" | tr -d ' ')"
  fi
  }

  self_test_adapter_stale_to_scheduler() {
  : > "$entries"
  env HOME="$test_root/home" CODEX_SANDBOX='' CODEX_SANDBOX_NETWORK_DISABLED='' \
    IWE_ROOT="$test_root/iwe" IWE_PEER_LOCK_DIR="$lock_root" \
    IWE_PEER_OAUTH_LOCK_TIMEOUT_SECONDS=8 IWE_PEER_TIMEOUT_SECONDS=12 \
    IWE_PEER_PLAIN=1 KIMI_BIN="$SCHEDULER_SELF" \
    IWE_PEER_TEST_OAUTH_PRE_SENTINEL_BARRIER="$test_root/adapter-stale-barrier" \
    IWE_SCHED_SELF_TEST_FAKE_MODE=normal \
    IWE_SCHED_SELF_TEST_ENTRIES="$entries" \
    IWE_SCHED_SELF_TEST_TAG=adapter-must-not-run \
    bash "$adapter" --add-dir "$adapter_stale_dir" \
    < /dev/null > "$test_root/adapter-stale.out" \
    2> "$test_root/adapter-stale.err" &
  adapter_stale_top=$!
  for _wait in $(seq 1 240); do
    [ -s "$test_root/adapter-stale-barrier.ready" ] \
      && [ -s "$lock_root/kimi-oauth-refresh.lineage-v4/owner" ] && break
    sleep 0.025
  done
  adapter_stale_helper=$(tr -d '[:space:]' \
    < "$test_root/adapter-stale-barrier.ready" 2>/dev/null || true)
  adapter_stale_owner=$(tr -d '\n' \
    < "$lock_root/kimi-oauth-refresh.lineage-v4/owner" 2>/dev/null || true)
  [ -z "$adapter_stale_helper" ] || kill -9 "$adapter_stale_helper" 2>/dev/null || true
  wait "$adapter_stale_top" 2>/dev/null
  adapter_stale_rc=$?

  env IWE_SCHED_SELF_TEST_WORKER=1 \
    IWE_PEER_LOCK_DIR="$lock_root" IWE_PEER_OAUTH_LOCK_TIMEOUT_SECONDS=5 \
    IWE_SCHED_SELF_TEST_TIMEOUT=5 \
    IWE_SCHED_SELF_TEST_WORKER_LOG="$test_root/adapter-stale-recovery.log" \
    IWE_SCHED_SELF_TEST_ENTRIES="$entries" \
    IWE_SCHED_SELF_TEST_CHILD_MODE=normal \
    IWE_SCHED_SELF_TEST_CHILD_TAG=adapter-stale-recovered \
    bash "$SCHEDULER_SELF" --self-test-oauth-lineage
  adapter_stale_recovery_rc=$?
  if [ -n "$adapter_stale_helper" ] \
     && [[ "$adapter_stale_owner" == iwe-oauth-lineage-v4\ * ]] \
     && [ "$adapter_stale_rc" -ne 0 ] \
     && [ "$adapter_stale_recovery_rc" -eq 0 ] \
     && [ "$(wc -l < "$entries" | tr -d ' ')" -eq 1 ] \
     && grep -q 'recovered drained OAuth v4 lineage' "$test_root/adapter-stale-recovery.log" \
     && test_oauth_bridge_absent; then
    self_test_ok "scheduler recovers adapter-v4 lineage before vendor admission"
  else
    self_test_bad "adapter stale helper=$adapter_stale_helper owner=$adapter_stale_owner adapter=$adapter_stale_rc scheduler=$adapter_stale_recovery_rc entries=$(wc -l < "$entries" | tr -d ' ')"
  fi
  }

  self_test_timeout_drain() {
  : > "$entries"
  env IWE_SCHED_SELF_TEST_WORKER=1 \
    IWE_PEER_LOCK_DIR="$lock_root" IWE_PEER_OAUTH_LOCK_TIMEOUT_SECONDS=5 \
    IWE_SCHED_SELF_TEST_TIMEOUT=1 \
    IWE_SCHED_SELF_TEST_WORKER_LOG="$test_root/timeout.log" \
    IWE_SCHED_SELF_TEST_ENTRIES="$entries" \
    IWE_SCHED_SELF_TEST_CHILD_MODE=resistant \
    IWE_SCHED_SELF_TEST_CHILD_TAG=timeout \
    IWE_SCHED_SELF_TEST_CHILD_READY="$test_root/timeout.ready" \
    IWE_SCHED_SELF_TEST_CHILD_VENDOR_PID_FILE="$test_root/timeout.vendor" \
    IWE_SCHED_SELF_TEST_CHILD_GRANDCHILD_PID_FILE="$test_root/timeout.grandchild" \
    bash "$SCHEDULER_SELF" --self-test-oauth-lineage &
  timeout_top=$!
  wait "$timeout_top" 2>/dev/null
  timeout_rc=$?
  timeout_vendor=$(tr -d '[:space:]' < "$test_root/timeout.vendor" 2>/dev/null || true)
  timeout_grandchild=$(tr -d '[:space:]' < "$test_root/timeout.grandchild" 2>/dev/null || true)
  wait_for_process_exit "$timeout_vendor" || true
  wait_for_process_exit "$timeout_grandchild" || true
  if [ "$timeout_rc" -eq 142 ] \
     && ! process_is_non_zombie "$timeout_vendor" \
     && ! process_is_non_zombie "$timeout_grandchild" \
     && test_oauth_bridge_absent; then
    self_test_ok "timeout returns 142 and drains TERM-resistant process group before unlock"
  else
    self_test_bad "timeout rc=$timeout_rc vendor=$timeout_vendor grandchild=$timeout_grandchild"
  fi
  }

  self_test_leader_exit_drain() {
  : > "$entries"
  env IWE_SCHED_SELF_TEST_WORKER=1 \
    IWE_PEER_LOCK_DIR="$lock_root" IWE_PEER_OAUTH_LOCK_TIMEOUT_SECONDS=5 \
    IWE_SCHED_SELF_TEST_TIMEOUT=5 \
    IWE_SCHED_SELF_TEST_WORKER_LOG="$test_root/normal.log" \
    IWE_SCHED_SELF_TEST_ENTRIES="$entries" \
    IWE_SCHED_SELF_TEST_CHILD_MODE=orphan-on-exit \
    IWE_SCHED_SELF_TEST_CHILD_TAG=normal \
    IWE_SCHED_SELF_TEST_CHILD_GRANDCHILD_PID_FILE="$test_root/normal.grandchild" \
    bash "$SCHEDULER_SELF" --self-test-oauth-lineage
  normal_rc=$?
  normal_grandchild=$(tr -d '[:space:]' < "$test_root/normal.grandchild" 2>/dev/null || true)
  wait_for_process_exit "$normal_grandchild" || true
  if [ "$normal_rc" -eq 0 ] \
     && [ "$(wc -l < "$entries" | tr -d ' ')" -eq 1 ] \
     && ! process_is_non_zombie "$normal_grandchild" \
     && [ -f "$lock_root/kimi-oauth-refresh.lease" ] \
     && test_oauth_bridge_absent; then
    self_test_ok "normal leader exit drains descendants, releases bridge, and keeps permanent lease"
  else
    self_test_bad "normal rc=$normal_rc grandchild=$normal_grandchild entries=$(wc -l < "$entries" | tr -d ' ')"
  fi
  }

  self_test_python_resolution() {
  : > "$entries"
  mkdir -p "$test_root/no-python-bin"
  ln -s /bin/bash "$test_root/no-python-bin/bash"
  ln -s /bin/sleep "$test_root/no-python-bin/sleep"
  env PATH="$test_root/no-python-bin" \
    IWE_SCHED_PYTHON_RESOLVER="$test_root/missing-resolver" \
    IWE_SCHED_SELF_TEST_WORKER=1 \
    IWE_PEER_LOCK_DIR="$lock_root" IWE_PEER_OAUTH_LOCK_TIMEOUT_SECONDS=5 \
    IWE_SCHED_SELF_TEST_TIMEOUT=5 \
    IWE_SCHED_SELF_TEST_WORKER_LOG="$test_root/resolver.log" \
    IWE_SCHED_SELF_TEST_ENTRIES="$entries" \
    IWE_SCHED_SELF_TEST_CHILD_MODE=normal \
    IWE_SCHED_SELF_TEST_CHILD_TAG=resolver-fallback \
    /bin/bash "$SCHEDULER_SELF" --self-test-oauth-lineage
  resolver_rc=$?
  if [ "$resolver_rc" -eq 0 ] \
     && [ "$(wc -l < "$entries" | tr -d ' ')" -eq 1 ] \
     && test_oauth_bridge_absent; then
    self_test_ok "Python resolver works when PATH has no python3 first candidate"
  else
    self_test_bad "Python resolver fallback rc=$resolver_rc entries=$(wc -l < "$entries" | tr -d ' ')"
  fi
  }

  self_test_no_fence_fail_closed() {
  : > "$entries"
  env IWE_SCHED_SELF_TEST_WORKER=1 \
    IWE_PEER_LOCK_DIR="$lock_root" IWE_PEER_OAUTH_LOCK_TIMEOUT_SECONDS=1 \
    IWE_SCHED_SELF_TEST_TIMEOUT=5 \
    IWE_SCHED_SELF_TEST_WORKER_LOG="$test_root/no-fence.log" \
    IWE_SCHED_SELF_TEST_ENTRIES="$entries" \
    IWE_SCHED_SELF_TEST_CHILD_MODE=normal \
    IWE_SCHED_SELF_TEST_CHILD_TAG=no-fence-must-not-run \
    bash "$SCHEDULER_SELF" --self-test-oauth-lineage
  no_fence_rc=$?
  if [ "$no_fence_rc" -eq 75 ] \
     && [ ! -e "$lock_root/kimi-oauth-refresh.lockdir" ] \
     && [ ! -L "$lock_root/kimi-oauth-refresh.lockdir" ] \
     && [ ! -e "$lock_root/kimi-oauth-refresh.lineage-v4" ] \
     && [ ! -L "$lock_root/kimi-oauth-refresh.lineage-v4" ] \
     && [ ! -s "$entries" ] \
     && grep -q 'permanent v4 legacy fence invalid' "$test_root/no-fence.log"; then
    self_test_ok "admission without an explicit v4 cutover fails closed"
  else
    self_test_bad "no-fence admission rc=$no_fence_rc entries=$(wc -l < "$entries" | tr -d ' ')"
  fi
  }

  self_test_aba_cutover_boundary() {
  local canonical="$lock_root/kimi-oauth-refresh.lockdir"
  local aba_ready="$test_root/aba-legacy-decided"
  mkdir "$canonical"
  printf '%s\n' 999999 > "$canonical/pid"
  (
    local holder
    holder=$(tr -d '[:space:]' < "$canonical/pid")
    if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then
      : > "$aba_ready"
      while [ ! -e "$test_root/aba-release" ]; do
        sleep 0.025
      done
      rm -rf "$canonical"
      if mkdir "$canonical" 2>/dev/null; then
        printf '%s\n' "$$" > "$canonical/pid"
      fi
    fi
  ) &
  aba_legacy=$!
  for _wait in $(seq 1 240); do
    [ -e "$aba_ready" ] && break
    sleep 0.025
  done

  env IWE_OAUTH_CUTOVER_QUIESCED=1 IWE_PEER_LOCK_DIR="$lock_root" \
    IWE_PEER_OAUTH_LOCK_TIMEOUT_SECONDS=1 \
    bash "$SCHEDULER_SELF" --cutover-oauth-lineage-v4 \
    2> "$test_root/cutover-existing.err"
  cutover_existing_rc=$?
  rm -rf "$canonical"
  env IWE_PEER_LOCK_DIR="$lock_root" IWE_PEER_OAUTH_LOCK_TIMEOUT_SECONDS=1 \
    bash "$SCHEDULER_SELF" --cutover-oauth-lineage-v4 \
    2> "$test_root/cutover-no-assertion.err"
  cutover_missing_assertion_rc=$?

  if [ -e "$aba_ready" ] \
     && process_is_non_zombie "$aba_legacy" \
     && [ "$cutover_existing_rc" -eq 75 ] \
     && [ "$cutover_missing_assertion_rc" -eq 64 ] \
     && [ ! -e "$canonical" ] && [ ! -L "$canonical" ]; then
    self_test_ok "paused legacy check-to-rm cannot cross the explicit cutover boundary"
  else
    self_test_bad "ABA boundary legacy=$aba_legacy existing=$cutover_existing_rc assertion=$cutover_missing_assertion_rc"
  fi
  kill -9 "$aba_legacy" 2>/dev/null || true
  wait "$aba_legacy" 2>/dev/null || true
  aba_legacy=""
  }

  self_test_cutover_publication_race() {
  local canonical="$lock_root/kimi-oauth-refresh.lockdir"
  cutover_race_barrier="$test_root/cutover-publish-race"
  env IWE_OAUTH_CUTOVER_QUIESCED=1 IWE_PEER_LOCK_DIR="$lock_root" \
    IWE_PEER_OAUTH_LOCK_TIMEOUT_SECONDS=2 \
    IWE_SCHED_TEST_CUTOVER_PRE_PUBLISH_BARRIER="$cutover_race_barrier" \
    bash "$SCHEDULER_SELF" --cutover-oauth-lineage-v4 \
    2> "$test_root/cutover-publish-race.err" &
  cutover_race_top=$!
  for _wait in $(seq 1 240); do
    [ -s "$cutover_race_barrier.ready" ] && break
    sleep 0.025
  done
  if [ ! -s "$cutover_race_barrier.ready" ]; then
    self_test_bad "cutover publication race never reached its barrier"
    kill -9 "$cutover_race_top" 2>/dev/null || true
    wait "$cutover_race_top" 2>/dev/null || true
    cutover_race_top=""
    return
  fi
  mkdir "$canonical"
  printf '%s\n' "$$" > "$canonical/pid"
  : > "$cutover_race_barrier.release"
  wait "$cutover_race_top" 2>/dev/null
  cutover_race_rc=$?
  cutover_race_top=""
  cutover_staging=$(find "$lock_root" -maxdepth 1 -type d \
    -name 'kimi-oauth-refresh.fence-v4.*' -print 2>/dev/null | head -1)
  if [ "$cutover_race_rc" -eq 75 ] \
     && [ -d "$canonical" ] && [ ! -L "$canonical" ] \
     && [ "$(tr -d '[:space:]' < "$canonical/pid")" = "$$" ] \
     && [ -z "$cutover_staging" ]; then
    self_test_ok "cutover publication never replaces a concurrently installed legacy directory"
  else
    self_test_bad "cutover publish race rc=$cutover_race_rc staging=$cutover_staging"
  fi
  rm -f "$canonical/pid"
  rmdir "$canonical" 2>/dev/null || true
  }

  self_test_cutover_idempotence() {
  env IWE_OAUTH_CUTOVER_QUIESCED=1 IWE_PEER_LOCK_DIR="$lock_root" \
    IWE_PEER_OAUTH_LOCK_TIMEOUT_SECONDS=2 \
    bash "$SCHEDULER_SELF" --cutover-oauth-lineage-v4 \
    2> "$test_root/cutover.err"
  cutover_rc=$?
  cutover_target=$(readlink "$lock_root/kimi-oauth-refresh.lockdir" 2>/dev/null || true)
  env IWE_OAUTH_CUTOVER_QUIESCED=1 IWE_PEER_LOCK_DIR="$lock_root" \
    IWE_PEER_OAUTH_LOCK_TIMEOUT_SECONDS=2 \
    bash "$SCHEDULER_SELF" --cutover-oauth-lineage-v4 \
    2> "$test_root/cutover-again.err"
  cutover_again_rc=$?
  cutover_target_again=$(readlink "$lock_root/kimi-oauth-refresh.lockdir" 2>/dev/null || true)
  if [ "$cutover_rc" -eq 0 ] \
     && [ "$cutover_again_rc" -eq 0 ] \
     && [ -n "$cutover_target" ] \
     && [ "$cutover_target_again" = "$cutover_target" ] \
     && test_legacy_fence \
     && test_oauth_bridge_absent \
     && grep -q 'cutover already installed' "$test_root/cutover-again.err"; then
    self_test_ok "explicit cutover publishes one durable idempotent legacy fence"
  else
    self_test_bad "cutover rc=$cutover_rc again=$cutover_again_rc target=$cutover_target/$cutover_target_again"
  fi
  }

  self_test_adapter_cutover_to_scheduler() {
  local adapter_cutover_root="$test_root/adapter-cutover-locks"
  local adapter_cutover_entries="$test_root/adapter-cutover.entries"
  local adapter_cutover_rc adapter_cutover_scheduler_rc
  mkdir -p "$adapter_cutover_root"
  : > "$adapter_cutover_entries"
  if [ -x "$adapter" ]; then
    env IWE_OAUTH_CUTOVER_QUIESCED=1 \
      IWE_PEER_LOCK_DIR="$adapter_cutover_root" \
      bash "$adapter" --cutover-oauth-lineage-v4 \
      > "$test_root/adapter-cutover.out" \
      2> "$test_root/adapter-cutover.err"
    adapter_cutover_rc=$?
  else
    adapter_cutover_rc=1
  fi

  env IWE_SCHED_SELF_TEST_WORKER=1 \
    IWE_PEER_LOCK_DIR="$adapter_cutover_root" \
    IWE_PEER_OAUTH_LOCK_TIMEOUT_SECONDS=5 \
    IWE_SCHED_SELF_TEST_TIMEOUT=5 \
    IWE_SCHED_SELF_TEST_WORKER_LOG="$test_root/adapter-cutover-scheduler.log" \
    IWE_SCHED_SELF_TEST_ENTRIES="$adapter_cutover_entries" \
    IWE_SCHED_SELF_TEST_CHILD_MODE=normal \
    IWE_SCHED_SELF_TEST_CHILD_TAG=adapter-cutover-scheduler \
    bash "$SCHEDULER_SELF" --self-test-oauth-lineage
  adapter_cutover_scheduler_rc=$?

  if [ "$adapter_cutover_rc" -eq 0 ] \
     && [ "$adapter_cutover_scheduler_rc" -eq 0 ] \
     && [ "$(wc -l < "$adapter_cutover_entries" | tr -d ' ')" -eq 1 ] \
     && test_legacy_fence "$adapter_cutover_root" \
     && [ ! -e "$adapter_cutover_root/kimi-oauth-refresh.lineage-v4" ] \
     && [ ! -L "$adapter_cutover_root/kimi-oauth-refresh.lineage-v4" ]; then
    self_test_ok "scheduler admits one run behind an adapter-created exact v4 fence"
  else
    self_test_bad "adapter cutover=$adapter_cutover_rc scheduler=$adapter_cutover_scheduler_rc entries=$(wc -l < "$adapter_cutover_entries" | tr -d ' ')"
  fi
  }

  self_test_rollback_legacy_fail_closed() {
  local canonical="$lock_root/kimi-oauth-refresh.lockdir"
  rollback_target=$(readlink "$canonical" 2>/dev/null || true)
  rollback_result=$(
    if mkdir "$canonical" 2>/dev/null; then
      echo entered
    else
      local holder
      holder=$(cat "$canonical/pid" 2>/dev/null | tr -d '[:space:]')
      if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then
        rm -rf "$canonical"
        echo removed
      else
        echo blocked
      fi
    fi
  )
  if [ "$rollback_result" = blocked ] \
     && kill -0 -1 2>/dev/null \
     && [ "$(readlink "$canonical" 2>/dev/null || true)" = "$rollback_target" ] \
     && test_legacy_fence; then
    self_test_ok "deployed or rolled-back legacy scheduler remains fail-closed on pid=-1"
  else
    self_test_bad "legacy rollback result=$rollback_result target=$rollback_target"
  fi
  }

  self_test_no_fence_fail_closed
  self_test_aba_cutover_boundary
  self_test_cutover_publication_race
  self_test_cutover_idempotence
  self_test_adapter_cutover_to_scheduler
  self_test_rollback_legacy_fail_closed
  self_test_private_publication_crash \
    private-mkdir IWE_SCHED_TEST_OAUTH_PRIVATE_MKDIR_BARRIER
  self_test_private_publication_crash \
    private-pid IWE_SCHED_TEST_OAUTH_PRIVATE_PID_BARRIER
  self_test_top_shell_crash
  self_test_controller_crash
  self_test_sentinel_crash
  self_test_missing_owner_tamper
  self_test_fence_tamper_fail_closed
  self_test_scheduler_stale_to_adapter
  self_test_adapter_stale_to_scheduler
  self_test_timeout_drain
  self_test_leader_exit_drain
  self_test_python_resolution

  echo "self-test: $passed passed, $failed failed"
  trap - EXIT HUP INT TERM
  if [ "$failed" -eq 0 ]; then
    cleanup_oauth_lineage_self_test 0
  else
    cleanup_oauth_lineage_self_test 1
  fi
  [ "$failed" -eq 0 ]
}

if [ -n "${IWE_SCHED_SELF_TEST_FAKE_MODE:-}" ]; then
  scheduler_self_test_fake_kimi "$@"
fi
if [ "${1:-}" = "--self-test-oauth-lineage" ]; then
  if [ "${IWE_SCHED_SELF_TEST_WORKER:-0}" = "1" ]; then
    run_scheduler_self_test_worker
  else
    run_oauth_lineage_self_test
  fi
  exit $?
fi
if [ "${1:-}" = "--cutover-oauth-lineage-v4" ]; then
  if [ "$#" -ne 1 ]; then
    echo "ERROR: --cutover-oauth-lineage-v4 accepts no other arguments" >&2
    exit 64
  fi
  cutover_oauth_lineage_v4
  exit $?
fi

ID="${1:-}"
[ -n "$ID" ] || { echo "ERROR: usage: kimi-wp-run-scheduled.sh <id>" >&2; exit 1; }

IWE_ROOT="${IWE_ROOT:-$HOME/IWE}"
# launchd runs this with a bare environment (no .claude/settings.json injection) —
# without this, IWE_GOVERNANCE_REPO stays unset and session-guard.sh falls back
# to the template default, misfiling sessions into the wrong directory.
# shellcheck source=/dev/null
source "$IWE_ROOT/.claude/lib/iwe-env-bootstrap.sh" || exit 1
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
# shellcheck source=DS-my-strategy/scripts/lib/governance-repo-path.sh
# shellcheck disable=SC1091  # absolute runtime path is selected by bootstrap
. "$IWE_ROOT/DS-my-strategy/scripts/lib/governance-repo-path.sh"
GOV_REPO_DIR="$(resolve_canonical_checkout)"
QUEUE_DIR="$IWE_ROOT/.iwe-runtime/wp-queue"
QUEUE_FILE="$QUEUE_DIR/queue.tsv"
LOG_DIR="$IWE_ROOT/.iwe-runtime/logs/wp-queue"
PLIST="$HOME/Library/LaunchAgents/ai.iwe.wp-queue.$ID.plist"
LABEL="ai.iwe.wp-queue.$ID"
LOG="$LOG_DIR/$ID.log"
REPORT="$LOG_DIR/report.md"

mkdir -p "$LOG_DIR"
cd "$IWE_ROOT" || exit 1

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }

# Sanity check: session-guard.sh writes sessions/open-sessions.log under this
# repo blind — a wrong IWE_GOVERNANCE_REPO would misfile every session record
# with no error. Refuse to proceed into a repo that doesn't look real instead.
if [ ! -f "$GOV_REPO_DIR/docs/WP-REGISTRY.md" ]; then
  log "ERROR: IWE_GOVERNANCE_REPO='$IWE_GOVERNANCE_REPO' does not look like a real governance repo (no docs/WP-REGISTRY.md) — check IWE_GOVERNANCE_REPO in .exocortex.env"
  exit 1
fi

# --- прочитать задание ------------------------------------------------------
ROW=$(grep "^$ID"$'\t' "$QUEUE_FILE" || true)
[ -n "$ROW" ] || { log "ERROR: id $ID not found in queue.tsv"; exit 1; }
WP=$(echo "$ROW" | cut -f3)
AGENT=$(echo "$ROW" | cut -f4)
TIMEOUT_MIN=$(echo "$ROW" | cut -f5)
MAX_TURNS=$(echo "$ROW" | cut -f6)
TIMEOUT_SEC=$(( TIMEOUT_MIN * 60 ))

set_status() {  # set_status <new-status>
  local tmp; tmp=$(mktemp)
  awk -F'\t' -v OFS='\t' -v id="$ID" -v st="$1" '$1==id {$7=st} {print}' "$QUEUE_FILE" > "$tmp" && mv "$tmp" "$QUEUE_FILE"
}

cleanup() {  # выгрузить и удалить одноразовую задачу launchd
  # ВАЖНО: unload собственной задачи посылает SIGTERM текущему процессу —
  # поэтому сначала удаляем plist, unload делаем ПОСЛЕДНИМ действием скрипта.
  rm -f "$PLIST"
  launchctl remove "$LABEL" >/dev/null 2>&1 || true
}

report_line() {  # report_line <status> <note>
  # shellcheck disable=SC2016  # Markdown backticks and $-free text are literal
  printf -- '- **%s** `%s` — %s via %s: **%s** (%s). Лог: `.iwe-runtime/logs/wp-queue/%s.log`\n' \
    "$(date '+%Y-%m-%d %H:%M')" "$ID" "$WP" "$AGENT" "$1" "$2" "$ID" >> "$REPORT"
}

log "=== scheduled run $ID: $WP via $AGENT (timeout ${TIMEOUT_MIN}m) ==="
set_status running

# bug-2026-07-17-kimi-queue-autostash-conflict-and-orphaned-semaphores п.3:
# sweep_orphaned_semaphores exists in session-guard.sh (audit --cleanup-orphans)
# but nothing called it periodically -- orphaned .open files (dead pid or no
# parseable timestamp) accumulated across a whole night's queue with no
# cleanup between runs. This runner already fires once per queued WP through
# the night, which makes it the natural periodic trigger -- no separate cron
# needed. Best-effort: a sweep failure must not abort this WP's own run.
bash "$IWE_ROOT/scripts/session-guard.sh" audit --cleanup-orphans >>"$LOG" 2>&1 || \
  log "WARN: orphan semaphore sweep failed (non-fatal, continuing)"

# --- dry-run (тестовый режим: не запускает LLM, проверяет launchd+plumbing) ---
if [ "${IWE_WP_QUEUE_DRYRUN:-0}" = "1" ]; then
  log "DRY-RUN: simulating agent run (no LLM call)"
  sleep 2
  set_status done-dryrun
  report_line done-dryrun "dry-run, no LLM call"
  log "=== done: $ID (done-dryrun) ==="
  cleanup  # последнее действие: unload убивает текущий процесс
  exit 0
fi

# --- collision guard: skip if this WP already has an active session --------
# Root cause of 6 failed Claude runs, ночь 17-18.07: scheduled run launched
# while a manual peer-session was already open on the same WP — both edited
# the context file concurrently, burning the turn budget on lock contention
# instead of the actual task. No existing check catches this (session-guard.sh
# open always creates a semaphore, cross-session/cross-agent collision is
# unchecked) — so skip up front instead of paying for a doomed run.
IS_TASK=0
[[ "$WP" =~ ^TASK- ]] && IS_TASK=1
if [ "$IS_TASK" != "1" ]; then
  for f in "$IWE_ROOT/.iwe-runtime/sessions/"*.open; do
    [ -f "$f" ] || continue
    OTHER_WP=$(grep "^wp: " "$f" | head -1 | cut -d' ' -f2-)
    [ "$OTHER_WP" = "$WP" ] || continue
    # WP-537: GNU stat -f leaks garbage on Linux (filesystem-status mode, not
    # a format flag) -- GNU form first so it short-circuits before BSD form runs.
    F_MTIME=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0)
    F_AGE=$(( $(date +%s) - F_MTIME ))
    [ "$F_AGE" -gt 1800 ] && continue  # older than session-guard's own orphan TTL — stale, ignore
    log "SKIP: $WP already has an active session ($(basename "$f"), age ${F_AGE}s) — avoiding collision"
    set_status skipped-collision
    report_line skipped-collision "active session already open: $(basename "$f")"
    cleanup; exit 0
  done
fi

# --- session-guard open -----------------------------------------------------
if [ "$IS_TASK" = "1" ] || [ "$AGENT" = "codex" ]; then
  # задача без РП или Codex peer pass: housekeeping-сессия (без ORZ, без WP Gate)
  if ! bash "$IWE_ROOT/scripts/session-guard.sh" open --housekeeping "sched-$ID" --agent "$AGENT" --owner-pid "$$" --canonical-owner "launchd-scheduled" --standalone-launch >>"$LOG" 2>&1; then
    log "ERROR: session-guard open (housekeeping) failed"
    set_status failed; report_line failed "session-guard open failed"; cleanup; exit 1
  fi
  if [ "$IS_TASK" = "1" ]; then
    [ -f "$QUEUE_DIR/$ID.prompt" ] || { log "ERROR: TASK without prompt file"; set_status failed; report_line failed "TASK without prompt"; bash "$IWE_ROOT/scripts/session-guard.sh" close --housekeeping "sched-$ID" --agent "$AGENT" >>"$LOG" 2>&1; cleanup; exit 1; }
  fi
  PROMPT_FILE="$QUEUE_DIR/$ID.prompt"
elif ! bash "$IWE_ROOT/scripts/session-guard.sh" open \
      --wp "$WP" --task "Scheduled run ($ID)" --slug "sched-$ID" \
      --files "$IWE_GOVERNANCE_REPO/inbox/$WP/$WP.md" --agent "$AGENT" --owner-pid "$$" --canonical-owner "launchd-scheduled" >>"$LOG" 2>&1; then
  log "ERROR: session-guard open failed"
  set_status failed; report_line failed "session-guard open failed"; cleanup; exit 1
fi

# --- промпт -----------------------------------------------------------------
if [ "$IS_TASK" != "1" ] && [ "$AGENT" != "codex" ]; then
PROMPT_FILE="$QUEUE_DIR/$ID.prompt"
if [ ! -f "$PROMPT_FILE" ]; then
  PROMPT_FILE=$(mktemp)
  # bug-2026-07-17-...-orphaned-semaphores п.4: session-guard.sh open (above)
  # already computed and scaffolded this exact path -- the old prompt only
  # said "запиши итог в ORZ сессии" with no path, so the agent picked its own
  # filename by habit, diverging from the scaffold (14 empty scaffolds found
  # dead in one night's queue, real ORZ content landing elsewhere). Same
  # basename formula session-guard.sh itself uses (now_month/now_date-slug.md,
  # date-prefix stripped from slug if already present) -- computed here
  # independently rather than parsed out of the open log, so a log-format
  # change can't silently desync the two again.
  ORZ_SLUG="sched-$ID"
  # Same default-fallback contract as session-guard.sh (ORZ_DIR / WP-526 Ф2):
  # the actual scaffold session-guard open() creates above uses this exact
  # formula, so ORZ_PATH must match it or the prompt below points nowhere.
  SESSIONS_ROOT="${IWE_SESSIONS_ROOT:-$IWE_ROOT/MC-sessions}"
  ORZ_PATH="$SESSIONS_ROOT/$(date '+%Y-%m')/$(date '+%Y-%m-%d')-${ORZ_SLUG}.md"
  cat > "$PROMPT_FILE" <<EOF
Автономный запуск по расписанию (планировщик WP-487, DP.SC.192). WP Gate для этого РП уже согласован пилотом заранее — Ритуал согласования не требуется, работай сразу.

Задача: выполни рабочий продукт $WP. Первым делом прочитай контекст: ~/IWE/$IWE_GOVERNANCE_REPO/inbox/$WP/$WP.md. Иерархия доверия: код → документы → WP context.

Правила автономного прогона:
- Работай только по этому РП, не начинай других задач.
- Если заблокирован решением пилота — запиши blocker в frontmatter контекст-файла РП ($IWE_GOVERNANCE_REPO/inbox/$WP/$WP.md) и завершись, не жди.
- Git: стейджь только конкретные свои файлы (никаких git add -A/-u/.), trailer Co-Authored-By по своему агенту.
- Не начинай операций, которые могут не уложиться в оставшееся время — тебя принудительно завершат по таймауту.
- По завершении обнови статус фаз в frontmatter контекст-файла РП и запиши краткий итог в ORZ-файл, который уже создан по пути: $ORZ_PATH (не создавай новый файл с другим именем — редактируй именно этот).
EOF
fi
fi  # IS_TASK

# --- запуск агента под таймаутом --------------------------------------------
RC=0
case "$AGENT" in
  kimi)
    KIMI_BIN="$(command -v kimi 2>/dev/null || true)"
    if [ -z "$KIMI_BIN" ]; then
      KIMI_CANDIDATE="$HOME/Library/Application Support/Code/User/globalStorage/moonshot-ai.kimi-code/bin/kimi/kimi"
      [ ! -x "$KIMI_CANDIDATE" ] || KIMI_BIN="$KIMI_CANDIDATE"
    fi
    if [ -z "$KIMI_BIN" ]; then
      log "ERROR: kimi binary not found"
      set_status failed; report_line failed "kimi binary not found"
      bash "$IWE_ROOT/scripts/session-guard.sh" close --agent "$AGENT" >>"$LOG" 2>&1
      cleanup; exit 1
    fi
    # preflight: проверяет, что сессия открыта (мы только что открыли)
    bash "$IWE_ROOT/scripts/kimi-standalone-preflight.sh" >>"$LOG" 2>&1 || log "WARN: preflight non-zero, continuing"
    log "starting kimi with crash-safe OAuth lineage supervisor (timeout ${TIMEOUT_SEC}s, max-steps 100)"
    run_kimi_with_oauth_lineage "$TIMEOUT_SEC" "$PROMPT_FILE" "$LOG" \
      "$KIMI_BIN" --quiet --yolo \
      --max-steps-per-turn "${IWE_WP_QUEUE_MAX_STEPS:-100}"
    RC=$?
    ;;
  claude)
    CLAUDE_BIN="$(command -v claude 2>/dev/null || true)"
    if [ -z "$CLAUDE_BIN" ]; then
      log "ERROR: claude binary not found"
      set_status failed; report_line failed "claude binary not found"
      bash "$IWE_ROOT/scripts/session-guard.sh" close --agent "$AGENT" >>"$LOG" 2>&1
      cleanup; exit 1
    fi
    log "starting claude (timeout ${TIMEOUT_SEC}s, max-turns $MAX_TURNS)"
    perl -e 'my $t=shift; alarm $t; exec @ARGV' -- "$TIMEOUT_SEC" \
      "$CLAUDE_BIN" -p "$(cat "$PROMPT_FILE")" --max-turns "$MAX_TURNS" --dangerously-skip-permissions >>"$LOG" 2>&1
    RC=$?
    ;;
  codex)
    WP502_SCRIPT="$GOV_REPO_DIR/scripts/wp502-codex-peer-pass.sh"
    if [ ! -x "$WP502_SCRIPT" ]; then
      log "ERROR: wp502-codex-peer-pass.sh not found/executable: $WP502_SCRIPT"
      set_status failed; report_line failed "wp502 script missing"
      bash "$IWE_ROOT/scripts/session-guard.sh" close --housekeeping "sched-$ID" --agent "$AGENT" >>"$LOG" 2>&1 || true
      cleanup; exit 1
    fi
    if [ ! -f "$PROMPT_FILE" ]; then
      log "ERROR: codex run requires custom prompt (task description)"
      set_status failed; report_line failed "codex missing prompt"
      bash "$IWE_ROOT/scripts/session-guard.sh" close --housekeeping "sched-$ID" --agent "$AGENT" >>"$LOG" 2>&1 || true
      cleanup; exit 1
    fi
    TASK_TEXT=$(cat "$PROMPT_FILE")
    log "starting codex wp502 peer pass (timeout ${TIMEOUT_SEC}s)"
    perl -e 'my $t=shift; alarm $t; exec @ARGV' -- "$TIMEOUT_SEC" \
      bash "$WP502_SCRIPT" "$WP" "$TASK_TEXT" >>"$LOG" 2>&1
    RC=$?
    ;;
  *)
    log "ERROR: unknown agent $AGENT"; RC=1 ;;
esac

# --- результат ---------------------------------------------------------------
case "$RC" in
  0)   STATUS="done"; NOTE="exit 0" ;;
  142|124) STATUS=timeout; NOTE="killed by ${TIMEOUT_MIN}m timeout (exit $RC)" ;;
  *)   STATUS=failed;  NOTE="exit $RC" ;;
esac
log "finished: $STATUS (exit $RC)"

# bug-2026-07-17-...-orphaned-semaphores п.1: the agent commits its own work as
# part of executing the WP, but this runner never independently verified the
# push actually landed -- the incident it caused (6 real unpushed commits
# after a night's queue) went unnoticed until a manual `git status` the next
# morning, because RC=0 from the agent binary says nothing about whether its
# own push succeeded. Defense-in-depth, not a replacement for the agent's own
# push: if commits are still ahead of upstream after the run, attempt one
# explicit push and log the outcome either way, so a silent push failure shows
# up in the SAME log this runner already writes instead of surfacing days
# later as a "why isn't this on GitHub" investigation.
if [ "$IS_TASK" != "1" ] && [ -d "$GOV_REPO_DIR/.git" ]; then
  AHEAD=$(git -C "$GOV_REPO_DIR" rev-list "@{u}.." --count 2>/dev/null || echo "")
  if [ -n "$AHEAD" ] && [ "$AHEAD" -gt 0 ]; then
    log "push-check: $AHEAD unpushed commit(s) in $IWE_GOVERNANCE_REPO after agent run — pushing explicitly"
    if git -C "$GOV_REPO_DIR" push >>"$LOG" 2>&1; then
      log "push-check: OK ($AHEAD commit(s) pushed)"
    else
      log "push-check: FAILED — $AHEAD commit(s) still unpushed, needs manual attention"
    fi
  else
    log "push-check: up to date with upstream (or no tracking branch), nothing to push"
  fi
fi

set_status "$STATUS"
report_line "$STATUS" "$NOTE"

# --- session-guard close + самоудаление задачи -------------------------------
if [ "$IS_TASK" = "1" ] || [ "$AGENT" = "codex" ]; then
  bash "$IWE_ROOT/scripts/session-guard.sh" close --housekeeping "sched-$ID" --agent "$AGENT" >>"$LOG" 2>&1 || log "WARN: session-guard close non-zero"
else
  bash "$IWE_ROOT/scripts/session-guard.sh" close --agent "$AGENT" >>"$LOG" 2>&1 || log "WARN: session-guard close non-zero"
fi
[ -f "$QUEUE_DIR/$ID.prompt" ] && rm -f "$QUEUE_DIR/$ID.prompt"
log "=== done: $ID ($STATUS) ==="
cleanup  # последнее действие: unload убивает текущий процесс
exit 0
