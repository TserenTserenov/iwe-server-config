# iwe-server-config — инструкции для Claude Code

> **Тип репозитория:** instance configuration (NixOS).
> **Назначение:** конфигурация личного сервера Tseren «Цех» (`tsekh-1`).
> **Связь со страт.планом:** WP-138 в `~/IWE/DS-my-strategy/inbox/WP-138-tsekh-server.md`.

## Принципы работы

1. **Инстанс ≠ шаблон.** `modules/` — переиспользуемое (станет шаблоном в Q3-Q4 при PMF). `instances/tsekh-1/` — мои константы и секреты. Никогда не хардкодить мои IP/пути/имена в `modules/`.
2. **Никаких ручных правок на сервере.** Вся работа через правку `.nix` → коммит → `nixos-rebuild switch --flake .#tsekh-1 --target-host root@95.216.75.148`.
3. **Секреты только через sops-nix.** Plain-text секреты в репо запрещены (см. `.gitignore`).
4. **Apache 2.0 — лицензия с первого коммита.** Заголовки `# SPDX-License-Identifier: Apache-2.0` в значимых `.nix` файлах.
5. **Декларативность:** если что-то делается на сервере — оно должно быть в `.nix` файле. Если не нужно делать декларативно (одноразовая отладка) — не коммитить, делать в Rescue mode.
6. **Bus factor:** `docs/recovery.md` всегда актуален. Андрей по нему должен поднять сервер за 2-3h.

## Как мы работаем вместе

Типичный цикл изменения:

1. Tseren формулирует цель («хочу cron для day-open в 08:00 МСК»).
2. Claude правит модуль (например, `modules/systemd-timers.nix`) или создаёт новый.
3. Claude фиксирует в Git и отправляет на GitHub.
4. Claude запускает `nixos-rebuild switch --flake .#tsekh-1 --target-host root@95.216.75.148` через Bash.
5. NixOS создаёт новую generation, переключает.
6. Tseren или Claude проверяет работоспособность (smoke).
7. Если плохо — `git revert` → повторный rebuild → возврат на предыдущую generation.

## Связи с другими репозиториями

| Репозиторий | Связь |
|-------------|-------|
| `~/IWE/DS-my-strategy/inbox/WP-138-tsekh-server.md` | Контекст рабочего продукта (фазы, риски, bus factor) |
| `~/IWE/PACK-digital-platform/.../08-service-clauses/DP.SC.019-autonomous-cloud-runtime.md` | Pack-обещание сервиса |
| `~/IWE/aist_bot_newarchitecture` | Бот @aist_me_bot, расширяемый IWE-командами в Ф5 |
| `~/IWE/FMT-exocortex-template` | В Q3-Q4 при PMF — извлечение шаблона из `modules/` |

## Антипаттерны

- ❌ `apt install`, `pacman` на сервере — пакетов нет, ставится через `environment.systemPackages` в `.nix`.
- ❌ Правка `/etc/*` руками — при следующем `nixos-rebuild` перезатрётся.
- ❌ Хардкод констант (IP, имени, путей) в `modules/` — только в `instances/tsekh-1/values.nix`.
- ❌ Plain-text секреты в коммите — sops-nix или env vars вне Git.
- ❌ Принимать PR от внешних без CLA (см. правило `feedback_repo_hosting_principle.md`).

## Полезные команды

```bash
# Применить новую конфигурацию на сервер
nixos-rebuild switch --flake .#tsekh-1 --target-host root@95.216.75.148

# Откат на предыдущую generation
nixos-rebuild --rollback --target-host root@95.216.75.148

# Проверить какие generations есть на сервере
ssh root@95.216.75.148 "nix-env --list-generations --profile /nix/var/nix/profiles/system"

# Проверить состояние ZFS-пула
ssh root@95.216.75.148 "zpool status"

# Резервная копия — список последних снимков
ssh root@95.216.75.148 "zfs list -t snapshot"
```
