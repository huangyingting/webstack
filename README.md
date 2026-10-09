# Azure 单机多网站部署：Linux + Terraform

这套部署包使用 **Terraform 管 Azure 资源，cloud-init/Bash 配置 Ubuntu，GitHub Actions 发布应用**。不需要 PowerShell、Azure 托管数据库、Kubernetes 或付费部署面板。入口为 `./deploy.sh`。

脚本会创建真实收费资源；先看 `./deploy.sh --plan-only`。目前提供的是部署代码和本地验证，不代表已经在你的 Azure 订阅上完成部署。

## 默认架构

| 部分 | 默认配置 |
|---|---|
| 虚机 | 新加坡，D2as v5，2 vCPU / 8GB，Ubuntu 24.04 LTS |
| 磁盘 | 64GB 系统盘；4 块 32GB Standard SSD LRS 组成 128GB RAID 0，挂载到 `/data` |
| 入口 | 原生 Caddy，多个域名，指定 Let's Encrypt，自动续期 |
| 数据库 | 原生 PostgreSQL，单实例、每个 app 独立数据库和账号 |
| 应用 | Docker Compose；仅将应用端口绑定到宿主机回环地址 |
| 数据库访问 | 固定 Docker 网络 `172.30.0.0/24`，网关 `172.30.0.1` |
| 备份 | PostgreSQL 全实例逻辑备份，包含角色和数据库，gzip 压缩后上传 Azure Blob |
| 备份网络 | Storage public access disabled；VM 通过 Private Endpoint 和私有 DNS 访问 Blob |
| 身份 | 备份使用专用托管身份；GitHub 每仓库一个 OIDC 身份 |

PostgreSQL 数据位于 `/data/postgresql`，Docker 数据位于 `/data/docker`，应用位于 `/data/apps`。RAID 0 提高汇总吞吐量但**没有冗余**：任一数据盘故障都会使整个阵列不可用，因此 Blob 备份和实际恢复演练是上线前提。

基础费用需加上 4 块 E4 数据盘的费用；请在目标区域用 Azure Pricing Calculator 核实。**不含 Blob 存储/操作、额外流量、域名及税费**。B 系列不适合持续高 CPU 负载，可通过 `vm_size` 改成非突发规格。

备份存储默认关闭公网访问。Terraform 会在应用 VNet 内创建 Blob Private Endpoint 和
`privatelink.blob.core.windows.net` 私有 DNS 链接；因此只能从 VNet 内的 VM 访问备份容器。

## 开始部署

在你的 Linux 电脑上准备 Terraform >= 1.9、Azure CLI、Python 3.9+、OpenSSH。云端备份只使用 Python 标准库，不需要在虚机上安装 Azure CLI 或 Python SDK。

```bash
az login
az account list -o table

# 如果没有现成 SSH 密钥，先创建；建议给私钥设置口令。
ssh-keygen -t ed25519 -a 64 -f ~/.ssh/id_ed25519

cp terraform.tfvars.example terraform.tfvars
chmod 600 terraform.tfvars
chmod +x deploy.sh
```

编辑 `terraform.tfvars`：替换订阅 ID、资源前缀、`vm_name`、管理员公网 IP 的 `/32`、邮箱和 GitHub 仓库。应用资源组的 `resource_group_name` 保持 `null` 时默认为 `<prefix>-rg`；如需指定精确名称，将它设置为不超过 83 个字符的 Azure 资源组名称。备份资源组始终为该名称加上 `-backup`（例如 `WebStack` 对应 `WebStack-backup`，默认 `testapps-rg` 对应 `testapps-rg-backup`），从而保证派生名称不超过 Azure 的 90 字符限制。`203.0.113.10` 和 `owner/app-a` 都只是示例，不能原样使用。公开和私有仓库都支持，仓库名使用小写。

SSH 公钥可任选一种方式传入；不要提供私钥：

```hcl
# 直接指定 OpenSSH 公钥（适合在部署时注入）
ssh_public_key = "ssh-ed25519 AAAAC3... admin@example.com"

# 或从本地文件读取（ssh_public_key 为 null 时使用）
ssh_public_key_path = "~/.ssh/id_ed25519.pub"
```

默认 Linux 管理员为 `azadmin`，并配置为无需密码即可使用 `sudo`。SSH 默认监听
`22222`，且仅允许 `admin_cidr` 访问。连接示例：

```bash
ssh -p 22222 azadmin@PUBLIC_IP
```

`azadmin` 默认属于 `docker` 组，可直接运行 Docker 命令；重新登录 SSH
后组权限才会生效。

同一 NSG 同时关联到应用子网和 VM NIC；两层都开放公网 HTTP `80`、HTTPS `443`
以及 `admin_cidr` 指定的 SSH `22222`，其他入站流量显式拒绝。当前配置使用
`0.0.0.0/0`，因此 SSH `22222` 对所有 IPv4 地址开放；生产环境建议改回固定 `/32`。

默认 `data_disk_count = 4`、`data_disk_size_gb = 32`，总容量为 128GB。修改磁盘数量或缩小磁盘不是在线安全操作；已有数据时应新建阵列并迁移，而不是直接修改这些值。

```bash
./deploy.sh --plan-only
./deploy.sh
```

`deploy.sh` 会初始化 Terraform、检查配置、展示资源变更并要求确认；应用变更后等待 cloud-init，检查本机服务、备份计时器及首份真实 Blob 备份。**首次备份失败不会报告部署成功。** 需要无人值守执行时，显式使用 `./deploy.sh --yes`。首次部署需要等待 Azure RBAC 和 Private Endpoint/DNS 传播。

Azure 登录账号需要创建资源、自定义角色和分配角色的权限；简单起步可以使用订阅 Owner。否则使用 Contributor 配合覆盖相关作用域的 RBAC 管理权限，并确保能够创建自定义角色。GitHub 身份直接使用 Azure 托管身份的联合凭据，不需要创建 Entra 应用或保存 client secret。

如果区域不支持默认 VM、配额不足或已有同名资源，Terraform 会明确报错；不会偷偷换机型，也不会自动删除资源。现有同名资源需要先正确 import 或更换资源前缀。

## 添加网站和共享数据库

把域名 A 记录指向 `terraform output -json deployment` 中的 `PUBLIC_IP`。不要设置错误的 AAAA 记录。默认不代替你操作域名注册商的 DNS。

SSH 登录后创建应用：

```bash
sudo webstack-create-app app_a app-a.example.com \
  --container-port 3000 --host-port 10001

sudo webstack-create-app app_b app-b.example.com \
  --container-port 8080 --host-port 10002
```

每次创建都会分配独立数据库、非超级用户账号、随机密码和 Caddy 域名配置，生成：

```text
/data/apps/app_a/
├── app.env       # 数据库凭据，root-only，禁止提交 GitHub
├── app.json
└── compose.yml
```

模板传入 `DATABASE_URL` 和标准 `PG*` 环境变量；应用若使用别的变量名，需要对应调整。应用必须监听容器内 `0.0.0.0`，不能只监听容器回环地址。默认内存上限 512MB，按实际应用调整，不要让所有应用的总内存挤占 PostgreSQL 和系统。

**生产部署前给 Compose 服务增加真实 healthcheck。** 没有 healthcheck 时，`--wait` 只能确认容器在运行，不能证明业务功能正常。首次镜像发布之前，访问该域名可能返回 502。

```bash
sudo webstack-deploy app_a ghcr.io/owner/app-a:COMMIT_SHA
```

helper 使用每应用部署锁，先拉镜像，再更新该应用；失败时尝试回滚到上一成功版本并以失败退出。部署 app 不会重启 PostgreSQL 或其他 app。应用数据库迁移由应用自己的发布流程处理，容器回滚不会自动回滚数据库迁移。单副本更新不是零停机。

## GitHub CI/CD

每个仓库根目录需要有可构建的 `Dockerfile`。将 `github-deploy.yml` 复制到该仓库的 `.github/workflows/deploy.yml`，并补充自己的测试步骤。

在仓库创建 GitHub Environment **production**，建议限制只能由 `main` 发布，并设置需要的审批。在该 Environment 添加 Variables：

| Variable | 值 |
|---|---|
| `AZURE_CLIENT_ID` | Terraform 输出 `GITHUB_CLIENT_IDS` 中当前仓库的 client ID |
| `AZURE_TENANT_ID` | 对应 Terraform 输出 |
| `AZURE_SUBSCRIPTION_ID` | 对应 Terraform 输出 |
| `AZURE_RESOURCE_GROUP` | 对应 Terraform 输出 |
| `AZURE_VM_NAME` | 对应 Terraform 输出 |
| `APP_NAME` | 服务器上的应用名，如 `app_a` |

流程为：GitHub runner 构建 amd64 镜像 → 推送 GHCR（commit SHA 标签）→ OIDC 登录 Azure → Run Command 更新应用。**不用开放 GitHub runner 的 SSH IP，也不用长期 Azure 密钥。**

GitHub Action 也支持人工触发的数据库与应用生命周期操作：

- `provision-db`：首次创建数据库和应用角色，确保数据库存在且有可登录用户；只在需要时执行。
- `inject-data`：在目标数据库中执行 SQL 初始化或数据导入脚本；适合新环境初始化。
- `deploy-webapp`：只更新指定应用的容器镜像；不会重启数据库，也不会执行任何数据库迁移。
- `full-deploy`：按需执行 `provision-db` → `inject-data` → `deploy-webapp`，适合第一次上架或回滚前重新初始化。

仓库内的 `.github/workflows/webstack-deploy.yml` 同时支持 `workflow_dispatch`
和 `workflow_call`。其他应用仓库可以直接调用：

```yaml
jobs:
  deploy:
    uses: OWNER/webstack/.github/workflows/webstack-deploy.yml@main
    with:
      mode: deploy-webapp
      app_name: app_a
      app_domain: app-a.example.com
      container_port: 3000
      host_port: 10001
      ref: ${{ github.event.workflow_run.head_sha }}
      # 留空 image 会构建调用仓库的 Dockerfile；也可传不可变 GHCR 标签。
      database_url_query: sslmode=require&connection_limit=8
    secrets:
      APPLICATION_ENV: ${{ secrets.APPLICATION_ENV }}
```

提供 `app_domain`、`container_port` 和 `host_port` 后，如果应用尚不存在，workflow 会先
调用 `webstack-create-app`，原子创建独立 PostgreSQL 数据库/角色、root-only
`app.env`、Compose 服务和 Caddy 路由；三项必须同时提供。应用已存在时，workflow
会核对这些不可变参数，拒绝意外改绑域名或端口。可选的 `APPLICATION_ENV` secret
以 `KEY=VALUE` 行合并到 `app.env`，但不能覆盖数据库凭据或发布版本。
`database_url_query` 用于为生成的 `DATABASE_URL` 增加应用需要的 TLS、schema 和连接池参数。

需要在切换 Web 镜像前执行 Prisma、Drizzle、Rails 等应用级迁移时，可提供一个调用
仓库内的 operations Dockerfile 和命令。Workflow 会构建独立的不可变 operations
镜像，在 `webstack-apps` 网络中读取该应用 root-only 的 `app.env` 执行命令，成功后
才部署 Web 镜像：

```yaml
jobs:
  deploy:
    uses: OWNER/webstack/.github/workflows/webstack-deploy.yml@main
    with:
      mode: deploy-webapp
      app_name: app_a
      operations_dockerfile: Dockerfile.ops
      operations_command: npm run db:migrate && npm run db:seed
      release_env_var: APP_VERSION
    secrets: inherit
```

`operations_dockerfile` 与 `operations_command` 必须同时提供。Operations 容器是临时
容器，不开放端口；命令失败时 Web 镜像不会切换。迁移本身仍应设计为可重复执行，
数据库 schema 变更也必须兼容应用回滚。`release_env_var` 可选；设置后，workflow
会在迁移和部署前把不可变镜像标签写入该应用的 `app.env`，用于健康检查和版本追踪。

调用仓库的 **production** Environment 必须配置上述 Azure Variables。执行
`provision-db` 或 `full-deploy` 时，还必须配置至少 16 字符的
`DATABASE_PASSWORD` Environment secret；密码不是普通 workflow input，不会显示在
人工触发表单中。`inject-data` 和 `full-deploy` 的 `sql_file` 必须指向调用仓库内的
普通 `.sql` 或 `.sql.gz` 文件，SQL 以目标数据库 owner 身份执行。
不超过 64 KiB 的文件随 Run Command 传输；更大的文件会自动压缩并上传到专用私有
Blob 容器 `db-imports`。存储账号保持 `public_network_access_enabled = false`：
workflow 通过 Azure Run Command 临时安装一次性 SSH 公钥、校验 VM 的 SSH host key，
再经 VM 建立到 Blob 私有端点的隧道。GitHub OIDC 身份只能写入 import 容器，VM
托管身份只能读取它。VM 下载后先核对 SHA-256，再开始导入；成功或失败都会尝试删除
临时 Blob 和 SSH 公钥，生命周期策略会在 1 天后清理遗留 Blob。

大型导入不会受 Azure Run Command 的执行时限限制，实际数据库导入通过已建立的
SSH 控制连接执行。GitHub runner 必须能连接 VM 的 `ssh_port`；如果将
`admin_cidr` 收紧到固定办公地址，大型导入会被 NSG 阻止，需要改用能访问该端口的
self-hosted runner。`deploy-webapp` 只调用容器部署
helper，不执行 SQL、不重启 PostgreSQL。应用目录和 `app.env` 仍需先通过
`webstack-create-app` 或等效配置创建，并使用与 secret 相同的数据库凭据。
`full-deploy` 用于首次部署；重复数据注入是否安全由 SQL 文件本身决定。

“可调用”不等于匿名 Azure 权限：每个调用仓库仍必须加入 Terraform 的
`github_repositories` allowlist，才能获得与其 `production` Environment 绑定的
OIDC 身份。没有 Environment 审批和 Azure OIDC 授权的仓库无法操作 VM。

2026 年 7 月后创建、重命名或迁移的 GitHub 仓库默认使用不可变 OIDC subject。
这类仓库还必须在 `github_repository_ids` 提供数字 owner/repository ID：

```hcl
github_repositories = ["huangyingting/eduloop"]
github_repository_ids = {
  "huangyingting/eduloop" = {
    owner         = "huangyingting"
    repository    = "EduLoop"
    owner_id      = "24954047"
    repository_id = "1313246955"
  }
}
```

可从 `GET /repos/OWNER/REPO/actions/oidc/customization/sub` 的
`sub_claim_prefix` 读取这些 ID 和大小写敏感的 canonical owner/repository 名称。
map key 保持小写以稳定现有 identity 地址；`owner` 和 `repository` 必须匹配 GitHub
实际大小写。Terraform 会生成形如
`repo:OWNER@OWNER_ID/REPO@REPO_ID:environment:production` 的 federated
credential；旧仓库未提供 ID 时继续使用名称格式。

输出镜像必须使用 commit SHA 这种不可变标签；不要用 `latest`。对于私有 GHCR 镜像，需要在 VM 上以 root 进行一次 `docker login ghcr.io`：使用有对应包读取权限的账号及 `read:packages` token；不要把 token 放进 Terraform、Run Command 脚本或 GitHub 仓库。Docker 默认凭据文件不是加密保险箱，应保护它，必要时使用 credential helper。公开镜像不需要这一步。

**只有受信任的仓库才能获得部署身份。** 虽然每仓库拥有不同身份、Azure 权限只覆盖这台 VM，但 Run Command 在机内以 root 执行，因此不是“只允许控制自己 app”的权限隔离。它也能间接使用 VM 的备份身份。互不信任的项目应该使用不同虚机，不能仅靠 Compose 隔离。

## 备份规则

按 `backup_time_zone` 定义日期，默认北京时间：

| 备份 | 时间 | 命名 | 保留规则 |
|---|---|---|---|
| 每日 | 每天 03:00，最多随机延迟 5 分钟 | `daily/YYYY-MM-DD.sql.gz` | 当天及之前 6 天，共 7 个日期槽 |
| 每周 | 周一随每日任务执行；失败后由本周后续每日任务补建 | `weekly/YYYY-Www.sql.gz` | 当前 ISO 周及之前 15 周，共 16 个周槽 |

首次部署立即补建本周备份；之后每周只在本周槽尚不存在时上传一份，已经成功的周备份不会被后续每日任务覆盖。重复运行不会生成额外日期槽。保留的是时间窗口：错过某天不会伪造备份，所以故障时可能不足 7 份或 16 份。

每次任务会：

1. 通过托管身份访问专用私有 Blob 容器，不使用账号密钥或 SAS。
2. 对整个 PostgreSQL 实例执行 `pg_dumpall`，压缩并检查 gzip 完整性。
3. 分块上传，每块带 MD5 传输校验；原子提交后核对长度和 SHA-256 元数据。
4. 所需上传全部成功之后，只清理过期的受管备份文件。

另外设置 Blob 生命周期策略：每日前缀 7 天、每周前缀 112 天删除，作为虚机停止后的清理兜底。Azure 生命周期扫描是异步的，不能保证到期瞬间删除；正常运行时脚本会主动按日期/ISO 周清理。

使用 Hot + LRS，避免每日短期备份触发 Cool/Archive 的最低保留期费用。为控制严格保留成本，默认不启用软删除、版本历史或不可变保护；**误删或主机 root 被攻破时，备份仍可能被删除**。正式重要业务应评估软删除、不可变备份及跨区域副本，这些不属于当前最低成本方案。

备份存储放在独立资源组，删除应用资源组不会连带删除存储。VM、备份资源组、存储账号及备份容器设置 `prevent_destroy`，Terraform 不会静默销毁它们。不要直接删除备份资源组。永久清理需要有意修改保护配置并确认数据可以丢弃。

这是每日逻辑备份，**不是 WAL 连续归档或 PITR**，最坏可能丢失最近约一天的数据；各数据库分别导出，不保证跨数据库处于同一个事务快照。备份会在本机生成临时压缩文件，完成后删除；大型数据库必须预留足够磁盘，当前低于 1GiB 可用空间会直接失败。它不备份应用上传文件、`app.env`、Caddy 私钥或整机系统；这些需要另行备份或保存到可靠的外部存储。

## 查看任务与恢复

```bash
sudo systemctl list-timers webstack-backup.timer
sudo cat /var/lib/webstack-backup/last-success.json
sudo journalctl -u webstack-backup.service -n 100 --no-pager
sudo systemctl start webstack-backup.service  # 手动备份
```

失败会导致 systemd 服务失败并写入 journal/系统错误日志，**不会主动通知你的手机或邮箱**。应将服务失败、备份成功时间过旧和磁盘空间不足接入自己的告警。

下载备份时，登录的运维身份需要该容器的 `Storage Blob Data Reader` 权限；Azure 管理面 Owner 并不自动等于 Blob 数据读取权限。账号密钥访问已经禁用：

```bash
az storage blob list --auth-mode login \
  --account-name YOUR_BACKUP_ACCOUNT --container-name pg-backups \
  --query '[].{name:name,size:properties.contentLength}' -o table

az storage blob download --auth-mode login \
  --account-name YOUR_BACKUP_ACCOUNT --container-name pg-backups \
  --name daily/2026-10-09.sql.gz --file backup.sql.gz

gzip -t backup.sql.gz
sha256sum backup.sql.gz
az storage blob show --auth-mode login \
  --account-name YOUR_BACKUP_ACCOUNT --container-name pg-backups \
  --name daily/2026-10-09.sql.gz --query metadata.sha256 -o tsv
```

比较本地 SHA-256 和远端元数据。之后在**隔离的新 PostgreSQL 实例**上演练恢复，使用相同或兼容的新版本，并先安装应用需要的扩展。以下只移除 initdb 已有的默认 `postgres` 角色创建语句，其他 SQL 错误会停止恢复：

```bash
set -o pipefail
gzip -dc backup.sql.gz \
  | sed '/^CREATE ROLE "postgres";$/d' \
  | sudo -u postgres psql -X --set=ON_ERROR_STOP=1 --dbname=postgres
```

目标必须是新实例，不能直接覆盖已有生产实例。恢复后核对数据库、角色、表数量、业务数据和应用连接。角色密码的哈希会恢复，但你仍需保存原来的 `app.env` 或重新设置应用密码；数据库备份不能反推出明文密码。

## 更新和状态管理

新增仓库、改变 SSH 白名单或修改其他 Azure 配置：修改 tfvars 后重新 `./deploy.sh`。**不要丢失 Terraform state，不要提交 state/私钥/凭据到 GitHub。** Provider 即使禁止 Shared Key 认证，仍可能把存储账号生成的访问密钥等属性写进 state；state 必须按敏感文件保护。

首次创建时用 cloud-init 安装；后续修改脚本不会通过 Terraform 自动重建 VM。若这是从旧版单盘配置升级，先运行普通 `./deploy.sh` 创建并挂载数据盘，再在维护窗口运行：

```bash
./deploy.sh --configure-only
```

这个命令更新机内脚本、把现有 PostgreSQL、Docker 和 `/srv/apps` 数据复制到 `/data` 并重跑 bootstrap，会短暂重启 PostgreSQL、Docker 和 Caddy，安排维护窗口并先做备份。也可用来明确重试失败的首次 cloud-init 配置；日志会显示此前失败，不会把旧失败当作成功。既有数据库和 app 密码不会被重新生成；若 `/srv/apps` 和 `/data/apps` 同时已有内容，脚本会拒绝猜测或合并。PostgreSQL 大版本升级仍需专门迁移，不能当作普通系统升级处理。

单人起步使用本地 state；团队使用时，建议单独建立 Azure Blob state backend，启用 Azure AD 认证及状态锁，并让基础设施 CI 执行 `plan/apply`。应用 CI 不应拥有 Terraform 基础设施管理权限。以后若主机配置变复杂，可把 Bash 配置层迁移到 Ansible，不需要改应用部署方式。

## 本地验证（不创建 Azure 资源）

```bash
python3 -m venv .venv
. .venv/bin/activate
pip install -r requirements-dev.txt
python3 -m unittest discover -s tests -p 'test_*.py'
bash tests/test-deploy.sh
terraform init -backend=false
terraform validate
terraform test
```

Terraform 测试使用 mock provider，不会实际创建资源。真实区域 SKU、订阅权限、网络、包仓库、证书申请和恢复效果仍必须在目标 Azure 环境验证。
