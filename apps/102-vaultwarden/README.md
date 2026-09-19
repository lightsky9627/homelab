# Vaultwarden — 自托管密码管理器

[Vaultwarden](https://github.com/dani-garcia/vaultwarden) 是 Bitwarden
服务端的轻量重写（Rust 实现），完全兼容 Bitwarden 官方客户端
（浏览器插件 / 桌面 / iOS / Android）。

## 部署

```bash
# 1. 启动（自动从 .env.example 创建 .env，从 secrets.env.example 创建 secrets.env）
bin/hl up vaultwarden

# 2. 改配置
vim apps/102-vaultwarden/.env     # 改 DOMAIN 为你的域名
vim apps/102-vaultwarden/.env     # 把 SIGNUPS_ALLOWED 临时改成 true

# 3. 生成管理令牌（可选但推荐）
docker run --rm -it vaultwarden/server:latest /vaultwarden hash --preset owasp
# 把输出的 $argon2id$... 粘进 apps/102-vaultwarden/secrets.env 的 ADMIN_TOKEN=

# 4. 加反代
bin/hl proxy add vaultwarden 8080
bin/hl proxy reload

# 5. 重启生效
bin/hl restart vaultwarden
```

## 首次注册

默认 `SIGNUPS_ALLOWED=false`（禁止开放注册）。首次部署二选一：

**方式 A（简单）**：`.env` 里把 `SIGNUPS_ALLOWED` 临时改成 `true`，
重启后访问 `https://vault.example.com` 注册第一个账号，注册完改回 `false` 再重启。

**方式 B（推荐）**：用 ADMIN_TOKEN 登录 `https://vault.example.com/admin`，
在面板里生成邀请链接，通过邀请注册（需要配好 SMTP 才能发邮件，
也可以把邀请链接直接发给对方）。

之后加人一律走邀请链接（`INVITATIONS_ALLOWED=true`）。

## 数据库

用官方默认的 **SQLite**，库文件在 `data/db.sqlite3`，不依赖 PostgreSQL。

- 个人/家庭单实例完全够用
- 备份恢复极简：`.backup` 快照 + 目录备份，恢复就是拷文件

`data/` 目录里还有两样极其重要的东西：

| 文件 | 作用 | 丢了会怎样 |
|------|------|-----------|
| `rsa_key.pem` / `rsa_key.pub.pem` | 加密组织数据的密钥 | 所有共享数据永久解不开 |
| `attachments/` | 附件文件 | 附件丢失 |

所以**密钥、数据库、附件都靠同一个备份**，恢复时一起还原。

## 反向代理

vaultwarden 1.30+ 的 WebSocket 通知走 `/notifications/hub`，和主端口同一个，
Caddy 默认就处理 WebSocket 升级，所以 `hl proxy add vaultwarden 8080` 生成的
配置直接用，不需要额外设置。

想限制**单文件上传大小**（附件配额限的是累计总量，不是单文件），
手动改 `infra/010-caddy/sites/vaultwarden.caddy`：

```
vault.example.com {
	import backend_ws 8080 200MB
}
```

然后 `bin/hl proxy reload`。

## 备份与恢复

已配置备份标签，`bin/hl backup now` 会自动：

1. 对 `db.sqlite3` 取 `.backup` 原子快照（不会拷到写一半的坏库）
2. 备份整个 `data/` 目录（密钥、附件、Send）
3. 排除 `icon_cache/`（图标缓存，可重建）

恢复：

```bash
bin/hl backup restore    # 选 102-vaultwarden → 原地覆盖（或导出检查后手动拷回）
bin/hl up vaultwarden
```

## 升级

镜像用 `latest` + watchtower 自动更新，升级自带迁移逻辑。
备份排班（3:30）在 watchtower（4:00）之前，即使升级翻车也有当天的备份。

手动升级：

```bash
bin/hl pull vaultwarden
bin/hl up vaultwarden
```

## 常见问题

**Q: 客户端连不上 / WebAuthn 报错？**
A: 检查 `.env` 的 `DOMAIN`，必须和实际访问地址完全一致（含 `https://`）。

**Q: 附件传不上去？**
A: 单文件大小由反代限制（见上方「反向代理」），累计总量由
`USER_ATTACHMENT_LIMIT` 控制。

**Q: 想中文化管理界面和邮件模板？**
A: 参考 [vaultwarden-lang-zhcn](https://github.com/WeiYusc/vaultwarden-lang-zhcn)，
把 `templates/` 拷进 `data/templates/` 重启即可。注意模板和镜像版本强绑定。

**Q: 用 admin 面板改过配置后，改 .env 不生效？**
A: 面板配置会生成 `data/config.json`，优先级**高于**环境变量。
两边别打架，统一在一处管（个人使用建议只用环境变量）。
