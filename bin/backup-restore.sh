#!/usr/bin/env bash
# ======================================================================
#  backup-restore.sh —— 查看快照 / 统计 / 交互式恢复
#
#  用法:
#    bin/hl backup list [应用]    列出快照
#    bin/hl backup stats          空间统计（按应用汇总）
#    bin/hl backup restore        交互式恢复向导
# ======================================================================

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/backup-lib.sh"

require_repo_env
setup_local_mount

MODE="restore"
FILTER=""

while (( $# )); do
  case "$1" in
    --list)  MODE="list" ;;
    --stats) MODE="stats" ;;
    -*) die "未知参数: $1" ;;
    *)  FILTER="$1" ;;
  esac
  shift
done

ask() {
  local prompt="$1" default="${2:-}" answer
  if [[ -n "$default" ]]; then
    read -rp "$(echo -e "${C_BLU}?${C_OFF} ${prompt} ${C_DIM}[${default}]${C_OFF}: ")" answer
    echo "${answer:-$default}"
  else
    read -rp "$(echo -e "${C_BLU}?${C_OFF} ${prompt}: ")" answer
    echo "$answer"
  fi
}

ask_yn() {
  local prompt="$1" default="${2:-n}" answer
  read -rp "$(echo -e "${C_BLU}?${C_OFF} ${prompt} ${C_DIM}[${default}]${C_OFF} (y/n): ")" answer
  answer="${answer:-$default}"
  [[ "$answer" =~ ^[Yy] ]]
}

# ======================================================================
#  列出快照
# ======================================================================
do_list() {
  local args=(snapshots --host homelab)
  [[ -n "$FILTER" ]] && args+=(--tag "app:${FILTER}")

  echo
  if [[ -n "$FILTER" ]]; then
    info "应用 ${C_YEL}${FILTER}${C_OFF} 的快照"
  else
    info "所有快照"
  fi
  echo

  run_restic "${args[@]}"

  echo
  echo "${C_DIM}恢复某个快照: bin/hl backup restore${C_OFF}"
}

# ======================================================================
#  空间统计（按应用汇总）
# ======================================================================
do_stats() {
  echo
  info "仓库总体占用"
  echo

  # raw-data 模式 = 去重压缩后真正占用的存储空间（决定你的对象存储账单）
  echo "  ${C_YEL}实际存储占用（去重压缩后）${C_OFF}"
  run_restic stats --mode raw-data 2>/dev/null | sed 's/^/    /'

  echo
  # restore-size 模式 = 所有快照还原出来的总大小（逻辑大小）
  echo "  ${C_YEL}逻辑大小（全部还原后）${C_OFF}"
  run_restic stats --mode restore-size 2>/dev/null | sed 's/^/    /'

  # ---- 按应用分别统计 ----
  echo
  info "按应用统计"
  echo
  printf '  %-20s %-8s %-12s %s\n' "应用" "快照数" "最新快照" "还原大小"
  printf '  %s\n' "------------------------------------------------------------"

  # 从所有快照里抽出 app: 开头的 tag，去重
  local tags
  tags="$(run_restic snapshots --json 2>/dev/null \
          | grep -oE '"app:[^"]+"' | tr -d '"' | sort -u || true)"

  if [[ -z "$tags" ]]; then
    echo "  ${C_DIM}还没有任何快照${C_OFF}"
    return
  fi

  local tag
  while IFS= read -r tag; do
    [[ -n "$tag" ]] || continue
    local app="${tag#app:}"

    # 该应用的快照数量
    local count
    count="$(run_restic snapshots --tag "$tag" --json 2>/dev/null \
             | grep -oE '"short_id"' | wc -l || echo 0)"

    # 最近一次备份时间
    local latest
    latest="$(run_restic snapshots --tag "$tag" --latest 1 --json 2>/dev/null \
              | grep -oE '"time":"[^"]+"' | head -1 \
              | sed 's/"time":"//; s/"//' | cut -c1-16 | tr 'T' ' ' || echo "?")"

    # 最新快照的还原大小。
    # 注意：restic stats 不支持 --latest，要先拿到快照 ID 再查。
    local latest_id size
    latest_id="$(run_restic snapshots --tag "$tag" --latest 1 --json 2>/dev/null \
                 | grep -oE '"short_id":"[^"]+"' | head -1 \
                 | sed 's/"short_id":"//; s/"//')"
    if [[ -n "$latest_id" ]]; then
      size="$(run_restic stats "$latest_id" --mode restore-size 2>/dev/null \
              | grep -oE 'Total Size: .*' | sed 's/Total Size: *//')"
    fi

    printf '  %-20s %-8s %-12s %s\n' "$app" "$count" "${latest:-?}" "${size:-?}"
  done <<< "$tags"

  # ---- 保留策略提示 ----
  echo
  local kd kw km kl mx
  kd="$(read_env "$REPO_ENV" KEEP_DAILY || echo 7)"
  kw="$(read_env "$REPO_ENV" KEEP_WEEKLY || echo 4)"
  km="$(read_env "$REPO_ENV" KEEP_MONTHLY || echo 6)"
  kl="$(read_env "$REPO_ENV" KEEP_LAST || echo 3)"
  mx="$(read_env "$REPO_ENV" MAX_REPO_SIZE_GB || echo 0)"

  echo "  ${C_DIM}保留策略: 每日×${kd} 每周×${kw} 每月×${km} 最近×${kl}（每个应用独立计算）${C_OFF}"
  [[ "$mx" != "0" ]] && echo "  ${C_DIM}空间告警阈值: ${mx}GB${C_OFF}"
  echo
  echo "  ${C_DIM}调整策略: 改 ops/backup/repo.env 后执行 bin/hl backup prune${C_OFF}"
}

# ======================================================================
#  交互式恢复
# ======================================================================
do_restore() {
  echo
  echo "${C_GRN}=========================================${C_OFF}"
  echo "${C_GRN}   恢复向导${C_OFF}"
  echo "${C_GRN}=========================================${C_OFF}"

  # ---- 第 1 步：选应用 ----
  echo
  echo "${C_YEL}【1/4】选择要恢复的应用${C_OFF}"
  echo

  local tags
  tags="$(run_restic snapshots --json 2>/dev/null \
          | grep -oE '"app:[^"]+"' | tr -d '"' | sort -u || true)"
  [[ -n "$tags" ]] || die "仓库里还没有任何快照"

  local apps=() i=1
  while IFS= read -r t; do
    [[ -n "$t" ]] || continue
    apps+=("${t#app:}")
    printf '  %d) %s\n' "$i" "${t#app:}"
    ((i++))
  done <<< "$tags"

  echo
  local choice; choice="$(ask "选择 (1-${#apps[@]})")"
  [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#apps[@]} )) \
    || die "无效选择"
  local app="${apps[$((choice-1))]}"

  # ---- 第 2 步：选快照 ----
  echo
  echo "${C_YEL}【2/4】选择快照版本${C_OFF}"
  echo
  run_restic snapshots --tag "app:${app}" 2>/dev/null | sed 's/^/  /'
  echo
  echo "${C_DIM}填快照 ID（左边那列短 ID），或直接回车用最新的一份${C_OFF}"
  local snap; snap="$(ask "快照 ID" "latest")"

  # ---- 第 3 步：选恢复方式 ----
  echo
  echo "${C_YEL}【3/4】选择恢复方式${C_OFF}"
  echo
  echo "  1) ${C_GRN}导出到临时目录${C_OFF}（安全，推荐）"
  echo "     恢复到 ops/backup/restored/ 下，你自己检查确认后再手动替换"
  echo "  2) ${C_RED}原地覆盖${C_OFF}（危险）"
  echo "     直接覆盖当前的 data/ 目录，现有数据会丢失"
  echo "  3) 只看内容，不恢复"
  echo "     列出这个快照里都有什么文件"
  echo
  local method; method="$(ask "选择 (1-3)" "1")"

  case "$method" in
    3)
      echo
      info "快照 ${snap} 的内容"
      run_restic ls "$snap" --tag "app:${app}" 2>/dev/null | sed 's/^/  /' | head -100
      echo
      echo "${C_DIM}（只显示前 100 行）${C_OFF}"
      return
      ;;
    1)
      local outdir="$REPO_ROOT/ops/backup/restored/${app}-$(date +%Y%m%d-%H%M%S)"
      mkdir -p "$outdir"

      echo
      echo "${C_YEL}【4/4】执行恢复${C_OFF}"
      info "恢复到 $(realpath --relative-to="$REPO_ROOT" "$outdir")"

      # --target 指定恢复到哪，restic 会在里面重建原始的目录结构
      docker run --rm \
        --env-file "$REPO_ENV" \
        --network host \
        -v "$REPO_ROOT:/data" \
        -v "restic-cache:/root/.cache/restic" \
        ${RESTIC_LOCAL_MOUNT:-} \
        "${REGISTRY:-hub.bravexist.cn}/restic/restic:${RESTIC_TAG:-latest}" \
        restore "$snap" --tag "app:${app}" \
        --target "/data/ops/backup/restored/$(basename "$outdir")" 2>&1 | sed 's/^/  /'

      echo
      ok "恢复完成"
      echo
      echo "文件在: ${C_YEL}${outdir}${C_OFF}"
      # 找出恢复出来的 dump 文件，以及它对应的真实库名。
      # 注意：库名不等于应用目录名（目录是 100-memos，库是 memos）
      local dumpfile dbname pguser
      dumpfile="$(find "$outdir" -name '*.sql.gz' -print -quit 2>/dev/null || true)"
      pguser="$(read_env "$REPO_ROOT/infra/020-postgresql/.env" POSTGRES_USER 2>/dev/null || echo postgres)"

      echo
      echo "${C_BLU}接下来手动操作：${C_OFF}"
      echo
      echo "  ${C_YEL}1)${C_OFF} 先看看恢复出来的内容对不对"
      echo "     find ${outdir}/data -maxdepth 4"
      echo

      if [[ -n "$dumpfile" ]]; then
        # 从文件名里反推库名：<应用目录名>-<库名>.sql.gz
        dbname="$(basename "$dumpfile" .sql.gz)"
        dbname="${dbname#${app}-}"

        echo "  ${C_YEL}2)${C_OFF} 导回数据库（库名: ${C_YEL}${dbname}${C_OFF}）"
        echo "     ${C_DIM}# 先停掉应用，避免写入冲突${C_OFF}"
        echo "     bin/hl down ${app}"
        echo "     ${C_DIM}# 删掉旧库重建（⚠️ 会清空现有数据）${C_OFF}"
        echo "     docker exec -i postgresql psql -U ${pguser} -c 'DROP DATABASE IF EXISTS ${dbname};'"
        echo "     docker exec -i postgresql psql -U ${pguser} -c 'CREATE DATABASE ${dbname} OWNER ${dbname};'"
        echo "     ${C_DIM}# 导入${C_OFF}"
        echo "     gunzip -c ${dumpfile} | docker exec -i postgresql psql -U ${pguser} -d ${dbname}"
        echo
      fi

      echo "  ${C_YEL}3)${C_OFF} 数据目录覆盖回去（注意末尾的小点，表示拷贝目录内容）"
      echo "     cp -a ${outdir}/data/apps/${app}/data/. ${REPO_ROOT}/apps/${app}/data/"
      echo
      echo "  ${C_YEL}4)${C_OFF} 重新启动"
      echo "     bin/hl up ${app}"
      ;;
    2)
      echo
      echo "${C_RED}⚠️  危险操作确认${C_OFF}"
      echo
      echo "这会用快照 ${snap} 直接覆盖 ${app} 当前的数据，"
      echo "${C_RED}覆盖后现有数据无法找回${C_OFF}。"
      echo
      ask_yn "确定要原地覆盖吗？" "n" || { echo "已取消"; return; }
      echo
      read -rp "$(echo -e "${C_RED}?${C_OFF} 请输入应用名 '${app}' 二次确认: ")" confirm
      [[ "$confirm" == "$app" ]] || { echo "输入不匹配，已取消"; return; }

      echo
      echo "${C_YEL}【4/4】执行恢复${C_OFF}"
      info "停止应用"
      "$REPO_ROOT/bin/hl" down "$app" 2>/dev/null || warn "停止失败，继续"

      info "覆盖恢复中"
      run_restic_rw restore "$snap" --tag "app:${app}" --target /data 2>&1 | sed 's/^/  /'

      ok "恢复完成"
      warn "数据库需要单独手动导入（见 ops/backup/restored 里的 .sql.gz）"
      echo
      echo "启动应用: bin/hl up ${app}"
      ;;
    *) die "无效选择" ;;
  esac
}

case "$MODE" in
  list)    do_list ;;
  stats)   do_stats ;;
  restore) do_restore ;;
esac
