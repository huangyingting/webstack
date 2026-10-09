#!/usr/bin/env bash
set -Eeuo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
bash -n deploy.sh bootstrap.sh deploy-app.sh db-ops.sh
grep -q 'directory="/data/apps/$app"' deploy-app.sh
grep -q 'Path("/data/apps")' create-app.py
grep -q "data_directory = '/data/postgresql/" bootstrap.sh
grep -q '"data-root": "/data/docker"' bootstrap.sh
grep -q 'RequiresMountsFor=/data' bootstrap.sh
grep -q 'Port $ssh_port' bootstrap.sh
grep -q 'systemctl restart ssh.service' bootstrap.sh
grep -q 'useradd --create-home --shell /bin/bash --groups sudo' bootstrap.sh
grep -q 'NOPASSWD:ALL' bootstrap.sh
grep -q 'visudo -cf /etc/sudoers.d/webstack-admin' bootstrap.sh
grep -q 'usermod -aG docker "\$admin_username"' bootstrap.sh
grep -q 'webstack-db' deploy.sh
grep -q 'db-ops.sh' main.tf
grep -q "<<'SQL'" db-ops.sh
grep -q 'WEBSTACK_DB_PROVISION_OK' db-ops.sh
grep -q 'WEBSTACK_DB_INJECT_OK' db-ops.sh
grep -q 'Refusing to modify the postgres role' db-ops.sh
grep -q 'inject-blob)' db-ops.sh
grep -q 'Import SHA-256 mismatch' db-ops.sh
grep -q 'Blob download failed with HTTP' db-ops.sh
grep -q 'preserving a 1 GiB reserve' db-ops.sh
grep -q 'public_network_access_enabled   = false' main.tf
grep -A3 'resource "azurerm_role_assignment" "github_storage"' main.tf \
    | grep -q 'scope.*azurerm_storage_container.imports.id'
assert_rejected() {
    local expected=$1
    shift
    local output
    if output=$(bash deploy-app.sh "$@" 2>&1); then
        echo "Invalid deployment arguments were accepted" >&2; exit 1
    fi
    [[ $output == *"$expected"* ]] || {
        echo "Unexpected rejection: $output" >&2; exit 1;
    }
}
assert_rejected "Usage:"
assert_rejected "Invalid app name" "../escape" image
assert_rejected "Use an immutable" app ghcr.io/owner/image:latest
assert_rejected "Invalid GHCR image" app not-a-registry/image:tag
python3 - <<'PY'
from pathlib import Path
import subprocess
import tempfile
import yaml

class UniqueKeyLoader(yaml.SafeLoader):
    pass

def construct_mapping(loader, node, deep=False):
    mapping = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in mapping:
            raise AssertionError(f"Duplicate YAML key: {key}")
        mapping[key] = loader.construct_object(value_node, deep=deep)
    return mapping

UniqueKeyLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, construct_mapping
)

for path in (Path("github-deploy.yml"), Path(".github/workflows/webstack-deploy.yml")):
    workflow = yaml.load(path.read_text(), Loader=UniqueKeyLoader)
    for job in workflow["jobs"].values():
        for step in job["steps"]:
            if "run" in step:
                with tempfile.NamedTemporaryFile(mode="w", suffix=".sh", delete=False) as f:
                    f.write(step["run"])
                    name = f.name
                try:
                    subprocess.run(["bash", "-n", name], check=True)
                finally:
                    Path(name).unlink()

reusable = yaml.load(
    Path(".github/workflows/webstack-deploy.yml").read_text(),
    Loader=UniqueKeyLoader,
)
triggers = reusable.get("on", reusable.get(True))
assert "workflow_call" in triggers
assert "database_password" not in triggers["workflow_dispatch"]["inputs"]
deploy = reusable["jobs"]["deploy"]
assert deploy["environment"] == "production"
assert deploy["steps"][0]["uses"].startswith("actions/checkout@")
run_script = deploy["steps"][-1]["run"]
assert 'EXPECTED_MARKER="WEBSTACK_FULL_DEPLOY_OK $APP_NAME"' in run_script
assert "messages.splitlines()" in run_script
assert "generate-sas" not in run_script
assert "sql_blob_url" not in run_script
assert "StrictHostKeyChecking=yes" in run_script
assert "WEBSTACK_TRANSFER hostkey" in run_script
assert "az storage blob upload --auth-mode login" in run_script
assert "/usr/local/sbin/webstack-db inject-blob" in run_script
assert 'BLOB_SHA256="$(sha256sum' in run_script
generator = run_script[run_script.index('if mode in ("provision-db", "full-deploy"):'):]
assert generator.index("/usr/local/sbin/webstack-db inject") < generator.index(
    "/usr/local/sbin/webstack-db deploy"
)
assert generator.index("/usr/local/sbin/webstack-db deploy") < generator.index(
    'if mode == "full-deploy":'
)
print("Bash and workflow checks passed")
PY
