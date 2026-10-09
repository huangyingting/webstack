#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

die() { printf '%s\n' "$*" >&2; exit 1; }
[[ $# -eq 2 ]] || die "Usage: webstack-deploy APP ghcr.io/OWNER/IMAGE:TAG"
app=$1
image=$2
[[ $app =~ ^[a-z][a-z0-9_]{0,39}$ ]] || die "Invalid app name"
[[ $image =~ ^ghcr\.io/[a-z0-9._/-]+:[a-zA-Z0-9._-]+$ ]] || die "Invalid GHCR image"
[[ $image != *:latest ]] || die "Use an immutable commit tag, not latest"
[[ $EUID -eq 0 ]] || die "Run with sudo"
directory="/data/apps/$app"
[[ -f "$directory/compose.yml" && -f "$directory/app.env" ]] || die "Create the app first"
exec 9>"/run/lock/webstack-deploy-$app.lock"
flock -w 600 9 || die "Another deployment is running"
cd "$directory"
old_image=""
if [[ -f image.env ]]; then
    old_image=$(sed -n 's/^APP_IMAGE=//p' image.env)
fi
docker pull "$image"
if APP_IMAGE="$image" docker compose up -d --no-build --wait --wait-timeout 120; then
    printf 'APP_IMAGE=%s\n' "$image" > image.env.tmp
    mv image.env.tmp image.env
    printf 'WEBSTACK_DEPLOY_OK %s\n' "$app"
else
    printf 'Deployment failed for %s\n' "$app" >&2
    if [[ -n $old_image ]]; then
        printf 'Attempting rollback to %s\n' "$old_image" >&2
        APP_IMAGE="$old_image" docker compose up -d --no-build --wait --wait-timeout 120 \
            || die "Deployment and rollback both failed; inspect the app immediately"
    fi
    exit 1
fi
