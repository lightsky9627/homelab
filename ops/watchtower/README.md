# Watchtower — 镜像自动更新

[Watchtower](https://containrrr.dev/watchtower/) 定期检查镜像更新，
有新版本就拉取并重建容器。

## 工作模式

按标签选择：`WATCHTOWER_LABEL_ENABLE=true`，
只更新显式打了 `com.centurylinklabs.watchtower.enable: "true"` 标签的容器。

| 容器 | 标签 | 说明 |
|------|------|------|
| caddy / memos / rustdesk | `latest` / `stable` | ✅ 自动更新（无状态或应用层，升级安全） |
| postgresql / mysql | `17-alpine` / `8.0` | ❌ 明确关闭（大版本升级会弄坏数据目录） |

## 部署

```bash
cp .env.example .env
vim .env                  # 确认 DOCKER_API_VERSION
bin/hl up watchtower
```

`DOCKER_API_VERSION` 必须匹配本机 Docker：
`docker version --format '{{.Server.APIVersion}}'`

## 更新计划

默认每天凌晨 4:00（排在备份的 3:30 之后，万一更新出问题，当天的备份已完成）。

`.env` 里 `WATCHTOWER_SCHEDULE` 是 6 段 cron（秒 分 时 日 月 周）。

## 通知（可选）

`.env` 里取消注释 `WATCHTOWER_NOTIFICATION_URL`，
支持 Telegram / Bark / 钉钉 / 邮件（shoutrrr 格式）。

## ⚠️ 安全说明

挂载 `/var/run/docker.sock` 等于给了容器宿主机 root 权限。
这是 watchtower 工作的必要条件，但意味着要信任镜像来源（官方 containrrr 镜像）。
