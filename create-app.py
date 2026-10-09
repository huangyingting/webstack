#!/usr/bin/env python3
"""Create an isolated database and a minimal independently deployed app."""

import argparse
import json
import os
from pathlib import Path
import re
import secrets
import subprocess


def identifier(value):
    if not re.fullmatch(r"[a-z][a-z0-9_]{0,39}", value):
        raise argparse.ArgumentTypeError("Use 1-40 lowercase letters, digits or underscores")
    return value


def domain_name(value):
    if len(value) > 253 or not re.fullmatch(
        r"(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+"
        r"[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?", value,
    ):
        raise argparse.ArgumentTypeError("Provide a lowercase public DNS hostname")
    return value


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("app", type=identifier)
    parser.add_argument("domain", type=domain_name)
    parser.add_argument("--container-port", type=int, required=True)
    parser.add_argument("--host-port", type=int, required=True)
    args = parser.parse_args()
    if os.geteuid() != 0:
        parser.error("Run with sudo")
    if not 1024 <= args.host_port <= 65535 or not 1 <= args.container_port <= 65535:
        parser.error("Host port must be 1024-65535; container port must be 1-65535")
    app_dir = Path("/data/apps") / args.app
    site = Path("/etc/caddy/sites") / (args.app + ".caddy")
    if app_dir.exists() or site.exists():
        parser.error("App already exists; existing credentials will not be overwritten")
    for existing in Path("/data/apps").glob("*/app.json"):
        other = json.loads(existing.read_text())
        if other["host_port"] == args.host_port or other["domain"] == args.domain:
            parser.error("Host port or domain is already assigned to another app")
    if subprocess.check_output(
        ["ss", "-H", "-ltn", f"sport = :{args.host_port}"], text=True,
    ).strip():
        parser.error("Host port is already listening")
    database = "app_" + args.app
    role = "app_" + args.app
    password = secrets.token_hex(32)
    sql = f"""
CREATE ROLE "{role}" LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE
  NOREPLICATION PASSWORD '{password}';
CREATE DATABASE "{database}" OWNER "{role}";
REVOKE ALL ON DATABASE "{database}" FROM PUBLIC;
GRANT CONNECT, TEMPORARY ON DATABASE "{database}" TO "{role}";
"""
    subprocess.run(
        ["runuser", "-u", "postgres", "--", "psql", "-X",
         "--set=ON_ERROR_STOP=1", "--dbname=postgres"],
        input=sql, text=True, check=True, stdout=subprocess.DEVNULL,
    )
    os.umask(0o077)
    app_dir.mkdir(mode=0o700)
    (app_dir / "app.env").write_text(
        f"PGHOST=172.30.0.1\nPGPORT=5432\nPGDATABASE={database}\n"
        f"PGUSER={role}\nPGPASSWORD={password}\n"
        f"DATABASE_URL=postgresql://{role}:{password}@172.30.0.1:5432/{database}\n"
    )
    (app_dir / "app.json").write_text(json.dumps(vars(args), indent=2) + "\n")
    (app_dir / "compose.yml").write_text(f"""services:
  web:
    image: ${{APP_IMAGE:?Run webstack-deploy with an immutable image tag}}
    restart: unless-stopped
    init: true
    env_file:
      - app.env
    ports:
      - "127.0.0.1:{args.host_port}:{args.container_port}"
    networks:
      - apps
    mem_limit: 512m
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
networks:
  apps:
    external: true
    name: webstack-apps
""")
    site.write_text(
        f"{args.domain} {{\n    encode zstd gzip\n"
        f"    reverse_proxy 127.0.0.1:{args.host_port}\n}}\n"
    )
    site.chmod(0o644)
    subprocess.run(["caddy", "validate", "--config", "/etc/caddy/Caddyfile"], check=True)
    subprocess.run(["systemctl", "reload", "caddy"], check=True)
    print(f"Created {app_dir}; credentials are in its root-only app.env.")
    print("Add a real application healthcheck to compose.yml before production use.")
    print(f"Deploy: sudo webstack-deploy {args.app} ghcr.io/OWNER/IMAGE:COMMIT_SHA")


if __name__ == "__main__":
    main()
