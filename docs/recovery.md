# Восстановление «Цеха»

> **Аудитория:** Tseren при сбое, Андрей или Ильшат если Tseren недоступен.
> **Цель:** поднять сервер до рабочего состояния за 2-3h с нуля.

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
6. Восстановить из B2 содержательные данные (если применимо):
   restic -r b2:aisystant-neon-backup restore latest --target /restored
```

Восстановление: 2-3h.

### Сценарий 4: Утрачен PGP-ключ для sops-nix

Худший случай — если потерян основной ключ и нет копии в 1Password.

```
1. Сгенерировать новый PGP-ключ
2. Расшифровать существующие секреты на старом ключе НЕВОЗМОЖНО — нужно перерегистрировать в каждом провайдере (Backblaze B2, Better Stack, Anthropic API, Telegram bot)
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
| Резервные копии Neon | Backblaze B2 bucket `aisystant-neon-backup` (восстановление через restic) |
| Снимки ZFS | На самом сервере: `zfs list -t snapshot rpool` |

## Контакты

- Tseren Tserenov — основной владелец, `aisystant@gmail.com`
- Андрей Смирнов — collaborator read access, может выполнять Сценарии 1-3
- Ильшат — в обучении к 1 июня (R2 свод в WeekPlan)
