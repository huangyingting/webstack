#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

die() {
    printf '%s\n' "$*" >&2
    exit 1
}

usage() {
    cat >&2 <<'EOF'
Usage:
  WEBSTACK_DB_PASSWORD=PASS webstack-db provision --db NAME --user USER
  webstack-db inject --db NAME --sql-file /path/to/file.sql[.gz]
  webstack-db inject-blob --db NAME --account ACCOUNT --container CONTAINER \
    --blob NAME --sha256 HEX
  webstack-db deploy --app APP --image ghcr.io/OWNER/IMAGE:TAG
EOF
    exit 1
}

mode=""
db_name=""
db_user=""
sql_file=""
app=""
image=""
storage_account=""
storage_container=""
blob_name=""
expected_sha256=""

while (($#)); do
    case "$1" in
        provision|inject|inject-blob|deploy)
            [[ -z "$mode" ]] || die "Only one operation is allowed"
            mode="$1"
            shift
            ;;
        --db)
            [[ $# -ge 2 ]] || die "Missing value for --db"
            db_name="$2"
            shift 2
            ;;
        --user)
            [[ $# -ge 2 ]] || die "Missing value for --user"
            db_user="$2"
            shift 2
            ;;
        --sql-file)
            [[ $# -ge 2 ]] || die "Missing value for --sql-file"
            sql_file="$2"
            shift 2
            ;;
        --app)
            [[ $# -ge 2 ]] || die "Missing value for --app"
            app="$2"
            shift 2
            ;;
        --image)
            [[ $# -ge 2 ]] || die "Missing value for --image"
            image="$2"
            shift 2
            ;;
        --account)
            [[ $# -ge 2 ]] || die "Missing value for --account"
            storage_account="$2"
            shift 2
            ;;
        --container)
            [[ $# -ge 2 ]] || die "Missing value for --container"
            storage_container="$2"
            shift 2
            ;;
        --blob)
            [[ $# -ge 2 ]] || die "Missing value for --blob"
            blob_name="$2"
            shift 2
            ;;
        --sha256)
            [[ $# -ge 2 ]] || die "Missing value for --sha256"
            expected_sha256="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            die "Unknown argument: $1"
            ;;
    esac
done

[[ -n "$mode" ]] || usage
[[ $EUID -eq 0 ]] || die "Run as root"

check_identifier() {
    local value=$1
    local label=$2
    [[ "$value" =~ ^[a-z][a-z0-9_]{0,31}$ ]] || die "Invalid $label: $value"
}

check_database() {
    check_identifier "$1" "database"
    [[ "$1" != postgres && "$1" != template0 && "$1" != template1 ]] \
        || die "Refusing to inject into a PostgreSQL system database"
}

inject_file() {
    local database=$1
    local file=$2
    local db_owner
    db_owner=$(runuser -u postgres -- psql -X -A -t --set=ON_ERROR_STOP=1 \
        --dbname=postgres --set=db_name="$database" <<'SQL'
SELECT pg_catalog.pg_get_userbyid(datdba)
FROM pg_database
WHERE datname = :'db_name';
SQL
)
    [[ -n "$db_owner" ]] || die "Database does not exist: $database"
    check_identifier "$db_owner" "database owner"
    if [[ "$file" == *.gz ]]; then
        gzip -t -- "$file"
        {
            printf 'SET ROLE "%s";\n' "$db_owner"
            gzip -cd -- "$file"
        } | runuser -u postgres -- psql -X --set=ON_ERROR_STOP=1 --dbname="$database"
    else
        {
            printf 'SET ROLE "%s";\n' "$db_owner"
            cat -- "$file"
        } | runuser -u postgres -- psql -X --set=ON_ERROR_STOP=1 --dbname="$database"
    fi
}

case "$mode" in
    provision)
        [[ -n "$db_name" && -n "$db_user" && -n "${WEBSTACK_DB_PASSWORD:-}" ]] \
            || die "provision requires --db, --user and WEBSTACK_DB_PASSWORD"
        check_identifier "$db_name" "database"
        check_identifier "$db_user" "database user"
        [[ "$db_name" != postgres && "$db_name" != template0 && "$db_name" != template1 ]] \
            || die "Refusing to modify a PostgreSQL system database"
        [[ "$db_user" != postgres ]] || die "Refusing to modify the postgres role"
        [[ ${#WEBSTACK_DB_PASSWORD} -ge 16 ]] \
            || die "Database password must be at least 16 characters"
        runuser -u postgres -- psql -X --set=ON_ERROR_STOP=1 --dbname=postgres \
            --set=db_name="$db_name" --set=db_user="$db_user" \
            --set=db_password="$WEBSTACK_DB_PASSWORD" <<'SQL'
SELECT format(
    'CREATE ROLE %I LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD %L',
    :'db_user', :'db_password'
)
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'db_user')
\gexec
SELECT format(
    'ALTER ROLE %I WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD %L',
    :'db_user', :'db_password'
)
\gexec
SELECT format('CREATE DATABASE %I OWNER %I', :'db_name', :'db_user')
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'db_name')
\gexec
SELECT format('ALTER DATABASE %I OWNER TO %I', :'db_name', :'db_user')
\gexec
SELECT format('REVOKE ALL ON DATABASE %I FROM PUBLIC', :'db_name')
\gexec
SELECT format('GRANT CONNECT, TEMPORARY ON DATABASE %I TO %I', :'db_name', :'db_user')
\gexec
SQL
        printf 'WEBSTACK_DB_PROVISION_OK %s %s\n' "$db_name" "$db_user"
        ;;
    inject)
        [[ -n "$db_name" && -n "$sql_file" ]] || die "inject requires --db and --sql-file"
        check_database "$db_name"
        [[ -f "$sql_file" && ! -L "$sql_file" && -r "$sql_file" ]] \
            || die "SQL file is not a readable regular file: $sql_file"
        inject_file "$db_name" "$sql_file"
        printf 'WEBSTACK_DB_INJECT_OK %s\n' "$db_name"
        ;;
    inject-blob)
        [[ -n "$db_name" && -n "$storage_account" && -n "$storage_container" \
            && -n "$blob_name" && -n "$expected_sha256" ]] \
            || die "inject-blob requires --db, --account, --container, --blob and --sha256"
        check_database "$db_name"
        [[ "$storage_account" =~ ^[a-z0-9]{3,24}$ ]] || die "Invalid storage account"
        [[ "$storage_container" == db-imports ]] || die "Invalid import container"
        [[ "$blob_name" =~ ^imports/[A-Za-z0-9._/-]+\.sql\.gz$ && "$blob_name" != *..* ]] \
            || die "Invalid import blob name"
        [[ "$expected_sha256" =~ ^[a-f0-9]{64}$ ]] || die "Invalid SHA-256"
        configured_account=$(python3 - <<'PY'
import json
from pathlib import Path
print(json.loads(Path("/etc/webstack/config.json").read_text())["storage_account"])
PY
)
        [[ "$storage_account" == "$configured_account" ]] \
            || die "Import account does not match host configuration"
        install -d -m 0700 /data/imports
        sql_file=$(mktemp /data/imports/webstack-import.XXXXXX.sql.gz)
        trap 'rm -f -- "$sql_file"' EXIT
        python3 - "$storage_account" "$storage_container" "$blob_name" \
            "$expected_sha256" "$sql_file" <<'PY'
import hashlib
import json
from pathlib import Path
import shutil
import sys
from urllib.parse import quote, urlencode
from urllib.error import HTTPError
from urllib.request import Request, urlopen

account, container, blob, expected, destination = sys.argv[1:]
config = json.loads(Path("/etc/webstack/config.json").read_text())
query = urlencode({
    "api-version": "2018-02-01",
    "resource": "https://storage.azure.com/",
    "client_id": config["identity_client_id"],
})
token_request = Request(
    "http://169.254.169.254/metadata/identity/oauth2/token?" + query,
    headers={"Metadata": "true"},
)
with urlopen(token_request, timeout=30) as response:
    token = json.load(response)["access_token"]
url = (
    f"https://{account}.blob.core.windows.net/{container}/"
    + quote(blob, safe="/")
)
request = Request(url, headers={
    "Authorization": "Bearer " + token,
    "x-ms-version": "2023-11-03",
})
digest = hashlib.sha256()
free = shutil.disk_usage("/data").free
limit = free - 1024**3
if limit <= 0:
    raise SystemExit("Import requires at least 1 GiB of free space on /data")
try:
    response = urlopen(request, timeout=120)
except HTTPError as error:
    raise SystemExit(
        f"Blob download failed with HTTP {error.code}: {error.reason}"
    ) from error
with response:
    length = int(response.headers.get("Content-Length", "0"))
    if length and length > limit:
        raise SystemExit(
            f"Import needs {length} bytes plus 1 GiB reserve, only {free} bytes are free"
        )
    received = 0
    with open(destination, "wb") as output:
        while chunk := response.read(8 * 1024 * 1024):
            received += len(chunk)
            if received > limit:
                raise SystemExit(
                    "Import exceeded available space while preserving a 1 GiB reserve"
                )
            output.write(chunk)
            digest.update(chunk)
actual = digest.hexdigest()
if actual != expected:
    Path(destination).unlink(missing_ok=True)
    raise SystemExit(f"Import SHA-256 mismatch: expected {expected}, got {actual}")
PY
        inject_file "$db_name" "$sql_file"
        printf 'WEBSTACK_DB_INJECT_OK %s\n' "$db_name"
        ;;
    deploy)
        [[ -n "$app" && -n "$image" ]] || die "deploy requires --app and --image"
        /usr/local/sbin/webstack-deploy "$app" "$image"
        ;;
    *)
        usage
        ;;
 esac
