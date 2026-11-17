#!/bin/bash
set -euo pipefail
find_python() {
  local candidate
  for candidate in "$(command -v python3.12 || true)" \
      "$HOME/.local/bin/python3.12" \
      /opt/homebrew/bin/python3.12 /opt/homebrew/opt/python@3.12/bin/python3.12 \
      /usr/local/bin/python3.12 /usr/local/opt/python@3.12/bin/python3.12 \
      /Library/Frameworks/Python.framework/Versions/3.12/bin/python3.12 \
      "$HOME"/.local/share/uv/python/cpython-3.12*/bin/python3.12; do
    if [ -x "$candidate" ] && "$candidate" -I -B -c \
        'import ensurepip, sys, venv; sys.exit(sys.version_info[:2] != (3, 12))' >/dev/null 2>&1; then
      # PATH can contain relative directories. Return an absolute invocation path.
      printf '%s/%s\n' "$(cd "$(dirname "$candidate")" && pwd -P)" "$(basename "$candidate")"
      return
    fi
  done
  return 1
}

if [ "${1:-}" = "--find-python" ] && [ "$#" -eq 1 ]; then
  find_python
  exit
fi
if [ "$#" -ne 0 ] && [ "$#" -ne 2 ]; then
  echo '用法：setup-formula.sh [资源目录 运行环境目录] 或 --find-python' >&2
  exit 2
fi

resources="${1:-/Applications/TapSnap.app/Contents/Resources}"
runtime="${2:-$HOME/Library/Application Support/com.sensnap.app/formula-runtime}"
if [ ! -f "$resources/formula-requirements.txt" ] || [ ! -f "$resources/formula-models.json" ] ||
   [ ! -f "$resources/verify_formula_models.py" ]; then
  echo "TapSnap 公式安装资源不完整，请重新安装应用。" >&2
  exit 1
fi

parent="$(dirname "$runtime")"
mkdir -p "$parent"
runtime="$(cd "$parent" && pwd -P)/$(basename "$runtime")"
lock="$runtime.install.lock"
if ! mkdir "$lock" 2>/dev/null; then
  echo "另一个公式安装正在运行，请稍后重试。" >&2
  exit 1
fi

stage_pid=
staged_runtime=
publish_dir=
staged_name=

# Give each stage its own process group. Terminating bash while it waits must
# also stop descendants such as pip's build process, before unlocking the runtime.
set -m
stop_stage() {
  if [ -n "$stage_pid" ]; then
    kill -TERM -- "-$stage_pid" 2>/dev/null || true
    kill -KILL -- "-$stage_pid" 2>/dev/null || true
    wait "$stage_pid" 2>/dev/null || true
    stage_pid=
  fi
}

run_stage() {
  local result=0
  "$@" &
  stage_pid=$!
  wait "$stage_pid" || result=$?
  if [ "$result" -ne 0 ]; then
    stop_stage
  else
    stage_pid=
  fi
  return "$result"
}

cleanup() {
  local pid
  trap '' HUP INT TERM
  stop_stage
  # Also cover a signal right after the subprocess starts, before $! is saved.
  for pid in $(jobs -pr); do
    stage_pid="$pid"
    stop_stage
  done
  if [ -n "$staged_runtime" ] &&
     { [ -z "$staged_name" ] || [ "$(readlink "$runtime" 2>/dev/null || true)" != "$staged_name" ]; }; then
    if [ -n "$publish_dir" ] && [ -d "$publish_dir/previous" ] &&
       [ ! -e "$runtime" ] && [ ! -L "$runtime" ]; then
      if ! mv "$publish_dir/previous" "$runtime"; then
        echo "恢复原运行环境失败，原目录仍保留在 $publish_dir/previous" >&2
        publish_dir=
      fi
    fi
    rm -rf "$staged_runtime"
  fi
  if [ -n "$publish_dir" ]; then rm -rf "$publish_dir"; fi
  rmdir "$lock"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

phase() {
  printf 'TAPSNAP_FORMULA_PHASE=%s\n' "$1"
}

validate_runtime() {
  local python="$1/bin/python"
  [ -x "$python" ] &&
    run_stage "$python" -I -B "$resources/verify_formula_models.py" "$resources/formula-models.json" &&
    run_stage env NO_ALBUMENTATIONS_UPDATE=1 HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 \
      "$python" -I -B -c 'from pix2tex.cli import LatexOCR'
}

phase environment
if validate_runtime "$runtime" >/dev/null 2>&1; then
  echo "本地公式识别已就绪，模型仅在识别时加载。"
  exit 0
fi
if [ -e "$runtime" ] && [ ! -d "$runtime" ]; then
  echo "公式运行环境路径已被其他文件占用。" >&2
  exit 1
fi
if ! python_bin="$(find_python)"; then
  echo "请先安装 Python 3.12，再运行此安装器。" >&2
  exit 1
fi

# A virtual environment's launch scripts use absolute paths. Keep it at the
# same path after verification and publish a sibling symlink to it.
staged_runtime="$(mktemp -d "$runtime.install.XXXXXX")"
staged_name="$(basename "$staged_runtime")"
run_stage "$python_bin" -I -B -m venv "$staged_runtime"
phase dependencies
run_stage env PIP_NO_INPUT=1 "$staged_runtime/bin/python" -I -B -m pip install -r "$resources/formula-requirements.txt"
phase models
# Fetch the checkpoint files without constructing LatexOCR, which would try
# to load them before the bundled checksums have been verified.
run_stage env NO_ALBUMENTATIONS_UPDATE=1 "$staged_runtime/bin/python" -I -B -u -c \
  'from pix2tex.model.checkpoints.get_latest_checkpoint import download_checkpoints; download_checkpoints()'
phase verify
validate_runtime "$staged_runtime"

publish_dir="$(mktemp -d "$runtime.publish.XXXXXX")"
ln -s "$staged_name" "$publish_dir/runtime"
if [ -d "$runtime" ] && [ ! -L "$runtime" ]; then
  mv "$runtime" "$publish_dir/previous"
fi
mv -fh "$publish_dir/runtime" "$runtime"
echo "本地公式识别已就绪，模型仅在识别时加载。"
