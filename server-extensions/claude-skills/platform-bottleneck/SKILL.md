---
name: platform-bottleneck
description: "Скилл IWE — см. тело файла"
version: 1.0.0
layer: L3
status: active
triggers:
  slash: [/platform-bottleneck]
  phrases: []
routing:
  executor: sonnet
  deterministic: false
---

# Skill: /platform-bottleneck

> **Алиас.** Делегирует в `/bottleneck-pick --layer platform`.
>
> Решение (S-46, 2026-05-21): два скилла (intra + platform) объединены в один через `--layer` параметр. Отдельный скилл — избыточен. Оставлен как удобный триггер.
>
> SC: DP.SC.152. Носитель: DP.ROLE.054.

## Поведение

При вызове `/platform-bottleneck [--horizon <h>] [--subsystem <s>]` — выполнить:

```
/bottleneck-pick --target c2:platform --layer platform [--horizon <h>]
```

Если `--subsystem` указан:

```
/bottleneck-pick --target c2:platform --layer platform --subsystem <s> [--horizon <h>]
```

## Полная документация

→ `/bottleneck-pick` SKILL.md (секция `--layer=platform`)
→ DP.SC.152 (обещание платформо-специфичного анализа)
