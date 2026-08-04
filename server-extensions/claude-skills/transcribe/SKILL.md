---
name: transcribe
description: "Транскрипция аудио/видео файлов через MLX Whisper (Apple Silicon). Использование: /transcribe path/to/file.mp3"
user_invocable: true
version: 1.0.1
layer: L3
status: active
triggers:
  slash: [/transcribe]
  phrases: []
routing:
  executor: script
  deterministic: true
  script_path: "scripts/iwe-transcribe.sh"
  optimization_priority: 2
agents: none
interaction: one-shot
gates_required: []
gates_enforced: []
gates_rationale: "операционный скилл; WP Gate применим только при создании нового РП, не для операционных вызовов"
---

# Транскрипция аудио/видео

Транскрипция через MLX Whisper на Apple Silicon. Работает локально, без облака.

## When to use

Транскрипция аудио/видео файлов через MLX Whisper (Apple Silicon). Использование: /transcribe path/to/file.mp3

## Расположение

- **Модели:** `~/.local/share/mlx-whisper/mlx_models/`
- **Venv:** `~/.local/share/mlx-whisper/.venv-whisper/`
- **Модель:** `large-v3` (точная, ~3 ГБ). Единственная используемая модель

## Algorithm

### Шаг 1: Проверить локальные ресурсы без импорта MLX

```bash
test -x ~/.local/share/mlx-whisper/.venv-whisper/bin/python
test -d ~/.local/share/mlx-whisper/mlx_models/large-v3
~/.local/share/mlx-whisper/.venv-whisper/bin/python -c \
  'import importlib.util; raise SystemExit(importlib.util.find_spec("mlx_whisper") is None)'
```

Не выполнять `import mlx_whisper` внутри Codex Seatbelt: MLX обращается к Metal уже при импорте и аварийно завершается, если песочница скрыла GPU. Если проверка ресурсов не прошла, сообщить, чего именно нет; не удалять и не пересоздавать окружение без отдельного разрешения пользователя.

### Шаг 2: Определить файл и модель

- Аргумент скилла = путь к файлу. Если не указан — спросить пользователя.
- Всегда использовать `large-v3`. Других моделей нет.

### Шаг 3: Транскрипция

MLX требует доступ к Metal/GPU. В Codex запустить **всю команду** с точечным `sandbox_permissions: require_escalated` и объяснением: «Разрешить локальному MLX Whisper использовать Apple Metal/GPU для транскрибации указанного файла?». Не запускать предварительный `import mlx_whisper` в обычной песочнице.

```bash
bash "$IWE_SCRIPTS/route-task.sh" --skill transcribe --args "<путь_к_файлу>"
```

Если скрипт завершился с кодом `77`, запросить точечное разрешение и повторить всю команду один раз. Это отказ песочницы, а не признак сломанного пакета; переустановка не нужна.

Если язык не русский — пользователь укажет, или скрипт автоматически детектирует.

### Шаг 4: Результат

- Показать текст пользователю.
- Если пользователь просит сохранить — записать в файл рядом с исходным: `<имя_файла>.txt`.
- Для длинных файлов (>30 мин) предупредить, что может занять несколько минут.

### Поддерживаемые форматы

mp3, m4a, wav, flac, ogg, mp4, mkv, webm — любые, которые поддерживает ffmpeg.
