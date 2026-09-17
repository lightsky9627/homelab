#!/usr/bin/env bash
# ======================================================================
#  backup-init.sh —— 交互式配置备份
#
#  用法: bin/hl backup init
#
#  它会一步步问你：用什么后端、地址、密钥、保留多少份，
#  然后生成 ops/backup/repo.env，测试连通性，最后初始化 restic 仓库。
# ======================================================================

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/backup-lib.sh"

# ---- 小工具：带默认值的提问 ----
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

# 隐藏输入（密码用）
ask_secret() {
  local prompt="$1" answer
  read -rsp "$(echo -e "${C_BLU}?${C_OFF} ${prompt}: ")" answer
  echo >&2
  echo "$answer"
}

ask_yn() {
  local prompt="$1" default="${2:-y}" answer
  read -rp "$(echo -e "${C_BLU}?${C_OFF} ${prompt} ${C_DIM}[${default}]${C_OFF} (y/n): ")" answer
  answer="${answer:-$default}"
  [[ "$answer" =~ ^[Yy] ]]
}

echo
echo "${C_GRN}=========================================${C_OFF}"
echo "${C_GRN}   homelab 备份配置向导${C_OFF}"
echo "${C_GRN}=========================================${C_OFF}"
echo
echo "备份基于 restic：增量去重 + 客户端加密。"
echo "数据在本机加密后才上传，对象存储服务商看不到你的内容。"
echo

# ---- 已存在就先确认 ----
if [[ -f "$REPO_ENV" ]]; then
  warn "$REPO_ENV 已存在"
  ask_yn "覆盖重新配置？" "n" || { echo "已取消"; exit 0; }
  cp "$REPO_ENV" "$REPO_ENV.bak.$(date +%s)"
  info "旧配置已备份"
fi

# ======================================================================
#  第 1 步：选后端
# ======================================================================
echo
echo "${C_YEL}【1/4】选择备份存储后端${C_OFF}"
echo
echo "  1) S3 兼容对象存储  (AWS S3 / 阿里云 OSS / 腾讯云 COS / MinIO / Cloudflare R2)"
echo "  2) Backblaze B2     (便宜，10GB 免费，适合冷备份)"
echo "  3) 本地目录 / NAS   (最简单，但和数据在同一台机器就失去异地容灾意义)"
echo "  4) SFTP 远程主机    (备份到另一台服务器)"
echo

BACKEND="$(ask "选择 (1-4)" "1")"

REPO_URL=""
AWS_KEY=""; AWS_SECRET=""
B2_ID=""; B2_KEY=""

case "$BACKEND" in
  1)
    echo
    echo "${C_DIM}常见 Endpoint 格式：${C_OFF}"
    echo "${C_DIM}  AWS S3:        https://s3.<region>.amazonaws.com/<bucket>/<路径>${C_OFF}"
    echo "${C_DIM}  阿里云 OSS:    https://oss-cn-hangzhou.aliyuncs.com/<bucket>/<路径>${C_OFF}"
    echo "${C_DIM}  腾讯云 COS:    https://cos.ap-guangzhou.myqcloud.com/<bucket>/<路径>${C_OFF}"
    echo "${C_DIM}  Cloudflare R2: https://<account_id>.r2.cloudflarestorage.com/<bucket>${C_OFF}"
    echo "${C_DIM}  MinIO 自建:    https://minio.example.com/<bucket>/<路径>${C_OFF}"
    echo
    ENDPOINT="$(ask "S3 地址 (不含 s3: 前缀)")"
    [[ -n "$ENDPOINT" ]] || die "地址不能为空"
    REPO_URL="s3:${ENDPOINT}"
    AWS_KEY="$(ask "Access Key ID")"
    AWS_SECRET="$(ask_secret "Secret Access Key")"
    ;;
  2)
    BUCKET="$(ask "B2 Bucket 名")"
    PREFIX="$(ask "路径前缀" "homelab")"
    REPO_URL="b2:${BUCKET}:${PREFIX}"
    B2_ID="$(ask "B2 Account ID / keyID")"
    B2_KEY="$(ask_secret "B2 Application Key")"
    ;;
  3)
    REPO_URL="$(ask "本地目录绝对路径" "/mnt/backup/homelab")"
    [[ "$REPO_URL" == /* ]] || die "必须是绝对路径"
    mkdir -p "$REPO_URL"
    warn "本地备份无法防机器损坏/丢失，建议之后再加一个异地后端"
    ;;
  4)
    SFTP_USER="$(ask "SSH 用户名")"
    SFTP_HOST="$(ask "远程主机")"
    SFTP_PATH="$(ask "远程路径" "/backup/homelab")"
    REPO_URL="sftp:${SFTP_USER}@${SFTP_HOST}:${SFTP_PATH}"
    warn "SFTP 需要提前配好免密登录（ssh-copy-id）"
    ;;
  *) die "无效选择" ;;
esac

# ======================================================================
#  第 2 步：仓库加密密码
# ======================================================================
echo
echo "${C_YEL}【2/4】设置仓库加密密码${C_OFF}"
echo
echo "${C_RED}⚠️  这是最重要的一步！${C_OFF}"
echo "这个密码用于加密所有备份数据。${C_RED}一旦丢失，备份将永久无法解密${C_OFF}，"
echo "没有任何找回办法（restic 没有后门，这是设计如此）。"
echo

if ask_yn "自动生成一个强密码？" "y"; then
  RESTIC_PASS="$(openssl rand -base64 32)"
  echo
  echo "  生成的密码: ${C_YEL}${RESTIC_PASS}${C_OFF}"
  echo
  echo "${C_RED}请立刻把它存到密码管理器里（Vaultwarden / 1Password / KeePass）${C_OFF}"
  echo
  read -rp "$(echo -e "${C_BLU}?${C_OFF} 已经保存好了？按回车继续 ")" _
else
  RESTIC_PASS="$(ask_secret "输入仓库密码")"
  PASS2="$(ask_secret "再输一次确认")"
  [[ "$RESTIC_PASS" == "$PASS2" ]] || die "两次输入不一致"
  [[ ${#RESTIC_PASS} -ge 12 ]] || warn "密码偏短，建议至少 12 位"
fi

# ======================================================================
#  第 3 步：保留策略
# ======================================================================
echo
echo "${C_YEL}【3/4】保留策略${C_OFF}"
echo
echo "restic 按多个维度保留快照，一份快照满足任一条件就不会被删。"
echo "由于增量去重，保留十几份的实际占用通常只有单份全量的 1.5-3 倍。"
echo

KEEP_DAILY="$(ask "保留最近几天的每日快照" "7")"
KEEP_WEEKLY="$(ask "保留最近几周的每周快照" "4")"
KEEP_MONTHLY="$(ask "保留最近几月的每月快照" "6")"
KEEP_LAST="$(ask "无论如何都保留最近几份" "3")"
MAX_SIZE="$(ask "仓库空间告警阈值 (GB，0 表示不告警)" "50")"

# ======================================================================
#  第 4 步：写配置并初始化
# ======================================================================
echo
echo "${C_YEL}【4/4】写入配置并初始化仓库${C_OFF}"
echo

umask 077   # 保证生成的文件是 600 权限
cat > "$REPO_ENV" <<EOF
# 由 bin/hl backup init 生成于 $(date '+%Y-%m-%d %H:%M:%S')
# ⚠️ 含密钥，已被 git 忽略，不要提交也不要外传

# ---- 仓库地址 ----
RESTIC_REPOSITORY=${REPO_URL}

# ---- 加密密码（丢了备份就永久打不开）----
RESTIC_PASSWORD=${RESTIC_PASS}

EOF

if [[ -n "$AWS_KEY" ]]; then
  cat >> "$REPO_ENV" <<EOF
# ---- S3 凭据 ----
AWS_ACCESS_KEY_ID=${AWS_KEY}
AWS_SECRET_ACCESS_KEY=${AWS_SECRET}

EOF
fi

if [[ -n "$B2_ID" ]]; then
  cat >> "$REPO_ENV" <<EOF
# ---- Backblaze B2 凭据 ----
B2_ACCOUNT_ID=${B2_ID}
B2_ACCOUNT_KEY=${B2_KEY}

EOF
fi

cat >> "$REPO_ENV" <<EOF
# ---- 保留策略 ----
KEEP_DAILY=${KEEP_DAILY}
KEEP_WEEKLY=${KEEP_WEEKLY}
KEEP_MONTHLY=${KEEP_MONTHLY}
KEEP_LAST=${KEEP_LAST}

# ---- 空间告警阈值（GB，0 = 不告警）----
MAX_REPO_SIZE_GB=${MAX_SIZE}

# ---- 完成通知（shoutrrr URL，留空则不通知）----
# NOTIFY_URL=
EOF

chmod 600 "$REPO_ENV"
ok "配置已写入 ops/backup/repo.env (权限 600)"

# ---- 初始化 restic 仓库 ----
echo
info "检查仓库状态"
setup_local_mount

if run_restic cat config >/dev/null 2>&1; then
  ok "仓库已存在且密码正确，直接复用"
else
  info "仓库不存在，正在初始化"
  if run_restic init; then
    ok "仓库初始化完成"
  else
    die "初始化失败。请检查：地址是否正确、密钥是否有权限、bucket 是否已创建"
  fi
fi

# ---- 完成 ----
echo
echo "${C_GRN}=========================================${C_OFF}"
echo "${C_GRN}   配置完成${C_OFF}"
echo "${C_GRN}=========================================${C_OFF}"
echo
echo "接下来："
echo "  bin/hl backup now      立即跑一次备份，验证能跑通"
echo "  bin/hl backup list     查看快照"
echo "  bin/hl up backup       启动定时调度（按 ops/backup/.env 的 cron）"
echo
echo "${C_YEL}强烈建议：配好后立刻做一次恢复演练（bin/hl backup restore），${C_OFF}"
echo "${C_YEL}确认备份真的能还原。没验证过的备份等于没有备份。${C_OFF}"
echo
