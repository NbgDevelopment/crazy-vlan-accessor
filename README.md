# crazy-vlan-accessor

Minimal Debian-based host setup for running Docker containers on multiple VLANs over a single Ethernet trunk while keeping SSH administration on a dedicated management VLAN.

## Goals

- minimal host installation
- Docker runtime for development and test workloads
- SSH administration
- one physical NIC carrying multiple VLANs
- portable approach that also fits other hardware, including Raspberry Pi and Hyper-V VMs

## Recommended baseline

This repository starts with a Debian 12 minimal implementation because it is:

- small and stable
- available on x86_64 and ARM
- easy to adapt to physical and virtual hardware
- compatible with `systemd-networkd`, `openssh-server`, and `docker.io`

## Network model

- the physical NIC is used as an 802.1Q trunk
- one VLAN is used for host management and SSH
- additional VLANs are exposed to containers through Docker `macvlan` networks
- the host does not need IP addresses on container VLANs unless explicitly required later

Example:

- `eno1` = physical uplink
- VLAN `10` = host management
- VLAN `20` = containers for network A
- VLAN `30` = containers for network B

## Manual host bootstrap

Use `scripts/setup-host.sh` after installing Debian manually to:

- install the minimal required Debian packages
- enable 802.1Q VLAN support
- generate `systemd-networkd` VLAN configuration
- enable `ssh`, `docker`, `systemd-networkd`, and `systemd-resolved`
- generate a helper script for creating Docker `macvlan` networks
- leave SSH authentication policy at the Debian default so it can be hardened to fit the target environment

### Example

```bash
cd /path/to/crazy-vlan-accessor
sudo ./scripts/setup-host.sh \
  --interface eno1 \
  --hostname crazy-vlan-accessor \
  --admin-vlan 10 \
  --admin-cidr 192.168.10.10/24 \
  --admin-gateway 192.168.10.1 \
  --admin-dns 192.168.10.1,1.1.1.1 \
  --container-vlans 20:192.168.20.0/24:192.168.20.1,30:192.168.30.0/24:192.168.30.1
```

Then review and, when ready, create the Docker networks:

```bash
sudo /usr/local/sbin/create-docker-vlans.sh
```

## Unattended USB installer workflow

This repository also provides Debian preseed assets and a USB image builder for creating a customized installer image.

### Included files

- `preseed/preseed.cfg` — unattended Debian installer template
- `preseed/first-boot.service` — optional first-boot automation unit
- `preseed/first-boot.sh` — first-boot wrapper invoked by the systemd unit
- `preseed/config.env` — site-specific VLAN and addressing configuration
- `scripts/build-usb-image.sh` — ISO customization helper

### What the unattended installer does

- installs Debian 12 with standard utilities and OpenSSH server
- creates a local administrative user defined at image build time
- copies `setup-host.sh`, `config.env`, and `first-boot.service` onto the target system
- enables the first-boot service so host configuration can be automated later if desired

### Configure first-boot behavior

Edit `preseed/config.env` before building the USB image.

- set `AUTO_RUN=0` to install only the OS and run the host bootstrap manually later
- set `AUTO_RUN=1` to run the host bootstrap automatically on the first boot
- adjust `INTERFACE`, `ADMIN_VLAN`, `ADMIN_CIDR`, `ADMIN_GATEWAY`, `ADMIN_DNS`, and `CONTAINER_VLANS` for the target environment

### Build the customized installer image

1. Download a Debian 12 netinstall ISO.
2. Generate a password hash:

   ```bash
   openssl passwd -6
   ```

3. Build the custom ISO:

   ```bash
   cd /path/to/crazy-vlan-accessor
   ./scripts/build-usb-image.sh \
     --source-iso /path/to/debian-12-netinst.iso \
     --output-iso /tmp/crazy-vlan-accessor-installer.iso \
     --admin-user vlanadmin \
     --admin-password-hash '$6$example$replace-this-with-a-real-hash'
   ```

4. Write the ISO to a USB stick:

   ```bash
   sudo dd if=/tmp/crazy-vlan-accessor-installer.iso of=/dev/sdX bs=4M status=progress oflag=sync
   ```

### Resulting install flow

- boot the USB installer image
- let Debian install unattended using the embedded preseed
- reboot into the installed system
- if `AUTO_RUN=1`, the first-boot service runs `setup-host.sh` and creates Docker VLAN networks
- if `AUTO_RUN=0`, log in and run `/usr/local/lib/crazy-vlan-accessor/setup-host.sh` manually with the desired parameters

## Running containers

After the host and Docker networks are prepared, containers can join the VLAN-backed networks directly.

Example:

```bash
docker run --rm -it --network vlan20 alpine:latest ip addr
docker run --rm -it --network vlan30 alpine:latest ip addr
```

## Manual preparation notes

- configure the switch port as an 802.1Q trunk
- allow the management VLAN and all required container VLANs
- install your SSH public key for the administrative user before disabling password logins
- verify firewall rules separately if the environment requires them

## Adapting to other hardware

The implementation is intentionally parameterized:

- choose the correct Linux interface name with `--interface`
- use the same script on bare metal, Raspberry Pi, or Hyper-V VMs
- adjust only VLAN IDs, subnets, and gateways for each environment

## Current scope

This is the initial implementation only. It focuses on a minimal host foundation for development and testing rather than a full appliance image or orchestration stack.
