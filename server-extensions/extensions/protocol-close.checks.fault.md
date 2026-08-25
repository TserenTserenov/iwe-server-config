## Agent Fault Profile (WP-316)

Запустить перед проверками — чтобы не пропустить шаги с историей пропусков:

```bash
IWE_ROOT="${IWE_WORKSPACE:-${WORKSPACE_DIR:-$HOME/IWE}}"
IWE_PLATFORM_SCRIPTS="${IWE_SCRIPTS:-${IWE_TEMPLATE:-$IWE_ROOT/FMT-exocortex-template}/scripts}"
python3 "$IWE_PLATFORM_SCRIPTS/agent-fault/iwe_checklist_memory.py" remind \
  --protocol close \
  --subject-kind "$IWE_FAULT_SUBJECT_KIND" \
  --subject-id "$IWE_FAULT_SUBJECT_ID"
```

🔴-пункты = часто пропускаемые именно при Close. Применить немедленно к оставшимся шагам.

> Если в этой сессии обнаружен новый косяк — передать его единому интерфейсу:
> ```bash
> IWE_ROOT="${IWE_WORKSPACE:-${WORKSPACE_DIR:-$HOME/IWE}}"
> IWE_PLATFORM_SCRIPTS="${IWE_SCRIPTS:-${IWE_TEMPLATE:-$IWE_ROOT/FMT-exocortex-template}/scripts}"
> python3 "$IWE_PLATFORM_SCRIPTS/agent-fault/iwe_checklist_memory.py" record \
>   --fault "описание" --severity major \
>   --subject-kind "$IWE_FAULT_SUBJECT_KIND" \
>   --subject-id "$IWE_FAULT_SUBJECT_ID"
> ```
> Legacy feedback импортируется только явной командой `import-feedback` с субъектом
> `system:feedback-import`.
