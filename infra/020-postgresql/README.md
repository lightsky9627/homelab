# PostgreSQL — 共享数据库

共享的 PostgreSQL 实例。**默认不需要启动**——所有应用已切换为 SQLite。

保留它的理由：
- 某些应用（如 Gitea、Nextcloud）强制要求 PG
- 多人并发写入场景 SQLite 扛不住时切过来
- 测试 PG 相关功能

## 部署

```bash
# 首次启动前必须改密码
cp .env.example .env
vim .env                  # 改 POSTGRES_PASSWORD
bin/hl up postgresql
```

## 给应用建库

```bash
bin/hl db create memos    # 自动随机密码，打印连接信息
bin/hl db list            # 列出所有库
bin/hl db shell           # 进 psql 交互
```

## 连接方式

| 场景 | 地址 |
|------|------|
| 同机应用（本项目默认） | `127.0.0.1:5432` |
| 其它 compose 项目 | 加入 `homelab-db` 网络后用 `postgresql:5432` |
| 远程调试 | SSH 隧道 `ssh -L 5432:127.0.0.1:5432 user@host` |

**绝不对公网暴露 5432 端口。**

## ⚠️ 大版本升级

镜像标签锁 `17-alpine`，Watchtower **关闭**。原因：

- PG 的数据目录格式和大版本绑定
- 17 → 18 自动升级会导致 `database files are incompatible`，容器起不来
- 改回 17 也起不来（数据目录已被新版标记污染）

升级步骤：

```bash
bin/hl down postgresql
docker exec postgresql pg_dumpall -U homelab > /tmp/pg-all.sql
rm -rf data/postgres/
vim .env                  # POSTGRES_TAG=18-alpine
bin/hl up postgresql      # 新版初始化空库
docker exec -i postgresql psql -U homelab < /tmp/pg-all.sql
```

锁 `17-alpine` 仍能自动吃到 17.x 安全补丁。

## 端口

| 端口 | 监听地址 | 说明 |
|------|----------|------|
| 5432 | 127.0.0.1 | PostgreSQL 默认端口 |
