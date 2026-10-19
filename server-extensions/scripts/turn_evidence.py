"""Read-only, conservative adapters for Codex, Claude, and Kimi journals.

No journal content is logged or persisted. ``boundary.completed`` records a
successful terminal event; ``complete`` additionally requires intact parsing.
Neither certifies task success. Unknown tool outcomes remain None. Response
mirrors are not counted twice; peer messages are not assistant answers.
"""

from __future__ import annotations

import hashlib
import json
import re
from collections import Counter
from pathlib import Path


def _text(content: object) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(
            item.get("text", "")
            for item in content
            if isinstance(item, dict)
            and item.get("type") in {"text", "output_text", "input_text"}
            and isinstance(item.get("text"), str)
        )
    return ""


def _valid_text(content: object) -> bool:
    if isinstance(content, str):
        return True
    return isinstance(content, list) and all(
        isinstance(item, dict)
        and item.get("type") in {"text", "output_text", "input_text"}
        and isinstance(item.get("text"), str)
        for item in content
    )


_NATIVE_EXIT = re.compile(
    r"\AChunk ID: [A-Za-z0-9_-]+\r?\n"
    r"Wall time: [0-9]+(?:\.[0-9]+)? seconds\r?\n"
    r"Process exited with code (-?[0-9]+)\r?\n"
    r"(?:Final output|Output):(?:\r?\n|\Z)"
)


def _error(result: object) -> bool | None:
    """Only explicit outcomes; failure wins when fields contradict each other."""
    if isinstance(result, str):
        try:
            return _error(json.loads(result))
        except (ValueError, TypeError):
            # Only the native transport header is status; markers inside stdout
            # or nested `output` are arbitrary task data, never outcome evidence.
            match = _NATIVE_EXIT.match(result)
            return int(match[1]) != 0 if match else None
    if not isinstance(result, dict):
        return None
    outcomes = []
    for key in ("isError", "is_error", "error"):
        if isinstance(result.get(key), bool):
            outcomes.append(result[key])
    for key in ("exit_code", "exitCode"):
        if type(result.get(key)) is int:
            outcomes.append(result[key] != 0)
    if result.get("error"):
        outcomes.append(True)
    return any(outcomes) if outcomes else None


class _Journal:
    def __init__(self, runtime: str, digest: str):
        self.result = {
            "schema_version": 1,
            "runtime": runtime,
            "source_sha256": digest,
            "turns": [],
            "diagnostics": [],
            "fatal_diagnostics": [],
        }
        self.active: dict | None = None
        self.closed: set[str] = set()
        self.bad = False

    def diagnose(self, line: int, code: str, *, fatal: bool = True) -> None:
        diagnostic = f"line {line}: {code}"
        self.result["diagnostics"].append(diagnostic)
        if fatal:
            self.result["fatal_diagnostics"].append(diagnostic)
        if fatal and self.active is not None:
            self.bad = True

    def start(self, identifier: object, line: int) -> None:
        if identifier is None or isinstance(identifier, (dict, list, bool)):
            self.diagnose(line, "missing_or_invalid_turn_id")
            return
        identifier = str(identifier)
        if self.active is not None:
            if self.active["id"] == identifier:
                return
            self.diagnose(line, "turn_missing_end")
            self.finish(None, line - 1, False)
        if identifier in self.closed:
            self.diagnose(line, "duplicate_closed_turn")
            return
        self.active = {
            "id": identifier,
            "final_text": "",
            "tools": [],
            "text_segments": [],
            "final_line": 0,
            "boundary": {"type": "incomplete", "line": line, "completed": False},
            "end_line": line,
            "complete": False,
        }
        self.bad = False

    def belongs(self, identifier: object, line: int) -> bool:
        if self.active is None:
            self.diagnose(line, "event_outside_turn")
            return False
        if identifier is not None and str(identifier) != self.active["id"]:
            self.diagnose(line, "foreign_turn_event")
            return False
        return True

    def text(self, value: str, line: int) -> None:
        if not self.belongs(None, line):
            return
        self.active["final_text"] = value
        self.active["final_line"] = line
        self.active["text_segments"].append({"text": value, "line": line})

    def content(self, value: object, line: int) -> None:
        if not _valid_text(value):
            self.diagnose(line, "unsupported_assistant_content")
            return
        self.text(_text(value), line)

    def call(self, identifier: object, name: object, args: object, line: int) -> None:
        if not self.belongs(None, line):
            return
        if (
            not isinstance(identifier, str)
            or not identifier
            or not isinstance(name, str)
        ):
            self.diagnose(line, "invalid_tool_call")
            return
        if any(t["id"] == identifier for t in self.active["tools"]):
            self.diagnose(line, "duplicate_tool_call_id")
            return
        self.active["tools"].append(
            {
                "id": identifier,
                "name": name,
                "arguments": args,
                "result": None,
                "error": None,
                "line": line,
                "result_line": None,
            }
        )

    def output(self, identifier: object, result: object, line: int) -> None:
        if not self.belongs(None, line):
            return
        tool = next((t for t in self.active["tools"] if t["id"] == identifier), None)
        if tool is None:
            self.diagnose(line, "unmatched_tool_result")
        elif tool["result_line"] is not None:
            self.diagnose(line, "duplicate_tool_result")
        else:
            tool.update(result=result, result_line=line, error=_error(result))

    def finish(
        self,
        identifier: object,
        line: int,
        completed: bool,
        boundary_type: str = "incomplete",
    ) -> None:
        if not self.belongs(identifier, line):
            return
        self.active.update(
            end_line=line,
            complete=completed and not self.bad,
            boundary={"type": boundary_type, "line": line, "completed": completed},
        )
        if not completed:
            self.diagnose(line, "turn_incomplete_or_cancelled", fatal=False)
        self.result["turns"].append(self.active)
        self.closed.add(self.active["id"])
        self.active = None


def _codex_mirror_lines(rows: list[tuple[int, dict]]) -> set[int]:
    """Pair message mirrors only within their task window, preserving repeats."""
    duplicates = set()
    window = []

    def collect() -> None:
        counts = Counter(
            _text(payload.get("content"))
            for _, kind, payload in window
            if kind == "response_item"
            and payload.get("type") == "message"
            and payload.get("role") == "assistant"
            and payload.get("recipient") in (None, "all")
        )
        for number, kind, payload in window:
            if kind != "event_msg" or payload.get("type") != "agent_message":
                continue
            value = _text(payload.get("message"))
            if counts[value]:
                duplicates.add(number)
                counts[value] -= 1

    for line, row in rows:
        payload = row.get("payload", {})
        if not isinstance(payload, dict):
            continue
        if row.get("type") == "event_msg" and payload.get("type") == "task_started":
            collect()
            window = []
        window.append((line, row.get("type"), payload))
        if row.get("type") == "event_msg" and payload.get("type") in {
            "task_complete",
            "turn_aborted",
        }:
            collect()
            window = []
    collect()
    return duplicates


def _codex(rows: list[tuple[int, dict]], journal: _Journal) -> None:
    mirrored_lines = _codex_mirror_lines(rows)
    mirror_text = ""
    mirror_line = 0
    for line, row in rows:
        kind = row.get("type")
        payload = row.get("payload", {})
        if not isinstance(payload, dict):
            journal.diagnose(line, "invalid_payload")
            continue
        event = payload.get("type")
        if kind == "event_msg" and event == "task_started":
            journal.start(payload.get("turn_id"), line)
            mirror_text, mirror_line = "", 0
        elif kind == "event_msg" and event in {"task_complete", "turn_aborted"}:
            if not journal.belongs(payload.get("turn_id"), line):
                continue
            # The terminal message is an authoritative mirror, not a new answer.
            terminal_text = payload.get("last_agent_message")
            if isinstance(terminal_text, str) and terminal_text:
                if terminal_text != journal.active["final_text"]:
                    if terminal_text == mirror_text:
                        journal.text(terminal_text, mirror_line)
                    else:
                        journal.text(terminal_text, line)
                        journal.diagnose(
                            line, "terminal_text_without_message_order_unknown"
                        )
            elif terminal_text is not None and not isinstance(terminal_text, str):
                journal.diagnose(line, "unsupported_assistant_content")
            elif not journal.active["final_text"] and mirror_text:
                journal.text(mirror_text, mirror_line)
            journal.finish(
                payload.get("turn_id"), line, event == "task_complete", event
            )
        elif kind == "event_msg" and event == "agent_message":
            if journal.belongs(payload.get("turn_id"), line):
                if not _valid_text(payload.get("message")):
                    journal.diagnose(line, "unsupported_assistant_content")
                    continue
                mirror_text = _text(payload.get("message"))
                mirror_line = line
                if line not in mirrored_lines:
                    journal.text(mirror_text, line)
        elif kind == "response_item":
            if event == "message" and payload.get("role") == "assistant":
                if payload.get("recipient") not in (None, "all"):
                    continue
                if journal.belongs(payload.get("turn_id"), line):
                    journal.content(payload.get("content"), line)
            elif event in {"function_call", "custom_tool_call"}:
                if journal.belongs(payload.get("turn_id"), line):
                    journal.call(
                        payload.get("call_id"),
                        payload.get("name"),
                        payload.get("arguments", payload.get("input")),
                        line,
                    )
            elif event in {"function_call_output", "custom_tool_call_output"}:
                if journal.belongs(payload.get("turn_id"), line):
                    journal.output(payload.get("call_id"), payload.get("output"), line)
            elif event not in {
                "message",
                "reasoning",
                "agent_message",
                "compaction",
                "web_search_call",
            }:
                journal.diagnose(line, "unsupported_response_item")
        elif kind == "event_msg":
            if event in {"mcp_tool_call_end", "web_search_end", "patch_apply_end"}:
                journal.diagnose(line, f"unsupported_tool_execution_event:{event}")
            elif event not in {
                "token_count",
                "item_completed",
                "thread_settings_applied",
                "user_message",
                "agent_reasoning",
                "context_compacted",
                "warning",
                "error",
                "shutdown_complete",
                "sub_agent_activity",
            }:
                journal.diagnose(line, "unsupported_event_msg")
        elif kind not in {
            "session_meta",
            "turn_context",
            "compacted",
            "world_state",
            "token_usage_record",
            "inter_agent_communication_metadata",
        }:
            journal.diagnose(line, "unsupported_record_type")


def _kimi(rows: list[tuple[int, dict]], journal: _Journal) -> None:
    canonical = any(row.get("type") == "context.append_loop_event" for _, row in rows)
    if not canonical and any(
        row.get("type") == "agent.message.appended" for _, row in rows
    ):
        journal.diagnose(0, "kimi_message_fallback_no_tool_evidence")
    for line, row in rows:
        kind = row.get("type")
        # A combined export must never mix child-agent events into the main turn.
        if row.get("agentId") not in (None, "main"):
            journal.diagnose(line, "foreign_agent_event")
            continue
        if kind in {"turn.begin", "turn.prompt"} or (
            kind == "agent.turn.started" and not canonical
        ):
            journal.start(row.get("turnId"), line)
        elif kind == "turn.ended":
            journal.finish(
                row.get("turnId"), line, row.get("reason") == "completed", kind
            )
        elif kind == "turn.cancel":
            journal.finish(row.get("turnId"), line, False, kind)
        elif kind == "context.append_loop_event":
            event = row.get("event")
            if not isinstance(event, dict):
                journal.diagnose(line, "invalid_loop_event")
                continue
            event_type = event.get("type")
            if event_type in {"content.part", "tool.call", "step.begin"}:
                if journal.active is None:
                    journal.start(event.get("turnId"), line)
                    journal.diagnose(line, "turn_missing_start")
                if not journal.belongs(event.get("turnId"), line):
                    continue
            if event_type == "content.part":
                part = event.get("part", {})
                if isinstance(part, dict) and part.get("type") == "text":
                    journal.content(part.get("text"), line)
                elif not isinstance(part, dict) or part.get("type") not in {
                    "think",
                    "reasoning",
                }:
                    journal.diagnose(line, "unsupported_content_part")
            elif event_type == "tool.call":
                journal.call(
                    event.get("toolCallId"), event.get("name"), event.get("args"), line
                )
            elif event_type == "tool.result":
                if journal.belongs(event.get("turnId"), line):
                    journal.output(event.get("toolCallId"), event.get("result"), line)
            elif event_type not in {"step.begin", "step.end"}:
                journal.diagnose(line, "unsupported_loop_event")
        elif kind == "agent.message.appended" and not canonical:
            wrapper = row.get("message", {})
            message = wrapper.get("message", {}) if isinstance(wrapper, dict) else {}
            if isinstance(message, dict) and message.get("role") == "assistant":
                if journal.active is None:
                    journal.diagnose(line, "fallback_message_without_turn")
                    continue
                journal.content(message.get("content"), line)
                journal.diagnose(line, "fallback_tool_evidence_unavailable")
        elif kind not in {
            "metadata",
            "runtime.set_binding",
            "permission.set_mode",
            "profile.bind",
            "agent.message.appended",
            "agent.turn.started",
            "agent.turn.ended",
            "context.append_message",
            "plugin.session_start",
            "llm.tools_snapshot",
            "llm.request",
            "usage.record",
            "token_counting.measured",
            "full_compaction.begin",
            "context.apply_compaction",
            "token_counting.rebased",
            "full_compaction.complete",
            "token_counting.turn_recorded",
            "prompt.completed",
            "prompt.aborted",
            "task.started",
            "task.terminated",
            "file_history.tracked",
            "file_history.checkpoint",
            "turn.step.interrupted",
            "task.waitDelivered",
            "tools.update_store",
            "prompt.steered",
            "turn.steer",
            "interaction.request",
            "interaction.resolved",
        }:
            journal.diagnose(line, "unsupported_record_type")


def _claude(rows: list[tuple[int, dict]], journal: _Journal) -> None:
    """Read native Claude JSONL; a tool-result user row is not a new prompt."""
    for line, row in rows:
        kind = row.get("type")
        if kind not in {"user", "assistant"}:
            continue  # Attachments, titles, and bridge metadata are not turns.
        if (
            row.get("isMeta")
            or row.get("isSidechain")
            or row.get("agentId") not in (None, "main")
        ):
            continue  # Hook/sidechain records are not main-thread user turns.
        message = row.get("message")
        if not isinstance(message, dict):
            journal.diagnose(line, "invalid_message")
            continue
        content = message.get("content", [])
        if isinstance(content, str):
            parts = [{"type": "text", "text": content}]
        elif isinstance(content, list) and all(isinstance(x, dict) for x in content):
            parts = content
        else:
            journal.diagnose(line, "unsupported_assistant_content")
            continue

        if kind == "user":
            for part in parts:
                if part.get("type") == "tool_result":
                    if journal.active is None:
                        journal.diagnose(line, "tool_result_outside_turn")
                    else:
                        journal.output(part.get("tool_use_id"), part, line)
            if any(
                part.get("type") == "text"
                and isinstance(part.get("text"), str)
                and part["text"].strip()
                for part in parts
            ):
                journal.start(row.get("uuid", f"user-{line}"), line)
            continue

        texts = [part.get("text") for part in parts if part.get("type") == "text"]
        calls = [part for part in parts if part.get("type") == "tool_use"]
        if not texts and not calls:
            continue  # Thinking-only end_turn can precede the visible answer.
        if journal.active is None:
            journal.start(row.get("uuid", f"assistant-{line}"), line)
        if not all(isinstance(value, str) for value in texts):
            journal.diagnose(line, "unsupported_assistant_content")
            continue
        if texts:
            journal.text("\n".join(texts), line)
        for part in calls:
            journal.call(part.get("id"), part.get("name"), part.get("input"), line)
        if message.get("stop_reason") == "end_turn" and texts:
            journal.finish(None, line, True, "end_turn")


def load_turns(path: Path, runtime: str) -> dict:
    """Normalize a journal without writing it; return evidence and diagnostics.

    A malformed JSON line invalidates completeness for the entire source since
    it could hide a turn boundary. Unknown runtime raises ValueError; filesystem
    errors propagate. Kimi's mirrored messages are text-only fallback evidence.
    """
    if runtime not in {"codex", "claude", "kimi"}:
        raise ValueError("unsupported runtime")
    raw = path.read_bytes()
    journal = _Journal(runtime, hashlib.sha256(raw).hexdigest())
    rows = []
    corrupt = False
    for line, value in enumerate(raw.splitlines(), 1):
        if not value.strip():
            continue
        try:
            record = json.loads(value)
            if not isinstance(record, dict) or not isinstance(record.get("type"), str):
                raise TypeError("invalid record")
        except (TypeError, ValueError, UnicodeDecodeError):
            journal.diagnose(line, "malformed_record")
            corrupt = True
            continue
        rows.append((line, record))
    adapter = {"codex": _codex, "claude": _claude, "kimi": _kimi}[runtime]
    adapter(rows, journal)
    if journal.active is not None:
        journal.diagnose(
            len(raw.splitlines()), "turn_missing_end", fatal=runtime != "claude"
        )
        journal.finish(None, len(raw.splitlines()), False)
    if not journal.result["turns"]:
        journal.diagnose(0, "no_recognized_turns")
    if corrupt:
        for turn in journal.result["turns"]:
            turn["complete"] = False
    return journal.result
