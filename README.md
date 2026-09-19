# homelab

自托管应用的 Docker Compose 集合。一条命令部署，统一管理，自动备份。

## 目录结构

```
homelab/
├── .env.example          # 全局配置（镜像站、域名、时区）
├── bin/
│   ├── hl                # 统一管理命令
│   ├── backup-init.sh    # 备份配置向导
│   ├── backup-run.sh     # 执行备份
│   ├── backup-restore.sh # 查看/恢复备份
│   └── backup-lib.sh     # 备份公共函数
├── infra/                # 基础设施（先启动）
│   ├── 010-caddy/        # 反向代理 + 自动 HTTPS
│   ├── 020-postgresql/   # 共享 PostgreSQL
│   └── 021-mysql/        # 共享 MySQL（按需）
├── apps/                 # 应用（依赖基础设施）
│   ├── 100-memos/        # 笔记服务
│   └── 101-rustdesk/     # 远程桌面
└── ops/                  # 运维
    ├── watchtower/       # 自动更新镜像
    └── backup/           # 定时备份（restic）
```

## 快速开始

```bash
# 1. 初始化全局配置
cp .env.example .env
vim .env                  # 改 BASE_DOMAIN、ACME_EMAIL

# 2. 启动基础设施
bin/hl up caddy
bin/hl up postgresql

# 3. 给应用建库
bin/hl db create memos    # 打印随机密码

# 4. 启动应用
bin/hl up memos           # 首次会自动创建 .env，提示填密码
vim apps/100-memos/.env   # 填 DB_PASSWORD
bin/hl up memos

# 5. 加反代
bin/hl proxy add memos 5230
bin/hl proxy reload

# 6. 看状态
bin/hl ps
bin/hl ports
```

## 常用命令

```bash
bin/hl up <应用>             # 启动
bin/hl down <应用>           # 停止
bin/hl restart <应用>        # 重启
bin/hl logs <应用>           # 看日志
bin/hl ps                    # 所有应用状态
bin/hl ports                 # 端口占用总览
bin/hl pull <应用>           # 拉最新镜像

bin/hl proxy add <名字> <端口>   # 加反代
bin/hl proxy list                # 列出反代
bin/hl proxy reload              # 热加载 Caddy

bin/hl db create <名字>      # 在共享 pg 里建库
bin/hl db list               # 列出所有库
bin/hl db shell [库名]       # 进 psql

bin/hl backup init           # 交互式配置备份
bin/hl backup now [应用]     # 立即备份
bin/hl backup list [应用]    # 查看快照
bin/hl backup restore        # 交互式恢复
bin/hl backup stats          # 空间统计
bin/hl backup prune          # 清理旧快照

bin/hl rustdesk key          # 打印 RustDesk 公钥
```

## 镜像加速

所有 compose 文件用的是标准 Docker Hub 镜像名（如 `postgres:17-alpine`），
任何人 clone 下来都能直接跑。

国内服务器直连 Docker Hub 很慢，建议在 Docker daemon 层面配置镜像加速：

```bash
# 创建或编辑 /etc/docker/daemon.json
sudo tee /etc/docker/daemon.json <<'EOF'
{
  "registry-mirrors": [
    "https://hub.bravexist.cn"
  ]
}
EOF

# 重启 docker
sudo systemctl restart docker

# 验证：应该能看到 Registry Mirrors 列表
docker info | grep -A5 'Registry Mirrors'
```

内网有 harbor 的话加上 `"https://harbor.qx.lab"`，多个镜像站会按顺序尝试。

## 自动更新策略

| 类型 | 标签 | Watchtower | 原因 |
|------|------|------------|------|
| 应用 | `latest` / `stable` | ✅ 开 | 应用层升级安全，自动迁移 |
| 数据库 | `17-alpine` / `8.0` | ❌ 关 | 大版本跳跃会导致数据目录不兼容 |

Watchtower 使用标签选择模式（`WATCHTOWER_LABEL_ENABLE=true`），只更新显式打了
`com.centurylinklabs.watchtower.enable: "true"` 的容器。

## 备份

基于 [restic](https://restic.net/)：增量去重 + 客户端加密。

- 支持 S3 / B2 / 本地目录 / SFTP
- 每个应用独立快照（带 tag），可单独查询/恢复
- SQLite 库用 `.backup` 取一致性快照，不会备出写一半的坏库
- 默认排除 `*.db-wal`、`*.db-shm`、`*.log`、`*.tmp`
- 单独备份全局配置快照（所有 `.env` + compose + Caddyfile）
- 按保留策略自动清理（每日/每周/每月/最近 N 份）
- 空间告警 + 可选通知（Telegram / Bark / 邮件）

```bash
bin/hl backup init    # 第一次用：交互式配置，选后端、生成密码、初始化仓库
bin/hl backup now     # 跑一次验证
bin/hl up backup      # 启动定时调度（默认每天 3:30）
```

### 备份范围控制

备份什么、不备份什么，由应用 `docker-compose.yaml` 里的标签决定：

```yaml
labels:
  homelab.backup.enable: "true"               # 开启备份
  homelab.backup.paths: "./data"              # 要备份的目录
  homelab.backup.sqlite: "./data/app.db"      # 需要一致性快照的 SQLite 库
  homelab.backup.exclude: "cache/,*.log"      # 排除规则（逗号分隔）
```

- `sqlite`：声明了才做 `.backup` 快照，没声明就按普通文件备份
- `exclude`：glob 模式，跳过缓存、缩略图、日志等丢了能重建的文件
- 典型场景：RSS 阅读器的文章缓存、图片缩略图，数据库里的订阅源才重要

### 恢复流程

```bash
bin/hl backup restore    # 交互式：选应用 → 选快照 → 导出到临时目录
# 确认内容无误后，按提示覆盖回去：
#   cp 快照.db 应用到 data/ 里   （覆盖 SQLite 库）
#   bin/hl up 应用               （重启）
```

相比之前用 PostgreSQL 时的「起 PG → 建库 → 灌 SQL → 对密码」，
现在全 SQLite 的恢复就是「拷文件 → 重启」，两步搞定。

## 新增应用

```bash
# 1. 建目录
mkdir -p apps/120-newapp

# 2. 写 docker-compose.yaml，镜像用标准 Docker Hub 名称
#    端口只绑 127.0.0.1，由 Caddy 反代
#    想自动更新就加 watchtower 标签
#    想备份就加 homelab.backup.* 标签

# 3. 写 .env.example

# 4. 如果用数据库
bin/hl db create newapp

# 5. 启动
bin/hl up newapp

# 6. 反代
bin/hl proxy add newapp 8080
bin/hl proxy reload
```

## 数据库大版本升级

数据库标签锁大版本（`17-alpine` / `8.0`），小版本修复自动跟进。
大版本升级必须手动 dump/restore：

```bash
# PostgreSQL 17 → 18 示例
bin/hl backup now postgresql       # 先备份
bin/hl down postgresql
docker exec postgresql pg_dumpall -U homelab > /tmp/pg-all.sql
rm -rf infra/020-postgresql/data/  # 删旧数据目录
vim infra/020-postgresql/.env      # POSTGRES_TAG=18-alpine
bin/hl up postgresql               # 新版本初始化空库
docker exec -i postgresql psql -U homelab < /tmp/pg-all.sql
```

## Git 忽略规则

- `data/` 目录（数据库文件、附件、证书）
- `.env` 文件（含密码）
- `ops/backup/repo.env`（对象存储密钥）

只提交：`docker-compose.yaml`、`.env.example`、`Caddyfile`、脚本、文档。
