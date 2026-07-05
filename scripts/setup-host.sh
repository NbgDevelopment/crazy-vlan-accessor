#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  setup-host.sh \
    --interface IFACE \
    --admin-vlan VLAN_ID \
    --admin-cidr CIDR \
    --admin-gateway GATEWAY \
    --admin-dns DNS1[,DNS2...] \
    --container-vlans VLAN:SUBNET:GATEWAY[,VLAN:SUBNET:GATEWAY...] \
    [--hostname HOSTNAME] \
    [--root-dir PATH] \
    [--skip-install] \
    [--create-docker-networks] \
    [--dry-run]

Examples:
  setup-host.sh \
    --interface eno1 \
    --admin-vlan 10 \
    --admin-cidr 192.168.10.10/24 \
    --admin-gateway 192.168.10.1 \
    --admin-dns 192.168.10.1,1.1.1.1 \
    --container-vlans 20:192.168.20.0/24:192.168.20.1,30:192.168.30.0/24:192.168.30.1
EOF
}

INTERFACE=""
HOSTNAME_VALUE="crazy-vlan-accessor"
ADMIN_VLAN=""
ADMIN_CIDR=""
ADMIN_GATEWAY=""
ADMIN_DNS=""
CONTAINER_VLANS=""
ROOT_DIR="/"
SKIP_INSTALL=0
CREATE_DOCKER_NETWORKS=0
DRY_RUN=0

while (($# > 0)); do
  case "$1" in
    --interface)
      INTERFACE="${2:?missing interface value}"
      shift 2
      ;;
    --hostname)
      HOSTNAME_VALUE="${2:?missing hostname value}"
      shift 2
      ;;
    --admin-vlan)
      ADMIN_VLAN="${2:?missing admin vlan value}"
      shift 2
      ;;
    --admin-cidr)
      ADMIN_CIDR="${2:?missing admin cidr value}"
      shift 2
      ;;
    --admin-gateway)
      ADMIN_GATEWAY="${2:?missing admin gateway value}"
      shift 2
      ;;
    --admin-dns)
      ADMIN_DNS="${2:?missing admin dns value}"
      shift 2
      ;;
    --container-vlans)
      CONTAINER_VLANS="${2:?missing container vlan value}"
      shift 2
      ;;
    --root-dir)
      ROOT_DIR="${2:?missing root-dir value}"
      shift 2
      ;;
    --skip-install)
      SKIP_INSTALL=1
      shift
      ;;
    --create-docker-networks)
      CREATE_DOCKER_NETWORKS=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
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

for required in INTERFACE ADMIN_VLAN ADMIN_CIDR ADMIN_GATEWAY ADMIN_DNS CONTAINER_VLANS; do
  if [[ -z "${!required}" ]]; then
    flag="--$(printf '%s' "$required" | tr "[:upper:]" "[:lower:]" | tr _ -)"
    echo "Missing required argument: ${flag}" >&2
    usage >&2
    exit 1
  fi
done

target_path() {
  local path="$1"
  if [[ "$ROOT_DIR" == "/" ]]; then
    printf '%s\n' "$path"
  else
    printf '%s%s\n' "${ROOT_DIR%/}" "$path"
  fi
}

run() {
  if ((DRY_RUN)); then
    printf 'DRY-RUN:'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

write_file() {
  local relative_path="$1"
  local destination
  destination="$(target_path "$relative_path")"
  run mkdir -p "$(dirname "$destination")"

  if ((DRY_RUN)); then
    echo "DRY-RUN: writing ${destination}"
    cat
  else
    cat >"$destination"
  fi
}

validate_vlan_definition() {
  local definition="$1"
  local vlan subnet gateway

  IFS=':' read -r vlan subnet gateway <<<"$definition"
  if [[ -z "$vlan" || -z "$subnet" || -z "$gateway" ]]; then
    echo "Invalid container VLAN definition: ${definition}" >&2
    exit 1
  fi
}

IFS=',' read -r -a CONTAINER_VLAN_ITEMS <<<"$CONTAINER_VLANS"
for definition in "${CONTAINER_VLAN_ITEMS[@]}"; do
  validate_vlan_definition "$definition"
done

if [[ "$ROOT_DIR" != "/" ]]; then
  SKIP_INSTALL=1
fi

if ((SKIP_INSTALL == 0)); then
  run apt-get update
  run apt-get install -y docker.io openssh-server systemd-resolved vlan
fi

write_file "/etc/hostname" <<EOF
${HOSTNAME_VALUE}
EOF

write_file "/etc/modules-load.d/8021q.conf" <<'EOF'
8021q
EOF

for definition in "${CONTAINER_VLAN_ITEMS[@]}"; do
  IFS=':' read -r vlan _subnet _gateway <<<"$definition"
  write_file "/etc/systemd/network/20-${INTERFACE}.${vlan}.netdev" <<EOF
[NetDev]
Name=${INTERFACE}.${vlan}
Kind=vlan

[VLAN]
Id=${vlan}
EOF

  if [[ "$vlan" == "$ADMIN_VLAN" ]]; then
    write_file "/etc/systemd/network/20-${INTERFACE}.${vlan}.network" <<EOF
[Match]
Name=${INTERFACE}.${vlan}

[Network]
Address=${ADMIN_CIDR}
Gateway=${ADMIN_GATEWAY}
DNS=${ADMIN_DNS//,/ }
EOF
  else
    write_file "/etc/systemd/network/20-${INTERFACE}.${vlan}.network" <<EOF
[Match]
Name=${INTERFACE}.${vlan}

[Network]
LinkLocalAddressing=no
EOF
  fi
done

if [[ ! " ${CONTAINER_VLANS} " =~ (^|[[:space:],])${ADMIN_VLAN}: ]]; then
  write_file "/etc/systemd/network/20-${INTERFACE}.${ADMIN_VLAN}.netdev" <<EOF
[NetDev]
Name=${INTERFACE}.${ADMIN_VLAN}
Kind=vlan

[VLAN]
Id=${ADMIN_VLAN}
EOF

  write_file "/etc/systemd/network/20-${INTERFACE}.${ADMIN_VLAN}.network" <<EOF
[Match]
Name=${INTERFACE}.${ADMIN_VLAN}

[Network]
Address=${ADMIN_CIDR}
Gateway=${ADMIN_GATEWAY}
DNS=${ADMIN_DNS//,/ }
EOF
fi

{
  printf '[Match]\n'
  printf 'Name=%s\n\n' "$INTERFACE"
  printf '[Network]\n'
  printf 'LinkLocalAddressing=no\n'
  printf 'VLAN=%s.%s\n' "$INTERFACE" "$ADMIN_VLAN"
  for definition in "${CONTAINER_VLAN_ITEMS[@]}"; do
    IFS=':' read -r vlan _subnet _gateway <<<"$definition"
    if [[ "$vlan" != "$ADMIN_VLAN" ]]; then
      printf 'VLAN=%s.%s\n' "$INTERFACE" "$vlan"
    fi
  done
} | write_file "/etc/systemd/network/10-${INTERFACE}.network"

{
  cat <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
EOF

  for definition in "${CONTAINER_VLAN_ITEMS[@]}"; do
    IFS=':' read -r vlan subnet gateway <<<"$definition"
    cat <<EOF
if ! docker network inspect vlan${vlan} >/dev/null 2>&1; then
  docker network create \\
    --driver macvlan \\
    --subnet "${subnet}" \\
    --gateway "${gateway}" \\
    -o parent="${INTERFACE}.${vlan}" \\
    vlan${vlan}
fi

EOF
  done
} | write_file "/usr/local/sbin/create-docker-vlans.sh"

run chmod 755 "$(target_path "/usr/local/sbin/create-docker-vlans.sh")"

if [[ "$ROOT_DIR" == "/" ]]; then
  if ((DRY_RUN == 0)); then
    ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
  else
    echo "DRY-RUN: ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf"
  fi

  run systemctl enable ssh docker systemd-networkd systemd-resolved
  run systemctl restart systemd-resolved systemd-networkd

  if ((CREATE_DOCKER_NETWORKS)); then
    run /usr/local/sbin/create-docker-vlans.sh
  fi
fi
