# Bash completion for hl (homelab CLI)
# Source this file: source /path/to/homelab/bin/hl-completion.bash
# Or symlink to /etc/bash_completion.d/hl

_hl_completions() {
  local cur prev words cword
  if type _init_completion >/dev/null 2>&1; then
    _init_completion || return
  else
    # 兼容没有安装 bash-completion 宏包的环境
    COMPREPLY=()
    words=("${COMP_WORDS[@]}")
    cword=$COMP_CWORD
    cur="${words[cword]}"
    prev="${words[cword-1]}"
  fi

  local repo_root=""
  # 如果是通过具体路径调用的 hl，用它的相对位置；否则用当前目录或环境变量
  if [[ -f "./bin/hl" ]]; then
    repo_root="$(pwd)"
  elif [[ "${COMP_WORDS[0]}" == /* && -f "${COMP_WORDS[0]}" ]]; then
    repo_root="$(cd "$(dirname "${COMP_WORDS[0]}")/.." && pwd)"
  elif [[ -n "${HOMELAB_ROOT:-}" && -d "$HOMELAB_ROOT" ]]; then
    repo_root="$HOMELAB_ROOT"
  fi

  # 获取所有可用服务的列表（既提供短名字如 memos，也提供编号全名如 100-memos）
  _hl_list_services() {
    if [[ -n "$repo_root" && -d "$repo_root" ]]; then
      local d
      for d in "$repo_root"/infra/*/ "$repo_root"/apps/*/ "$repo_root"/ops/*/; do
        [[ -f "${d}docker-compose.yaml" ]] || continue
        local name; name="$(basename "$d")"
        local slug="${name#*-}"
        echo "$name"
        [[ "$name" != "$slug" ]] && echo "$slug"
      done
    else
      echo "caddy 010-caddy postgresql 020-postgresql mysql 021-mysql memos 100-memos rustdesk 110-rustdesk watchtower backup"
    fi
  }

  local commands="up down restart logs ps ports proxy db backup rustdesk help"

  # 第一级参数：子命令
  if [[ $cword -eq 1 ]]; then
    COMPREPLY=($(compgen -W "$commands" -- "$cur"))
    return 0
  fi

  local subcmd="${words[1]}"

  case "$subcmd" in
    up|down)
      local services
      services="$(_hl_list_services) --all"
      COMPREPLY=($(compgen -W "$services" -- "$cur"))
      return 0
      ;;
    restart|logs)
      local services
      services="$(_hl_list_services)"
      COMPREPLY=($(compgen -W "$services" -- "$cur"))
      return 0
      ;;
    proxy)
      if [[ $cword -eq 2 ]]; then
        COMPREPLY=($(compgen -W "add list reload remove cat" -- "$cur"))
      elif [[ $cword -eq 3 && "${words[2]}" =~ ^(remove|cat)$ ]]; then
        # 补全现有的代理站点
        if [[ -n "$repo_root" && -d "$repo_root/infra/010-caddy/sites" ]]; then
          local sites
          sites="$(cd "$repo_root/infra/010-caddy/sites" 2>/dev/null && ls *.caddy 2>/dev/null | sed 's/\.caddy$//' || true)"
          COMPREPLY=($(compgen -W "$sites" -- "$cur"))
        fi
      fi
      return 0
      ;;
    db)
      if [[ $cword -eq 2 ]]; then
        COMPREPLY=($(compgen -W "create list shell" -- "$cur"))
      fi
      return 0
      ;;
    backup)
      if [[ $cword -eq 2 ]]; then
        COMPREPLY=($(compgen -W "init now list restore stats prune" -- "$cur"))
      elif [[ $cword -eq 3 && "${words[2]}" =~ ^(now|list)$ ]]; then
        local services
        services="$(_hl_list_services)"
        COMPREPLY=($(compgen -W "$services" -- "$cur"))
      fi
      return 0
      ;;
    rustdesk)
      if [[ $cword -eq 2 ]]; then
        COMPREPLY=($(compgen -W "key" -- "$cur"))
      fi
      return 0
      ;;
  esac
}

# 注册补全：支持 hl、./bin/hl、bin/hl
complete -F _hl_completions hl
complete -F _hl_completions ./bin/hl
complete -F _hl_completions bin/hl
