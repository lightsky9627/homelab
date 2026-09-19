# MySQL — 共享数据库

共享的 MySQL 实例。**默认不需要启动**，只在以下场景使用：

- 某些应用只支持 MySQL（如早期版本的 WordPress）
- 需要测试 MySQL 特定功能

大部分应用用 SQLite（默认）或 PostgreSQL 就够了，不用两个数据库都开着占内存。

## 部署

```bash
cp .env.example .env
vim .env                  # 改 MYSQL_ROOT_PASSWORD 和 MYSQL_PASSWORD
bin/hl up mysql
```

## ⚠️ 大版本升级

镜像标签锁 `8.0`，Watchtower **关闭**。

- `mysql:latest` 已经是 9.x，自动升上去数据目录不兼容且**无法降级**
- 锁 `8.0` 仍能自动吃到 `8.0.x` 安全补丁

升级方式同 PostgreSQL：先 dump、删数据目录、改标签、起新版、灌数据。

## 端口

| 端口 | 监听地址 | 说明 |
|------|----------|------|
| 3306 | 127.0.0.1 | MySQL 默认端口 |
