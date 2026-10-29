"""Convergence registry of git checkouts: loader, validator, comparison with discovery.

WP-539 F21 B1 (ArchGate verdict in DRR-f21-b1-repo-registry). The registry says HOW
each checkout is meant to converge with its upstream on each host. It deliberately
does NOT hold fetch permissions: those stay in refs-sync-broker.repos.yaml until the
broker is switched (one fact, one place); a `fetch_allowed` key here is a validation
error, not an ignored field.

Read-only: nothing here touches a working tree, an index or a remote.
"""

import posixpath
import re
from pathlib import Path

try:
    import yaml
except ImportError:  # the caller reports it as "source unavailable", never as "no repos"
    yaml = None

REGISTRY_VERSION = 1
CLASSES = ("canon", "reader", "working", "undecided")
PURPOSES = ("normal", "copy")
HOSTS = ("mac", "tsekh-1")
SCOPES = ("repo", "checkout")
THRESHOLD_KEYS = (
    "fetch_max_age_min",
    "behind_max_commits",
    "behind_observed_for_min",
    "block_resolution_max_age_min",
)
ENTRY_KEYS = {
    "repo_id", "class", "checkouts", "expected_branch", "upstream",
    "decision_owner", "executor", "mutation_mechanism", "thresholds", "note",
}
CHECKOUT_KEYS = {"host", "path", "purpose", "optional", "integrity_evidence"}
REPO_ID_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*")


def _validate_checkout(where, checkout, seen):
    errors = []
    if not isinstance(checkout, dict):
        return [f"{where}: checkout должен быть словарём"]
    for key in sorted(set(checkout) - CHECKOUT_KEYS):
        errors.append(f"{where}: неизвестное поле checkout '{key}'")
    host, path = checkout.get("host"), checkout.get("path")
    if host not in HOSTS:
        errors.append(f"{where}: host должен быть одним из {HOSTS}, получено {host!r}")
    if not isinstance(path, str) or not path:
        errors.append(f"{where}: path обязателен и должен быть строкой")
    elif path.startswith("/") or ".." in path.split("/"):
        errors.append(f"{where}: path относителен корню IWE, без '..': {path!r}")
    elif posixpath.normpath(path) != path:
        errors.append(f"{where}: path в нормальной форме (без './' и завершающего '/'): {path!r}")
    elif host in HOSTS and (host, path) in seen:  # `host in HOSTS` first: an unhashable host must not reach the dict
        errors.append(f"{where}: пара ({host}, {path}) уже занята записью '{seen[(host, path)]}'")
    if checkout.get("purpose", "normal") not in PURPOSES:
        errors.append(f"{where}: purpose должен быть одним из {PURPOSES}")
    if not isinstance(checkout.get("optional", False), bool):
        errors.append(f"{where}: optional должен быть булевым")
    return errors


def _validate_entry(index, entry, seen_ids, seen_paths):
    label = f"repos[{index}]"
    if not isinstance(entry, dict):
        return [f"{label}: запись должна быть словарём"]
    errors = []
    repo_id = entry.get("repo_id")
    if not isinstance(repo_id, str) or not REPO_ID_RE.fullmatch(repo_id):
        errors.append(f"{label}: repo_id обязателен ([A-Za-z0-9._-]+), получено {repo_id!r}")
        label = f"{label}"
    else:
        label = f"{label} ({repo_id})"
        if repo_id in seen_ids:
            errors.append(f"{label}: repo_id повторяется")
        seen_ids.add(repo_id)
    if "fetch_allowed" in entry:
        errors.append(f"{label}: fetch_allowed здесь запрещён — право на получение хранит refs-sync-broker.repos.yaml")
    for key in sorted(set(entry) - ENTRY_KEYS - {"fetch_allowed"}):
        errors.append(f"{label}: неизвестное поле '{key}'")
    if entry.get("class") not in CLASSES:
        errors.append(f"{label}: class должен быть одним из {CLASSES}")
    checkouts = entry.get("checkouts")
    if not isinstance(checkouts, list) or not checkouts:
        errors.append(f"{label}: checkouts — непустой список")
    else:
        for n, checkout in enumerate(checkouts):
            errors += _validate_checkout(f"{label}.checkouts[{n}]", checkout, seen_paths)
            # Only well-typed pairs are hashable; a wrong type is already reported by the checkout check.
            if isinstance(checkout, dict) and checkout.get("host") in HOSTS and isinstance(checkout.get("path"), str):
                seen_paths.setdefault((checkout["host"], checkout["path"]), repo_id)
    owner = entry.get("decision_owner")
    if owner is not None:
        if not isinstance(owner, dict) or not owner.get("ref") or owner.get("scope") not in SCOPES:
            errors.append(f"{label}: decision_owner = null или {{ref, scope: {SCOPES}}}")
    elif entry.get("class") in ("canon", "reader", "working"):
        errors.append(f"{label}: класс {entry.get('class')} без записанного решения (decision_owner); неопределённое — class: undecided")
    thresholds = entry.get("thresholds") or {}
    if not isinstance(thresholds, dict):
        errors.append(f"{label}: thresholds должен быть словарём")
    else:
        for key, value in thresholds.items():
            if key not in THRESHOLD_KEYS:
                errors.append(f"{label}: неизвестный порог '{key}'")
            elif value is not None and (isinstance(value, bool) or not isinstance(value, int) or value < 0):
                errors.append(f"{label}: порог {key} = null или целое >= 0 (null = не задан, не ноль)")
    return errors


def validate(data):
    """List of human-readable errors; empty list means the registry is valid."""
    if not isinstance(data, dict):
        return ["корень реестра должен быть словарём"]
    errors = []
    version = data.get("version")
    if isinstance(version, bool) or version != REGISTRY_VERSION or not isinstance(version, int):
        errors.append(f"version должен быть {REGISTRY_VERSION}, получено {data.get('version')!r}")
    repos = data.get("repos")
    if not isinstance(repos, list) or not repos:
        return errors + ["repos — непустой список"]
    seen_ids, seen_paths = set(), {}
    for index, entry in enumerate(repos):
        errors += _validate_entry(index, entry, seen_ids, seen_paths)
    return errors


def load(path):
    """(registry or None, errors). A missing/broken/unreadable file is an error, never an empty registry."""
    path = Path(path)
    if yaml is None:
        return None, ["PyYAML не установлен — реестр не прочитан"]
    if not path.is_file():
        return None, [f"нет файла реестра: {path.name}"]
    try:
        data = yaml.safe_load(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, yaml.YAMLError) as exc:
        return None, [f"реестр не читается ({exc.__class__.__name__})"]
    errors = validate(data)
    return (None if errors else data), errors


def compare(registry, discovered, host_id):
    """Four separate answers, never one merged status.

    outside      -- found on disk, registered nowhere;
    absent       -- registered for this host (not optional), not found on disk;
    not_expected -- found on disk, registered only for other hosts;
    registered   -- found and registered for this host.
    `discovered` is a list of paths relative to the IWE root ('.' = the root itself).
    """
    mine, others, optional = {}, {}, set()
    for entry in registry["repos"]:
        for checkout in entry["checkouts"]:
            target = mine if checkout["host"] == host_id else others
            target[checkout["path"]] = entry["repo_id"]
            if checkout["host"] == host_id and checkout.get("optional"):
                optional.add(checkout["path"])
    found = set(discovered)
    return {
        "registered": sorted(found & set(mine)),
        "outside": sorted(found - set(mine) - set(others)),
        "not_expected": sorted((found - set(mine)) & set(others)),
        "absent": sorted(set(mine) - found - optional),
    }
