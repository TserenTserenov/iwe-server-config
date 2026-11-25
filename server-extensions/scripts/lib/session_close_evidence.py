"""Read-only AR.005 proof for an exact session or an explicit no-owner close run.

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


def lag_note(checkout: Path, remote: str) -> str:
    """Name the checkout and how far it trails the published tip, so a stalled copy is not
    mistaken for a broken session or a broken sync service (WP-484 F327, 22.11: a session
    read this refusal as "the sync service is dead" while the copy was held by two dirty files)."""
    raw = proof.git(checkout, "rev-list", "--count", f"HEAD..{remote}", allowed=(0, 128)).decode().strip()
    behind = int(raw) if raw.isdigit() else None
    if behind:
        return (f" (checkout {checkout} is {behind} commits behind published main: "
                "advance that copy, then close again)")
    return f" (checkout {checkout})"


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
            if not (actual == expected or actual == remote_entries[path]):
                # The diagnostic git call runs only on the failure path: a slow or failing
                # rev-list must never turn a valid close into a refusal.
                require(False, "owned path differs from published content: " + path
                        + lag_note(checkout, remote))
            snapshots[(checkout, path)] = (actual, remote_entries[path])
    return snapshots


def report_filled(path: Path) -> None:
    text = proof.snapshot(path).decode()
    match = re.search(r"(?m)^#{1,2} Главный инсайт\s*\n([^#]*)(?:^#|\Z)", text)
    require(match is not None and bool(match.group(1).strip()), "session report is missing its insight")


def no_owner_run(workspace: Path, agent: str, harness: str,
                 run_id: str) -> tuple[Path, bytes, list[Path]]:
    """Require an explicit active run before considering an absent owner."""
    import yaml

    class UniqueLoader(yaml.SafeLoader):
        pass

    def unique_mapping(loader, node):
        pairs = loader.construct_pairs(node, deep=True)
        require(all(isinstance(key, str) for key, _ in pairs), "non-string run card key")
        return scope.unique_object(pairs)

    UniqueLoader.add_constructor(
        yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG,
        unique_mapping,
    )
    require(SAFE_ID.fullmatch(run_id) is not None and run_id.startswith("quick-close-"),
            "no-owner close requires an exact quick-close run id")
    governance = os.environ.get("IWE_GOVERNANCE_REPO", "DS-my-strategy")
    require(SAFE_ID.fullmatch(governance) is not None and governance not in {".", ".."},
            "invalid governance repository")
    card = workspace / governance / "inbox/agent/tasks" / f"RUN-{run_id}.md"
    raw = proof.snapshot(card)
    require(raw.startswith(b"---\n"), "run card has no frontmatter")
    parts = raw.decode().split("\n---\n", 1)
    require(len(parts) == 2, "run card frontmatter is incomplete")
    try:
        data = yaml.load(parts[0][4:], Loader=UniqueLoader)
    except yaml.YAMLError as error:
        raise ValueError("invalid run card frontmatter") from error
    require(isinstance(data, dict) and data.get("process_id") == "quick-close"
            and data.get("run_id") == run_id and data.get("owner_session_id") == harness
            and data.get("status") == "waiting" and data.get("current_step") == "verify-r23",
            "run is not this owner's active quick-close verification")
    results = data.get("results")
    require(isinstance(results, dict), "run results are missing")
    facts = results.get("gather-session-facts")
    required = {"agent", "wp", "session_file", "session_file_exists", "has_diff", "commit_needed",
                "repos", "repos_resolved"}
    require(isinstance(facts, dict) and required <= facts.keys()
            and facts["agent"] == agent and facts["wp"] in (None, "")
            and facts["session_file"] in (None, "")
            and facts["session_file_exists"] is False and facts["has_diff"] is False
            and facts["commit_needed"] is False and facts["repos_resolved"] is True,
            "no-owner close has a WP, report, changes, or incomplete gathered facts")
    declared = facts["repos"]
    require(isinstance(declared, list) and bool(declared)
            and all(isinstance(repo, str) for repo in declared), "no-owner repository scope is missing")
    repositories = [canonical_path(repo) for repo in declared]
    require(workspace in repositories and len(set(repositories)) == len(repositories),
            "no-owner repository scope must include the workspace exactly once")
    mapping = workspace / ".iwe-runtime/quick-close-harness-session" / f"{run_id}.session_id"
    require(proof.regular_file_snapshot(mapping).decode().strip() == harness,
            "run harness mapping mismatch")
    return card, raw, repositories


def require_clean_repository(repo: Path) -> None:
    require(not proof.git(repo, "status", "--porcelain=v1", "-z", "--untracked-files=normal"),
            "no-owner repository has uncommitted changes: " + str(repo))


def published_repositories(repositories: list[Path]) -> dict[Path, tuple[str, str]]:
    snapshots = {}
    for repo in repositories:
        remote = proof.fetch_target(repo, proof.MAIN_REF)
        head = proof.oid(repo, "HEAD^{commit}")
        require(proof.ancestor(repo, head, remote),
                "no-owner repository has unpublished commits: " + str(repo))
        require_clean_repository(repo)
        snapshots[repo] = (head, remote)
    return snapshots


def verify_no_owner(workspace: Path, agent: str, harness: str, run_id: str) -> dict:
    """Use the same locked absence proof as the runner's no-op release."""
    require(SAFE_ID.fullmatch(agent) is not None and SAFE_ID.fullmatch(harness) is not None
            and harness not in {".", "..", "default"}, "missing exact no-owner identity")
    workspace = workspace.resolve(strict=True)
    card, raw, repositories = no_owner_run(workspace, agent, harness, run_id)
    snapshots = published_repositories(repositories)
    result = subprocess.run(
        ["bash", str(workspace / "scripts/session-guard.sh"), "owner-status",
         "--owner-session-id", harness, "--owner-agent", agent],
        check=True, capture_output=True, text=True, timeout=30,
        env={**os.environ, "IWE_ROOT": str(workspace), "IWE_WORKSPACE": str(workspace)},
    )
    owner = json.loads(result.stdout, object_pairs_hook=scope.unique_object)
    require(isinstance(owner, dict) and owner.get("schema_version") == 1
            and owner.get("owner_session_id") == harness and owner.get("state") == "absent"
            and owner.get("proof") == "admission-locked-snapshot/v1"
            and owner.get("blockers") == [], "owner absence is not proved")
    current_card, current_raw, current_repositories = no_owner_run(workspace, agent, harness, run_id)
    require(current_card == card and current_raw == raw and current_repositories == repositories,
            "run changed during absence proof")
    for repo, (head, remote) in snapshots.items():
        require(proof.oid(repo, "HEAD^{commit}") == head
                and proof.oid(repo, proof.tracking_ref(repo, proof.MAIN_REF) + "^{commit}") == remote,
                "repository changed during absence proof")
        require_clean_repository(repo)
    return {"check": "session_close", "result": "ok", "run_id": run_id,
            "owner_session_id": harness, "reason": "no_owner_semaphore",
            "scope": "declared_repositories",
            "proof": owner["proof"], "files_checked": 0, "commits_checked": 0,
            "repos_checked": [str(repo) for repo in repositories]}


def verify_session(workspace: Path, agent: str, session_id: str, harness: str,
                   *, run_id: str = "") -> dict:
    if not session_id and run_id:
        return verify_no_owner(workspace, agent, harness, run_id)
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
    parser.add_argument("--run-id", default="", help="exact active quick-close run for a no-owner close")
    args = parser.parse_args()
    try:
        result = verify_session(args.workspace, args.agent, args.session_id, args.harness_session_id,
                                run_id=args.run_id)
    except (OSError, ValueError, ImportError, proof.ProofError, subprocess.SubprocessError) as error:
        print(json.dumps({"check": "session_close", "result": "block", "detail": str(error)}, ensure_ascii=False))
        return 1
    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
