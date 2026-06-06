## Agent Fault Profile (WP-316)

Запустить перед проверками — чтобы не пропустить шаги с историей пропусков:

```bash
python3 /Users/tserentserenov/IWE/DS-my-strategy/scripts/agent_fault_remind.py --protocol close
```

🔴-пункты = часто пропускаемые именно при Close. Применить немедленно к оставшимся шагам.

> Если в этой сессии обнаружен новый косяк — записать напрямую в SQLite (L1 primary path):
> ```bash
> python3 ~/IWE/DS-my-strategy/scripts/iwe_checklist_memory.py record --fault "описание" --severity major
> ```
> `sync_feedback_to_memory.py` — только для миграции legacy feedback_*.md (Ф11, WP-316).
