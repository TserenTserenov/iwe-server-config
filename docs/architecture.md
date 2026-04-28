# Архитектура «Цеха»

> **Аудитория:** Андрей (для дружеского ревью), Ильшат (для bus factor к 1 июня), команда. Тех.детали реализации — в `flake.nix` и модулях.

## Контекст и роли

«Цех» (`tsekh-1`) — личный сервер Tseren на Hetzner ($53/мес, Intel Xeon E3-1275V6, 64GB ECC, 2× NVMe 512GB, Финляндия HEL1-DC2). Куплен 1 апр 2026, на «Времянке» Ф0 с 26 апр (Ubuntu + Docker), переходит на NixOS с 30 апр – 1 мая 2026.

Сервер выполняет три роли одновременно:

1. **Personal IWE Runtime** — автоматизация Tseren (расписания заданий, агенты Claude Agent SDK), работающая 24/7. Закрывает single point of failure через Mac launchd: при сбоях обновлений macOS launchd сбрасывается, при закрытом Mac расписания не работают.

2. **Backstage команды** — резервное копирование 12 баз данных Neon в Backblaze B2 (cold backup на случай инцидента уровня SLA-провайдера), предпроизводственная среда PostgreSQL 17 + pgvector для проверок миграций (использовалась для прогона WP-268 ETL до перехода 28-29 апр).

3. **Reference implementation T5** — образец для будущего продуктового уровня «Self-hosted IWE» в Q3-Q4 при подтверждении PMF. Параметризованная часть (`modules/`) при наступлении момента извлекается в отдельный публичный шаблон.

## Архитектурные решения

### Стек

| Решение | Альтернатива | Почему выбрано |
|---------|--------------|----------------|
| **NixOS 24.11** | Ubuntu + Ansible | Полная декларативность, generations с автоматическим откатом, шаблонизуемость для T5, ZFS из коробки |
| **ZFS-зеркало (mirror)** | ZFS-stripe, ext4 + LVM | Защита от сбоя одного из NVMe + сжатие + снимки + checksums против bitrot |
| **`nixos-anywhere`** | `nixos-infect` (Ubuntu→NixOS in-place) | Чистая установка, нет наследия от Ubuntu, zero-touch из Hetzner Rescue |
| **sops-nix** | agenix, HashiCorp Vault | Стандарт сообщества nix, PGP/age шифрование, секреты в Git зашифрованными |
| **Caddy** | nginx, traefik | Минимальная конфигурация, автоматический Let's Encrypt из коробки |
| **restic + Backblaze B2** | rsync.net, AWS S3 + Glacier | Дедуп, шифрование на клиенте, B2 дешевле S3 в 4 раза, проверенная пара |
| **systemd-таймеры** | cron | Декларативно через NixOS `systemd.timers.*`, лучше journald-логи, health-check встроен |
| **Расширение @aist_me_bot** | Отдельный Telegram-бот на сервере | Один интерфейс пользователя, инфраструктура на Railway уже LIVE, авторизация через Ory уже работает |

### Что НЕ переносим на сервер

| Сервис | Причина отказа |
|--------|----------------|
| Bridge-2 (legacy LMS bridge) | Снимется после полной миграции LMS, перенос = работа в стол |
| multi-domain projection-worker (WP-270) | Sequential ceiling 50-60 событий/мин хватает на пилот ≤50; триггер переноса — когорта 50+ |
| rewards-projection-worker | Аналогично |
| Embedding daemon (BGE-M3 / E5 на CPU) | Заменён GitHub Actions runner pattern по предложению Андрея 28 апр (событийная обработка по коммиту, не daemon) |
| Self-hosted LLM (Llama, Qwen) | Нет GPU; CPU 1-3 токенов/сек не подходит для production |
| Aisystant MCP, Knowledge MCP | Cloudflare Workers глобальны (edge), Hetzner один регион — деградация задержек для пользователей |
| Self-hosted Discourse / Mattermost | Сообщество в Telegram |

## Безопасность

| Слой | Защита |
|------|--------|
| Доступ SSH | Только ключи (PasswordAuthentication off), fail2ban, UFW (порты 22, 443) |
| Секреты | sops-nix с PGP-ключом владельца на локальной машине Tseren + бэкап в 1Password |
| Резервные копии | restic с парольным шифрованием + B2 ключи через sops-nix |
| Сетевые сервисы | Все внешние сервисы через Caddy (TLS); внутренние сервисы (Postgres preprod) только на 127.0.0.1 или Tailscale |
| ОС | unattended-upgrades + automatic-reboot для security patches; ZFS snapshots до апгрейдов |

## Bus factor

- **Ф1-Ф5:** 1 (Tseren исполняет, Андрей делает дружеское ревью).
- **К 1 июня:** ≥2 (передача Ильшату — R2 свод в WeekPlan).
- **Андрей** имеет collaborator read access на репозиторий и доступ к 1Password сейфу `tseren-knowledge` (передан 1 апр при покупке сервера).
- **Recovery doc** в `docs/recovery.md` обновляется по ходу Ф1-Ф2.

## Связь с другими рабочими продуктами

| РП | Связь |
|----|-------|
| WP-268 (Phase 2 dual-write transition) | Предпроизводственная среда «Цеха» использовалась для прогона ETL до перехода 28-29 апр |
| WP-253 (новая архитектура Neon) | Ф9.6 reliability gate (4-6 мая) — нагрузочные тесты на той же предпроизводственной среде |
| WP-244 (Platform Observability) | Better Stack heartbeats для всех systemd-таймеров «Цеха» |
| WP-187 (Knowledge Gateway) | Открытый вопрос — где будет жить переиндексация (GitHub Actions self-hosted runner на «Цехе» — кандидат в Ф6 при триггерах) |
| WP-276 (карта внешних провайдеров) | «Цех» — одна из групп Backstage в карте |
| WP-7 (бот техдолг) | Расширение @aist_me_bot новыми командами в Ф5 |

## Открытые вопросы

- **Юрисдикция размещения шаблона** в Q3-Q4 (после PMF) — Foundation-org или org конкретного юрлица. Решается тогда, когда определится разделение РФ/мир (WP-215).
- **GitHub Actions runner** для индексации Knowledge MCP — self-hosted на «Цехе» или GitHub-managed. Решается в Ф6 по триггеру (>$50/мес OpenAI embeddings или потребность в приватной обработке PII).
- **Multi-tenant cron для пилотов** — отдельный мини-РП в Q3 при PMF (хранение чужих токенов = класс защиты payment_credentials, нужен secret management + изоляция через контейнеры).
