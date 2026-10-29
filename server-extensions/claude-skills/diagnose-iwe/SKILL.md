---
name: diagnose-iwe
description: "Старое имя скилла диагностики ступени мастерства — переадресация на /diagnose. Запускай когда: пилот говорит «/diagnose-iwe», «диагностика прямо в VS Code», «пройди диагностику в редакторе»."
argument-hint: "[необязательно: --check для просмотра профиля без нового опроса]"
related: [WP-578, WP-318, DP.ROLE.042, PD.FORM.089]
version: 5.1.0
layer: L3
status: active
triggers:
  slash: [/diagnose-iwe]
  phrases:
    - "диагностика прямо в VS Code"
    - "пройди диагностику в редакторе"
    - "diagnose iwe"
    - "скилл диагностика мастерства в редакторе"
routing:
  executor: sonnet
  deterministic: false
agents: single
interaction: multi-step
gates_required: []
gates_enforced: []
gates_rationale: "операционный скилл; WP Gate применим только при создании нового РП, не для операционных вызовов"
---

# /diagnose-iwe — переадресация на /diagnose

Это старое имя скилла. Команду `/diagnose-iwe` называют подсказки участникам и сценарии бота, поэтому имя сохранено, а своей логики у скилла нет.

**Действие:** выполнить скилл `diagnose` (`.claude/skills/diagnose/SKILL.md`) целиком, передав те же аргументы (например, `--check`).

Не выполнять здесь собственный опрос и не сохранять профиль самостоятельно: у самооценки один писатель — инструмент `learning_ctx_record_cp_assessment`, которым пользуется `diagnose` (WP-578 Ф21.3). Прежняя версия этого файла писала профиль в цифровой двойник и в базу напрямую — этот путь закрыт.
