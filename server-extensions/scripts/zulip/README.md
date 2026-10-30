# Zulip для агентов (РП-5 Ф68)

- `zulip_listener.py` — служба на Цехе (`systemctl --user zulip-listener`): пишет все входящие сообщения в `~/.local/state/zulip/inbox.jsonl`, помечает упоминание бота и упоминание пилота (`mentions_pilot`).
- `zulip_read.py` — чтение для агентов без доступа к ключу: `streams`, `history --stream S [--topic T]`, `inbox`, `wp N` (темы из поля `zulip_topics` карточки РП).
- Ключ бота: `~/.secrets/zuliprc` (Мак и Цех), в репозиторий не попадает.
- Рабочие копии запускаются из `~/zulip-listener/`; после правки здесь скопировать туда.
