#!/usr/bin/env bash
set -Eeuo pipefail


# Check if the script is being run as root
#if [ "$EUID" -ne 0 ]; then
#  echo "Not running as root. Rerunning with sudo..."
#  exec sudo "$0" "$@"
#fi
#
## Everything below this line runs as root safely
#echo "Success! Current user ID is: $EUID"


# ---- config ----
BASE_DIR="/comfy/mnt"

YUE2_DIR="$BASE_DIR/YuE"
YUE2_REPO="https://github.com/multimodal-art-projection/YuE.git"
YUE2_VENV="$YUE2_DIR/.venv"
YUE2_UV="$YUE2_VENV/bin/uv"

STUDIO_DIR="$YUE2_DIR/Yue2_Studio"
STUDIO_REPO="https://github.com/eddiehavila/Yue2_Studio.git"
STUDIO_BRANCH="dockerized"
STUDIO_PORT=7862

# YuE2 weights Studio uses by default (models/YuE2-3B, models/YuE2-Vae). Revisions match the
# ones Studio's trainer setup pins (src/yue2_studio/trainer_setup.py).
YUE2_MODEL_REVISION="1a96eca688d6ae5d7f0feb88573fec89920fcd19"
YUE2_VAE_REVISION="95535e72a97bc0f09b8ada125d26b4009428c0e8"

# audio.cpp engine for Studio's optional GGUF backend. Off by default: Torch needs none of it.
# Enable with YUE2_BUILD_AUDIOCPP=1 (e.g. under environment: in compose.yaml).
BUILD_AUDIOCPP="${YUE2_BUILD_AUDIOCPP:-0}"
# The commit is the one Studio's adapter
# (src/yue2_studio/gguf.py) was checked against. The binary lands in build/bin under
# tools/audio.cpp, where Studio detects it automatically.
AUDIOCPP_REPO="https://github.com/0xShug0/audio.cpp.git"
AUDIOCPP_COMMIT="fbe3eedbf6c504e45189e2cdcf1b257740a28863"
AUDIOCPP_DIR="$YUE2_DIR/tools/audio.cpp"
AUDIOCPP_CUDA_ARCH="native"   # build for the GPUs visible at build time; e.g. 89 = RTX 4000



LOG_PREFIX="[yue2_studio]"

# ---- helpers ----
log() { echo "$LOG_PREFIX $*"; }
need_cmd() { command -v "$1" >/dev/null 2>&1; }

ensure_root_or_sudo() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    if ! need_cmd sudo; then
      echo "This script requires root or sudo." >&2
      exit 1
    fi
  fi
}

apt_install_if_missing() {
  local pkg="$1"
  if dpkg -s "$pkg" >/dev/null 2>&1; then
    log "Package already installed: $pkg"
  else
    log "Installing package: $pkg"
    DEBIAN_FRONTEND=noninteractive sudo apt-get install -y "$pkg"
  fi
}

# git_sync <repo_url> <dir> [branch] [keep_local]
# branch: check out origin/<branch> (default: the current branch).
# keep_local=1: leave a checkout with uncommitted changes untouched instead of resetting it.
git_sync() {
  local repo_url="$1"
  local target_dir="$2"
  local branch="${3:-}"
  local keep_local="${4:-0}"

  if [[ -d "$target_dir/.git" ]]; then
    if [[ "$keep_local" == 1 && -n "$(git -C "$target_dir" status --porcelain --untracked-files=no)" ]]; then
      log "WARNING: $target_dir has uncommitted changes; skipping update so they are not lost"
      return
    fi
    log "Updating repo in $target_dir (git pull)"
    git -C "$target_dir" remote set-url origin "$repo_url"
    git -C "$target_dir" fetch --all --prune
    # keep it deterministic for repeat runs
    branch="${branch:-$(git -C "$target_dir" rev-parse --abbrev-ref HEAD)}"
    if [[ "$(git -C "$target_dir" rev-parse --abbrev-ref HEAD)" != "$branch" ]]; then
      git -C "$target_dir" checkout -B "$branch" "origin/$branch"
    fi
    git -C "$target_dir" reset --hard "origin/$branch"
  elif [[ -e "$target_dir" ]]; then
    echo "ERROR: $target_dir exists but is not a git repo. Move it aside or delete it." >&2
    exit 1
  else
    log "Cloning repo into $target_dir"
    git clone ${branch:+--branch "$branch"} "$repo_url" "$target_dir"
  fi
}

ensure_dir() { mkdir -p "$1"; }

# Download a pinned YuE2 snapshot into models/<name>, where Studio and the yue2 CLI look by
# default. YuE's models/ is gitignored and on the mounted volume, so it survives restarts,
# container rebuilds and the git clean above. A stamp records the finished revision; an
# interrupted download is resumed on the next run.
fetch_model() {
  local repo="$1" revision="$2" target="$YUE2_DIR/models/$3"
  if [[ -f "$target/config.json" && "$(cat "$target/.yue2-revision" 2>/dev/null)" == "$revision" ]]; then
    log "Model ready: $target ($repo@${revision:0:7})"
    return 0
  fi
  log "Downloading $repo@${revision:0:7} into $target"
  python - "$repo" "$revision" "$target" <<'PY' || return 1
import sys
from huggingface_hub import snapshot_download
from yue2.storage import MODEL_FILES, MODEL_LICENSES
repo, revision, target = sys.argv[1:]
# Same file set yue2 itself resolves; never pulls anything else from the repo.
snapshot_download(repo, revision=revision, local_dir=target,
                  allow_patterns=sorted(MODEL_FILES) + ["model-?????-of-?????.safetensors"] +
                                 ["licenses/" + name for name in sorted(MODEL_LICENSES)])
PY
  echo "$revision" > "$target/.yue2-revision"
}

# Build audiocpp_cli once per AUDIOCPP_COMMIT. Each step returns on failure explicitly:
# set -e does not apply inside a function called from an || list.
build_audiocpp() {
  local cli="$AUDIOCPP_DIR/build/bin/audiocpp_cli"
  local stamp="$AUDIOCPP_DIR/build/.audiocpp-commit"
  if [[ -x "$cli" && "$(cat "$stamp" 2>/dev/null)" == "$AUDIOCPP_COMMIT" ]]; then
    log "audio.cpp $AUDIOCPP_COMMIT already built: $cli"
    return 0
  fi
  log "Fetching audio.cpp $AUDIOCPP_COMMIT into $AUDIOCPP_DIR"
  if [[ ! -d "$AUDIOCPP_DIR/.git" ]]; then
    mkdir -p "$AUDIOCPP_DIR" && git -C "$AUDIOCPP_DIR" init -q || return 1
  fi
  git -C "$AUDIOCPP_DIR" fetch --depth 1 "$AUDIOCPP_REPO" "$AUDIOCPP_COMMIT" || return 1
  git -C "$AUDIOCPP_DIR" checkout -q --detach FETCH_HEAD || return 1
  log "Building audiocpp_cli with CUDA (arch: $AUDIOCPP_CUDA_ARCH); the first build takes a while"
  (cd "$AUDIOCPP_DIR" && ./scripts/build_linux.sh --backend cuda --cuda-arch "$AUDIOCPP_CUDA_ARCH" \
      --build-dir build --target audiocpp_cli) || return 1
  [[ -x "$cli" ]] || { log "audio.cpp build finished but $cli is missing"; return 1; }
  echo "$AUDIOCPP_COMMIT" > "$stamp"
  log "audio.cpp ready: $cli"
}

stop_existing_api() {
  if need_cmd pgrep; then
    local pids
    pids="$(pgrep -f "acestep-api.*--port[ =]$API_PORT" || true)"
    if [[ -n "${pids:-}" ]]; then
      log "Stopping existing acestep-api on port $API_PORT (pids: $pids)"
      kill $pids || true
      sleep 1
    fi
  fi
}

# ---- main ----
log "Starting as user: $(whoami)"
ensure_root_or_sudo



log "== Installing system packages"
DEBIAN_FRONTEND=noninteractive sudo apt-get update -y
if [[ "$BUILD_AUDIOCPP" == 1 ]]; then
  apt_install_if_missing cmake        # audio.cpp build
  apt_install_if_missing ninja-build  # audio.cpp build
fi


log "== Sync yue2_studio repo (contained under $YUE2_DIR)"
ensure_dir "$BASE_DIR"
git_sync "$YUE2_REPO" "$YUE2_DIR"

log "== Entering directory $YUE2_DIR"
cd "$YUE2_DIR"

log "== Forcing commit 92a73cc7652fcc1f937855e4b765e0a0edd7ff2e"
git reset --hard 92a73cc7652fcc1f937855e4b765e0a0edd7ff2e
git clean -df


log "== Ensure yue2 venv (contained under $YUE2_VENV)"
if [[ ! -d "$YUE2_VENV" ]]; then
  log "Creating venv: $YUE2_VENV"
  /usr/bin/python3 -m venv "$YUE2_VENV"
else
  log "Venv already exists: $YUE2_VENV"
fi

log "== Activate yue2 venv"
# shellcheck disable=SC1090
source "$YUE2_VENV/bin/activate"

log "== Currently we are in: $(pwd)"

log "== Bootstrap python tooling (inside YuE venv only)"
python -m pip install -U pip wheel setuptools

python -m pip install --upgrade pip
python -m pip install .

log "== Ensure YuE2 models (first run downloads about 8 GB)"
fetch_model m-a-p/YuE2-3B "$YUE2_MODEL_REVISION" YuE2-3B || { log "ERROR: YuE2-3B download failed"; exit 1; }
fetch_model m-a-p/YuE2-Vae "$YUE2_VAE_REVISION" YuE2-Vae || { log "ERROR: YuE2-Vae download failed"; exit 1; }

log "== Ensure audio.cpp engine (GGUF backend)"
# After the YuE reset/clean above: git clean leaves the nested audio.cpp repo alone.
if [[ "$BUILD_AUDIOCPP" == 1 ]]; then
  build_audiocpp || log "WARNING: audio.cpp build failed; GGUF is unavailable, the Torch engine still works"
else
  log "Skipping audio.cpp (set YUE2_BUILD_AUDIOCPP=1 to build it for the GGUF backend)"
fi


log "== Sync yue2_studio repo (contained under $YUE2_DIR)"
ensure_dir "$YUE2_DIR"
git_sync "$STUDIO_REPO" "$STUDIO_DIR" "$STUDIO_BRANCH" 1

log "== Entering directory $STUDIO_DIR"
cd "$STUDIO_DIR"

log "== Executing python install_studio.py"
python "install_studio.py"  || exit 1
log "== Executing python launch_studio.py"
# ../launch_studio.py is the copy install_studio.py placed in the YuE checkout.
# Bind all interfaces so the published port reaches it; keep running when browser tabs close.
python "../launch_studio.py" --host 0.0.0.0 --port "$STUDIO_PORT" --no-browser --keep-alive "$@"

log "yue2_studio finished "
log "Waiting a few seconds before proceeding"


log "== Done. Exiting with 1 to prevent default Comfy start."
exit 1
