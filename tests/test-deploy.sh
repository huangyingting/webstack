#!/usr/bin/env bash
set -Eeuo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
bash -n deploy.sh bootstrap.sh deploy-app.sh
grep -q 'directory="/data/apps/$app"' deploy-app.sh
grep -q 'Path("/data/apps")' create-app.py
grep -q "data_directory = '/data/postgresql/" bootstrap.sh
grep -q '"data-root": "/data/docker"' bootstrap.sh
grep -q 'RequiresMountsFor=/data' bootstrap.sh
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
workflow = yaml.safe_load(Path("github-deploy.yml").read_text())
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
assert workflow["jobs"]["deploy"]["environment"] == "production"
print("Bash and workflow checks passed")
PY
