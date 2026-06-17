# Day Close — Before Extension

## Peer-session guard

Если пользователь сказал «в пир-сессии с Кими» / «peer-сессия» / «вместе с Кими» / «с участием Кими» — запустить Day Close через скилл `kimi-peer-writer`, а не напрямую.

Проверить контекст текущего сообщения пользователя:
- если содержит: «пир-сессии», «peer», «с Кими», «Kimi» — **СТОП**. Не запускать day-close solo.
- Сообщить: «Обнаружен модификатор пир-сессии. Запускаю через kimi-peer-writer.»
- Вызвать: `Skill(skill="kimi-peer-writer", args="Day Close <дата>")`
- После запуска kimi-peer-writer — не продолжать шаги day-close solo.
