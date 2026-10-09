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
  webstack-db inject --db NAME --sql-file /path/to/file.sql
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

while (($#)); do
    case "$1" in
        provision|inject|deploy)
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
        check_identifier "$db_name" "database"
        [[ "$db_name" != postgres && "$db_name" != template0 && "$db_name" != template1 ]] \
            || die "Refusing to inject into a PostgreSQL system database"
        [[ -f "$sql_file" && ! -L "$sql_file" && -r "$sql_file" ]] \
            || die "SQL file is not a readable regular file: $sql_file"
        db_owner=$(runuser -u postgres -- psql -X -A -t --set=ON_ERROR_STOP=1 \
            --dbname=postgres --set=db_name="$db_name" <<'SQL'
SELECT pg_catalog.pg_get_userbyid(datdba)
FROM pg_database
WHERE datname = :'db_name';
SQL
)
        [[ -n "$db_owner" ]] || die "Database does not exist: $db_name"
        check_identifier "$db_owner" "database owner"
        {
            printf 'SET ROLE "%s";\n' "$db_owner"
            cat -- "$sql_file"
        } | runuser -u postgres -- psql -X --set=ON_ERROR_STOP=1 --dbname="$db_name"
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
