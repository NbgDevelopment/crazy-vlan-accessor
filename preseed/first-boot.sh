#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE=/usr/local/etc/crazy-vlan-accessor/config.env
STATE_DIR=/var/lib/crazy-vlan-accessor
DONE_FILE=${STATE_DIR}/first-boot.done

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "crazy-vlan-accessor config not found: $CONFIG_FILE"
  exit 0
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"

if [[ "${AUTO_RUN:-0}" != "1" ]]; then
  echo "crazy-vlan-accessor first boot automation disabled"
  exit 0
fi

if [[ -f "$DONE_FILE" ]]; then
  echo "crazy-vlan-accessor first boot already completed"
  exit 0
fi

mkdir -p "$STATE_DIR"

/usr/local/lib/crazy-vlan-accessor/setup-host.sh \
  --interface "${INTERFACE:?missing INTERFACE}" \
  --hostname "${HOSTNAME:-crazy-vlan-accessor}" \
  --admin-vlan "${ADMIN_VLAN:?missing ADMIN_VLAN}" \
  --admin-cidr "${ADMIN_CIDR:?missing ADMIN_CIDR}" \
  --admin-gateway "${ADMIN_GATEWAY:?missing ADMIN_GATEWAY}" \
  --admin-dns "${ADMIN_DNS:?missing ADMIN_DNS}" \
  --container-vlans "${CONTAINER_VLANS:?missing CONTAINER_VLANS}" \
  --create-docker-networks

touch "$DONE_FILE"
