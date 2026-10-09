#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
trap 'printf "Bootstrap failed at line %s\n" "$LINENO" >&2' ERR
[[ $EUID -eq 0 ]] || { echo "Run as root" >&2; exit 1; }
source /etc/os-release
[[ $ID == ubuntu && $VERSION_ID == 24.04 ]] || {
    echo "Only a fresh Ubuntu 24.04 VM is supported" >&2; exit 1;
}
export DEBIAN_FRONTEND=noninteractive
if [[ ${WEBSTACK_CLOUD_INIT:-0} != 1 ]]; then
    if ! cloud-init status --wait; then
        [[ ${WEBSTACK_ALLOW_FAILED_CLOUD_INIT:-0} == 1 ]] || exit 1
        echo "Previous cloud-init failed; retrying configuration explicitly" >&2
    fi
fi
install -d -m 0755 /etc/apt/keyrings /etc/webstack /etc/caddy/sites
install -d -m 0700 /var/lib/webstack-backup
rm -f /etc/apt/sources.list.d/caddy.list
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg python3 tzdata sudo postgresql postgresql-contrib \
    gzip openssl iptables unattended-upgrades mdadm openssh-server rsync

ssh_port=$(python3 - <<'PY'
import json
from pathlib import Path

value = json.loads(Path("/etc/webstack/config.json").read_text())["ssh_port"]
if not isinstance(value, int) or not 1024 <= value <= 65535:
    raise SystemExit("Invalid ssh_port in host configuration")
print(value)
PY
)
admin_username=$(python3 - <<'PY'
import json
from pathlib import Path

value = json.loads(Path("/etc/webstack/config.json").read_text())["admin_username"]
import re
if not isinstance(value, str) or not re.fullmatch(r"[a-z_][a-z0-9_-]{0,31}", value) or value == "root":
    raise SystemExit("Invalid admin_username in host configuration")
print(value)
PY
)
if ! id "$admin_username" >/dev/null 2>&1; then
    useradd --create-home --shell /bin/bash --groups sudo "$admin_username"
fi
printf '%s ALL=(ALL:ALL) NOPASSWD:ALL\n' "$admin_username" > /etc/sudoers.d/webstack-admin
chmod 0440 /etc/sudoers.d/webstack-admin
visudo -cf /etc/sudoers.d/webstack-admin >/dev/null
install -d -m 0700 -o "$admin_username" -g "$admin_username" "/home/$admin_username/.ssh"
if [[ -s /home/azureadmin/.ssh/authorized_keys && ! -s "/home/$admin_username/.ssh/authorized_keys" ]]; then
    install -m 0600 -o "$admin_username" -g "$admin_username" \
        /home/azureadmin/.ssh/authorized_keys "/home/$admin_username/.ssh/authorized_keys"
fi
install -d -m 0755 /etc/ssh/sshd_config.d /run/sshd
cat > /etc/ssh/sshd_config.d/99-webstack.conf <<EOF
Port $ssh_port
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
EOF
sshd -t
systemctl disable --now ssh.socket 2>/dev/null || true
systemctl enable ssh.service
systemctl restart ssh.service
ss -H -ltn "sport = :$ssh_port" | grep -q .

curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod 0644 /etc/apt/keyrings/docker.asc
printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu %s stable\n' \
    "$(dpkg --print-architecture)" "$VERSION_CODENAME" > /etc/apt/sources.list.d/docker.list
apt-get update -qq
apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
usermod -aG docker "$admin_username"

caddy_version=2.11.7
caddy_package="caddy_${caddy_version}_linux_amd64.deb"
caddy_sha256=47e8351c2317b427af14a103e763ca1118a3d2396a88b4c0669cdec9c4a68a957690194e2423a1633f53135741c33a41bdac2b55515b7d0f7adc8b733add50d9
curl -fsSL "https://github.com/caddyserver/caddy/releases/download/v${caddy_version}/${caddy_package}" \
    -o "/tmp/$caddy_package"
printf '%s  %s\n' "$caddy_sha256" "/tmp/$caddy_package" | sha512sum -c -
apt-get install -y -qq "/tmp/$caddy_package"
rm -f "/tmp/$caddy_package"

data_disk_count=$(python3 - <<'PY'
import json
from pathlib import Path

value = json.loads(Path("/etc/webstack/config.json").read_text())["data_disk_count"]
if not isinstance(value, int) or not 2 <= value <= 4:
    raise SystemExit("Invalid data_disk_count in host configuration")
print(value)
PY
)
data_disks=()
for ((lun = 0; lun < data_disk_count; lun++)); do
    path="/dev/disk/azure/scsi1/lun$lun"
    for _ in {1..120}; do
        [[ -b $path ]] && break
        sleep 5
    done
    [[ -b $path ]] || { echo "Data disk LUN $lun was not attached" >&2; exit 1; }
    data_disks+=("$(readlink -f "$path")")
done

if [[ -e /dev/md/webstack ]]; then
    raid_devices=$(mdadm --detail /dev/md/webstack | awk '/Raid Devices :/ {print $4}')
    raid_level=$(mdadm --detail /dev/md/webstack | awk '/Raid Level :/ {print $4}')
    [[ $raid_devices == "$data_disk_count" && $raid_level == raid0 ]] || {
        echo "Existing /dev/md/webstack does not match the configured RAID-0 array" >&2
        exit 1
    }
    for disk in "${data_disks[@]}"; do
        mdadm --detail /dev/md/webstack | grep -Fq " $disk" || {
            echo "Existing /dev/md/webstack does not contain configured disk $disk" >&2
            exit 1
        }
    done
else
    for disk in "${data_disks[@]}"; do
        if blkid "$disk" >/dev/null 2>&1 || mdadm --examine "$disk" >/dev/null 2>&1; then
            echo "Refusing to overwrite nonblank data disk $disk" >&2
            exit 1
        fi
    done
    mdadm --create /dev/md/webstack --name=webstack --level=0 \
        --raid-devices="$data_disk_count" --metadata=1.2 "${data_disks[@]}"
fi
if ! grep -qE '^ARRAY .*(name=[^ ]*:)?webstack([[:space:]]|$)' /etc/mdadm/mdadm.conf; then
    mdadm --detail --scan >> /etc/mdadm/mdadm.conf
    update-initramfs -u
fi

filesystem=$(blkid -s TYPE -o value /dev/md/webstack || true)
if [[ -z $filesystem ]]; then
    mkfs.ext4 -L webstack-data /dev/md/webstack
elif [[ $filesystem != ext4 ]]; then
    echo "The webstack data array must use ext4, found $filesystem" >&2
    exit 1
fi
data_uuid=$(blkid -s UUID -o value /dev/md/webstack)
install -d -m 0755 /data
if ! grep -qE "^[^#]+[[:space:]]+/data[[:space:]]" /etc/fstab; then
    printf 'UUID=%s /data ext4 defaults,nofail 0 2\n' "$data_uuid" >> /etc/fstab
fi
mountpoint -q /data || mount /data
[[ $(findmnt -n -o UUID /data) == "$data_uuid" ]] || {
    echo "/data is not mounted from the managed-disk array" >&2
    exit 1
}
install -d -m 0711 /data/apps
install -d -o postgres -g postgres -m 0750 /data/postgresql
install -d -m 0710 /data/docker

mapfile -t clusters < <(pg_lsclusters --no-header)
[[ ${#clusters[@]} -eq 1 ]] || {
    echo "Expected exactly one PostgreSQL cluster; refusing to change multiple clusters" >&2
    exit 1
}
read -r pg_version pg_cluster _ <<< "${clusters[0]}"
[[ $pg_cluster == main ]] || { echo "Expected the main PostgreSQL cluster" >&2; exit 1; }
if pg_ctlcluster "$pg_version" "$pg_cluster" status >/dev/null 2>&1; then
    pg_ctlcluster "$pg_version" "$pg_cluster" stop
fi
systemctl stop postgresql docker
if [[ ! -e /data/apps/.webstack-migrated ]]; then
    if [[ -d /srv/apps ]] && find /srv/apps -mindepth 1 -print -quit | grep -q .; then
        if find /data/apps -mindepth 1 -print -quit | grep -q .; then
            echo "Refusing to merge existing /srv/apps and /data/apps directories" >&2
            exit 1
        fi
        rsync -aHAX /srv/apps/ /data/apps/
    fi
    touch /data/apps/.webstack-migrated
fi
if [[ ! -e /data/postgresql/.webstack-migrated ]]; then
    rsync -aHAX /var/lib/postgresql/ /data/postgresql/
    touch /data/postgresql/.webstack-migrated
    chown postgres:postgres /data/postgresql/.webstack-migrated
fi
if [[ ! -e /data/docker/.webstack-migrated ]]; then
    rsync -aHAX /var/lib/docker/ /data/docker/
    touch /data/docker/.webstack-migrated
fi

cat > /etc/docker/daemon.json <<'EOF'
{
  "data-root": "/data/docker",
  "log-driver": "json-file",
  "log-opts": {"max-size": "10m", "max-file": "3"}
}
EOF
systemctl enable --now docker
if docker network inspect webstack-apps > /dev/null 2>&1; then
    python3 - <<'PY'
import json, subprocess
n = json.loads(subprocess.check_output(["docker", "network", "inspect", "webstack-apps"]))[0]
if n["Driver"] != "bridge" or n["IPAM"]["Config"] != [{"Subnet": "172.30.0.0/24", "Gateway": "172.30.0.1"}]:
    raise SystemExit("Existing webstack-apps network has unexpected settings")
if n["Options"].get("com.docker.network.bridge.name") != "br-webapps":
    raise SystemExit("Unexpected Docker bridge name")
PY
else
    docker network create --driver bridge --subnet 172.30.0.0/24 --gateway 172.30.0.1 \
        --opt com.docker.network.bridge.name=br-webapps webstack-apps
fi

# Unprivileged app containers must not obtain the VM's backup identity.
cat > /usr/local/sbin/webstack-firewall <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
iptables -C DOCKER-USER -i br-webapps -d 169.254.169.254/32 -j REJECT 2>/dev/null \
    || iptables -I DOCKER-USER 1 -i br-webapps -d 169.254.169.254/32 -j REJECT
EOF
chmod 0755 /usr/local/sbin/webstack-firewall
install -d -m 0755 /etc/systemd/system/docker.service.d
cat > /etc/systemd/system/docker.service.d/webstack-firewall.conf <<'EOF'
[Unit]
RequiresMountsFor=/data

[Service]
ExecStartPost=/usr/local/sbin/webstack-firewall
EOF
/usr/local/sbin/webstack-firewall

pg_config="/etc/postgresql/$pg_version/$pg_cluster"
memory_kb=$(awk '/MemTotal:/ {print $2}' /proc/meminfo)
shared_mb=$((memory_kb / 1024 / 8))
(( shared_mb < 128 )) && shared_mb=128
(( shared_mb > 512 )) && shared_mb=512
cat > "$pg_config/conf.d/90-webstack.conf" <<EOF
data_directory = '/data/postgresql/$pg_version/$pg_cluster'
listen_addresses = '127.0.0.1,172.30.0.1'
password_encryption = 'scram-sha-256'
shared_buffers = '${shared_mb}MB'
max_connections = 80
work_mem = '4MB'
maintenance_work_mem = '128MB'
wal_compression = on
fsync = on
synchronous_commit = on
full_page_writes = on
EOF
chmod 0644 "$pg_config/conf.d/90-webstack.conf"
if ! grep -q '^# webstack app network$' "$pg_config/pg_hba.conf"; then
    printf '\n# webstack app network\nhost all all 172.30.0.0/24 scram-sha-256\n' \
        >> "$pg_config/pg_hba.conf"
fi
install -d -m 0755 "/etc/systemd/system/postgresql@$pg_version-$pg_cluster.service.d"
cat > "/etc/systemd/system/postgresql@$pg_version-$pg_cluster.service.d/webstack.conf" <<'EOF'
[Unit]
After=docker.service
Wants=docker.service
RequiresMountsFor=/data
EOF

python3 - <<'PY'
import json
from pathlib import Path
from zoneinfo import ZoneInfo
c = json.loads(Path("/etc/webstack/config.json").read_text())
ZoneInfo(c["time_zone"])
path = Path("/etc/caddy/Caddyfile")
path.write_text(
    "{\n    email " + c["acme_email"] + "\n"
    "    acme_ca https://acme-v02.api.letsencrypt.org/directory\n}\n"
    "import /etc/caddy/sites/*.caddy\n"
    ":80 {\n    respond \"Webstack infrastructure is ready. Configure your domain and app.\" 200\n}\n"
)
path.chmod(0o644)
timer = Path("/etc/systemd/system/webstack-backup.timer")
timer.write_text(
    "[Unit]\nDescription=Daily PostgreSQL Blob backup\n\n"
    "[Timer]\nOnCalendar=*-*-* 03:00:00 " + c["time_zone"] + "\n"
    "Persistent=true\nRandomizedDelaySec=300\nUnit=webstack-backup.service\n\n"
    "[Install]\nWantedBy=timers.target\n"
)
timer.chmod(0o644)
PY
cat > /etc/systemd/system/webstack-backup.service <<'EOF'
[Unit]
Description=PostgreSQL cluster backup to Azure Blob
After=network-online.target postgresql.service
Wants=network-online.target
OnFailure=webstack-backup-failure.service

[Service]
Type=oneshot
UMask=0077
ExecStart=/usr/bin/flock -n /run/lock/webstack-backup.lock /usr/local/sbin/webstack-backup
TimeoutStartSec=2h
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
EOF
cat > /etc/systemd/system/webstack-backup-failure.service <<'EOF'
[Unit]
Description=Report PostgreSQL backup failure

[Service]
Type=oneshot
ExecStart=/usr/bin/logger -p daemon.err -t webstack-backup "BACKUP FAILED: inspect journalctl -u webstack-backup.service"
EOF
cat > /etc/apt/apt.conf.d/52webstack-upgrades <<'EOF'
Unattended-Upgrade::Automatic-Reboot "false";
EOF
systemctl daemon-reload
systemctl enable postgresql caddy
systemctl restart "postgresql@$pg_version-$pg_cluster"
runuser -u postgres -- psql -X --set=ON_ERROR_STOP=1 --dbname=postgres \
    --command="REVOKE CONNECT ON DATABASE postgres FROM PUBLIC; REVOKE CONNECT ON DATABASE template1 FROM PUBLIC;"
caddy validate --config /etc/caddy/Caddyfile
systemctl restart caddy
curl --fail --silent http://127.0.0.1/ > /dev/null
systemctl is-active --quiet docker caddy "postgresql@$pg_version-$pg_cluster"
docker compose version
flock -w 900 /run/lock/webstack-backup.lock \
    python3 /usr/local/sbin/webstack-backup --wait-for-access 900
systemctl enable --now webstack-backup.timer
echo "WEBSTACK_BOOTSTRAP_OK"
