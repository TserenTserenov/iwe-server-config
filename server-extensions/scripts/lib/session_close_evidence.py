"""Read-only AR.005 proof for one exact open session, including published worktrees.

Never accept a caller's success flag or a model verdict. Reconstruct publication
receipts against freshly fetched origin/main and inspect every attributed path.
"""
from __future__ import annotations

import argparse
from collections import defaultdict
import json
import os
from pathlib import Path
import re
import subprocess

import claim_line
import publication_receipt as proof
import session_receipt_scope as scope


require = scope.require
SAFE_ID = re.compile(r"[A-Za-z0-9_.-]+")


def require_claim_syntax(raw: bytes) -> None:
    for line in raw.decode().splitlines():
        match = re.match(r"^\s*(file(?:_v2)?|commit)\s*:", line)
        if match:
            require(line.startswith(match.group(1) + ": "), "malformed claim prefix")


def common_dir(repo: Path) -> Path:
    return proof.repository_identity(repo)[0]


def canonical_path(value: str) -> Path:
    path = Path(value)
    require(path.is_absolute() and path.resolve(strict=True) == path,
            "noncanonical session path")
    return path


def session_files(raw: bytes, report: str, reports_common: Path) -> dict[Path, set[str]]:
    groups: dict[Path, set[str]] = defaultdict(set)
    pending = None
    unpaired = []
    for line in raw.decode().splitlines() + [""]:
        if pending is not None and not line.startswith("file_v2: "):
            unpaired.append(pending)
            pending = None
        if line.startswith("file: "):
            pending = line[6:]
            require(scope.exact_path(pending), "invalid file claim")
        elif line.startswith("file_v2: "):
            item = json.loads(line[9:], object_pairs_hook=scope.unique_object)
            require(isinstance(item, dict) and set(item) == {"path", "repo"}
                    and pending is not None and item["path"] == pending
                    and isinstance(item["repo"], str), "unpaired file attribution")
            common = canonical_path(item["repo"])
            require(common.name == ".git" and common.is_dir(), "invalid repository identity")
            groups[common].add(pending)
            pending = None
    require(unpaired == [report, "inbox/open-sessions.log"],
            "unqualified files outside the session report and runtime opening log")
    groups[reports_common].add(report)
    return dict(groups)


def session_commits(raw: bytes) -> dict[str, list[claim_line.Claim]]:
    groups: dict[str, list[claim_line.Claim]] = defaultdict(list)
    for line in raw.decode().splitlines():
        if not line.startswith("commit: "):
            continue
        claim = claim_line.parse(line)
        require(claim is not None and SAFE_ID.fullmatch(claim.repo) is not None
                and claim.repo not in {".", ".."}
                and claim_line.is_canonical_sha(claim.sha), "invalid commit claim")
        groups[claim.repo].append(claim)
        require(len(groups[claim.repo]) <= 32, "too many claims in one repository")
    require(bool(groups), "no owned publication claims")
    return dict(groups)


def registered_checkout(repo: Path, candidate: Path) -> None:
    require(common_dir(candidate) == common_dir(repo), "checkout belongs to another repository")
    registered = proof.git(repo, "worktree", "list", "--porcelain", "-z").split(b"\0")
    require(registered.count(b"worktree " + os.fsencode(candidate)) == 1,
            "checkout is not uniquely registered")


def repository_checkouts(repo: Path, claims: list[claim_line.Claim],
                         governance: Path, reports: Path) -> set[Path]:
    checkouts = set()
    for claim in claims:
        if claim.checkout not in (None, "-"):
            checkout = canonical_path(claim.checkout)
            registered_checkout(repo, checkout)
            checkouts.add(checkout)
        else:
            checkouts.add(repo)
    for recorded in (governance, reports):
        if common_dir(repo) == common_dir(recorded):
            registered_checkout(repo, recorded)
            checkouts.add(recorded)
    return checkouts


def published_entries(repo: Path, semaphore: Path, raw: bytes, name: str,
                      claims: list[claim_line.Claim], remote: str,
                      paths: set[str]) -> dict[str, list[tuple[str, dict | None]]]:
    published: dict[str, list[tuple[str, dict | None]]] = defaultdict(list)
    for claim in claims:
        changed = set(proof.changed_paths(repo, claim.sha))
        require(changed <= paths, "commit changes an unattributed path")
        if proof.ancestor(repo, claim.sha, remote):
            anchor = claim.sha
            rows = proof.entries(repo, claim.sha, sorted(changed))
        else:
            require(proof.verify(repo, semaphore, name, claim.sha, remote),
                    "owned commit lacks verified publication")
            receipt = scope.receipt_for(raw, name, claim.sha)
            anchor, rows = receipt["anchor_commit"], receipt["published_paths"]
        for row in rows:
            candidate = (anchor, row["entry"])
            if candidate not in published[row["path"]]:
                published[row["path"]].append(candidate)
    return dict(published)


def require_clean_path(checkout: Path, path: str, actual: dict | None,
                       remote_entry: dict | None) -> None:
    status = proof.git(checkout, "status", "--porcelain=v1", "-z", "--untracked-files=all",
                       "--ignored", "--", path)
    if not status:
        return
    # A stale shared checkout may hold the exact published report as an
    # untracked projection. Never extend this exception to index changes.
    require(status == b"?? " + os.fsencode(path) + b"\0" and remote_entry is not None
            and actual == remote_entry
            and not proof.git(checkout, "ls-files", "--stage", "-z", "--", path)
            and proof.entries(checkout, "HEAD", [path])[0]["entry"] is None,
            "uncommitted owned path: " + path)


def verify_paths(repo: Path, checkouts: set[Path], paths: set[str], remote: str,
                 published: dict[str, list[tuple[str, dict | None]]]) -> dict:
    algorithm = proof.git(repo, "rev-parse", "--show-object-format").decode().strip()
    require(algorithm in {"sha1", "sha256"}, "unsupported Git object format")
    snapshots = {}
    remote_entries = {row["path"]: row["entry"] for row in proof.entries(repo, remote, sorted(paths))}
    for path in paths:
        expected = scope.latest_entry(repo, published[path]) if path in published else remote_entries[path]
        for checkout in checkouts:
            actual = scope.local_entry(checkout, path, algorithm)
            require_clean_path(checkout, path, actual, remote_entries[path])
            require(actual == expected or actual == remote_entries[path],
                    "owned path differs from published content: " + path)
            snapshots[(checkout, path)] = (actual, remote_entries[path])
    return snapshots


def report_filled(path: Path) -> None:
    text = proof.snapshot(path).decode()
    match = re.search(r"(?m)^#{1,2} Главный инсайт\s*\n([^#]*)(?:^#|\Z)", text)
    require(match is not None and bool(match.group(1).strip()), "session report is missing its insight")


def verify_session(workspace: Path, agent: str, session_id: str, harness: str) -> dict:
    require(SAFE_ID.fullmatch(agent) is not None and SAFE_ID.fullmatch(session_id) is not None
            and session_id not in {".", "..", "default"} and bool(harness), "missing exact session identity")
    workspace = workspace.resolve(strict=True)
    semaphore = workspace / ".iwe-runtime" / "sessions" / f"{agent}-{session_id}.open"
    raw = proof.snapshot(semaphore)
    require_claim_syntax(raw)
    require(proof.field(raw, "agent") == agent and proof.field(raw, "session_id") == session_id
            and proof.field(raw, "harness_session_id") == harness, "session owner mismatch")
    require(proof.field(raw, "close_path") in {"quick-close", "peer-session", "unknown"},
            "unsupported session close path")
    governance = canonical_path(proof.field(raw, "governance_worktree"))
    reports = canonical_path(proof.field(raw, "orz_sessions_dir"))
    report = proof.field(raw, "orz_file")
    require(scope.exact_path(report), "invalid recorded report address")
    files = session_files(raw, report, common_dir(reports))
    commits = session_commits(raw)
    checked_common = set()
    all_snapshots = []
    tips = []
    for name, claims in commits.items():
        repo = workspace if name == "iwe-root" else (workspace / name).resolve(strict=True)
        common = common_dir(repo)
        require(common in files and common not in checked_common, "ambiguous repository attribution")
        checked_common.add(common)
        checkouts = repository_checkouts(repo, claims, governance, reports)
        remote = proof.fetch_target(repo, proof.MAIN_REF)
        tips.append((repo, remote))
        published = published_entries(repo, semaphore, raw, name, claims, remote, files[common])
        snapshots = verify_paths(repo, checkouts, files[common], remote, published)
        algorithm = proof.git(repo, "rev-parse", "--show-object-format").decode().strip()
        all_snapshots.append((algorithm, snapshots))
    require(checked_common == set(files), "file repository has no verified publication claims")
    report_filled(reports / report)
    for algorithm, snapshots in all_snapshots:
        for (checkout, path), (entry, remote_entry) in snapshots.items():
            actual = scope.local_entry(checkout, path, algorithm)
            require(actual == entry, "owned path changed during proof")
            require_clean_path(checkout, path, actual, remote_entry)
    require(all(proof.oid(repo, "refs/remotes/origin/main^{commit}") == remote for repo, remote in tips)
            and proof.snapshot(semaphore) == raw, "session or publication changed during proof")
    return {"check": "session_close", "result": "ok", "session_id": session_id,
            "files_checked": sum(map(len, files.values())),
            "commits_checked": sum(map(len, commits.values())), "report": str(reports / report)}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workspace", required=True, type=Path)
    parser.add_argument("--agent", required=True)
    parser.add_argument("--session-id", required=True)
    parser.add_argument("--harness-session-id", required=True)
    args = parser.parse_args()
    try:
        result = verify_session(args.workspace, args.agent, args.session_id, args.harness_session_id)
    except (OSError, ValueError, proof.ProofError, subprocess.SubprocessError) as error:
        print(json.dumps({"check": "session_close", "result": "block", "detail": str(error)}, ensure_ascii=False))
        return 1
    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
