# Установка NixOS на «Цех» через `nixos-anywhere`

> **Аудитория:** Tseren выполняет ручные шаги в Hetzner Robot, Claude через SSH запускает установку.
> **Время:** ~1-1.5 часа от перевода в Rescue до полного NixOS с ZFS-зеркалом.
> **Точка отката:** Hetzner всегда может вернуть сервер в Rescue mode независимо от состояния ОС.

## Перед началом — проверки

| Что | Команда | Ожидаемое |
|-----|---------|-----------|
| Снимок текущего Ubuntu сделан | `ssh root@95.216.75.148 ls /root/pre-nixos-snapshot-2026-04-28.tar.gz` | Файл существует |
| flake.nix в репо актуален | `git -C ~/IWE/iwe-server-config log -1` | Последний коммит на месте |
| SSH-ключ в `values.nix` совпадает с `~/.ssh/id_*.pub` | `ssh-keygen -lf ~/.ssh/id_ed25519.pub` | Тот же fingerprint |

## Шаг 1 — Tseren: перевести сервер в Rescue mode

1. Открыть Hetzner Robot — https://robot.hetzner.com/server
2. Найти сервер `hetzner-backstage` (IPv4 `95.216.75.148`)
3. Перейти в раздел **Rescue** для этого сервера
4. Заполнить:
   - **Operating system:** `Linux`
   - **Architecture:** `64 bit`
   - **Public key:** выбрать ключ Tseren (или сразу вставить публичный SSH-ключ — тот же что и в `values.nix`)
5. Нажать **Activate rescue system** — Hetzner подтвердит активацию
6. Перейти в раздел **Reset** для сервера
7. Выбрать **Send CTRL+ALT+DEL to the server** (мягкая перезагрузка) → **Send**
8. Подождать ~2-3 минуты пока сервер перезагрузится в Rescue

> Если CTRL+ALT+DEL не сработал — использовать **Execute an automatic hardware reset** (жёсткая перезагрузка через power cycle).

После этого Tseren говорит мне «Цех в Rescue» — я продолжаю автоматически.

## Шаг 2 — Claude: проверить что сервер в Rescue

```bash
ssh -o StrictHostKeyChecking=accept-new root@95.216.75.148 "uname -a; cat /etc/os-release | head -5"
```

Ожидаемое: `Debian GNU/Linux` (Hetzner Rescue работает на Debian) или текст с упоминанием rescue.

Если возвращается Ubuntu — сервер ещё не перезагрузился, подождать ещё 1-2 минуты.

## Шаг 3 — Claude: установить Nix локально

Локально на Mac Tseren — единоразовая установка, чтобы был доступен `nix run`:

```bash
curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install
```

Tseren вводит sudo password один раз. После установки — открыть новый shell или `source /etc/zshrc`. Проверка: `nix --version`.

## Шаг 4 — Claude: dry-run проверка flake

```bash
cd ~/IWE/iwe-server-config
nix flake check --no-build 2>&1 | head -30
```

Если flake собирается — продолжаем. Если ошибки синтаксиса — правим, коммитим, проверяем снова.

## Шаг 4.5 — Tseren: подготовить ZFS-ключ (только если `encrypt = true`)

Пропустить если в `values.nix` стоит `encrypt = false` (default).

```bash
# 1) Генерация 256-битного hex-ключа
dd if=/dev/urandom of=/tmp/zfs.key bs=32 count=1
HEX_KEY=$(xxd -p /tmp/zfs.key | tr -d '\n')
echo "$HEX_KEY"  # сохранить в 1Password сейф `tseren-knowledge`, запись «ZFS key tsekh-1»

# 2) Подготовить файл для передачи в /boot через --extra-files
mkdir -p /tmp/extra-files/boot
echo -n "$HEX_KEY" > /tmp/extra-files/boot/zfs.key
chmod 400 /tmp/extra-files/boot/zfs.key
```

Без этого шага nixos-anywhere упадёт на этапе создания пула с `keylocation=file:///boot/zfs.key not found`.

## Шаг 5 — Claude: запустить `nixos-anywhere`

```bash
cd ~/IWE/iwe-server-config

nix run github:nix-community/nixos-anywhere -- \
    --flake .#tsekh-1 \
    --target-host root@95.216.75.148 \
    --vm-test  # сначала VM-тест: проверить что flake собирает рабочую систему
```

Если VM-тест прошёл (NixOS грузится в QEMU и пингуется) — запускаем реальную установку:

```bash
# Если encrypt = true, передать ключ через --extra-files
EXTRA_FILES_ARG=""
[ -d /tmp/extra-files ] && EXTRA_FILES_ARG="--extra-files /tmp/extra-files"

nix run github:nix-community/nixos-anywhere -- \
    --flake .#tsekh-1 \
    --target-host root@95.216.75.148 \
    $EXTRA_FILES_ARG \
    --debug
```

Что происходит:
1. nixos-anywhere копирует kexec image на сервер
2. Запускает `kexec` — переключение ядра без перезагрузки
3. Стирает оба NVMe согласно `disko-zfs-mirror.nix`
4. Создаёт ZFS-зеркало, разделы /boot
5. Собирает NixOS из flake локально → копирует на сервер
6. Устанавливает GRUB на оба диска
7. Перезагружает сервер

Время: 15-30 минут.

## Шаг 6 — Smoke-test после reboot

Подождать 3-5 минут после reboot, потом:

```bash
ssh root@95.216.75.148 "
echo '=== OS ==='
cat /etc/os-release | head -5
echo
echo '=== ZFS ==='
zpool status rpool
echo
echo '=== Datasets ==='
zfs list
echo
echo '=== Network ==='
ip -br a
ping -c 3 8.8.8.8
ping6 -c 3 2606:4700:4700::1111
echo
echo '=== Generations ==='
nix-env --list-generations --profile /nix/var/nix/profiles/system
"
```

Ожидаемое:
- OS = NixOS 24.11
- ZFS pool `rpool` ONLINE, mirror healthy
- Datasets root, nix, home, var, var/log смонтированы
- IPv4 95.216.75.148 + IPv6 2a01:4f9:2b:bc3::2 присвоены
- ping работает на оба
- Generation 1 присутствует

## Откат если что-то пошло не так

| Проблема | Действие |
|----------|----------|
| ZFS pool не загружается после reboot | Hetzner Robot → Activate Rescue → SSH в rescue → `zpool import -f rpool` → проверить ошибки → исправить flake → повторить с Шага 5 |
| Сервер не пингуется после reboot | Hetzner Robot → KVM Console → посмотреть на ошибки загрузки. Если networking не поднялся — `nixos-rebuild --rollback` через KVM. Если ZFS не импортируется — Rescue mode |
| nixos-anywhere упал на kexec | Hetzner Robot → Reset → Activate Rescue ещё раз → повторить с Шага 4 |
| GRUB не установился на оба диска | После загрузки: `nixos-rebuild boot` — переустановит GRUB |

Худший случай — потеря данных текущего Ubuntu. Митигация:
- Снимок `/root/pre-nixos-snapshot-2026-04-28.tar.gz` уже сделан
- Содержимое `/etc/hetzner-backstage/env` (B2 ключи, restic password, TG token) — Tseren в 1Password сейфе `tseren-knowledge`
- Резервные копии 12 БД Neon уже в B2 (через restic), не пострадают при переустановке

## После успешной установки

1. Закоммитить актуальный `hardware-configuration.nix` (что сгенерировал nixos-generate-config — могут быть отличия от моей минимальной заглушки):
   ```bash
   ssh root@95.216.75.148 "cat /etc/nixos/hardware-configuration.nix" > instances/tsekh-1/hardware-configuration.nix
   git add . && git commit -m "feat(Ф1): зафиксирован реальный hardware-configuration.nix" && git push
   ```
2. Перейти к Ф2: добавить `modules/backup.nix`, `modules/monitoring.nix`, `modules/caddy.nix`.

---

## Текущий прогресс Ф1 (28 апр)

- ✅ Снимок текущего Ubuntu сделан на сервере (`/root/pre-nixos-snapshot-2026-04-28.tar.gz`)
- ✅ Базовые модули написаны и закоммичены (flake, disko, base, networking, users)
- ✅ SSH-ключ Tseren подставлен в `values.nix`
- ✅ ZFS hostId сгенерирован: `f27da647`
- ✅ Runbook этот написан
- ⏳ **Ждёт окна Tseren (Чт 30 апр или Пт 1 мая после Red Line WP-250):**
  - Tseren активирует Rescue mode в Hetzner Robot (Шаг 1)
  - Tseren устанавливает Nix локально (Шаг 3, разово, sudo)
  - Claude запускает `nixos-anywhere` (Шаги 4-5)
  - Smoke-test и фиксация `hardware-configuration.nix` (Шаги 6-7)
