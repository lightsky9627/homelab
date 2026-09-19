#!/usr/bin/env bash
# ======================================================================
#  backup-lib.sh —— 备份脚本的公共函数库
#
#  这个文件不直接执行，由 backup-init.sh / backup-run.sh /
#  backup-restore.sh 用 source 引入。
#
#  核心思路：restic 本身跑在临时容器里（不用在宿主装 restic），
#  通过 run_restic 这个函数统一调用，自动挂载仓库目录和注入凭据。
# ======================================================================

# 仓库根目录
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_DIR="$REPO_ROOT/ops/backup"
REPO_ENV="$BACKUP_DIR/repo.env"

# ---- 颜色 ----
if [[ -t 1 ]]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
  C_BLU=$'\033[36m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_DIM=""; C_OFF=""
fi

info() { echo "${C_BLU}==>${C_OFF} $*"; }
ok()   { echo "${C_GRN}✓${C_OFF} $*"; }
warn() { echo "${C_YEL}!${C_OFF} $*" >&2; }
die()  { echo "${C_RED}✗ 错误:${C_OFF} $*" >&2; exit 1; }

# 从 env 文件读变量（不 source，避免执行文件里的任意代码）
read_env() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 1
  sed -n "s/^${key}=//p" "$file" | tail -1 | sed 's/^["'\'']//; s/["'\'']$//'
}

# 读取全局配置
load_global() {
  RESTIC_TAG="$(read_env "$BACKUP_DIR/.env" RESTIC_TAG 2>/dev/null || echo "latest")"
  RESTIC_IMAGE="restic/restic:${RESTIC_TAG}"
}

# 检查备份是否已配置
require_repo_env() {
  [[ -f "$REPO_ENV" ]] || die "备份还没配置，请先执行: bin/hl backup init"
}

# ----------------------------------------------------------------------
#  run_restic —— 在临时容器里执行 restic 命令
#
#  为什么用容器：宿主不用装 restic，版本也统一。
#  挂载说明：
#    --env-file repo.env   注入仓库地址、密码、S3 凭据
#    -v REPO_ROOT:/data    把整个仓库挂进去，这样能备份各应用的 data/ 目录
#    -v restic-cache       缓存目录持久化，否则每次都要重新下载索引，很慢
#    --network host        本地仓库/内网 S3 需要走宿主网络
# ----------------------------------------------------------------------
run_restic() {
  load_global
  docker run --rm \
    --env-file "$REPO_ENV" \
    --network host \
    -v "$REPO_ROOT:/data:ro" \
    -v "restic-cache:/root/.cache/restic" \
    ${RESTIC_LOCAL_MOUNT:-} \
    "$RESTIC_IMAGE" "$@"
}

# 可写模式（恢复数据时需要写入，所以仓库目录不能只读挂载）
run_restic_rw() {
  load_global
  docker run --rm \
    --env-file "$REPO_ENV" \
    --network host \
    -v "$REPO_ROOT:/data" \
    -v "restic-cache:/root/.cache/restic" \
    ${RESTIC_LOCAL_MOUNT:-} \
    "$RESTIC_IMAGE" "$@"
}

# 交互式运行（需要 tty，用于 restic 的交互提示）
run_restic_tty() {
  load_global
  docker run --rm -it \
    --env-file "$REPO_ENV" \
    --network host \
    -v "$REPO_ROOT:/data" \
    -v "restic-cache:/root/.cache/restic" \
    ${RESTIC_LOCAL_MOUNT:-} \
    "$RESTIC_IMAGE" "$@"
}

# ----------------------------------------------------------------------
#  如果仓库是本地路径（不是 s3:// b2: sftp: 开头），
#  需要额外把那个路径挂进容器，否则容器里访问不到。
# ----------------------------------------------------------------------
setup_local_mount() {
  local repo; repo="$(read_env "$REPO_ENV" RESTIC_REPOSITORY)"
  if [[ "$repo" == /* ]]; then
    # 本地目录：原样挂载到容器内同样的路径
    mkdir -p "$repo"
    RESTIC_LOCAL_MOUNT="-v $repo:$repo"
  else
    RESTIC_LOCAL_MOUNT=""
  fi
}

# ----------------------------------------------------------------------
#  发现所有需要备份的应用
#
#  从各应用的 docker-compose.yaml 里读 homelab.backup.* 标签：
#    homelab.backup.enable: "true"     要备份
#    homelab.backup.paths: "./data/x"  要备份的目录（逗号分隔）
#    homelab.backup.pg-db:  "memos"    要 dump 的 PostgreSQL 库名
#
#  输出格式（每行一个应用）：  应用目录|应用名|pg库名|路径列表
# ----------------------------------------------------------------------
discover_apps() {
  # 关键：临时关掉 set -e。
  # 这个函数里大量用 grep / read_env 去探测可能不存在的内容，
  # 探测失败（返回非零）是正常情况，不应该让整个脚本退出。
  set +e
  local d
  for d in "$REPO_ROOT"/apps/*/ "$REPO_ROOT"/infra/*/; do
    local yaml="${d}docker-compose.yaml"
    [[ -f "$yaml" ]] || continue

    # 只处理显式打了 enable: "true" 的
    grep -q 'homelab.backup.enable: *"true"' "$yaml" || continue

    local name; name="$(basename "$d")"
    # 从 yaml 里抓标签值（简单 grep，够用且不引入 yq 依赖）
    local paths sqlite excludes
    # paths：要备份的目录，逗号分隔
    paths="$(grep -oE 'homelab\.backup\.paths: *"[^"]*"' "$yaml" | head -1 | sed 's/.*"\(.*\)"/\1/')"
    # sqlite：需要做一致性快照的库文件，逗号分隔
    sqlite="$(grep -oE 'homelab\.backup\.sqlite: *"[^"]*"' "$yaml" | head -1 | sed 's/.*"\(.*\)"/\1/')"
    # exclude：不备份的内容，glob 模式，逗号分隔
    excludes="$(grep -oE 'homelab\.backup\.exclude: *"[^"]*"' "$yaml" | head -1 | sed 's/.*"\(.*\)"/\1/')"

    echo "${d}|${name}|${paths}|${sqlite}|${excludes}"
  done
  set -e
}

# 人类可读的字节数
human_size() {
  local bytes="${1:-0}"
  awk -v b="$bytes" 'BEGIN{
    split("B KB MB GB TB", u, " ");
    i = 1;
    while (b >= 1024 && i < 5) { b /= 1024; i++ }
    printf "%.1f%s", b, u[i]
  }'
}

# 发通知（如果配了 NOTIFY_URL）
notify() {
  local msg="$1"
  local url; url="$(read_env "$REPO_ENV" NOTIFY_URL 2>/dev/null || echo "")"
  [[ -n "$url" ]] || return 0
  load_global
  docker run --rm "containrrr/shoutrrr:latest" \
    send --url "$url" --message "$msg" >/dev/null 2>&1 || true
}
