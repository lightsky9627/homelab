# Caddy — 反向代理 + 自动 HTTPS

整个 homelab 唯一对公网开放的入口。所有应用只绑 `127.0.0.1`，
由 Caddy 统一反代并自动签发 Let's Encrypt 证书。

## 架构

```
公网 :80/:443 → Caddy → 127.0.0.1:<各应用端口>
```

## 为什么用 host 网络

应用都绑 `127.0.0.1`，Caddy 必须共享宿主 loopback 才能转发。
用 host 网络最省事——新增应用不用改网络配置，加个站点文件就行。

## 部署

```bash
bin/hl up caddy
```

首次启动自动从 `.env.example` 创建 `.env`，默认配置即可用。

## 添加反代

```bash
# 推荐用脚本（自动生成站点文件 + 热加载）
bin/hl proxy add memos 5230
bin/hl proxy reload

# 手动也行
cp sites/example.caddy.disabled sites/memos.caddy
vim sites/memos.caddy          # 改域名和端口
bin/hl proxy reload
```

前提：域名的 A/AAAA 记录已解析到本机公网 IP，且 80/443 端口放行。

## 站点文件

每个域名对应 `sites/` 下一个 `.caddy` 文件。

- `.caddy` 后缀：被 Caddyfile `import` 自动加载
- `.caddy.disabled` 后缀：不加载（临时停用某个站点就改后缀）

## ACME 调试

首次配置建议打开 staging，避免触发 Let's Encrypt 速率限制（同域名每周 5 次）：

```
# Caddyfile 里取消注释：
acme_ca https://acme-staging-v02.api.letsencrypt.org/directory
```

staging 证书浏览器会报不受信任，属正常。调通后注释掉再 `bin/hl proxy reload`。

## 端口

| 端口 | 监听地址 | 用途 |
|------|----------|------|
| 80   | 0.0.0.0  | HTTP → 自动跳转 HTTPS |
| 443  | 0.0.0.0  | HTTPS 入口 |
| 2019 | 127.0.0.1 | Caddy Admin API（healthcheck 用） |

## 数据持久化

| 宿主路径 | 说明 |
|----------|------|
| `data/caddy_data` | 证书 + ACME 账户私钥（**丢了会重签，频繁触发限流**） |
| `data/caddy_config` | Caddy 自动生成的 JSON 配置缓存 |
