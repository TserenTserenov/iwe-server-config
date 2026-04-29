# Восстановление «Цеха»

> **Аудитория:** Tseren при сбое, Андрей или Ильшат если Tseren недоступен.
> **Цель:** поднять сервер до рабочего состояния за 2-3h с нуля.
> **Актуально на:** 2026-04-29 (после Ф5)

## Текущее состояние (что работает)

| Компонент | Состояние | Проверка |
|-----------|-----------|---------|
| NixOS 24.11 | ✅ | `ssh root@95.216.75.148 nixos-version` |
| ZFS mirror (rpool) | ✅ без шифрования | `zpool status` |
| 7 systemd-таймеров | ✅ | `systemctl list-timers \| grep iwe` |
| TG-алерты при сбое | ✅ | `systemctl status iwe-failure-alert@\*` |
| Health endpoint | ✅ | `curl http://95.216.75.148:8080/health` |
| Claude CLI | ✅ v2.1.123 | `ssh tseren@95.216.75.148 claude --version` |
| Restic → B2 | ✅ | `systemctl status iwe-restic-\*` |
| Better Stack heartbeat | ✅ | uptime.betterstack.com |
| GitHub Actions CD | ✅ | Push main → rebuild автоматически |

## Шифрование (статус и план)

**Текущий пул `rpool` создан без шифрования (28 апр 2026).** ZFS encryption задаётся при `zpool create` — на живом пуле не включить без переустановки.

**Чтобы включить при следующей переустановке:**
1. В `instances/tsekh-1/values.nix` изменить `encrypt = false` → `encrypt = true`
2. Сгенерировать ключ: `dd if=/dev/urandom of=/tmp/zfs.key bs=32 count=1; xxd -p /tmp/zfs.key | tr -d '\n'`
3. Сохранить hex-ключ в 1Password (сейф `tseren-knowledge`, запись «ZFS key tsekh-1»)
4. Передать ключ в `/boot/zfs.key` через nixos-anywhere `--extra-files`
5. Запустить переустановку через nixos-anywhere

Пока шифрование выключено, **резервные копии в B2 зашифрованы** (restic client-side), данные Neon защищены.

## Доступ к серверу

| Кто | Доступ | SSH-ключ |
|-----|--------|----------|
| Tseren Tserenov | root + tseren | `tserenov1972@gmail.com` — в 1Password `tseren-knowledge` |
| Андрей Смирнов | root (добавить ключ) | **Запросить в TG** → добавить в `values.nix → teamSshKeys.root` → deploy |

**Как добавить ключ Андрея:**
```bash
# В instances/tsekh-1/values.nix раскомментировать строку:
# "ssh-ed25519 AAAA...  andrey-smirnov"
# Вставить реальный публичный ключ, затем:
cd ~/IWE/iwe-server-config
git add instances/tsekh-1/values.nix
git commit -m "feat: add Andrey SSH key for bus factor"
git push
# GitHub Actions CD задеплоит автоматически
```

## Сценарии восстановления

### Сценарий 1: Сломался NixOS, нужен откат

```bash
# Вариант A: rebuild --rollback
nixos-rebuild --rollback --target-host root@95.216.75.148

# Вариант B: загрузить предыдущую generation вручную
# 1. Hetzner Robot → Console → Reboot
# 2. В bootloader выбрать предыдущую generation
```

Восстановление: 30 секунд – 5 минут.

### Сценарий 2: ZFS pool не загружается после rebuild

```
1. Hetzner Robot → Activate Rescue mode (Ubuntu rescue)
2. Tseren жмёт «Reboot» в Robot
3. SSH в rescue: ssh root@95.216.75.148 (Robot покажет временный пароль)
4. Импортировать ZFS pool вручную:
   zpool import -f rpool
5. Если есть вопросы про hostid — пересобрать конфиг с новым hostid
6. Выйти из rescue, перезагрузиться нормально
```

Восстановление: 30-60 минут.

### Сценарий 3: Полная переустановка с нуля (диск утрачен, замена железа)

```
1. Hetzner Robot → Activate Rescue mode на сервере
2. Локально на машине администратора:
   git clone https://github.com/TserenTserenov/iwe-server-config.git
   cd iwe-server-config
3. Получить sops-nix PGP key из 1Password сейфа `tseren-knowledge`
4. Запустить установку:
   nix run github:nix-community/nixos-anywhere -- \
       --flake .#tsekh-1 root@<новый-IP>
5. После reboot — проверить что сервисы поднялись:
   ssh root@<IP> "systemctl --failed"
6. Восстановить секреты:
   ssh root@<IP> "mkdir -p /etc/iwe && cat > /etc/iwe/env"
   # ввести содержимое из 1Password → tseren-knowledge → «Цех /etc/iwe/env»
7. Восстановить из B2 содержательные данные (если применимо):
   restic -r b2:aisystant-neon-backup restore latest --target /restored
```

Восстановление: 2-3h.

### Сценарий 4: GitHub Actions CD сломался (не деплоится при push)

```
1. Проверить последний run: https://github.com/TserenTserenov/iwe-server-config/actions
2. Если ошибка SSH: проверить Secrets → SSH_PRIVATE_KEY, SSH_KNOWN_HOSTS
   (Settings → Secrets and variables → Actions)
3. Задеплоить вручную:
   ssh root@95.216.75.148 "cd /root/iwe-server-config && git pull && nixos-rebuild switch --flake .#tsekh-1 2>&1"
4. Smoke test: curl http://95.216.75.148:8080/health
```

Восстановление: 5-15 минут.

### Сценарий 5: Утрачен PGP-ключ для sops-nix

Худший случай — если потерян основной ключ и нет копии в 1Password.

```
1. Сгенерировать новый PGP-ключ
2. Расшифровать существующие секреты на старом ключе НЕВОЗМОЖНО — нужно перерегистрировать
   в каждом провайдере (Backblaze B2, Better Stack, Anthropic API, Telegram bot)
3. Обновить .sops.yaml на новый key fingerprint
4. Пересоздать `instances/tsekh-1/secrets.yaml` с новыми секретами
5. nixos-rebuild switch
```

Восстановление: 4-6h.

## Где что искать

| Что | Где |
|-----|-----|
| Конфигурация NixOS | https://github.com/TserenTserenov/iwe-server-config |
| PGP-ключ sops-nix | 1Password сейф `tseren-knowledge` (передан Андрею 1 апр 2026) |
| SSH-ключи доступа | 1Password сейф `tseren-knowledge` |
| Backblaze B2 ключи | 1Password сейф `tseren-knowledge` |
| Hetzner Robot login | 1Password сейф `tseren-knowledge` |
| Better Stack API | 1Password сейф `tseren-knowledge` |
| @aist_me_bot токен | 1Password сейф `tseren-knowledge` |
| ZFS key (для следующего reinstall) | 1Password сейф `tseren-knowledge` → «ZFS key tsekh-1» (добавить при генерации) |
| Содержимое /etc/iwe/env | 1Password сейф `tseren-knowledge` → «Цех /etc/iwe/env» |
| Резервные копии Neon | Backblaze B2 bucket `aisystant-neon-backup` (восстановление через restic) |
| Снимки ZFS | На самом сервере: `zfs list -t snapshot rpool` |

## Контакты

- **Tseren Tserenov** — основной владелец, `aisystant@gmail.com`
- **Андрей Смирнов** — collaborator (SSH ключ добавить в `values.nix → teamSshKeys.root`)
- **Ильшат** — в обучении к 1 июня 2026 (R2 свод в WeekPlan)

## Добавление командного TG-канала (алерты)

Сейчас алерты при сбое идут только в личный чат Tseren (`TELEGRAM_CHAT_ID`).

Чтобы добавить командный канал:
```bash
ssh root@95.216.75.148
# Добавить в /etc/iwe/env:
echo "TELEGRAM_TEAM_CHAT_ID=-1001234567890" >> /etc/iwe/env
# Перезапустить таймеры (активируются сами при следующем запуске)
# Проверить: systemctl status iwe-failure-alert@iwe-scheduler.service
```

Бот должен быть добавлен в командный канал как администратор (право «Публикация сообщений»).
