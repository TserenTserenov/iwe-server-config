# Настройка Google Calendar на tsekh-1 (DOC3, WP-7)

Шаги для подключения Google Calendar к серверу через sops-nix (вариант A).

## Шаг 1: Получить refresh_token от Google

1. Перейти в [Google Cloud Console](https://console.cloud.google.com/)
2. Выбрать проект (или создать новый)
3. Включить **Google Calendar API**
4. Создать OAuth2 credentials → тип **Desktop app**
5. Скачать JSON с `client_id` и `client_secret`

6. Получить `refresh_token` через OAuth2 flow (один раз):

```bash
# Заменить YOUR_CLIENT_ID и YOUR_CLIENT_SECRET
CLIENT_ID="YOUR_CLIENT_ID"
CLIENT_SECRET="YOUR_CLIENT_SECRET"
SCOPE="https://www.googleapis.com/auth/calendar.readonly"

# 1. Открыть URL в браузере:
echo "https://accounts.google.com/o/oauth2/auth?client_id=$CLIENT_ID&redirect_uri=urn:ietf:wg:oauth:2.0:oob&response_type=code&scope=$SCOPE"

# 2. Авторизоваться, скопировать CODE из браузера

# 3. Получить tokens:
CODE="PASTE_CODE_HERE"
curl -s -X POST https://oauth2.googleapis.com/token \
  -d "code=$CODE&client_id=$CLIENT_ID&client_secret=$CLIENT_SECRET&redirect_uri=urn:ietf:wg:oauth:2.0:oob&grant_type=authorization_code" \
  | python3 -m json.tool
# Из ответа взять refresh_token (длинная строка)
```

## Шаг 2: Получить age key сервера

```bash
# На Mac:
ssh-keyscan -t ed25519 95.216.75.148 | ssh-to-age
# Сохрани вывод — это age public key сервера
```

## Шаг 3: Настроить .sops.yaml

Создать файл `iwe-server-config/.sops.yaml`:

```yaml
creation_rules:
  - path_regex: secrets/.*\.yaml$
    age:
      - AGE_PUBLIC_KEY_SERVER  # из шага 2
```

## Шаг 4: Зашифровать credentials

```bash
cd ~/IWE/iwe-server-config

# Создать plaintext файл (НЕ коммитить):
cat > /tmp/google-calendar-plain.yaml << 'EOF'
google-calendar:
    refresh_token: "PASTE_REFRESH_TOKEN_HERE"
    client_id: "PASTE_CLIENT_ID_HERE"
    client_secret: "PASTE_CLIENT_SECRET_HERE"
EOF

# Зашифровать:
sops --encrypt /tmp/google-calendar-plain.yaml > secrets/google-calendar.yaml

# Удалить plaintext:
rm /tmp/google-calendar-plain.yaml

# Проверить (должен показать зашифрованные данные):
head secrets/google-calendar.yaml
```

## Шаг 5: Подключить модуль в NixOS конфиге

В `instances/tsekh-1/default.nix` добавить:

```nix
imports = [
  # ... существующие импорты ...
  ../../modules/iwe-calendar-secrets.nix  # DOC3
];

tsekh.calendarSecrets = {
  enable = true;
};
```

Настроить sops age key на сервере (если ещё не настроен):

```nix
sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
```

## Шаг 6: Задеплоить

```bash
git add secrets/google-calendar.yaml .sops.yaml instances/tsekh-1/default.nix modules/iwe-calendar-secrets.nix
git commit -m "feat(DOC3): Google Calendar read-only creds via sops-nix"
git push  # CD задеплоит автоматически
```

## Проверка

После деплоя на сервере:

```bash
ssh root@95.216.75.148 "cat /home/tseren/.secrets/google-calendar"
# Должен показать KEY=VALUE без раскрытия значений в логах
```

Затем запустить Day Open — секция «Календарь» должна появиться.
