#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# 1stream -> Xray custom geosite dat builder
#
# Best-practice version:
#   - Generates category tags:
#       ai
#       global-platform
#       taiwan-media
#
#   - Generates category-service tags:
#       ai-openai
#       ai-google-gemini
#       global-platform-netflix
#       taiwan-media-bahamut-anime
#
#   - Does NOT generate legacy flat service tags:
#       openai
#       netflix
#       youtube
#       all
#
# Output:
#   /usr/local/share/xray/1stream.dat
#
# Usage:
#   bash /root/1stream.sh
#
# Optional:
#   RESTART_XRAY=1 bash /root/1stream.sh
# ============================================================

# ======================
# User-configurable vars
# ======================

WORKDIR="${WORKDIR:-/opt/1stream-geosite}"
DATADIR="${DATADIR:-$WORKDIR/data}"
DLC_DIR="${DLC_DIR:-$WORKDIR/domain-list-community}"

ASSET_DIR="${ASSET_DIR:-/usr/local/share/xray}"
OUT_DAT="${OUT_DAT:-$ASSET_DIR/1stream.dat}"
BACKUP_DAT="${BACKUP_DAT:-$ASSET_DIR/1stream.dat.bak}"

XRAY_CONFIG="${XRAY_CONFIG:-/usr/local/etc/xray/config.json}"

STREAM_URL="${STREAM_URL:-https://raw.githubusercontent.com/1-stream/1stream-public-utils/main/stream.xray.list}"

GO_MIN_VERSION="${GO_MIN_VERSION:-1.24}"
GO_INSTALL_DIR="${GO_INSTALL_DIR:-/usr/local/go}"
GO_DOWNLOAD_API="${GO_DOWNLOAD_API:-https://go.dev/dl/?mode=json}"
GO_DOWNLOAD_BASE="${GO_DOWNLOAD_BASE:-https://go.dev/dl}"

GOPROXY="${GOPROXY:-https://goproxy.cn,direct}"
export GOPROXY
export PATH="$PATH:/usr/local/bin:/usr/bin:/bin"
if [ -d "$GO_INSTALL_DIR/bin" ]; then
  # Keep an existing toolchain from actions/setup-go or the user's PATH ahead of
  # /usr/local/go, which may contain an older preinstalled Go on CI runners.
  export PATH="$PATH:$GO_INSTALL_DIR/bin"
fi

LOG_FILE="${LOG_FILE:-/var/log/1stream-dat-update.log}"

# 0 = only build/install/test
# 1 = restart xray after successful build and test
RESTART_XRAY="${RESTART_XRAY:-0}"

# 1 = config test failure exits with error and rolls back
# 0 = skip hard failure when xray/config is absent
REQUIRE_XRAY_TEST="${REQUIRE_XRAY_TEST:-1}"

# ======================
# Logging
# ======================

mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

log() {
  echo
  echo "========== $* =========="
}

info() {
  echo "[INFO] $*"
}

warn() {
  echo "[WARN] $*" >&2
}

die() {
  echo "[ERROR] $*" >&2
  exit 1
}

on_error() {
  local exit_code=$?
  echo
  echo "[ERROR] Script failed."
  echo "[ERROR] Line: ${BASH_LINENO[0]}"
  echo "[ERROR] Command: ${BASH_COMMAND}"
  echo "[ERROR] Exit code: $exit_code"
  exit "$exit_code"
}
trap on_error ERR

TMP_RAW=""
TMP_PY=""
TMP_DAT=""
TMP_GO_JSON=""
TMP_GO_TGZ=""

cleanup() {
  rm -f \
    "${TMP_RAW:-}" \
    "${TMP_PY:-}" \
    "${TMP_DAT:-}" \
    "${TMP_GO_JSON:-}" \
    "${TMP_GO_TGZ:-}"
}
trap cleanup EXIT

# ======================
# Helpers
# ======================

cmd_exists() {
  command -v "$1" >/dev/null 2>&1
}

version_ge() {
  python3 - "$1" "$2" <<'PY'
import re
import sys

def parse(v: str):
    nums = re.findall(r"\d+", v)
    nums = nums[:3]
    while len(nums) < 3:
        nums.append("0")
    return tuple(map(int, nums))

current = parse(sys.argv[1])
minimum = parse(sys.argv[2])

sys.exit(0 if current >= minimum else 1)
PY
}

get_go_version() {
  if ! cmd_exists go; then
    return 1
  fi

  go version | awk '{print $3}' | sed 's/^go//'
}

detect_go_arch() {
  local machine
  machine="$(uname -m)"

  case "$machine" in
    x86_64|amd64)
      echo "amd64"
      ;;
    aarch64|arm64)
      echo "arm64"
      ;;
    *)
      die "Unsupported architecture for automatic Go install: $machine"
      ;;
  esac
}

safe_rm_dir() {
  local dir="$1"

  if [ -z "$dir" ] || [ "$dir" = "/" ]; then
    die "Refusing to remove unsafe directory: '$dir'"
  fi

  rm -rf -- "$dir"
}

# ======================
# Step 0: Environment
# ======================

ensure_base_commands() {
  log "0/8 Checking base environment"

  info "Started at: $(date '+%F %T')"
  info "Log file: $LOG_FILE"
  info "Workdir: $WORKDIR"
  info "Data dir: $DATADIR"
  info "Output dat: $OUT_DAT"
  info "Xray config: $XRAY_CONFIG"

  local missing=()

  for cmd in curl git python3 tar; do
    if ! cmd_exists "$cmd"; then
      missing+=("$cmd")
    fi
  done

  if [ "${#missing[@]}" -gt 0 ]; then
    warn "Missing base commands: ${missing[*]}"

    if cmd_exists apt-get && [ "$(id -u)" -eq 0 ]; then
      info "Installing missing base packages with apt-get..."
      apt-get update
      apt-get install -y curl git python3 tar ca-certificates
    else
      die "Please install missing commands manually: ${missing[*]}"
    fi
  fi

  info "curl: $(command -v curl)"
  info "git: $(command -v git)"
  info "python3: $(command -v python3)"
  info "tar: $(command -v tar)"

  if cmd_exists xray; then
    info "xray: $(command -v xray)"
    xray version | head -n 1 || true
  else
    warn "xray command not found."
    if [ "$REQUIRE_XRAY_TEST" = "1" ]; then
      die "REQUIRE_XRAY_TEST=1 but xray command is missing."
    fi
  fi
}

# ======================
# Step 1: Go
# ======================

install_go_latest() {
  log "1/8 Installing official Go"

  if [ "$(id -u)" -ne 0 ]; then
    die "Need root to install Go to $GO_INSTALL_DIR."
  fi

  local go_arch filename sha256 download_url actual_sha

  go_arch="$(detect_go_arch)"
  info "Detected architecture: linux-$go_arch"

  TMP_GO_JSON="$(mktemp)"
  TMP_GO_TGZ="$(mktemp)"

  info "Fetching Go release metadata:"
  info "$GO_DOWNLOAD_API"
  curl -fsSL "$GO_DOWNLOAD_API" -o "$TMP_GO_JSON"

  read -r filename sha256 < <(
    python3 - "$TMP_GO_JSON" "$go_arch" <<'PY'
import json
import sys

metadata_path = sys.argv[1]
arch = sys.argv[2]

with open(metadata_path, "r", encoding="utf-8") as f:
    releases = json.load(f)

for release in releases:
    if not release.get("stable", False):
        continue

    for item in release.get("files", []):
        if (
            item.get("os") == "linux"
            and item.get("arch") == arch
            and item.get("kind") == "archive"
            and item.get("filename", "").endswith(".tar.gz")
        ):
            print(item["filename"], item.get("sha256", ""))
            raise SystemExit(0)

raise SystemExit("No matching stable Go archive found")
PY
  )

  [ -n "$filename" ] || die "Could not resolve Go archive filename."

  download_url="$GO_DOWNLOAD_BASE/$filename"

  info "Downloading Go:"
  info "$download_url"
  curl -fL --progress-bar "$download_url" -o "$TMP_GO_TGZ"

  if [ -n "$sha256" ] && cmd_exists sha256sum; then
    info "Verifying Go archive sha256..."
    actual_sha="$(sha256sum "$TMP_GO_TGZ" | awk '{print $1}')"

    if [ "$actual_sha" != "$sha256" ]; then
      die "Go archive sha256 mismatch. Expected $sha256, got $actual_sha"
    fi
  else
    warn "Skipping sha256 verification."
  fi

  info "Installing Go to $GO_INSTALL_DIR"
  rm -rf "$GO_INSTALL_DIR"
  tar -C "$(dirname "$GO_INSTALL_DIR")" -xzf "$TMP_GO_TGZ"

  cat > /etc/profile.d/go.sh <<PROFILE
export PATH=$GO_INSTALL_DIR/bin:\$PATH
PROFILE

  export PATH="$GO_INSTALL_DIR/bin:$PATH"

  info "Installed Go:"
  go version
}

ensure_go() {
  log "1/8 Checking Go environment"

  if cmd_exists go; then
    local current
    current="$(get_go_version || true)"

    info "Go path: $(command -v go)"
    info "Go version: ${current:-unknown}"

    if [ -n "$current" ] && version_ge "$current" "$GO_MIN_VERSION"; then
      info "Go version is OK: $current >= $GO_MIN_VERSION"
      return 0
    fi

    warn "Go version is too old or invalid. Need >= $GO_MIN_VERSION"
  else
    warn "Go not found."
  fi

  if [ -x "$GO_INSTALL_DIR/bin/go" ]; then
    local install_dir_version
    install_dir_version="$($GO_INSTALL_DIR/bin/go version | awk '{print $3}' | sed 's/^go//' || true)"

    if [ -n "$install_dir_version" ] && version_ge "$install_dir_version" "$GO_MIN_VERSION"; then
      export PATH="$GO_INSTALL_DIR/bin:$PATH"
      info "Using Go from GO_INSTALL_DIR: $GO_INSTALL_DIR/bin/go"
      info "Go version: $install_dir_version"
      return 0
    fi
  fi

  install_go_latest

  local installed
  installed="$(get_go_version || true)"

  if ! version_ge "$installed" "$GO_MIN_VERSION"; then
    die "Installed Go version is still too old: $installed"
  fi
}

# ======================
# Step 2: Download list
# ======================

download_1stream() {
  log "2/8 Downloading 1stream xray list"

  TMP_RAW="$(mktemp)"

  info "URL: $STREAM_URL"
  curl -fL --progress-bar "$STREAM_URL" -o "$TMP_RAW"

  info "Downloaded to: $TMP_RAW"
  info "Downloaded lines: $(wc -l < "$TMP_RAW")"
}

# ======================
# Step 3: Parse groups
# ======================

parse_1stream() {
  log "3/8 Parsing 1stream groups"

  info "Cleaning old data directory: $DATADIR"
  safe_rm_dir "$DATADIR"
  mkdir -p "$DATADIR"

  TMP_PY="$(mktemp)"

  cat > "$TMP_PY" <<'PY'
import re
import sys
from pathlib import Path
from collections import defaultdict

raw_file = Path(sys.argv[1])
data_dir = Path(sys.argv[2])
data_dir.mkdir(parents=True, exist_ok=True)

def slugify(name: str) -> str:
    name = name.strip().lower()
    name = name.replace("&", "and")
    name = name.replace("+", "plus")
    name = re.sub(r"[^a-z0-9]+", "-", name)
    name = re.sub(r"-+", "-", name).strip("-")
    return name or "unknown"

category_alias = {
    "ai-platform": "ai",
    "global-plaform": "global-platform",
    "global-platform": "global-platform",
}

service_alias = {
    "openai": "openai",
    "claude-2": "claude",
    "google-gemini": "google-gemini",
    "google-aistudio": "google-aistudio",
    "microsoft-copilot-for-image-generates": "copilot",
    "disneyplus": "disneyplus",
    "netflix": "netflix",
    "youtube": "youtube",
}

current_category = None
current_service = None

groups = defaultdict(set)

for line in raw_file.read_text(encoding="utf-8", errors="ignore").splitlines():
    line = line.strip()

    # Category:
    #   # ---------- > AI Platform
    cat = re.match(r"#\s*-+\s*>\s*(.+?)\s*$", line)
    if cat:
        current_category = slugify(cat.group(1))
        current_category = category_alias.get(current_category, current_category)
        current_service = None
        continue

    # Service:
    #   # > Openai
    srv = re.match(r"#\s*>\s*(.+?)\s*$", line)
    if srv:
        current_service = slugify(srv.group(1))
        current_service = service_alias.get(current_service, current_service)
        continue

    # Rule:
    #   "domain:example.com",
    m = re.search(r'"((?:domain|full|keyword|regexp):[^"]+)"', line)
    if not m:
        continue

    rule = m.group(1).strip()
    if not rule:
        continue

    # Best-practice output:
    # 1. Category tag:
    #      ai
    #      global-platform
    #      taiwan-media
    if current_category:
        groups[current_category].add(rule)

    # 2. Category-service tag:
    #      ai-openai
    #      global-platform-netflix
    #      taiwan-media-bahamut-anime
    if current_category and current_service:
        groups[f"{current_category}-{current_service}"].add(rule)

for name, rules in sorted(groups.items()):
    if not rules:
        continue

    (data_dir / name).write_text(
        "\n".join(sorted(rules)) + "\n",
        encoding="utf-8",
    )

print("Generated tags:")
for name in sorted(groups):
    print(f"  {name}: {len(groups[name])}")
PY

  python3 "$TMP_PY" "$TMP_RAW" "$DATADIR"

  info "Generated clean data directory: $DATADIR"
  info "Generated tag count: $(find "$DATADIR" -type f | wc -l)"
}

# ======================
# Step 4: domain-list-community
# ======================

prepare_dlc() {
  log "4/8 Preparing domain-list-community"

  mkdir -p "$WORKDIR"

  if [ ! -d "$DLC_DIR/.git" ]; then
    info "Cloning domain-list-community:"
    info "$DLC_DIR"
    git clone --depth=1 https://github.com/v2fly/domain-list-community.git "$DLC_DIR"
  else
    info "Updating domain-list-community:"
    info "$DLC_DIR"
    git -C "$DLC_DIR" pull --ff-only
  fi
}

# ======================
# Step 5: Build dat
# ======================

build_dat() {
  log "5/8 Building 1stream.dat"

  cd "$DLC_DIR"

  info "Cleaning old build artifact:"
  rm -f "$DLC_DIR/dlc.dat"

  info "Go version:"
  go version

  info "GOPROXY=$GOPROXY"

  info "Running: go mod download"
  go mod download

  info "Running: go run ./ --datapath=$DATADIR"
  go run ./ --datapath="$DATADIR"

  if [ ! -f "$DLC_DIR/dlc.dat" ]; then
    die "Build failed: $DLC_DIR/dlc.dat not found"
  fi

  TMP_DAT="$(mktemp)"
  cp "$DLC_DIR/dlc.dat" "$TMP_DAT"

  info "Built dat:"
  ls -lh "$TMP_DAT"
}

# ======================
# Step 6: Install dat
# ======================

install_dat() {
  log "6/8 Installing dat"

  mkdir -p "$ASSET_DIR"

  local new_dat="${OUT_DAT}.new"

  rm -f "$new_dat"

  if [ -f "$OUT_DAT" ]; then
    info "Backing up current dat:"
    info "$BACKUP_DAT"
    cp "$OUT_DAT" "$BACKUP_DAT"
  else
    warn "No existing dat found. This is probably the first install."
  fi

  info "Preparing new dat:"
  install -m 0644 "$TMP_DAT" "$new_dat"
  ls -lh "$new_dat"

  info "Replacing dat:"
  mv -f "$new_dat" "$OUT_DAT"

  info "Installed dat:"
  ls -lh "$OUT_DAT"
}

rollback_dat() {
  if [ -f "$BACKUP_DAT" ]; then
    warn "Rolling back dat from backup:"
    warn "$BACKUP_DAT"
    install -m 0644 "$BACKUP_DAT" "$OUT_DAT"
  else
    warn "No backup dat found. Cannot roll back."
  fi
}

# ======================
# Step 7: Test Xray
# ======================

test_xray_config() {
  log "7/8 Testing Xray config"

  if ! cmd_exists xray; then
    if [ "$REQUIRE_XRAY_TEST" = "1" ]; then
      rollback_dat
      die "xray command not found and REQUIRE_XRAY_TEST=1."
    fi

    warn "xray command not found. Skipping config test."
    return 0
  fi

  if [ ! -f "$XRAY_CONFIG" ]; then
    if [ "$REQUIRE_XRAY_TEST" = "1" ]; then
      rollback_dat
      die "Xray config not found: $XRAY_CONFIG"
    fi

    warn "Xray config not found. Skipping config test:"
    warn "$XRAY_CONFIG"
    return 0
  fi

  info "Config:"
  info "$XRAY_CONFIG"

  local ok=0

  info "Trying: xray run -test -config $XRAY_CONFIG"
  if xray run -test -config "$XRAY_CONFIG"; then
    ok=1
  else
    warn "xray run -test failed."
    warn "Trying fallback: xray test -config $XRAY_CONFIG"

    if xray test -config "$XRAY_CONFIG"; then
      ok=1
    fi
  fi

  if [ "$ok" != "1" ]; then
    rollback_dat
    die "Xray config test failed."
  fi

  info "Xray config test passed."

  if [ "$RESTART_XRAY" = "1" ]; then
    if cmd_exists systemctl; then
      info "Restarting xray because RESTART_XRAY=1"
      systemctl restart xray
      systemctl --no-pager --full status xray | sed -n '1,20p' || true
    else
      warn "systemctl not found. Please restart xray manually."
    fi
  else
    info "Not restarting xray. Set RESTART_XRAY=1 if you want automatic restart."
  fi
}

# ======================
# Step 8: Summary
# ======================

show_result() {
  log "8/8 Done"

  info "Final dat:"
  ls -lh "$OUT_DAT"

  echo
  echo "Recommended Xray refs:"
  for tag in \
    ai \
    ai-openai \
    ai-claude \
    ai-google-gemini \
    ai-google-aistudio \
    ai-copilot \
    global-platform \
    global-platform-netflix \
    global-platform-disneyplus \
    global-platform-youtube \
    taiwan-media \
    taiwan-media-bahamut-anime \
    taiwan-media-hami-video
  do
    if [ -f "$DATADIR/$tag" ]; then
      echo "  ext:1stream.dat:$tag"
    fi
  done

  echo
  echo "All generated tags:"
  ls -1 "$DATADIR" | sort

  echo
  echo "Example Xray routing rule:"
  cat <<'JSON'
{
  "type": "field",
  "domain": [
    "ext:1stream.dat:ai"
  ],
  "outboundTag": "tw-s5",
  "ruleTag": "1stream-ai"
}
JSON

  echo
  echo "Update completed successfully."
  echo "Log file: $LOG_FILE"
}

main() {
  ensure_base_commands
  ensure_go
  download_1stream
  parse_1stream
  prepare_dlc
  build_dat
  install_dat
  test_xray_config
  show_result
}

main "$@"
