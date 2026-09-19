#!/usr/bin/env bash
# ======================================================================
#  backup-run.sh —— 执行备份
#
#  用法:
#    bin/hl backup now           备份所有应用
#    bin/hl backup now memos     只备份 memos
#    bin/hl backup prune         只清理旧快照，不备份
#
#  备份流程（每个应用独立一份快照，打上 tag 便于按应用查询/恢复）：
#    1) 如果声明了 sqlite 库，先用 .backup 取一致性快照
#    2) 把应用的数据目录 + .env 交给 restic（按 exclude 排除垃圾）
#    3) 单独备份一份全局配置快照（所有 .env + compose）
#    4) 全部完成后按保留策略清理旧快照
#    5) 检查仓库大小，超阈值告警
#
#  为什么不用 pg_dump：应用都用 SQLite，数据就在 data/ 里，
#  直接备目录即可。恢复时还原文件就能用，不用建库灌数据。
#  如果将来真用上了 PG，再加 pg-db 标签支持。
# ======================================================================

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/backup-lib.sh"

require_repo_env
setup_local_mount

PRUNE_ONLY=0
FILTER=""

# ---- 解析参数 ----
while (( $# )); do
  case "$1" in
    --prune-only) PRUNE_ONLY=1 ;;
    -*) die "未知参数: $1" ;;
    *)  FILTER="$1" ;;
  esac
  shift
done

# 临时目录：放 SQLite 快照，备份完就删
SNAP_DIR="$REPO_ROOT/ops/backup/.snapshots"
cleanup() { rm -rf "$SNAP_DIR"; }
trap cleanup EXIT

START_TS=$(date +%s)
FAILED=()
SUCCEEDED=()

# ======================================================================
#  备份单个应用
# ======================================================================
backup_app() {
  local dir="$1" name="$2" paths="$3" sqlite="${4:-}" excludes="${5:-}"

  info "备份 ${C_YEL}${name}${C_OFF}"

  # 这个应用要交给 restic 的所有路径（容器内视角，都在 /data 下）
  local targets=()

  # ---- 1) SQLite 一致性快照 ----
  # SQLite 写入时数据分散在 .db 和 .db-wal 两个文件里，
  # 直接 cp 可能拷到「写到一半」的状态，恢复出来是坏库。
  # .backup 命令是原子的，拿到的一定是完整可用的库。
  if [[ -n "$sqlite" ]]; then
    local -a db_arr
    IFS=',' read -ra db_arr <<< "$sqlite"
    local db_rel
    for db_rel in "${db_arr[@]}"; do
      db_rel="$(echo "$db_rel" | xargs)"
      [[ -n "$db_rel" ]] || continue
      local db_abs="${dir}${db_rel#./}"

      if [[ ! -f "$db_abs" ]]; then
        warn "    SQLite 库不存在，跳过: $db_rel"
        continue
      fi

      mkdir -p "$SNAP_DIR/$name"
      local snap="$SNAP_DIR/$name/$(basename "$db_abs")"

      # 用容器跑 sqlite3，宿主不用装。
      # --user 0：keinos/sqlite3 镜像默认用非 root 用户运行，
      # 对挂载的宿主目录没有写权限，必须指定 root。
      # 源目录不能挂 :ro —— WAL 模式的库打开时要访问 -shm 共享内存文件，
      # 只读挂载会让 sqlite3 报 "unable to open database file"。
      if docker run --rm --user 0 \
           -v "$(dirname "$db_abs"):/src" \
           -v "$SNAP_DIR/$name:/out" \
           keinos/sqlite3:latest \
           sqlite3 "/src/$(basename "$db_abs")" ".backup /out/$(basename "$db_abs")" 2>/dev/null; then
        echo "    SQLite 快照: ${db_rel} ($(human_size "$(stat -c%s "$snap")"))"
        targets+=("/data/ops/backup/.snapshots/${name}/$(basename "$db_abs")")
      else
        warn "    SQLite 快照失败，将直接备份原库文件: $db_rel"
      fi
    done
  fi

  # ---- 2) 数据目录 ----
  if [[ -n "$paths" ]]; then
    local rel
    local -a path_arr
    # paths 是逗号分隔的相对路径列表。
    # 注意要用 local -a 声明，否则会污染全局变量。
    IFS=',' read -ra path_arr <<< "$paths"
    for rel in "${path_arr[@]}"; do
      rel="$(echo "$rel" | xargs)"  # 去掉首尾空格
      local abs="${dir}${rel#./}"
      if [[ -e "$abs" ]]; then
        # 转成容器内路径：/data + 相对仓库根的路径
        local relroot="${abs#$REPO_ROOT/}"
        targets+=("/data/${relroot}")
        echo "    数据目录: ${relroot}"
      else
        warn "    路径不存在，跳过: $rel"
      fi
    done
  fi

  # ---- 3) 应用的 .env（含密码，但仓库是加密的，值得备份）----
  if [[ -f "${dir}.env" ]]; then
    targets+=("/data/${dir#$REPO_ROOT/}.env")
  fi

  if [[ ${#targets[@]} -eq 0 ]]; then
    warn "    没有可备份的内容，跳过"
    return 0
  fi

  # ---- 4) 组装排除规则 ----
  # 通用的：套接字、pid、SQLite 的 wal/shm 临时文件
  #（wal/shm 的内容已经包含在上面的快照里了，备了反而干扰恢复）
  local -a exclude_args=(
    --exclude '*.sock'
    --exclude '*.pid'
    --exclude '*.db-wal'
    --exclude '*.db-shm'
  )

  # 应用自己声明的排除规则
  if [[ -n "$excludes" ]]; then
    local -a ex_arr
    IFS=',' read -ra ex_arr <<< "$excludes"
    local ex
    for ex in "${ex_arr[@]}"; do
      ex="$(echo "$ex" | xargs)"
      [[ -n "$ex" ]] || continue
      exclude_args+=(--exclude "$ex")
      echo "    排除: ${ex}"
    done
  fi

  # ---- 5) 交给 restic ----
  # --tag 打上应用名，之后可以用 --tag 过滤查询和恢复
  # --host 统一设成 homelab，避免容器主机名变化导致快照分组混乱
  if run_restic backup \
      --tag "app:${name}" \
      --host homelab \
      "${exclude_args[@]}" \
      "${targets[@]}" 2>&1 | sed 's/^/    /'; then
    ok "  ${name} 备份完成"
    SUCCEEDED+=("$name")
  else
    warn "  ${name} 备份失败"
    FAILED+=("$name")
  fi
}

# ======================================================================
#  主流程
# ======================================================================

if [[ $PRUNE_ONLY -eq 0 ]]; then
  echo
  info "开始备份 $(date '+%Y-%m-%d %H:%M:%S')"
  echo

  found=0
  # 先把发现结果收集到数组，再逐个处理。
  # 不能边读边备份：backup_app 内部的 read / docker 会消费 stdin，
  # 导致外层 while 循环提前结束，只备份到第一个应用。
  # mapfile 一次性读入所有行，比 while read 可靠：
  # while read 配合 set -e 时，循环体里任一命令返回非零就会中断整个脚本。
  app_list=()
  mapfile -t app_list < <(discover_apps)

  entry=""
  for entry in "${app_list[@]}"; do
    IFS='|' read -r dir name paths sqlite excludes <<< "$entry"
    [[ -n "$name" ]] || continue
    # 有过滤条件时只备份匹配的
    if [[ -n "$FILTER" ]]; then
      [[ "$name" == *"$FILTER"* ]] || continue
    fi
    found=1
    backup_app "$dir" "$name" "$paths" "$sqlite" "$excludes"
    echo
  done

  if [[ $found -eq 0 ]]; then
    if [[ -n "$FILTER" ]]; then
      die "没有匹配 '$FILTER' 的应用"
    else
      die "没有发现任何需要备份的应用。
请在应用的 docker-compose.yaml 里加标签：
    labels:
      homelab.backup.enable: \"true\"
      homelab.backup.paths: \"./data\"
      homelab.backup.sqlite: \"./data/xxx.db\"      # 有 SQLite 库的应用
      homelab.backup.exclude: \"cache/,*.log\"      # 不想备的东西"
    fi
  fi

  # ---- 全局配置快照 ----
  # 单独备一份所有 .env 和 compose 文件，不依赖应用标签。
  # 理由：.env 里是密码和密钥，而且被 .gitignore 排除，不在任何
  # git 仓库里，丢了就真没了。数据救回来了但配置没了，一样跑不起来。
  if [[ -z "$FILTER" ]]; then
    info "备份 ${C_YEL}配置文件${C_OFF}"

    conf_targets=()
    while IFS= read -r f; do
      [[ -n "$f" ]] && conf_targets+=("/data/${f#$REPO_ROOT/}")
    done < <(find "$REPO_ROOT" \
               \( -name '.env' -o -name 'docker-compose.yaml' -o -name 'Caddyfile' \) \
               -not -path '*/data/*' -not -path '*/.git/*' 2>/dev/null | sort)

    # 脚本和反代站点配置也带上
    [[ -d "$REPO_ROOT/bin" ]] && conf_targets+=("/data/bin")
    [[ -d "$REPO_ROOT/infra/010-caddy/sites" ]] && conf_targets+=("/data/infra/010-caddy/sites")

    if [[ ${#conf_targets[@]} -gt 0 ]]; then
      echo "    文件数: ${#conf_targets[@]}"
      if run_restic backup \
          --tag "app:_config" \
          --host homelab \
          --exclude '*.sock' --exclude '*.pid' \
          "${conf_targets[@]}" 2>&1 | sed 's/^/    /'; then
        ok "  配置文件备份完成"
        SUCCEEDED+=("_config")
      else
        warn "  配置文件备份失败"
        FAILED+=("_config")
      fi
    fi
    echo
  fi
fi

# ======================================================================
#  清理旧快照
# ======================================================================
echo
info "按保留策略清理旧快照"

KEEP_DAILY="$(read_env "$REPO_ENV" KEEP_DAILY || echo 7)"
KEEP_WEEKLY="$(read_env "$REPO_ENV" KEEP_WEEKLY || echo 4)"
KEEP_MONTHLY="$(read_env "$REPO_ENV" KEEP_MONTHLY || echo 6)"
KEEP_LAST="$(read_env "$REPO_ENV" KEEP_LAST || echo 3)"

echo "    策略: 每日×${KEEP_DAILY} 每周×${KEEP_WEEKLY} 每月×${KEEP_MONTHLY} 最近×${KEEP_LAST}"

# --group-by tags：按 tag 分组应用保留策略，
# 这样每个应用各自保留 N 份，而不是全局只留 N 份（很关键！）
# --prune：真正从存储里删除不再被引用的数据块，回收空间
run_restic forget \
  --group-by tags \
  --keep-daily "$KEEP_DAILY" \
  --keep-weekly "$KEEP_WEEKLY" \
  --keep-monthly "$KEEP_MONTHLY" \
  --keep-last "$KEEP_LAST" \
  --prune 2>&1 | sed 's/^/    /' || warn "清理过程有告警"

# ======================================================================
#  空间检查
# ======================================================================
MAX_GB="$(read_env "$REPO_ENV" MAX_REPO_SIZE_GB || echo 0)"
if [[ "$MAX_GB" =~ ^[0-9]+$ ]] && [[ "$MAX_GB" -gt 0 ]]; then
  echo
  info "检查仓库大小"
  # stats 的 raw-data 模式给出实际占用的存储空间
  raw="$(run_restic stats --mode raw-data --json 2>/dev/null || echo '{}')"
  total_bytes="$(echo "$raw" | grep -oE '"total_size":[0-9]+' | grep -oE '[0-9]+$' || echo 0)"
  total_gb=$(( total_bytes / 1024 / 1024 / 1024 ))

  echo "    当前占用: $(human_size "$total_bytes")  /  阈值 ${MAX_GB}GB"
  if [[ "$total_gb" -ge "$MAX_GB" ]]; then
    warn "仓库已超过阈值！建议调小保留策略，或扩容 / 清理"
    notify "⚠️ homelab 备份仓库已达 $(human_size "$total_bytes")，超过 ${MAX_GB}GB 阈值"
  fi
fi

# ======================================================================
#  汇总
# ======================================================================
ELAPSED=$(( $(date +%s) - START_TS ))
echo
echo "${C_GRN}=========================================${C_OFF}"
echo "  备份完成，耗时 ${ELAPSED}s"
[[ ${#SUCCEEDED[@]} -gt 0 ]] && echo "  成功: ${SUCCEEDED[*]}"
if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo "  ${C_RED}失败: ${FAILED[*]}${C_OFF}"
  notify "❌ homelab 备份部分失败: ${FAILED[*]}"
  echo "${C_GRN}=========================================${C_OFF}"
  exit 1
fi
echo "${C_GRN}=========================================${C_OFF}"

notify "✅ homelab 备份完成: ${SUCCEEDED[*]} (${ELAPSED}s)"
