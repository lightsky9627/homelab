# RustDesk — 自建远程桌面服务端

[RustDesk](https://rustdesk.com/) 开源远程桌面。自己部署服务端后，
不再依赖官方公共中继（官方那个在国内经常连不上）。

## 架构

两个进程拆成两个服务：

| 服务 | 作用 |
|------|------|
| `hbbs` | ID / Rendezvous 服务器：客户端注册、心跳、NAT 打洞协商、Web 客户端 |
| `hbbr` | Relay 中继：打洞失败时转发流量（走它会消耗你的带宽） |

两者共享同一个 `./data` 卷，因为要用同一对密钥（`id_ed25519` / `id_ed25519.pub`）。

## ⚠️ 与其它应用最大的不同

RustDesk 客户端走**自有 TCP/UDP 协议**，不是 HTTP，Caddy 无法反代。
必须直接对公网开放端口：

- 防火墙放行：**TCP 21115-21119**、**UDP 21116**
- `.env` 里 `BIND_ADDR` 保持 `0.0.0.0`

## 部署

```bash
bin/hl up rustdesk
bin/hl rustdesk key     # 打印公钥（客户端配置要用）
```

## 客户端配置

在 RustDesk 客户端里，把「ID 服务器」「中继服务器」填成你的服务器 IP/域名，
`Key` 填 `bin/hl rustdesk key` 打印出来的公钥。

`.env` 里 `-k _` 参数会**强制客户端校验服务端公钥**，防止中间人攻击，
所以 Key 必须填对，否则连不上。

## 备份

密钥文件（`data/id_ed25519*`）很小但**极其重要**——丢了所有客户端都要重新配置。
已配置备份标签，`bin/hl backup now` 会自动备上。

## 端口

| 端口 | 协议 | 服务 | 说明 |
|------|------|------|------|
| 21115 | TCP | hbbs | NAT 类型探测 |
| 21116 | TCP | hbbs | ID 注册 / 心跳（主端口） |
| 21116 | UDP | hbbs | 打洞 |
| 21117 | TCP | hbbr | 中继 |
| 21118 | TCP | hbbs | Web 客户端 websocket |
| 21119 | TCP | hbbr | Web 客户端 websocket |

## 常见问题

**Q: 客户端一直「连接中」？**
A: 检查防火墙是否放行了全部 6 个端口（TCP 21115-21119 + UDP 21116）。

**Q: 数据迁移？**
A: 数据都在 `./data` 目录（密钥 + 配置）。迁移就是拷这个目录。

**Q: 为什么没有 healthcheck？**
A: 官方镜像是 `FROM scratch` 纯静态二进制，没有 shell 和 wget，写不了。
