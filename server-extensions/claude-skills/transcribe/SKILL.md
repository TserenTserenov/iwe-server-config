---
name: transcribe
description: Транскрипция аудио/видео файлов через MLX Whisper (Apple Silicon). Использование: /transcribe path/to/file.mp3
user_invocable: true
---

# Транскрипция аудио/видео

Транскрипция через MLX Whisper на Apple Silicon. Работает локально, без облака.

## Расположение

- **Модели:** `~/.local/share/mlx-whisper/mlx_models/`
- **Venv:** `~/.local/share/mlx-whisper/.venv-whisper/`
- **Модель:** `large-v3` (точная, ~3 ГБ). Единственная используемая модель

## Инструкция для Claude

### Шаг 1: Проверка venv

```bash
~/.local/share/mlx-whisper/.venv-whisper/bin/python -c "import mlx_whisper; print('ok')" 2>/dev/null
```

Если ошибка (сломан или отсутствует) — пересоздать:
```bash
rm -rf ~/.local/share/mlx-whisper/.venv-whisper
python3 -m venv ~/.local/share/mlx-whisper/.venv-whisper
~/.local/share/mlx-whisper/.venv-whisper/bin/pip install mlx-whisper
```

### Шаг 2: Определить файл и модель

- Аргумент скилла = путь к файлу. Если не указан — спросить пользователя.
- Всегда использовать `large-v3`. Других моделей нет.

### Шаг 3: Транскрипция

```bash
~/.local/share/mlx-whisper/.venv-whisper/bin/python -c "
import mlx_whisper
result = mlx_whisper.transcribe(
    '<путь_к_файлу>',
    path_or_hf_repo='$HOME/.local/share/mlx-whisper/mlx_models/large-v3',
    language='ru',
    word_timestamps=True
)
print(result['text'])
"
```

Если язык не русский — пользователь укажет, или убрать `language` для автодетекции.

### Шаг 4: Результат

- Показать текст пользователю.
- Если пользователь просит сохранить — записать в файл рядом с исходным: `<имя_файла>.txt`.
- Для длинных файлов (>30 мин) предупредить, что может занять несколько минут.

### Поддерживаемые форматы

mp3, m4a, wav, flac, ogg, mp4, mkv, webm — любые, которые поддерживает ffmpeg.
