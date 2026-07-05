#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  build-usb-image.sh \
    --source-iso PATH \
    --output-iso PATH \
    --admin-user USER \
    --admin-password-hash HASH \
    [--hostname HOSTNAME] \
    [--config-env PATH] \
    [--staging-dir PATH] \
    [--render-only]

Alternative testing mode:
  build-usb-image.sh \
    --source-tree PATH \
    --admin-user USER \
    --admin-password-hash HASH \
    [--hostname HOSTNAME] \
    [--config-env PATH] \
    [--staging-dir PATH] \
    --render-only

Options:
  --source-iso PATH         Debian netinstall ISO to customize.
  --source-tree PATH        Pre-extracted ISO tree for testing or advanced workflows.
  --output-iso PATH         Output ISO path. Required unless --render-only is used.
  --admin-user USER         Local administrative user created by Debian installer.
  --admin-password-hash HASH
                            Crypt(3) password hash for the administrative user.
  --hostname HOSTNAME       Installer hostname. Default: crazy-vlan-accessor.
  --config-env PATH         Config env copied into the image. Default: preseed/config.env.
  --staging-dir PATH        Reuse this directory instead of a temporary workspace.
  --render-only             Prepare the customized ISO tree but do not rebuild an ISO.

Notes:
  - Generate a password hash with: openssl passwd -6
  - The resulting ISO can be written to USB with: sudo dd if=OUTPUT.iso of=/dev/sdX bs=4M status=progress oflag=sync
USAGE
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SOURCE_ISO=""
SOURCE_TREE=""
OUTPUT_ISO=""
ADMIN_USER=""
ADMIN_PASSWORD_HASH=""
HOSTNAME_VALUE="crazy-vlan-accessor"
CONFIG_ENV="${REPO_ROOT}/preseed/config.env"
STAGING_DIR=""
RENDER_ONLY=0

while (($# > 0)); do
  case "$1" in
    --source-iso)
      SOURCE_ISO="${2:?missing source iso path}"
      shift 2
      ;;
    --source-tree)
      SOURCE_TREE="${2:?missing source tree path}"
      shift 2
      ;;
    --output-iso)
      OUTPUT_ISO="${2:?missing output iso path}"
      shift 2
      ;;
    --admin-user)
      ADMIN_USER="${2:?missing admin user}"
      shift 2
      ;;
    --admin-password-hash)
      ADMIN_PASSWORD_HASH="${2:?missing admin password hash}"
      shift 2
      ;;
    --hostname)
      HOSTNAME_VALUE="${2:?missing hostname}"
      shift 2
      ;;
    --config-env)
      CONFIG_ENV="${2:?missing config env path}"
      shift 2
      ;;
    --staging-dir)
      STAGING_DIR="${2:?missing staging dir path}"
      shift 2
      ;;
    --render-only)
      RENDER_ONLY=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -n "$SOURCE_ISO" && -n "$SOURCE_TREE" ]]; then
  echo "Use either --source-iso or --source-tree, not both. --source-iso extracts files from a Debian ISO, while --source-tree uses an already extracted ISO directory." >&2
  exit 1
fi

if [[ -z "$SOURCE_ISO" && -z "$SOURCE_TREE" ]]; then
  echo "Either --source-iso or --source-tree is required." >&2
  exit 1
fi

for required in ADMIN_USER ADMIN_PASSWORD_HASH; do
  if [[ -z "${!required}" ]]; then
    echo "Missing required argument: ${required}" >&2
    usage >&2
    exit 1
  fi
done

if ((RENDER_ONLY == 0)) && [[ -z "$OUTPUT_ISO" ]]; then
  echo "--output-iso is required unless --render-only is used." >&2
  exit 1
fi

if [[ ! -f "$CONFIG_ENV" ]]; then
  echo "Config env file not found: $CONFIG_ENV" >&2
  exit 1
fi

if [[ -n "$SOURCE_ISO" && ! -f "$SOURCE_ISO" ]]; then
  echo "Source ISO not found: $SOURCE_ISO" >&2
  exit 1
fi

if [[ -n "$SOURCE_TREE" && ! -d "$SOURCE_TREE" ]]; then
  echo "Source tree not found: $SOURCE_TREE" >&2
  exit 1
fi

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

prepare_workspace() {
  if [[ -n "$STAGING_DIR" ]]; then
    mkdir -p "$STAGING_DIR"
    WORKDIR="$STAGING_DIR"
  else
    WORKDIR="$(mktemp -d /tmp/crazy-vlan-accessor-iso.XXXXXX)"
  fi

  ISO_ROOT="$WORKDIR/iso-root"
  rm -rf "$ISO_ROOT"
  mkdir -p "$ISO_ROOT"
}

extract_source() {
  if [[ -n "$SOURCE_TREE" ]]; then
    cp -a "$SOURCE_TREE/." "$ISO_ROOT/"
    return
  fi

  require_command xorriso
  xorriso -osirrox on -indev "$SOURCE_ISO" -extract / "$ISO_ROOT" >/dev/null
}

render_preseed() {
  python - "$REPO_ROOT/preseed/preseed.cfg" "$ISO_ROOT/preseed/preseed.cfg" "$HOSTNAME_VALUE" "$ADMIN_USER" "$ADMIN_PASSWORD_HASH" <<'PY'
from pathlib import Path
import sys

template = Path(sys.argv[1]).read_text()
rendered = (template
    .replace('@@HOSTNAME@@', sys.argv[3])
    .replace('@@ADMIN_USER@@', sys.argv[4])
    .replace('@@ADMIN_PASSWORD_HASH@@', sys.argv[5]))
Path(sys.argv[2]).parent.mkdir(parents=True, exist_ok=True)
Path(sys.argv[2]).write_text(rendered)
PY
}

copy_payloads() {
  mkdir -p "$ISO_ROOT/preseed" "$ISO_ROOT/crazy-vlan-accessor"
  cp "$REPO_ROOT/preseed/first-boot.service" "$ISO_ROOT/preseed/first-boot.service"
  cp "$REPO_ROOT/preseed/first-boot.sh" "$ISO_ROOT/preseed/first-boot.sh"
  cp "$CONFIG_ENV" "$ISO_ROOT/preseed/config.env"
  cp "$REPO_ROOT/scripts/setup-host.sh" "$ISO_ROOT/crazy-vlan-accessor/setup-host.sh"
  chmod 755 "$ISO_ROOT/crazy-vlan-accessor/setup-host.sh" "$ISO_ROOT/preseed/first-boot.sh"
}

patch_isolinux() {
  local file="$ISO_ROOT/isolinux/txt.cfg"
  [[ -f "$file" ]] || return 0

  python - "$file" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
extra = 'auto=true priority=critical file=/cdrom/preseed/preseed.cfg'
lines = []
for raw in path.read_text().splitlines():
    stripped = raw.lstrip()
    if stripped.startswith('append ') and 'file=/cdrom/preseed/preseed.cfg' not in stripped:
        if ' ---' in raw:
            raw = raw.replace(' ---', f' {extra} ---', 1)
        else:
            raw = f'{raw} {extra}'
    lines.append(raw)
path.write_text('\n'.join(lines) + '\n')
PY
}

patch_grub() {
  local file="$ISO_ROOT/boot/grub/grub.cfg"
  [[ -f "$file" ]] || return 0

  python - "$file" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
extra = 'auto=true priority=critical file=/cdrom/preseed/preseed.cfg'
lines = []
for raw in path.read_text().splitlines():
    stripped = raw.lstrip()
    if stripped.startswith('linux') and 'file=/cdrom/preseed/preseed.cfg' not in stripped:
        if ' ---' in raw:
            raw = raw.replace(' ---', f' {extra} ---', 1)
        else:
            raw = f'{raw} {extra}'
    lines.append(raw)
path.write_text('\n'.join(lines) + '\n')
PY
}

refresh_md5() {
  local file="$ISO_ROOT/md5sum.txt"
  [[ -e "$file" ]] || return 0

  (
    cd "$ISO_ROOT"
    find . -path './md5sum.txt' -prune -o -type f -print0 \
      | sort -z \
      | xargs -0 md5sum
  ) > "$file"
}

build_iso() {
  require_command xorriso
  xorriso \
    -indev "$SOURCE_ISO" \
    -outdev "$OUTPUT_ISO" \
    -boot_image any replay \
    -update_r "$ISO_ROOT" / \
    -commit \
    -end >/dev/null

  if command -v isohybrid >/dev/null 2>&1; then
    isohybrid --uefi "$OUTPUT_ISO" >/dev/null 2>&1 || true
  fi
}

prepare_workspace
extract_source
render_preseed
copy_payloads
patch_isolinux
patch_grub
refresh_md5

if ((RENDER_ONLY)); then
  echo "Prepared customized ISO tree at: $ISO_ROOT"
  exit 0
fi

if [[ -n "$SOURCE_TREE" ]]; then
  echo "--source-tree supports only --render-only. Use --source-iso to rebuild an ISO." >&2
  exit 1
fi

build_iso

echo "Created customized ISO: $OUTPUT_ISO"
