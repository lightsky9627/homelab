# homelab

自托管应用的 Docker Compose 集合。一条命令部署，统一管理，自动备份。

## 目录结构

```
homelab/
├── .env.example          # 全局配置（域名、时区、邮箱）
├── PORTS.md              # 端口台账
├── bin/
│   ├── hl                # 统一管理命令
│   ├── backup-init.sh    # 备份配置向导
│   ├── backup-run.sh     # 执行备份
│   ├── backup-restore.sh # 查看/恢复备份
│   └── backup-lib.sh     # 备份公共函数
├── infra/                # 基础设施（按需启动）
│   ├── 010-caddy/        # 反向代理 + 自动 HTTPS
│   ├── 020-postgresql/   # PostgreSQL（测试/多人场景用）
│   └── 021-mysql/        # MySQL（按需）
├── apps/                 # 应用
│   ├── 100-memos/        # 笔记 / 备忘录
│   ├── 101-rustdesk/     # 远程桌面
│   └── 102-vaultwarden/  # 密码管理器（Bitwarden 兼容）
└── ops/                  # 运维
    ├── watchtower/       # 自动更新镜像
    └── backup/           # 定时备份（restic）
```

### 编号规则

- `infra/0xx-*`：基础设施，`010` 起
- `apps/1xx-*`：应用，`100` 起
- 每个段内连续递增，全局不重复

## 快速开始

```bash
# 1. 初始化全局配置
cp .env.example .env
vim .env                  # 改 BASE_DOMAIN、ACME_EMAIL

# 2. 启动反向代理
bin/hl up caddy

# 3. 启动应用（首次会自动从 .env.example 创建 .env）
bin/hl up memos
vim apps/100-memos/.env   # 改 MEMOS_INSTANCE_URL 为你的域名
bin/hl restart memos

# 4. 加反代（自动生成 Caddy 站点配置）
bin/hl proxy add memos 5230
bin/hl proxy reload

# 5. 看状态
bin/hl ps
bin/hl ports
```

应用默认用 SQLite，不需要先起数据库。如果某个应用要用 PostgreSQL，
再 `bin/hl up postgresql` 并 `bin/hl db create <库名>`。

## 常用命令

```bash
# ---- 服务管理 ----
bin/hl up <服务名...>        # 启动指定服务
bin/hl up --all              # 启动全部
bin/hl down <服务名...>      # 停止
bin/hl restart <服务名>      # 重启
bin/hl logs <服务名>         # 看日志
bin/hl ps                    # 所有容器状态
bin/hl ports                 # 端口占用总览
bin/hl pull <服务名>         # 拉最新镜像

# ---- 反向代理 ----
bin/hl proxy add <名字> <端口>   # 生成站点配置
bin/hl proxy list                # 列出已有站点
bin/hl proxy reload              # 热加载 Caddy

# ---- 数据库（按需）----
bin/hl db create <库名>      # 在共享 PG 里建库
bin/hl db list               # 列出所有库
bin/hl db shell [库名]       # 进 psql

# ---- 备份 ----
bin/hl backup init           # 交互式配置备份（选后端、生成密码）
bin/hl backup now [应用]     # 立即备份
bin/hl backup list [应用]    # 查看快照
bin/hl backup restore        # 交互式恢复向导
bin/hl backup stats          # 空间统计
bin/hl backup prune          # 手动清理旧快照

# ---- 其它 ----
bin/hl rustdesk key          # 打印 RustDesk 公钥
```

不带参数的 `hl up` 和 `hl down` 会显示帮助和可用服务列表，不会默认操作全部。

## 镜像加速

所有 compose 文件用标准 Docker Hub 镜像名（如 `postgres:17-alpine`），
任何人 clone 下来都能直接跑。

国内服务器直连 Docker Hub 慢，在 Docker daemon 层面配镜像加速：

```bash
sudo tee /etc/docker/daemon.json <<'EOF'
{
  "registry-mirrors": [
    "https://hub.bravexist.cn"
  ]
}
EOF

sudo systemctl restart docker
docker info | grep -A5 'Registry Mirrors'    # 验证
```

## 数据库策略

个人单用户场景，**所有应用默认用 SQLite**。好处：

- 没有额外依赖，不用先起 PG、建库、配密码
- 备份恢复极简：拷文件 → 重启，两步搞定
- PG 挂了不会级联拖垮所有应用

PostgreSQL 和 MySQL 保留在 `infra/` 下，用于：
- 需要多人并发写入的应用
- 想测试 PG/MySQL 相关功能时

## 自动更新策略

| 类型 | 标签 | Watchtower | 原因 |
|------|------|------------|------|
| 应用 | `latest` / `stable` | ✅ 开 | 应用层升级安全，自动迁移 |
| 数据库 | `17-alpine` / `8.0` | ❌ 关 | 大版本跳跃会导致数据目录不兼容 |

Watchtower 使用标签选择模式（`WATCHTOWER_LABEL_ENABLE=true`），只更新显式打了
`com.centurylinklabs.watchtower.enable: "true"` 标签的容器。

## 备份

基于 [restic](https://restic.net/)：增量去重 + 客户端加密。

- 支持 S3（AWS/OSS/COS/R2/MinIO）/ B2 / 本地目录 / SFTP
- 每个应用独立快照（带 tag），可单独查询/恢复
- SQLite 库用 `.backup` 取一致性快照，不会备出写一半的坏库
- 默认排除 `*.db-wal`、`*.db-shm`、`*.log`、`*.tmp`
- 单独备份全局配置快照（所有 `.env` + compose + Caddyfile + bin/）
- 按保留策略自动清理（每日/每周/每月/最近 N 份）
- 空间告警 + 可选通知（Telegram / Bark / 邮件）

```bash
bin/hl backup init    # 第一次用：交互式配置，选后端、生成密码、初始化仓库
bin/hl backup now     # 跑一次验证
bin/hl up backup      # 启动定时调度（默认每天 3:30）
```

### 备份范围控制

在应用的 `docker-compose.yaml` 里用标签声明：

```yaml
labels:
  homelab.backup.enable: "true"               # 开启备份
  homelab.backup.paths: "./data"              # 要备份的目录
  homelab.backup.sqlite: "./data/app.db"      # 需要一致性快照的 SQLite 库
  homelab.backup.exclude: "cache/,*.log"      # 排除规则（逗号分隔）
```

- `sqlite`：声明了才做 `.backup` 原子快照；没声明按普通文件备份
- `exclude`：glob 模式，跳过缓存、缩略图、日志等丢了能重建的文件

### 恢复流程

```bash
bin/hl backup restore    # 交互式：选应用 → 选快照 → 导出到临时目录
# 确认内容无误后，按提示操作：
#   1) cp 快照.db → 应用的 data/ 目录（覆盖 SQLite 库）
#   2) bin/hl up 应用（重启）
```

相比用 PostgreSQL 时的「起 PG → 建库 → 灌 SQL → 对密码」，
全 SQLite 的恢复就是「拷文件 → 重启」。

## 新增应用

```bash
# 1. 建目录（编号在 1xx 段内递增）
mkdir -p apps/103-newapp

# 2. 写 docker-compose.yaml
#    镜像用标准 Docker Hub 名称
#    端口只绑 127.0.0.1，由 Caddy 反代
#    想自动更新就加 watchtower 标签
#    想备份就加 homelab.backup.* 标签

# 3. 写 .env.example（给出所有变量的默认值和注释）
#    需要用户填写的重要变量，用 "# @required" 注释标记（紧挨变量行），
#    hl up 启动前会检查这些变量，还是占位符或空值就拒绝启动：
#      # @required 对外地址
#      DOMAIN=https://vault.example.com

# 4. 写 README.md（一句话介绍 + 部署步骤 + 常见问题）

# 5. 启动
bin/hl up newapp

# 6. 反代
bin/hl proxy add newapp 8080
bin/hl proxy reload
```

## 数据库大版本升级

数据库标签锁大版本（`17-alpine` / `8.0`），小版本安全更新自动跟进。
大版本升级必须手动 dump/restore：

```bash
# PostgreSQL 17 → 18 示例
bin/hl down postgresql
docker exec postgresql pg_dumpall -U homelab > /tmp/pg-all.sql
rm -rf infra/020-postgresql/data/
vim infra/020-postgresql/.env      # POSTGRES_TAG=18-alpine
bin/hl up postgresql               # 新版本初始化空库
docker exec -i postgresql psql -U homelab < /tmp/pg-all.sql
```

## Git 忽略规则

- `data/` 目录（数据库文件、附件、证书）
- `.env` 文件（含密码）
- `ops/backup/repo.env`（对象存储密钥 + 仓库密码）

只提交配置模板和脚本，数据和密钥全部 gitignore。
