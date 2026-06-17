---
name: connect-guide
description: Подключить персональное руководство пилота — установить GitHub App «Aisystant Personal Guide» на репо personal-guide. Открывает install-flow в браузере, проверяет успех через github_status MCP. Используй когда пилот говорит «подключи руководство», «установи app», «настрой репо», «connect personal guide» — или для ступени 3-4 (VS Code-primary канал).
argument-hint: "[необязательно: --telegram-id=N или --github-username=X — если skill не может автоопределить identity]"
experimental: true
sunset: "после WP-303 (вынос OAuth Gateway в standalone сервис с прямой Ory-аутентификацией; W21+)"
related: [WP-149, WP-301, lesson, lesson-close, personal-guide-start]
version: 1.0.0
layer: L3
status: active
triggers:
  slash: [/connect-guide]
  phrases: []
routing:
  executor: script
  deterministic: true
  script_path: ".claude/skills/connect-guide/connect.sh"
agents: none
interaction: one-shot
gates_required: []
gates_enforced: []
gates_rationale: "операционный скилл; WP Gate применим только при создании нового РП, не для операционных вызовов"
---

# /connect-guide — подключить персональное руководство (VS Code канал)

> ⚡ **Алгоритм, не диалог.** Шаги 1-5 последовательно. Уточняющий вопрос — только если шаг 1 не дал identity.

> **Парный канал к боту:** `/connect_guide` в Telegram делает то же самое через бот-кнопку.
> Этот скилл — для пилотов, работающих primary в VS Code / Claude Code (ступени 3-4 по SC.020).

## When to use

Подключить персональное руководство пилота — установить GitHub App «Aisystant Personal Guide» на репо personal-guide. Открывает install-flow в браузере, проверяет успех через github_status MCP. Используй когда пилот говорит «подключи руководство», «установи app», «настрой репо», «connect personal guide» — или для ступени 3-4 (VS Code-primary канал).

## Контракт скилла

- **Вход:** аккаунт Aisystant с активной подпиской БР; пилот уже прошёл онбординг в Telegram-боте (хотя бы /start, чтобы создалась запись в dt_tokens). Доступ к `mcp__claude_ai_IWE__github_status`.
- **Выход:** GitHub App установлен на репо `<user>/personal-guide`, mapping (chat_id, installation_id, repo) в Neon secrets DB. Пилот может запускать `/lesson` и `/lesson-close`.
- **Время:** 3-5 мин (включая выбор репо в GitHub UI).
- **Не делает:** не создаёт репо `personal-guide` (это `/personal-guide-start`); не делает первый рендер (это `/personal-guide-render`); не запускает first lesson (это `/lesson`).

## Algorithm

## Шаг 1. Определить identity пилота

Получи `telegram_user_id` одним из путей (в порядке предпочтения):

1. **Через аргумент скилла:** если пользователь передал `--telegram-id=N` — использовать N
2. **Через `mcp__claude_ai_IWE__github_status`:** вызови tool — должен вернуть `github_username` + connected account info. Это подтверждение что identity-mapping есть. **Дополнительно** — попроси пилота назвать свой Telegram ID (чтобы построить setup URL).
3. **Спроси пользователя:** «Какой у тебя Telegram chat_id? Чтобы узнать — открой `@aist_pilot_me` или `@aist_me_bot`, отправь /profile — id будет в начале ответа.»

Без telegram_user_id шаг 3 — стоп до получения. **Без identity URL setup endpoint'а не построится корректно.**

## Шаг 2. Проверить пред-условия

Через Bash:
```bash
# проверить что репо personal-guide локально склонирован
test -d ~/personal-guide || test -d ~/IWE/personal-guide && echo "repo OK" || echo "no local clone"
```

Если репо нет локально:
- Запусти `/personal-guide-start` сначала (создаст репо)
- Если репо уже создан на GitHub, но не локально — `git clone https://github.com/<github_username>/personal-guide.git ~/personal-guide`

Не блокируй на этом — пилот может склонить позже. Просто проинформируй.

## Шаг 3. Построить setup URL и открыть в браузере

```
SETUP_URL = https://aistmebot-production.up.railway.app/auth/github_app/setup?telegram_user_id={N}
```

Для **pilot-теста** (env=pilot-бот): `https://aistpilotbot-production.up.railway.app/auth/github_app/setup?telegram_user_id={N}`.

Через Bash:
```bash
open "${SETUP_URL}"  # macOS
# или: xdg-open на Linux
```

Скажи пилоту:
```
🌐 Открыт GitHub install page.

Что делать:
1. Выбери репо `personal-guide` (если в списке нет — нажми «All repositories» или «Only select repositories» → найди personal-guide)
2. Нажми «Install»
3. GitHub отправит тебя на страницу «✅ App установлен»
4. Вернись сюда и скажи «готово»
```

## Шаг 4. Подождать подтверждение

Жди реплику пилота «готово» / «done» / «установил» / «установлено».

После реплики — верификация через `mcp__claude_ai_IWE__github_status`:
- Если tool возвращает данные с признаком App installed (или просто GitHub connected — это уже подтверждает успех flow) → шаг 5
- Если tool возвращает ошибку или connected=false — спроси: «Telegram пришло ли сообщение "✅ GitHub App установлен"? Если нет — возможно, проблема с identity-mapping или нужно выполнить /start в боте сначала».

Если `github_status` не отражает App-installation (это не стандартный signal MCP сейчас) — полагайся на **слово пилота + ссылка на TG-уведомление** как primary confirmation.

## Шаг 5. Подтвердить готовность

После подтверждения:

```
✅ Подключение завершено.

Готовы основные команды для занятий:
• /lesson [дата] — пройти урок из assignments/
• /lesson-close — закрыть занятие, push в workbook, обновить ЦД

Следующий шаг — запусти первый рендер руководства:
• /personal-guide-render — Портной создаст 6 файлов в репо + первый assignment

Контур замкнут:
  Портной → assignments/ → /lesson → /lesson-close → push → webhook → ЦД → завтрашний assignment
```

## Граничные случаи

| Ситуация | Действие |
|---|---|
| Пилот не помнит свой Telegram ID и не пользуется ботом | Сказать: «Зайди в `@aist_me_bot`, нажми /start. После онбординга встроенная кнопка в боте подключит App без необходимости знать ID. Этот скилл актуален для тех, кто primary использует VS Code» |
| `mcp__claude_ai_IWE__github_status` вернул `not connected` | Identity-mapping ещё не создан. Сначала `/github` в боте (OAuth) → потом /connect-guide |
| Браузер не открылся (нет графической среды, headless) | Скажи URL пилоту, попроси открыть вручную |
| После Install у пилота не пришло TG-сообщение | Возможные причины: (a) telegram_user_id неправильный, (b) пилот не запускал бот, (c) callback не сработал. Предложи проверить логи Railway или повторить установку с правильным ID |
| Пилот пытается запустить /connect-guide ДО создания репо personal-guide | Скажи: сначала `/personal-guide-start` (он создаст репо), потом /connect-guide |
| Уже установлен (повторный вызов) | После redirect на callback GitHub покажет «App already installed» — это нормально, mapping обновится |

## Связь с другими механизмами

- **Аналог в боте:** `/connect_guide` команда (handlers/settings.py в aist_bot_newarchitecture) — той же setup endpoint, через inline-кнопку в TG
- **Backend:** `oauth_server.py:/auth/github_app/setup` (HMAC state) + `/auth/github_app/callback` (save mapping)
- **БД:** `github_connections.app_installation_id` (миграция 014)
- **Webhook:** `/webhook/github/workbook` — приём push events от установленного App, маршрутизация по installation_id

## Архитектурное замечание (для понимания)

Этот скилл — **MVP-canal B** из SC.020. По исходному дизайну канал B должен принимать identity напрямую через Ory SSO (без необходимости знать telegram_user_id). Сейчас это упрощено — identity берётся через Telegram-mapping, потому что:

- Aisystant MCP не отдаёт `ory_user_id` напрямую в скиллы (требует расширения MCP gateway)
- Setup endpoint не имеет Ory-OAuth flow (вся OAuth-логика в боте, не вынесена)

Полное решение — **WP-303 (вынос OAuth Gateway)** + расширение setup endpoint для Ory-direct-flow. Текущий скилл работает для пилотов с Telegram identity (большинство case'ов для пилотного запуска).

## Антипаттерны

- ❌ Не запускать `/connect-guide` без telegram_user_id — Setup endpoint вернёт 400
- ❌ Не пытаться установить App на чужой репо — App должен ставиться пилотом на его собственный personal-guide
- ❌ Не обходить TG-уведомление как primary signal of success — это самый надёжный путь подтверждения
- ❌ Не делать polling БД из скилла — антипаттерн (skill ≠ persistent worker)
