# Memos — 轻量级笔记 / 备忘录

[Memos](https://www.usememos.com/) 是一个开源的自托管备忘录服务，
类似 flomo / 微信的"文件传输助手"，适合随手记想法、TODO、碎片笔记。

## 部署

```bash
bin/hl up memos
vim apps/100-memos/.env    # 改 MEMOS_INSTANCE_URL 为你的域名

# 加反代
bin/hl proxy add memos 5230
bin/hl proxy reload
```

首次访问 Web 界面会引导创建管理员账号。

## 数据库

用 memos 自带的 **SQLite**，不依赖 PostgreSQL。

- 库文件在 `data/memos/memos_prod.db`
- 个人使用绰绰有余，官网自己也用 SQLite 跑
- 备份恢复极简：拷文件 → 重启

什么时候该换 PG：多人协作、笔记量到几十万条、或要做复杂查询。
真到那天，在 `.env` 里设 `MEMOS_DRIVER` 和连接参数即可，
`infra/020-postgresql` 一直保留在那里。

## 备份

已配置备份标签，`bin/hl backup now` 会自动：

1. 用 `sqlite3 .backup` 取一致性快照（不会拷到写一半的坏库）
2. 备份整个 `data/memos/` 目录
3. 排除 `*.db-wal`、`*.db-shm`、`*.log`、`thumbs/`

恢复：

```bash
bin/hl backup restore      # 选 100-memos → 导出到临时目录
bin/hl down memos
cp 快照目录/.snapshots/100-memos/memos_prod.db data/memos/memos_prod.db
bin/hl up memos
```

## 端口

| 端口 | 监听地址 | 说明 |
|------|----------|------|
| 5230 | 127.0.0.1 | memos 默认端口，由 Caddy 反代 |

## 常见问题

**Q: 分享链接地址不对？**
A: 检查 `.env` 里的 `MEMOS_INSTANCE_URL`，必须和实际访问域名完全一致（含 `https://`）。

**Q: 镜像标签用什么？**
A: `stable`（memos 官方的滚动稳定标签）。注意 memos **没有** `latest` 标签，写 `latest` 会拉取失败。
