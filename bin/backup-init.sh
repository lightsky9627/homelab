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
    echo "${C_DIM}只填服务地址（Endpoint），不要带 bucket 名，下一步单独问。${C_OFF}"
    echo
    echo "${C_DIM}  AWS S3:        s3.us-east-1.amazonaws.com${C_OFF}"
    echo "${C_DIM}  阿里云 OSS:    oss-cn-hangzhou.aliyuncs.com${C_OFF}"
    echo "${C_DIM}  腾讯云 COS:    cos.ap-guangzhou.myqcloud.com${C_OFF}"
    echo "${C_DIM}  Cloudflare R2: <account_id>.r2.cloudflarestorage.com${C_OFF}"
    echo "${C_DIM}  MinIO 自建:    minio.example.com${C_OFF}"
    echo
    ENDPOINT="$(ask "Endpoint 域名")"
    [[ -n "$ENDPOINT" ]] || die "Endpoint 不能为空"

    # 把用户可能粘贴的 https:// 前缀和末尾斜杠剪掉，统一成纯域名，
    # 后面拼 URL 时才不会出现 https://https:// 这种错误。
    SCHEME="https"
    case "$ENDPOINT" in
      http://*)  SCHEME="http";  ENDPOINT="${ENDPOINT#http://}"  ;;
      https://*) SCHEME="https"; ENDPOINT="${ENDPOINT#https://}" ;;
    esac
    ENDPOINT="${ENDPOINT%%/*}"   # 删掉第一个 / 及之后的所有内容

    # ---- bucket 单独问，这是之前漏掉导致报错的地方 ----
    BUCKET="$(ask "Bucket 名称")"
    [[ -n "$BUCKET" ]] || die "Bucket 名不能为空"

    # 腾讯云 COS 的 bucket 必须带 APPID 后缀，很多人会忘
    if [[ "$ENDPOINT" == *myqcloud.com ]] && [[ "$BUCKET" != *-[0-9]* ]]; then
      warn "腾讯云 COS 的 bucket 名通常形如 mybucket-1250000000（带 APPID）"
      ask_yn "确定 '${BUCKET}' 是完整名称？" "y" || die "请重新运行并填完整 bucket 名"
    fi

    PREFIX="$(ask "仓库在 bucket 内的路径前缀（留空则放根目录）" "homelab")"

    # ---- 寻址风格 ----
    echo
    echo "${C_DIM}寻址风格决定 bucket 写在 URL 的哪个位置：${C_OFF}"
    echo "${C_DIM}  虚拟主机风格：${BUCKET}.${ENDPOINT}/${PREFIX}${C_OFF}"
    echo "${C_DIM}  路径风格：    ${ENDPOINT}/${BUCKET}/${PREFIX}${C_OFF}"
    echo
    echo "  1) 虚拟主机风格（推荐）"
    echo "     主流云厂商都用这个：AWS S3 / 阿里云 OSS / 腾讯云 COS / Cloudflare R2"
    echo "  2) 路径风格"
    echo "     自建 MinIO / Ceph 等多数默认这个，AWS 已官方弃用"
    echo

    # 根据 endpoint 自动猜一个默认值，减少用户选错的概率
    STYLE_DEFAULT="1"
    case "$ENDPOINT" in
      *amazonaws.com|*aliyuncs.com|*myqcloud.com|*r2.cloudflarestorage.com)
        STYLE_DEFAULT="1" ;;
      *)
        # 自建的服务（MinIO 等）大多数是路径风格
        STYLE_DEFAULT="2" ;;
    esac

    STYLE="$(ask "选择 (1-2)" "$STYLE_DEFAULT")"

    # 拼接仓库 URL。注意 PREFIX 可能为空，要避免出现末尾多余的斜杠。
    if [[ "$STYLE" == "1" ]]; then
      # 虚拟主机风格：bucket 作为域名的一部分
      if [[ -n "$PREFIX" ]]; then
        REPO_URL="s3:${SCHEME}://${BUCKET}.${ENDPOINT}/${PREFIX}"
      else
        REPO_URL="s3:${SCHEME}://${BUCKET}.${ENDPOINT}"
      fi
    else
      # 路径风格：bucket 作为路径的第一段
      if [[ -n "$PREFIX" ]]; then
        REPO_URL="s3:${SCHEME}://${ENDPOINT}/${BUCKET}/${PREFIX}"
      else
        REPO_URL="s3:${SCHEME}://${ENDPOINT}/${BUCKET}"
      fi
    fi

    echo
    info "仓库地址: ${C_YEL}${REPO_URL}${C_OFF}"

    AWS_KEY="$(ask "Access Key ID")"
    [[ -n "$AWS_KEY" ]] || die "Access Key 不能为空"
    AWS_SECRET="$(ask_secret "Secret Access Key")"
    [[ -n "$AWS_SECRET" ]] || die "Secret Key 不能为空"
    ;;
  2)
    BUCKET="$(ask "B2 Bucket 名")"
    [[ -n "$BUCKET" ]] || die "Bucket 名不能为空"
    PREFIX="$(ask "路径前缀" "homelab")"
    # b2 的格式是 b2:<bucket>:<path>，path 为空时连冒号一起省掉
    if [[ -n "$PREFIX" ]]; then
      REPO_URL="b2:${BUCKET}:${PREFIX}"
    else
      REPO_URL="b2:${BUCKET}"
    fi
    B2_ID="$(ask "B2 Account ID / keyID")"
    [[ -n "$B2_ID" ]] || die "Account ID 不能为空"
    B2_KEY="$(ask_secret "B2 Application Key")"
    [[ -n "$B2_KEY" ]] || die "Application Key 不能为空"
    echo
    info "仓库地址: ${C_YEL}${REPO_URL}${C_OFF}"
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
info "检查仓库状态（最多等 30 秒）"
setup_local_mount

# 用 timeout 包住，避免地址写错时卡在网络超时上干等。
# 返回 124 = timeout 杀掉了进程，说明网络不通或地址不对。
set +e
timeout 30 bash -c 'source "$0"; run_restic cat config' "${BASH_SOURCE[0]%/*}/backup-lib.sh" >/dev/null 2>&1
CHECK_RC=$?
set -e

if [[ $CHECK_RC -eq 124 ]]; then
  echo
  warn "连接超时，可能是 Endpoint 写错或网络不通"
  echo "  当前地址: ${C_YEL}${REPO_URL}${C_OFF}"
  echo
  ask_yn "仍然尝试初始化？" "y" || die "已取消，配置保留在 ops/backup/repo.env"
  CHECK_RC=1
fi

if [[ $CHECK_RC -eq 0 ]]; then
  ok "仓库已存在且密码正确，直接复用"
else
  info "仓库不存在，正在初始化"
  if run_restic init; then
    ok "仓库初始化完成"
  else
    echo
    echo "${C_RED}初始化失败。常见原因：${C_OFF}"
    echo
    echo "  • ${C_YEL}Bucket name cannot be empty${C_OFF}"
    echo "    仓库地址里没包含 bucket，重新运行向导并填写 Bucket 名称"
    echo
    echo "  • ${C_YEL}寻址风格选错${C_OFF}"
    echo "    试试另一种风格。当前地址：${REPO_URL}"
    echo
    echo "  • ${C_YEL}bucket 不存在${C_OFF}"
    echo "    restic 不会自动建 bucket，要先在控制台手动创建"
    echo
    echo "  • ${C_YEL}腾讯云 COS 忘带 APPID${C_OFF}"
    echo "    bucket 名必须写完整，如 mybucket-1250000000"
    echo
    echo "  • ${C_YEL}密钥权限不足${C_OFF}"
    echo "    需要读写权限，只读密钥无法初始化"
    echo
    echo "${C_DIM}配置已保留在 ops/backup/repo.env，可直接编辑后重试：${C_OFF}"
    echo "${C_DIM}  vim ops/backup/repo.env${C_OFF}"
    echo "${C_DIM}  bin/hl backup init${C_OFF}"
    exit 1
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
