---
name: agent-fault
description: Регистрация косяка агента в системе учёта WP-316 L1. Без LLM — детерминированный скрипт.
argument-hint: "record --severity {critical|major|minor} --fault '<description>'"
routing:
  executor: script
  deterministic: true
  script_path: DS-my-strategy/scripts/iwe_checklist_memory.py
---

# Agent Fault Registrar

Задача: передать косяк агента в `iwe_checklist_memory.py record`.

Использование:
```bash
python3 "${IWE_SCRIPTS:-$HOME/IWE/scripts}/iwe_checklist_memory.py" record --severity major --fault "агент пропустил чеклист"
```
