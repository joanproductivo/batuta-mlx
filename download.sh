#!/bin/bash
set -e
export HF_HUB_DISABLE_PROGRESS_BARS=0
.venv/bin/hf download mlx-community/Qwen3.8-27B-MTP-4bit
echo "=== DRAFTER OK ==="
.venv/bin/hf download mlx-community/Qwen3.8-27B-4bit
echo "=== TARGET OK ==="
