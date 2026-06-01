# Auto-pull репо на сервере

> Source-of-truth runbook для механизма pre-tick git pull в `iwe-scheduler.service`.
> WP-7 фаза S-A (7 мая 2026), iwe-server-config commit `970ee31`.

## Зачем это

Закрывает архитектурную дыру **«GitHub ≠ сервер»**: на NixOS-сервере (`tsekh-1`) systemd-таймер `iwe-scheduler.timer` запускает `iwe-scheduler.service` 11 раз/день. До auto-pull код-обновления в репо (например, `DS-IT-systems/DS-ai-systems/synchronizer/scripts/*.sh`) не доезжали до сервера автоматически — кто-то должен был вручную делать `git pull`. В результате: сервер запускал устаревший код, фиксы лежали в GitHub, но не работали в проде.

## Как это работает

### Механика

В `modules/systemd-timers.nix` определён `pullScript` через `pkgs.writeShellScript`. Он:

1. Читает фиксированный список `repos[]` (см. ниже)
2. Для каждого репо:
   - Проверяет существование `$dir/.git` — если нет, `SKIP: не клонирован`
   - `git status --porcelain` — если есть uncommitted changes, `DIRTY: skip` (защита локальных правок)
   - `timeout 60s git pull --ff-only` — fast-forward only (без rebase, без merge-коммитов)
3. Накапливает `failed[]` для DIRTY и FAIL'ов
4. При непустом `failed[]` шлёт TG-уведомление через `TELEGRAM_BOT_TOKEN`/`CHAT_ID` из `/etc/iwe/env`
5. **`exit 0` always** — не блокирует scheduler-tick

Интеграция в сервис:

```nix
systemd.services."iwe-scheduler" = {
  serviceConfig = commonServiceConfig // {
    ExecStartPre = "-${pullScript}";   # `-` → fail в pull НЕ блокирует ExecStart
    ExecStart    = "...scheduler.sh dispatch";
    TimeoutSec   = 1800;               # 30 мин включая pull
  };
};
```

### Защиты

| Риск | Защита |
|------|--------|
| Network hang | `timeout 60s` на `git pull` |
| Password prompt | `GIT_TERMINAL_PROMPT=0` + `GIT_SSH_COMMAND="ssh -o BatchMode=yes"` |
| Потеря локальных правок | `git status --porcelain` → skip dirty + `--ff-only` (без rebase) |
| Merge-коммит при divergent | `--ff-only` отказывается, помечает FAIL |
| Pull падает → блокирует scheduler | `ExecStartPre = "-${...}"` (минус-префикс игнорирует exit code) + сам скрипт `exit 0` always |
| Шум при штатных DIRTY | Текущая стратегия: TG-алерт при ANY failed. Может потребоваться different-strategy если DIRTY становится рутинным |

## Список репо

```
DS-IT-systems/DS-ai-systems       # scheduler-код, pack-project, template-sync
DS-IT-systems/activity-hub         # профилировщик данных
DS-MCP/knowledge-mcp               # knowledge-mcp runtime (DS-MCP — родительская папка)
DS-agent-workspace                 # workspace агентов
DS-autonomous-agents               # overnight-scout, render-pilot-guides
DS-Knowledge-Index-Tseren          # знания пилота
PACK-personal                      # Pack-источник для PACK-personal-агентов
```

### Исключения

- **DS-my-strategy** — почти всегда DIRTY из-за `iwe-sync-fleeting-notes.timer` (каждые 2 мин правит `inbox/fleeting-notes.md`). Точечная синхронизация уже делается через `sync-files.sh`. **Mini-debt:** расширить `sync-files.sh` на `inbox/WP-*.md` и `current/*.md`.
- **FMT-exocortex-template** — на сервере не git-репо (runtime-копия, обновляется через template-sync flow).
- **PACK-MIM, PACK-agent-rules, PACK-autonomous-agents, PACK-digital-platform, PACK-ecosystem, PACK-verification** — не клонированы на сервер. **PACK-digital-platform склонирован 7 мая** в рамках S-B (для pack-project), может быть добавлен в pullScript после первого штатного цикла. Остальные — по мере появления потребителей runtime.

## Расписание

`iwe-scheduler.timer` запускает каждый день:
- 00:00, 02:00, 03:00, 04:00, 06:00, 09:00, 12:00, 15:00, 18:00, 21:00, 23:00 (МСК / Europe/Helsinki)

**11 пуллов в день × 7 репо = 77 fetch/день.** GitHub лимит 5000/час для аутентифицированных — порядок ничтожный, не риск.

## Troubleshooting

### Симптом: TG-шум «IWE pull-repos warnings»

```
⚠️ IWE pull-repos warnings (tsekh-1, ...): DS-IT-systems/DS-ai-systems (dirty)
```

**Что делать:**
1. SSH на сервер: `ssh tsekh-1 "sudo -u tseren git -C /home/tseren/IWE/<repo> status --short"`
2. Если файлы должны быть в `.gitignore` — добавить и запушить
3. Если runtime-артефакт (state-файл) — переместить в `.gitignore` или другой path
4. Если ручная правка (нежелательная на сервере) — `git stash` или `git checkout --` чтобы убрать
5. После очистки на следующем tick'е репо подхватится OK

### Симптом: pull медленный или висит

1. Проверить network: `ssh tsekh-1 "ping -c 3 github.com"`
2. Проверить SSH auth: `ssh tsekh-1 "sudo -u tseren ssh -T -o BatchMode=yes git@github.com"` — должно быть `successfully authenticated`
3. Если SSH-ключ умер — обновить deploy key в `~tseren/.ssh/`

### Симптом: scheduler-tick пропустил (не запустился)

1. `systemctl list-timers iwe-scheduler.timer` — проверить NEXT и LAST
2. `journalctl -u iwe-scheduler.service --since '24h ago'` — логи последних tick'ов
3. Если ExecStartPre упал и `-` префикс не сработал — должен сработать; если нет, проверить версию systemd (`systemctl --version`)

### Симптом: отстала ветка iwe-server-config на сервере

```bash
ssh tsekh-1 "cd /home/tseren/iwe-server-config && git branch -v"
```

Если ветка `master` (не `main`) или отстаёт — `git checkout -B main origin/main` (как было сделано 7 мая 2026).

## Verification

После любых изменений pullScript или списка репо:

1. `nix flake check --no-build` — синтаксис
2. `nixos-rebuild switch --flake .#tsekh-1 --target-host root@95.216.75.148` (с локали) ИЛИ `ssh tsekh-1 "cd /home/tseren/iwe-server-config && git pull && nixos-rebuild switch --flake .#tsekh-1"` (на сервере)
3. `ssh tsekh-1 "systemctl cat iwe-scheduler.service | grep ExecStartPre"` — проверить новый путь pullScript
4. `ssh tsekh-1 "systemctl start iwe-scheduler.service"` + `journalctl -u iwe-scheduler.service --since '1 minute ago' | grep -E 'OK:|SKIP:|DIRTY:|FAIL:'` — увидеть результат
