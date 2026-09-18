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
#    1) 如果应用用了 PostgreSQL，先 pg_dump 出一个 .sql.gz
#    2) 把 dump 文件 + 应用的 data/ 目录一起交给 restic
#    3) 全部完成后按保留策略清理旧快照
#    4) 检查仓库大小，超阈值告警
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

# 临时目录：放数据库 dump，备份完就删
DUMP_DIR="$REPO_ROOT/ops/backup/.dumps"
cleanup() { rm -rf "$DUMP_DIR"; }
trap cleanup EXIT

START_TS=$(date +%s)
FAILED=()
SUCCEEDED=()

# ======================================================================
#  备份单个应用
# ======================================================================
backup_app() {
  local dir="$1" name="$2" pgdb="$3" paths="$4" excludes="${5:-}"
  local dumpall="${6:-}" mysqldumpall="${7:-}"

  info "备份 ${C_YEL}${name}${C_OFF}"

  # 这个应用要交给 restic 的所有路径（容器内视角，都在 /data 下）
  local targets=()

  # ---- 0) 全库 dump（数据库本体的备份）----
  # pg_dumpall / mysqldump --all-databases 会连用户、权限一起导出，
  # 比逐库 dump 更适合灾难恢复（换台机器不用手建账号）。
  if [[ "$dumpall" == "true" ]]; then
    mkdir -p "$DUMP_DIR"
    local allfile="$DUMP_DIR/${name}-all-databases.sql.gz"
    echo "    导出全部 PostgreSQL 库和角色"

    local pguser; pguser="$(read_env "${dir}.env" POSTGRES_USER 2>/dev/null || echo postgres)"
    if docker exec postgresql pg_dumpall -U "$pguser" 2>/dev/null | gzip > "$allfile"; then
      if [[ -s "$allfile" ]] && [[ $(stat -c%s "$allfile") -gt 100 ]]; then
        echo "    dump 大小: $(human_size "$(stat -c%s "$allfile")")"
        targets+=("/data/ops/backup/.dumps/$(basename "$allfile")")
      else
        warn "    dump 文件异常（太小），跳过"
        rm -f "$allfile"
      fi
    else
      warn "    pg_dumpall 失败（PostgreSQL 容器在运行吗？）"
      rm -f "$allfile"
    fi
  fi

  if [[ "$mysqldumpall" == "true" ]]; then
    mkdir -p "$DUMP_DIR"
    local myfile="$DUMP_DIR/${name}-all-databases.sql.gz"
    echo "    导出全部 MySQL 库和账号"

    local mypass; mypass="$(read_env "${dir}.env" MYSQL_ROOT_PASSWORD 2>/dev/null || echo "")"
    # --single-transaction 让 InnoDB 在不锁表的情况下拿到一致快照
    if docker exec -e MYSQL_PWD="$mypass" mysql \
         mysqldump -u root --all-databases --single-transaction \
         --routines --events 2>/dev/null | gzip > "$myfile"; then
      if [[ -s "$myfile" ]] && [[ $(stat -c%s "$myfile") -gt 100 ]]; then
        echo "    dump 大小: $(human_size "$(stat -c%s "$myfile")")"
        targets+=("/data/ops/backup/.dumps/$(basename "$myfile")")
      else
        warn "    dump 文件异常（太小），跳过"
        rm -f "$myfile"
      fi
    else
      warn "    mysqldump 失败（MySQL 容器在运行吗？）"
      rm -f "$myfile"
    fi
  fi

  # ---- 1) 单库 dump（应用声明自己用哪个库）----
  if [[ -n "$pgdb" ]]; then
    mkdir -p "$DUMP_DIR"
    local dumpfile="$DUMP_DIR/${name}-${pgdb}.sql.gz"
    echo "    导出 PostgreSQL 库: $pgdb"

    # 用 pg_dump 导出。注意这里连的是共享 pg 容器。
    # -Fc 是自定义格式（支持并行恢复、单表恢复），但为了可读性和通用性
    # 这里用纯 SQL + gzip，恢复时直接 psql < 就行。
    local pgdir="$REPO_ROOT/infra/postgresql"
    local pguser; pguser="$(read_env "$pgdir/.env" POSTGRES_USER)"

    if docker exec postgresql pg_dump -U "$pguser" -d "$pgdb" 2>/dev/null | gzip > "$dumpfile"; then
      # 检查 dump 不是空的（pg_dump 失败时可能产生空文件）
      if [[ -s "$dumpfile" ]] && [[ $(stat -c%s "$dumpfile") -gt 100 ]]; then
        echo "    dump 大小: $(human_size "$(stat -c%s "$dumpfile")")"
        targets+=("/data/ops/backup/.dumps/$(basename "$dumpfile")")
      else
        warn "    dump 文件异常（太小），跳过该库"
        rm -f "$dumpfile"
      fi
    else
      warn "    pg_dump 失败，跳过数据库部分（PostgreSQL 容器在运行吗？）"
      rm -f "$dumpfile"
    fi
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
  # 先放通用的：套接字和 pid 文件备份了也没意义，而且可能导致 restic 报错。
  local -a exclude_args=(--exclude '*.sock' --exclude '*.pid')

  # 再叠加应用自己声明的。比如 RSS 阅读器的文章缓存、缩略图，
  # 这些东西丢了会自动重建，没必要占备份空间。
  if [[ -n "$excludes" ]]; then
    local -a ex_arr
    IFS=',' read -ra ex_arr <<< "$excludes"
    local ex
    for ex in "${ex_arr[@]}"; do
      ex="$(echo "$ex" | xargs)"   # 去首尾空格
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
    IFS='|' read -r dir name pgdb paths excludes dumpall mysqldumpall <<< "$entry"
    [[ -n "$name" ]] || continue
    # 有过滤条件时只备份匹配的
    if [[ -n "$FILTER" ]]; then
      [[ "$name" == *"$FILTER"* ]] || continue
    fi
    found=1
    backup_app "$dir" "$name" "$pgdb" "$paths" "$excludes" "$dumpall" "$mysqldumpall"
    echo
  done

  # ---- 配置快照 ----
  # 单独备份全仓库的 .env 和 compose 文件，不依赖任何应用标签。
  # 为什么单独做：.env 里是数据库密码、API key 这些东西，
  # 没它们就算数据库 dump 救回来了也跑不起来。
  # 而且它们被 .gitignore 排除，不在任何 git 仓库里，丢了就真没了。
  if [[ -z "$FILTER" ]]; then
    info "备份 ${C_YEL}配置文件${C_OFF}"

    # 找出所有 .env（含密码）和 compose 文件（含编排结构）
    conf_targets=()
    while IFS= read -r f; do
      [[ -n "$f" ]] && conf_targets+=("/data/${f#$REPO_ROOT/}")
    done < <(find "$REPO_ROOT" \
               \( -name '.env' -o -name 'docker-compose.yaml' -o -name 'Caddyfile' \) \
               -not -path '*/data/*' -not -path '*/.git/*' 2>/dev/null | sort)

    # bin/ 里的脚本和反代站点配置也一并带上
    [[ -d "$REPO_ROOT/bin" ]] && conf_targets+=("/data/bin")
    [[ -d "$REPO_ROOT/infra/caddy/sites" ]] && conf_targets+=("/data/infra/caddy/sites")

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

  if [[ $found -eq 0 ]]; then
    if [[ -n "$FILTER" ]]; then
      die "没有匹配 '$FILTER' 的应用"
    else
      die "没有发现任何需要备份的应用。
请在应用的 docker-compose.yaml 里加标签：
    labels:
      homelab.backup.enable: \"true\"
      homelab.backup.paths: \"./data\"
      homelab.backup.pg-db: \"\${DB_NAME}\"     # 用 pg 的应用才需要
      homelab.backup.exclude: \"cache/,*.tmp\"   # 排除不重要的文件（可选）"
    fi
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
