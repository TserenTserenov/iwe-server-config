# Hermes Agent на Railway — деплоймент

## Архитектура

```
User → @aist_me_bot (Railway) → MCP aisystant → hermes_chat
                                            ↓
                                    Hermes Gateway (Railway)
                                    POST /v1/hermes/invoke
                                        → LLM (OpenRouter)
                                        → Memory (state.db)
```

## Шаги развёртывания

### 1. Создать проект

```bash
railway login
railway init --name hermes-agent
```

### 2. Указать Docker-образ

В Railway Dashboard → Service → Deploy → Docker:
- **Image:** `nousresearch/hermes-agent:latest`
- **Command:** `["gateway", "run"]`

Или использовать сборку из исходников: форк `github.com/NousResearch/hermes-agent` → Railway деплоит через Dockerfile.

### 3. Persistent Volume (Railway)

Railway → Project → Storage → Add Volume:
- **Name:** `hermes-data`
- **Mount Path:** `/opt/data`
- **Size:** 5 GB (Hermes: state.db ~50МБ + memories/ + sessions/, рост ~100МБ/мес)

### 4. Переменные окружения

| Переменная | Значение | Зачем |
|-----------|----------|-------|
| `OPENROUTER_API_KEY` | `sk-or-v1-...` | Доступ к LLM через OpenRouter |
| `API_SERVER_HOST` | `0.0.0.0` | Экспорт API-сервера за localhost |
| `API_SERVER_KEY` | `...` | Ключ аутентификации API |
| `HERMES_UID` | `10000` | Владелец файлов внутри контейнера |
| `HERMES_GID` | `10000` | Группа файлов внутри контейнера |
| `TELEGRAM_BOT_TOKEN` | (опционально) | Если Hermes держит Telegram-шлюз |
| `TELEGRAM_ALLOWED_USERS` | (опционально) | Белый список пользователей |

### 5. Healthcheck

Hermes gateway экспонирует `/health` на порту 9118.
Railway проверяет: `GET /health` → 200.

### 6. Конечная точка для hermes_chat

После деплоя Hermes доступен на:
```
https://hermes-agent-production-0d5c.up.railway.app/v1/hermes/invoke
POST { "message": "...", "user_id": "...", "session_id": "..." }
```

Healthcheck: `GET https://hermes-agent-production-0d5c.up.railway.app/health`

### 7. Ключ для gateway-mcp

Установить в gateway-mcp (`peaceful-vision` → `gateway-mcp` сервис):
```
HERMES_RUNTIME_URL=https://hermes-agent-production-0d5c.up.railway.app
HERMES_RUNTIME_TIMEOUT=25000
HERMES_API_KEY=5a279a14e6869b7775d515ed67394b0ce42e73ef85d10f18a92e285eae3e672f
```

`API_SERVER_KEY` (уже в hermes-agent сервисе) = `HERMES_API_KEY` в gateway-mcp.

## Варианты развёртывания

| Вариант | Плюсы | Минусы |
|---------|-------|--------|
| **Railway** (рекомендуется) | Рядом с ботом, Persistent Volume, managed infra | $5-20/мес |
| **Локально** (`docker compose up -d`) | Бесплатно, full control | Требует Mac, не 24/7 без ноутбука |
| **VPS** (Hetzner $5/мес) | 24/7, полный контроль | Требует настройки сервера |

## Проверка

```bash
# После деплоя:
curl -fsS https://hermes-agent.{domain}.railway.app/health
# → {"status":"ok","version":"0.15.1"}
```
