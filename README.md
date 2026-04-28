# iwe-server-config

> **Personal instance — not for direct reuse.**
> NixOS configuration for Tseren's personal IWE server «Цех» (`tsekh-1`).

## Что это

Декларативная конфигурация NixOS для личного сервера IWE (Intellectual Work Environment). Хостится на Hetzner. Закрывает три роли:

1. **Personal IWE Runtime** — автоматизация (расписания заданий, агенты Claude Agent SDK), работающая 24/7 вместо `launchd` на Mac.
2. **Backstage команды** — резервное копирование 12 баз данных Neon → Backblaze B2, предпроизводственная среда PostgreSQL для проверок миграций.
3. **Reference implementation** — образец для будущего продуктового уровня T5 «Self-hosted IWE» (когда придёт время — параметризованная часть будет извлечена в отдельный публичный шаблон).

Связь со страт.планом — рабочий продукт WP-138, см. `docs/architecture.md`.

## Стек

| Слой | Технология |
|------|------------|
| ОС | NixOS 24.11 |
| Файловая система | ZFS-зеркало двух NVMe 512GB (root) |
| Установка | `nixos-anywhere` (zero-touch из Hetzner Rescue mode) |
| Секреты | sops-nix |
| Обратный прокси | Caddy (автоматический Let's Encrypt) |
| Резервное копирование | restic + Backblaze B2 |
| Снимки | ZFS native autoSnapshot |
| Мониторинг | Better Stack heartbeats + Telegram уведомления |
| Агенты | Claude Agent SDK (Python) |

## Статус

🚧 **Ф1 в работе** (старт 30 апр – 1 мая 2026). До этого момента — пустой скелет.

Фазы плана:
- Ф1 — NixOS bootstrap (6-10h)
- Ф2 — декларативное резервное копирование (3-5h)
- Ф3 — systemd-таймеры взамен Mac launchd (8-12h)
- Ф4 — Claude Agent SDK на сервере (8-12h)
- Ф5 — IWE-команды в @aist_me_bot (4-6h)
- Ф6 — тяжёлые вычисления по триггерам (Q3+ при PMF)

## Структура

```
.
├── flake.nix                # entry point, описывает inputs
├── modules/                 # переиспользуемые модули (станет шаблоном в Q3-Q4)
├── instances/
│   └── tsekh-1/             # мой конкретный инстанс (константы + секреты)
└── docs/
    ├── architecture.md      # обзор для bus factor (Андрей читает)
    └── recovery.md          # шаги восстановления
```

**Принцип «инстанс ≠ шаблон»:** `modules/` свободны от моих констант, `instances/tsekh-1/values.nix` содержит мои значения. Это позволит в Q3-Q4 извлечь шаблон через копирование `modules/` без переписывания.

## Лицензия

Apache License 2.0 — см. [LICENSE](LICENSE).

Конфигурация открыта намеренно: команда (Андрей, Ильшат) читают для bus factor; модули можно изучать и форкать. Личные секреты (sops-nix зашифрованы) не публикуются в открытом виде.

## Контакты

Tseren Tserenov — `aisystant@gmail.com`
