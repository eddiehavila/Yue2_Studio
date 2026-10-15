#!/usr/bin/env bash
set -Eeuo pipefail


# Check if the script is being run as root
if [ "$EUID" -ne 0 ]; then
  echo "Not running as root. Rerunning with sudo..."
  exec sudo "$0" "$@"
fi

# Everything below this line runs as root safely
echo "Success! Current user ID is: $EUID"


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
    git -C "$target_dir" checkout -B "$branch" "origin/$branch"
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
