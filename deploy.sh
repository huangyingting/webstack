#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
mode=apply
yes=false
for argument in "$@"; do
    case "$argument" in
        --plan-only) mode=plan ;;
        --configure-only) mode=configure ;;
        --yes) yes=true ;;
        *) echo "Usage: ./deploy.sh [--plan-only | --configure-only] [--yes]" >&2; exit 1 ;;
    esac
done
for command in terraform az python3; do
    command -v "$command" >/dev/null || { echo "Install $command first" >&2; exit 1; }
done
[[ -f terraform.tfvars ]] || {
    echo "Copy terraform.tfvars.example to terraform.tfvars and edit it first" >&2; exit 1;
}
[[ $(az cloud show --query name -o tsv) == AzureCloud ]] || {
    echo "Only global Azure is supported" >&2; exit 1;
}
az account show --only-show-errors >/dev/null
terraform init -input=false
terraform validate

if [[ $mode != configure ]]; then
    terraform plan -input=false -out=.deploy.tfplan
    [[ $mode == plan ]] && exit 0
    if [[ $yes != true ]]; then
        read -r -p "Apply the plan and create/update billable Azure resources? [y/N] " answer
        [[ $answer == y || $answer == Y ]] || { echo "Cancelled"; exit 1; }
    fi
    terraform apply -input=false .deploy.tfplan
fi

temporary=$(mktemp -d)
trap 'rm -f -- "$temporary/check.sh" "$temporary/configure.sh" "$temporary/result.json"; rmdir -- "$temporary"' EXIT
terraform output -json deployment > "$temporary/result.json"
readarray -t values < <(python3 - "$temporary/result.json" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
for key in ("AZURE_RESOURCE_GROUP", "AZURE_VM_NAME", "AZURE_SUBSCRIPTION_ID"):
    print(c[key])
PY
)
[[ ${#values[@]} -eq 3 ]] || { echo "Incomplete Terraform outputs" >&2; exit 1; }

if [[ $mode == configure ]]; then
    terraform output -json bootstrap_config | python3 -c '
import base64, json, pathlib, shlex, sys
config = json.load(sys.stdin)
commands = ["#!/usr/bin/env bash", "set -Eeuo pipefail", "umask 077",
            "install -d -m 0755 /etc/webstack /usr/local/sbin"]
files = {
    "/etc/webstack/config.json": json.dumps(config).encode(),
    "/usr/local/sbin/webstack-backup": pathlib.Path("backup.py").read_bytes(),
    "/usr/local/sbin/webstack-create-app": pathlib.Path("create-app.py").read_bytes(),
    "/usr/local/sbin/webstack-deploy": pathlib.Path("deploy-app.sh").read_bytes(),
    "/etc/webstack/bootstrap.sh": pathlib.Path("bootstrap.sh").read_bytes(),
}
for remote, content in files.items():
    encoded = base64.b64encode(content.replace(b"\r\n", b"\n")).decode()
    commands.append("printf %s " + shlex.quote(encoded) + " | base64 -d > " + shlex.quote(remote))
    commands.append("chmod " + ("0600" if remote.endswith(".json") else "0755") + " " + shlex.quote(remote))
commands.append("WEBSTACK_ALLOW_FAILED_CLOUD_INIT=1 bash /etc/webstack/bootstrap.sh")
pathlib.Path(sys.argv[1]).write_text("\n".join(commands) + "\n")
' "$temporary/configure.sh"
    script="$temporary/configure.sh"
else
    cat > "$temporary/check.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
cloud-init status --wait
systemctl is-active --quiet docker caddy
mountpoint -q /data
mdadm --detail "$(findmnt -n -o SOURCE /data)" | grep -q 'Raid Level : raid0'
test "$(docker info --format '{{.DockerRootDir}}')" = /data/docker
runuser -u postgres -- psql -XAtqc "show data_directory" \
    | grep -qx '/data/postgresql/'"$(pg_lsclusters --no-header | awk 'NR == 1 {print $1 \"/\" $2}')"
test -s /var/lib/webstack-backup/last-success.json
systemctl is-enabled --quiet webstack-backup.timer
curl --fail --silent http://127.0.0.1/ > /dev/null
echo WEBSTACK_BOOTSTRAP_OK
EOF
    script="$temporary/check.sh"
fi
az vm run-command invoke --resource-group "${values[0]}" --name "${values[1]}" \
    --subscription "${values[2]}" --command-id RunShellScript --scripts @"$script" \
    --only-show-errors --output json > "$temporary/result.json"
python3 - "$temporary/result.json" <<'PY'
import json, sys
result = json.load(open(sys.argv[1]))
messages = "\n".join(item.get("message", "") for item in result.get("value", []))
print(messages)
if "WEBSTACK_BOOTSTRAP_OK" not in messages:
    raise SystemExit("Bootstrap failed. Resources are preserved; inspect cloud-init logs.")
PY
terraform output -json deployment
echo "Infrastructure and its first Blob backup are ready. See README.md for DNS and app setup."
