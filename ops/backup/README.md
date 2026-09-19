# 备份模块 — restic 定时备份

基于 [restic](https://restic.net/) 的自动备份：增量去重 + 客户端加密。

## 快速开始

```bash
# 1. 交互式配置（选后端 → 填密钥 → 生成仓库密码 → 初始化仓库）
bin/hl backup init

# 2. 立即备份一次验证
bin/hl backup now

# 3. 启动定时调度（默认每天 3:30）
bin/hl up backup
```

## 支持的后端

| 后端 | 说明 |
|------|------|
| S3 兼容 | AWS S3 / 阿里云 OSS / 腾讯云 COS / Cloudflare R2 / MinIO |
| Backblaze B2 | 便宜，10GB 免费，适合冷备份 |
| 本地目录 / NAS | 最简单（但和数据同机就失去异地容灾意义） |
| SFTP | 备份到另一台服务器 |

## 备份内容

### 每个应用

由应用 `docker-compose.yaml` 的标签声明：

```yaml
labels:
  homelab.backup.enable: "true"            # 开启备份
  homelab.backup.paths: "./data"           # 要备份的目录
  homelab.backup.sqlite: "./data/app.db"   # SQLite 库（做一致性快照）
  homelab.backup.exclude: "cache/,*.log"   # 排除规则
```

SQLite 库用 `sqlite3 .backup` 取原子快照——直接 `cp` 运行中的库可能拷到
「写到一半」的状态（数据在 `.db-wal` 里没合入），恢复出来是坏库。

### 全局配置

自动备份所有 `.env`、`docker-compose.yaml`、`Caddyfile`、`bin/` 脚本，
标签 `app:_config`。

原因：`.env` 被 gitignore，不在 git 里，里面全是不可再生的密钥密码。

## 恢复

```bash
bin/hl backup restore     # 交互式向导

# 步骤：选应用 → 选快照版本 → 选恢复方式
#   1) 导出到临时目录（安全，推荐）：检查无误后手动拷回
#   2) 原地覆盖（危险）：直接覆盖当前数据
#   3) 只看内容：列出快照里的文件
```

全 SQLite 应用恢复只需两步：拷回 `.db` 文件 → 重启。

## 保留策略

在 `repo.env` 里配置（`bin/hl backup init` 生成）：

| 变量 | 默认 | 说明 |
|------|------|------|
| `KEEP_DAILY` | 7 | 保留最近 7 天的每日快照 |
| `KEEP_WEEKLY` | 4 | 保留最近 4 周的每周快照 |
| `KEEP_MONTHLY` | 6 | 保留最近 6 月的每月快照 |
| `KEEP_LAST` | 3 | 无论如何保留最近 3 份 |
| `MAX_REPO_SIZE_GB` | 50 | 超过告警（不强制删除） |

一个快照只要满足任一维度就不会被删。这组配置最终约保留 17 份快照，
因增量去重，实际空间通常只有单份全量的 1.5-3 倍。

## 安全

- 数据在**本机加密后**才上传，对象存储服务商也看不到内容
- `repo.env` 含仓库密码和对象存储密钥，已被 gitignore，权限 600
- **仓库密码（RESTIC_PASSWORD）丢了所有备份永久无法解密**，
  务必抄一份存密码管理器

## 通知（可选）

`repo.env` 里取消注释 `NOTIFY_URL`，备份完成后发通知（shoutrrr 格式）。
