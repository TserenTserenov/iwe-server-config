#!/usr/bin/env bash
# iwe-transcribe.sh — транскрипция аудио/видео через MLX Whisper (Apple Silicon)
# routing: executor=script  deterministic=true  skill=transcribe  optimization_priority=2
# see DP.SC.159, DP.ROLE.059
#
# Usage: iwe-transcribe.sh <path/to/file.mp3|mp4|m4a|wav>

set -euo pipefail

readonly VENV="$HOME/.local/share/mlx-whisper/.venv-whisper"
readonly PYTHON="$VENV/bin/python"
readonly MODEL="$HOME/.local/share/mlx-whisper/mlx_models/large-v3"
readonly EXIT_PERMISSION_REQUIRED=77

die() {
  local message="$1"
  local exit_code="${2:-1}"
  echo "ERROR: $message" >&2
  exit "$exit_code"
}

require_local_assets() {
  [[ -x "$PYTHON" ]] || die "Python environment not found: $VENV"

  if ! "$PYTHON" -c \
    'import importlib.util; raise SystemExit(importlib.util.find_spec("mlx_whisper") is None)'; then
    die "mlx_whisper package not found in $VENV"
  fi

  [[ -d "$MODEL" ]] || die "MLX Whisper model not found: $MODEL"
}

require_metal_access() {
  if [[ "${CODEX_SANDBOX:-}" == "seatbelt" ]]; then
    echo "ERROR: MLX Whisper requires Metal/GPU access unavailable inside the Codex Seatbelt sandbox." >&2
    echo "ACTION: rerun the entire transcription command with a scoped sandbox escalation." >&2
    echo "Do not reinstall mlx-whisper: this is a permission boundary, not a missing package." >&2
    exit "$EXIT_PERMISSION_REQUIRED"
  fi
}

[[ $# -ge 1 ]] || die "Usage: iwe-transcribe.sh <audio-file>"

readonly FILE="$*"

[[ -f "$FILE" ]] || die "file not found: $FILE"

require_local_assets
require_metal_access

"$PYTHON" - "$FILE" "$MODEL" << 'EOF'
import sys
import mlx_whisper

file_path, model_path = sys.argv[1], sys.argv[2]
result = mlx_whisper.transcribe(
    file_path,
    path_or_hf_repo=model_path,
    language="ru",
    word_timestamps=True,
)
print(result["text"])
EOF
