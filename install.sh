#!/usr/bin/env bash
# ===========================================================================
# SCWebManager 一键安装脚本（Linux）
#
#   curl -fsSL https://gitee.com/JIILStudio/jiilsc-web-manger/raw/master/install.sh | bash
#   sh install.sh
# ===========================================================================
set -u

# 参数（可单独或组合使用；不传参数时保持原有交互安装体验）：
#   -f          静默安装：不询问任何问题，使用默认值，最后只输出一条结果
#   -json       最终只输出一行标准 JSON（ok/version/installDir/panelUrl/osOk/error）
#   -1 <答案>   预填第 1 个问题（安装目录）
#   -2 <答案>   预填第 2 个问题（版本号：latest 或具体版本）
#   -3 <答案>   预填第 3 个问题（系统版本过低时是否强制安装：y/n）
#   -h          显示帮助
#
# 没有 PowerShell 的机器可手动下载安装：
#   1) 打开 versions.json，按本机架构找到目标版本的 "linux_amd64" 或 "linux_arm64" 下载直链
#   2) 下载后用 tar/unzip 解压到任意目录
#   3) 先运行 ./scweb-daemon -dir <安装目录>，再运行 ./scweb-panel
#   4) 浏览器访问 http://127.0.0.1:18233

VERSIONS_URL="https://gitee.com/JIILStudio/jiilsc-web-manger/raw/master/versions.json"
TRUE_LIST_URL="https://gitee.com/JIILStudio/jiilsc-web-manger/raw/master/true-list.json"
DEFAULT_PORT=18233
MIN_DISK_MB=300

# 参数与状态
OPT_SILENT=0
OPT_JSON=0
OPT_HELP=0
PREFILL_1=""
PREFILL_2=""
PREFILL_3=""
MUTE=0
OS_LOW=0
OS_LOW_MSG=""
RESULT_VERSION=""
FAIL_MSG=""
TL_FILE=""
TL_FLAT=""

INSTALL_DIR=""
PANEL_URL=""
PANEL_PID=""
DAEMON_PID=""
RUNTIME_PID=""
RUNTIME_PORT=""
WORK_DIRS=""
# 安装过程中产生的临时目录：只在安装成功或安装器退出前清理，失败时保留现场
TMP_DIRS=""
ENTRIES_FILE=""
LATEST_VERSION=""
# 当前机器对应的安装包架构后缀（amd64 / arm64），由 check_env 探测；
# 版本清单里优先取 "linux_<arch>"，amd64 机器还可回退到旧的 "linux" 字段。
ARCH_KIND=""

# ---------------------------- 参数解析 ----------------------------

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      -f|--silent) OPT_SILENT=1 ;;
      -json|--json) OPT_JSON=1 ;;
      -h|--help|-help|/?)
        OPT_HELP=1 ;;
      -1) shift; [ $# -gt 0 ] && PREFILL_1="$1" ;;
      -2) shift; [ $# -gt 0 ] && PREFILL_2="$1" ;;
      -3) shift; [ $# -gt 0 ] && PREFILL_3="$1" ;;
      *) : ;;
    esac
    shift
  done
  if [ "$OPT_SILENT" -eq 1 ] || [ "$OPT_JSON" -eq 1 ]; then
    MUTE=1
  fi
  return 0
}

usage() {
  cat <<'EOF'
SCWebManager 安装脚本（Linux）

  sh install.sh [-f] [-json] [-1 目录] [-2 版本] [-3 y/n]

  -f          静默安装：不询问，全部用默认值，最后只输出一条结果
  -json       最终只输出一行标准 JSON（ok/version/installDir/panelUrl/osOk/error）
  -1 <答案>   预填第 1 个问题：安装目录
  -2 <答案>   预填第 2 个问题：版本号（latest 或具体版本）
  -3 <答案>   预填第 3 个问题：系统版本过低时是否强制安装（y/n）
  -h          显示本帮助

手动安装（无需本脚本）：
  1) 打开 versions.json，按本机架构找到目标版本的 linux_amd64 或 linux_arm64 下载直链
  2) 下载后用 tar/unzip 解压到目标目录
  3) 先运行 ./scweb-daemon -dir <安装目录>，再运行 ./scweb-panel
  4) 浏览器访问 http://127.0.0.1:18233
EOF
}

# JSON 字符串转义
json_escape() {
  printf '%s' "$1" | tr -d '\r\n\t' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

json_result() {
  _jr_ok="$1"
  _jr_err="$2"
  _jr_os="true"
  [ "$OS_LOW" -eq 1 ] && _jr_os="false"
  printf '{"ok":%s,"version":"%s","installDir":"%s","panelUrl":"%s","osOk":%s,"error":"%s"}\n' \
    "$_jr_ok" "$(json_escape "$RESULT_VERSION")" "$(json_escape "$INSTALL_DIR")" \
    "$(json_escape "$PANEL_URL")" "$_jr_os" "$(json_escape "$_jr_err")"
}

# ---------------------------- 输出工具 ----------------------------

banner() {
  [ "$MUTE" -eq 1 ] && return 0
cat <<'EOF'

+------------------------------------------------------------------+
|                                                                  |
|   _  _ ___ ___ _      ___      ___      __      _                |
|  | || |_ _|_ _| |    / __|_ __/ __|_ __/ /_  __| | __ _  _ _      |
|  | || || || || |__  \__ \ '_ \__ \ '_ \/ _ \/ _` |/ _` || '_|    |
|  |_||_||_||_||____| |___/ .__/___/ .__/\___/\__,_|\__,_||_|      |
|                         |_|     |_|                             |
|                                                                  |
|          S C W E B  M A N A G E R   /   Installer                |
+------------------------------------------------------------------+

EOF
printf '  安装脚本 / Installer\n'
}

step() { [ "$MUTE" -eq 1 ] && return 0; printf '\n* %s\n' "$1"; }
ok()   { [ "$MUTE" -eq 1 ] && return 0; printf '  ✔ %s\n' "$1"; }
bad()  { [ "$MUTE" -eq 1 ] && return 0; printf '  ✘ %s\n' "$1"; }
note() { [ "$MUTE" -eq 1 ] && return 0; printf '  ! %s\n' "$1"; }
sep()  { [ "$MUTE" -eq 1 ] && return 0; printf '%s\n' "================================================================"; }

# 交互输入：优先从终端读，避免 curl | bash 时把脚本文本当成输入
prompt_read() {
  _pr_prompt="$1"
  REPLY=""
  [ "$MUTE" -eq 1 ] && return 0
  if [ -r /dev/tty ]; then
    printf '%s' "$_pr_prompt" > /dev/tty
    IFS= read -r REPLY < /dev/tty || REPLY=""
  else
    printf '%s' "$_pr_prompt"
    IFS= read -r REPLY || REPLY=""
  fi
  return 0
}

# ---------------------------- 环境检查 ----------------------------

check_env() {
  step "运行环境检查"
  _env_ok=1

  # CPU 架构
  _arch="$(uname -m 2>/dev/null || echo unknown)"
  case "$_arch" in
    x86_64|amd64)
      ARCH_KIND="amd64"
      ok "CPU 架构 $_arch（安装包架构 amd64）" ;;
    aarch64|arm64)
      ARCH_KIND="arm64"
      ok "CPU 架构 $_arch（安装包架构 arm64）" ;;
    *)
      bad "CPU 架构 $_arch 不受支持（仅提供 x86_64 / aarch64 构建）"
      _env_ok=0 ;;
  esac

  # 下载工具
  _curl=""
  _wget=""
  command -v curl >/dev/null 2>&1 && _curl="curl"
  command -v wget >/dev/null 2>&1 && _wget="wget"
  if [ -n "$_curl" ]; then
    ok "下载工具 curl 可用"
  elif [ -n "$_wget" ]; then
    ok "下载工具 wget 可用"
  else
    bad "未找到 curl 或 wget（至少需要一个）"
    _env_ok=0
  fi

  # 解包工具
  _tar=""
  _unzip=""
  command -v tar >/dev/null 2>&1 && _tar="tar"
  command -v unzip >/dev/null 2>&1 && _unzip="unzip"
  if [ -n "$_tar" ] && [ -n "$_unzip" ]; then
    ok "解包工具 tar / unzip 可用"
  elif [ -n "$_tar" ]; then
    ok "解包工具 tar 可用（安装包须为 .tar.gz）"
  elif [ -n "$_unzip" ]; then
    ok "解包工具 unzip 可用（安装包须为 .zip）"
  else
    bad "未找到 tar 或 unzip（至少需要一个）"
    _env_ok=0
  fi

  # 磁盘空间
  _free_kb=""
  _free_kb="$(df -Pk "${HOME:-/}" 2>/dev/null | awk 'NR==2 {print $4}')"
  if [ -n "$_free_kb" ] && [ "$_free_kb" -ge $((MIN_DISK_MB * 1024)) ] 2>/dev/null; then
    ok "可用磁盘 $((_free_kb / 1024)) MB（要求 ${MIN_DISK_MB} MB）"
  else
    bad "可用磁盘不足 ${MIN_DISK_MB} MB 或无法检测"
    _env_ok=0
  fi

  # 发行版信息（可选）
  if [ -r /etc/os-release ]; then
    _pretty="$(grep -E '^PRETTY_NAME=' /etc/os-release 2>/dev/null | head -n 1 | cut -d '=' -f 2- | tr -d '"')"
    [ -n "$_pretty" ] && ok "系统 $_pretty"
  fi

  # 内核
  _kernel="$(uname -r 2>/dev/null || echo unknown)"
  ok "内核 $_kernel"

  # root / sudo
  if [ "$(id -u 2>/dev/null || echo 1000)" -eq 0 ]; then
    ok "当前为 root 用户"
  else
    note "当前非 root；将安装到用户目录，无需 sudo"
  fi

  return $((_env_ok == 0))
}

# ---------------------------- 系统版本门槛 ----------------------------

# 从 /etc/os-release 读取字段（缺失输出空）
osrel_get() {
  [ -r /etc/os-release ] || return 0
  _org_key="$1"
  ( . /etc/os-release 2>/dev/null; eval "v=\${$_org_key:-}"; printf '%s' "$v" )
}

# 发行版 ID -> true-list.json 使用的规范键
distro_alias() {
  case "$1" in
    ubuntu*|linuxmint|pop) echo ubuntu ;;
    debian*|raspbian*|kali*) echo debian ;;
    fedora*) echo fedora ;;
    rhel*|redhat*|rocky*|almalinux*|ol) echo rhel ;;
    centos*) echo centos ;;
    alpine*) echo alpine ;;
    opensuse*) echo opensuse ;;
    sles*|sled*|suse*) echo sles ;;
    azurelinux*|mariner*|cbl-mariner*) echo azurelinux ;;
    *) echo "" ;;
  esac
}

# 只取版本号第一位数字（20.04 -> 2，12 -> 1）
first_digit() {
  printf '%s' "$1" | sed -n 's/^[^0-9]*\([0-9]\).*/\1/p' | head -n 1
}

# 下载并展平 true-list.json（逗号/花括号换行，便于按 key 定位）
load_true_list() {
  TL_FILE="$(mktemp 2>/dev/null || echo "/tmp/scweb-true-list.$$")"
  TL_FLAT="$(mktemp 2>/dev/null || echo "/tmp/scweb-true-list-flat.$$")"
  : > "$TL_FLAT"
  if download_file "$TRUE_LIST_URL" "$TL_FILE" && [ -s "$TL_FILE" ]; then
    tr -d '\r' < "$TL_FILE" | tr '\n' ' ' | tr 'A-Z' 'a-z' \
      | sed -e 's/,/\n/g' -e 's/{/\n/g' -e 's/}/\n/g' > "$TL_FLAT"
    return 0
  fi
  return 1
}

# 查某个发行版的最低版本首位数字（找不到输出空）
tl_min_digit() {
  _tl_alias="$1"
  [ -s "$TL_FLAT" ] || return 0

  # 只取该条目自身的数据：命中目标键后开始收集，遇到下一个发行版键即停止，
  # 避免把相邻条目的版本号（尤其 min 字段）误当成自己的要求。
  _tl_seg=""
  _tl_n=0
  _tl_go=0
  while IFS= read -r _tl_line; do
    case "$_tl_line" in
      *"\"$_tl_alias\""*) _tl_go=1 ;;
    esac
    [ "$_tl_go" -eq 1 ] || continue
    if [ "$_tl_n" -gt 0 ]; then
      case "$_tl_line" in
        *'"ubuntu"'*|*'"debian"'*|*'"fedora"'*|*'"rhel"'*|*'"centos"'*|*'"alpine"'*|*'"opensuse"'*|*'"sles"'*|*'"azurelinux"'*)
          break ;;
      esac
    fi
    _tl_seg="$_tl_seg $_tl_line"
    _tl_n=$((_tl_n + 1))
    [ "$_tl_n" -ge 4 ] && break
  done < "$TL_FLAT"

  [ -n "$_tl_seg" ] || return 0
  # 优先取 min / minVersion / minMajor 这类字段
  _tl_d="$(printf '%s' "$_tl_seg" | sed -n 's/.*"min[^"]*"[^0-9]*\([0-9]\).*/\1/p' | head -n 1)"
  if [ -n "$_tl_d" ]; then
    printf '%s' "$_tl_d"
    return 0
  fi
  # 否则取该条目出现的第一个数字
  printf '%s' "$_tl_seg" | sed -n 's/^[^0-9]*\([0-9]\).*/\1/p' | head -n 1
}

# 按 true-list.json 做系统版本门槛检查（容错：缺数据/未识别发行版均放行）
os_gate() {
  step "操作系统版本检查"

  _og_id="$(osrel_get ID)"
  _og_ver="$(osrel_get VERSION_ID)"
  _og_like="$(osrel_get ID_LIKE)"
  _og_pretty="$(osrel_get PRETTY_NAME)"

  _og_alias=""
  for _og_c in $_og_id $_og_like; do
    _og_alias="$(distro_alias "$_og_c")"
    [ -n "$_og_alias" ] && break
  done

  [ -n "$_og_pretty" ] && ok "系统 $_og_pretty"
  [ -n "$_og_ver" ] && ok "系统版本 $_og_ver"

  if [ -z "$_og_alias" ]; then
    note "未识别的发行版（${_og_id:-unknown}），跳过系统版本检查"
    return 0
  fi

  if ! load_true_list; then
    note "无法获取 true-list.json，跳过系统版本检查"
    return 0
  fi

  _og_min="$(tl_min_digit "$_og_alias")"
  if [ -z "$_og_min" ]; then
    note "true-list.json 中缺少 $_og_alias 的版本要求，跳过比较"
    return 0
  fi

  if [ -z "$_og_ver" ]; then
    note "无法读取当前系统版本号（要求首位数字 >= $_og_min），跳过比较"
    return 0
  fi

  _og_cur="$(first_digit "$_og_ver")"
  if [ -z "$_og_cur" ]; then
    note "无法解析系统版本号 $_og_ver，跳过比较"
    return 0
  fi

  if [ "$_og_cur" -ge "$_og_min" ] 2>/dev/null; then
    ok "系统版本检查通过（$_og_alias 版本首位数字 $_og_cur >= $_og_min）"
    return 0
  fi

  OS_LOW=1
  OS_LOW_MSG="操作系统版本过低（$_og_alias $_og_ver，最低要求首位数字 $_og_min）。面板本身兼容性极强，但运行生存战争服务端可能遇到问题，建议升级后再安装。"
  note "$OS_LOW_MSG"
  return 0
}

# 系统版本过低时询问是否强制安装（问题 3，可用 -3 y / -3 n 预填）
confirm_os_low() {
  [ "$OS_LOW" -eq 1 ] || return 0
  note "$OS_LOW_MSG"

  if [ -z "$PREFILL_3" ]; then
    if [ "$OPT_SILENT" -eq 1 ]; then
      FAIL_MSG="操作系统版本过低，已按安全默认中止安装；如确认继续，请追加参数 -3 y"
      return 1
    fi
    while :; do
      prompt_read "是否仍要继续安装？(y/n): "
      case "$REPLY" in
        y|Y|yes) note "已按用户要求继续安装（系统版本低于建议值）"; return 0 ;;
        n|N|no) FAIL_MSG="用户取消安装（操作系统版本过低）"; return 1 ;;
      esac
      printf '  请输入 y 或 n\n'
    done
  fi

  case "$PREFILL_3" in
    y|Y|yes) note "已按指定参数继续安装（系统版本低于建议值）"; return 0 ;;
  esac
  FAIL_MSG="用户取消安装（操作系统版本过低）"
  return 1
}

# -------------------- 安装标识记录（Linux 文件） --------------------
# 仅用于标识「这台机器装过 SCWebManager、最初装的是哪个版本」，供安装器识别；
# 面板自身的更新不会改写这里，所以版本永远是最初安装的版本。
# 文件：${XDG_CONFIG_HOME:-$HOME/.config}/scweb/installs.list
# 每行：目录<TAB>初始版本<TAB>安装时间

install_registry_file() {
  printf '%s/scweb/installs.list' "${XDG_CONFIG_HOME:-$HOME/.config}"
}

show_install_hint() {
  [ "$MUTE" -eq 1 ] && return 0
  _rf="$(install_registry_file)"
  [ -s "$_rf" ] || return 0
  note "本机已有 SCWebManager 安装记录（仅作标识，面板更新不会改动）："
  awk -F '\t' 'NF>=2 { printf "    %s（初始版本 %s）\n", $1, $2 }' "$_rf"
  note "多份安装共用 18233 / 18234 端口会冲突，建议只保留一份；仍可继续安装到其他目录。"
  return 0
}

record_install() {
  _rf="$(install_registry_file)"
  _rdir="$(printf '%s' "$INSTALL_DIR" | tr -d '\t')"
  _rver="${RESULT_VERSION:-unknown}"
  mkdir -p "$(dirname "$_rf")" 2>/dev/null || return 0
  if [ -f "$_rf" ] && awk -F '\t' -v d="$_rdir" '$1==d{f=1} END{exit f?0:1}' "$_rf"; then
    return 0
  fi
  printf '%s\t%s\t%s\n' "$_rdir" "$_rver" "$(date '+%Y-%m-%dT%H:%M:%S')" >> "$_rf" 2>/dev/null || true
  return 0
}

# -------------------------- 安装目录选择 --------------------------

# 目录是否可用：必须是绝对路径；已存在时必须是目录；不存在时父目录必须存在
_validate_dir() {
  _vd="$1"
  case "$_vd" in
    /*) : ;;
    *) return 1 ;;
  esac
  if [ -e "$_vd" ]; then
    [ -d "$_vd" ] || return 1
  else
    _vd_parent="$(dirname "$_vd" 2>/dev/null)"
    [ -n "$_vd_parent" ] && [ -d "$_vd_parent" ] || return 1
  fi
  return 0
}

select_dir() {
  step "选择安装目录"

  _default="$HOME/.local/share/scweb"
  if [ "$(id -u 2>/dev/null || echo 1000)" -eq 0 ]; then
    if mkdir -p /opt/scweb 2>/dev/null && [ -w /opt/scweb ]; then
      _default="/opt/scweb"
    fi
  fi

  # 预填（-1 <目录>）优先；静默模式没有预填则用默认目录
  if [ -n "$PREFILL_1" ]; then
    INSTALL_DIR="$(printf '%s' "$PREFILL_1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"//' -e 's/"$//')"
    [ "$MUTE" -eq 1 ] || printf '  使用指定目录：%s\n' "$INSTALL_DIR"
    return 0
  fi
  if [ "$OPT_SILENT" -eq 1 ]; then
    INSTALL_DIR="$_default"
    return 0
  fi

  show_install_hint

  while :; do
    printf '\n  请选择安装目录方式：\n'
    printf '    1) 使用默认目录（%s）\n' "$_default"
    printf '    2) 手动输入目录\n'
    prompt_read "  请输入 1 或 2（直接回车 = 1）: "
    _sel="$(printf '%s' "$REPLY" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    case "$_sel" in
      ""|1)
        INSTALL_DIR="$_default"
        printf '  安装目录：%s\n' "$INSTALL_DIR"
        return 0 ;;
      2)
        prompt_read "  请输入安装目录的完整路径: "
        _input="$(printf '%s' "$REPLY" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"//' -e 's/"$//')"
        if _validate_dir "$_input"; then
          INSTALL_DIR="$_input"
          printf '  安装目录：%s\n' "$INSTALL_DIR"
          return 0
        fi
        bad "路径无效：$_input"
        note "请重新选择（需为以 / 开头的绝对路径，且父目录存在）" ;;
      *)
        bad "输入无效：$_sel"
        note "请输入 1 或 2，直接回车使用默认目录" ;;
    esac
  done
}

# ---------------------------- 版本列表 ----------------------------

load_versions() {
  step "获取版本列表"
  ENTRIES_FILE="$(mktemp 2>/dev/null || echo "/tmp/scweb-versions.$$")"
  : > "$ENTRIES_FILE"

  _json=""
  _src=""

  # 1) 脚本同目录 versions.json
  if [ -n "${script_dir:-}" ] && [ -f "$script_dir/versions.json" ]; then
    _json="$script_dir/versions.json"
    _src="本地 $script_dir/versions.json"
  elif [ -f "./versions.json" ]; then
    _json="./versions.json"
    _src="本地 ./versions.json"
  fi

  if [ -n "$_json" ]; then
    parse_versions "$_json" "$ENTRIES_FILE"
    ok "使用$_src"
  else
    _tmpjson="$(mktemp 2>/dev/null || echo "/tmp/scweb-versions.json.$$")"
    if download_file "$VERSIONS_URL" "$_tmpjson"; then
      parse_versions "$_tmpjson" "$ENTRIES_FILE"
      LATEST_VERSION="$(extract_latest "$_tmpjson")"
      if [ -s "$ENTRIES_FILE" ]; then
        ok "已从仓库获取版本列表"
      else
        bad "仓库返回的版本列表为空"
      fi
      rm -f "$_tmpjson"
    else
      bad "无法获取版本列表"
      rm -f "$_tmpjson"
    fi
  fi

  if [ -s "$ENTRIES_FILE" ]; then
    if [ -z "$LATEST_VERSION" ] && [ -n "$_json" ]; then
      LATEST_VERSION="$(extract_latest "$_json")"
    fi
    if [ -z "$LATEST_VERSION" ]; then
      LATEST_VERSION="$(sort_entries "$ENTRIES_FILE" | head -n 1 | cut -f1)"
    fi
    return 0
  fi
  return 1
}

# 把 JSON 里的版本对象转成 "version<TAB>url<TAB>sha256" 行。
# 按当前机器架构取包：优先 "linux_<arch>" 与 "linux_<arch>_sha256"；
# amd64 机器仍兼容旧清单的单字段 "linux"（历史版本只有 x86_64 包）。
# 注意：清单要求每个版本对象独占一行（awk 按 } 切分）。
parse_versions() {
  _pv_json="$1"
  _pv_out="$2"
  tr '\r' '\n' < "$_pv_json" 2>/dev/null \
    | awk '{ gsub(/}/, "}\n"); print }' \
    | while IFS= read -r _line; do
        case "$_line" in
          *'"version"'*) ;;
          *) continue ;;
        esac
        _v="$(printf '%s' "$_line" | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
        [ -n "$_v" ] || continue
        _l=""
        _s=""
        if [ -n "${ARCH_KIND:-}" ]; then
          _l="$(printf '%s' "$_line" | sed -n "s/.*\"linux_${ARCH_KIND}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p")"
          _s="$(printf '%s' "$_line" | sed -n "s/.*\"linux_${ARCH_KIND}_sha256\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p")"
        fi
        if [ -z "$_l" ] && [ "${ARCH_KIND:-}" = "amd64" ]; then
          _l="$(printf '%s' "$_line" | sed -n 's/.*"linux"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
          _s="$(printf '%s' "$_line" | sed -n 's/.*"linux_sha256"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
          [ -n "$_s" ] || _s="$(printf '%s' "$_line" | sed -n 's/.*"sha256"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
        fi
        [ -n "$_l" ] || continue
        printf '%s\t%s\t%s\n' "$_v" "$_l" "$_s" >> "$_pv_out"
      done
}

extract_latest() {
  [ -n "$1" ] && [ -f "$1" ] || return 0
  tr '\r' '\n' < "$1" 2>/dev/null | tr -d '\n' \
    | sed -n 's/.*"latest"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
}

# 按版本号数值排序（新 → 旧），输出原始 "version<TAB>url<TAB>sha" 行
sort_entries() {
  awk -F'\t' '{
      n = split($1, a, "[.]");
      key = sprintf("%04d%04d%04d%04d", a[1] + 0, a[2] + 0, a[3] + 0, a[4] + 0);
      printf "%s\t%s\n", key, $0;
    }' "$1" | sort -r | cut -f2-
}

confirm_install() {
  while :; do
    prompt_read "是否立即开始安装？(y/n): "
    case "$REPLY" in
      y|Y) return 0 ;;
      n|N) return 1 ;;
    esac
    printf '  请输入 y 或 n\n'
  done
}

# 发行版渠道：Gitee 发布时可勾选「预览版（pre-release）」，这里查仓库的
# release 详情接口确认该版本是不是预览版。查不到（离线/接口限流/版本不存在）
# 就按正式版处理，静默跳过，不影响安装。
is_prerelease() {
  _ip_ver="$1"
  [ -n "$_ip_ver" ] || return 1
  _ip_body="$(curl -fsSL --max-time 10 "https://gitee.com/api/v5/repos/JIILStudio/jiilsc-web-manger/releases/tags/${_ip_ver}" 2>/dev/null || true)"
  [ -n "$_ip_body" ] || return 1
  printf '%s' "$_ip_body" | grep -Eq '"prerelease"[[:space:]]*:[[:space:]]*true'
}

# 预览版提示（正式版不输出任何内容；-json/静默模式不输出）
warn_prerelease() {
  _wp_ver="$1"
  is_prerelease "$_wp_ver" || return 0
  [ "$MUTE" -eq 1 ] && return 0
  sep
  note "当前版本 ${_wp_ver} 为预览版（pre-release）"
  note "预览版用于提前体验新功能，可能不稳定、功能缺失或出现数据异常"
  note "生产环境建议改用正式版：发布页中未标记「预览」的版本"
  sep
}

find_entry() {
  _fe_v="$1"
  sort_entries "$ENTRIES_FILE" | awk -F'\t' -v v="$_fe_v" '$1 == v { print; exit }'
}

select_version() {
  # 预填（-2 latest / -2 <版本号>）；静默模式没有预填则默认 latest
  _sv_pre="$PREFILL_2"
  if [ -z "$_sv_pre" ] && [ "$OPT_SILENT" -eq 1 ]; then
    _sv_pre="latest"
  fi
  if [ -n "$_sv_pre" ]; then
    if [ "$_sv_pre" = "latest" ] || [ "$_sv_pre" = "1" ]; then
      if [ -z "$LATEST_VERSION" ]; then
        FAIL_MSG="版本列表为空"
        return 1
      fi
      _entry="$(find_entry "$LATEST_VERSION")"
      if [ -z "$_entry" ]; then
        FAIL_MSG="版本列表中找不到最新版本 $LATEST_VERSION"
        return 1
      fi
      [ "$MUTE" -eq 1 ] || printf '  最新版本：%s\n' "$LATEST_VERSION"
      SELECTED_ENTRY="$_entry"
      return 0
    fi
    _entry="$(find_entry "$_sv_pre")"
    if [ -z "$_entry" ]; then
      FAIL_MSG="版本 $_sv_pre 不在版本列表中"
      return 1
    fi
    SELECTED_ENTRY="$_entry"
    return 0
  fi

  step "选择安装版本"
  while :; do
    printf '  1) 安装最新版本\n'
    printf '  0) 手动输入版本号\n'
    printf '  2) 列出全部版本\n'
    prompt_read "请选择 [1/0/2]: "
    _c="$(printf '%s' "$REPLY" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

    case "$_c" in
      1)
        if [ -z "$LATEST_VERSION" ]; then
          bad "版本列表为空"
          continue
        fi
        _entry="$(find_entry "$LATEST_VERSION")"
        if [ -z "$_entry" ]; then
          bad "版本列表中找不到最新版本 $LATEST_VERSION"
          continue
        fi
        printf '  最新版本：%s\n' "$LATEST_VERSION"
        if confirm_install; then
          SELECTED_ENTRY="$_entry"
          return 0
        fi
        ;;
      0)
        while :; do
          prompt_read "请输入版本号（输入 0 返回菜单）: "
          _v="$(printf '%s' "$REPLY" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
          if [ "$_v" = "0" ]; then break; fi
          _entry="$(find_entry "$_v")"
          if [ -n "$_entry" ]; then
            SELECTED_ENTRY="$_entry"
            return 0
          fi
          bad "版本 $_v 不在列表中，请重新输入"
        done
        ;;
      2)
        printf '  可用版本（新 → 旧）：\n'
        sort_entries "$ENTRIES_FILE" | while IFS="$(printf '\t')" read -r _ver _url _sha; do
          _tag=""
          [ "$_ver" = "$LATEST_VERSION" ] && _tag="   <- 最新"
          printf '    %s%s\n' "$_ver" "$_tag"
        done
        ;;
      *)
        printf '  输入无效，请输入 1、0 或 2\n'
        ;;
    esac
  done
}

# ---------------------------- 下载安装 ----------------------------

download_file() {
  _df_url="$1"
  _df_out="$2"
  if [ -n "${_curl:-}" ]; then
    curl -fsSL "$_df_url" -o "$_df_out" 2>/dev/null
    return $?
  fi
  if [ -n "${_wget:-}" ]; then
    wget -qO "$_df_out" "$_df_url" 2>/dev/null
    return $?
  fi
  return 1
}

install_version() {
  # $1 = entry ("version<TAB>url<TAB>sha")
  _iv_entry="$1"
  _iv_ver="$(printf '%s' "$_iv_entry" | cut -f1)"
  _iv_url="$(printf '%s' "$_iv_entry" | cut -f2)"
  _iv_sha="$(printf '%s' "$_iv_entry" | cut -f3)"

  step "下载并安装面板 $_iv_ver"
  if [ -z "$_iv_url" ]; then
    bad "该版本没有提供 Linux 安装包"
    return 1
  fi

  case "$_iv_url" in
    *.zip) _iv_kind="zip" ;;
    *.tar.gz|*.tgz) _iv_kind="tar" ;;
    *)
      bad "无法识别的安装包类型：$_iv_url"
      return 1 ;;
  esac
  if [ "$_iv_kind" = "zip" ] && [ -z "${_unzip:-}" ]; then
    bad "该安装包为 .zip，但系统没有 unzip（请先安装 unzip）"
    return 1
  fi
  if [ "$_iv_kind" = "tar" ] && [ -z "${_tar:-}" ]; then
    bad "该安装包为 .tar.gz，但系统没有 tar（请先安装 tar）"
    return 1
  fi

  _iv_tmp="$(mktemp -d 2>/dev/null || echo "/tmp/scweb-install.$$")"
  mkdir -p "$_iv_tmp" 2>/dev/null
  TMP_DIRS="$TMP_DIRS$_iv_tmp "
  _iv_pkg="$_iv_tmp/pkg"
  _iv_extract="$_iv_tmp/extract"

  [ "$MUTE" -eq 1 ] || printf '  下载：%s\n' "$_iv_url"
  if ! download_file "$_iv_url" "$_iv_pkg"; then
    bad "下载失败：$_iv_url"
    :  # 临时目录保留到安装结束统一清理
    return 1
  fi
  if [ ! -s "$_iv_pkg" ]; then
    bad "下载失败：文件为空"
    :  # 临时目录保留到安装结束统一清理
    return 1
  fi
  ok "下载完成"

  if [ -n "$_iv_sha" ]; then
    _iv_hash=""
    if command -v sha256sum >/dev/null 2>&1; then
      _iv_hash="$(sha256sum "$_iv_pkg" 2>/dev/null | cut -d ' ' -f1)"
    elif command -v shasum >/dev/null 2>&1; then
      _iv_hash="$(shasum -a 256 "$_iv_pkg" 2>/dev/null | cut -d ' ' -f1)"
    fi
    if [ -z "$_iv_hash" ]; then
      note "缺少 sha256sum，跳过校验"
    elif [ "$_iv_hash" != "$(printf '%s' "$_iv_sha" | tr 'A-Z' 'a-z')" ]; then
      bad "SHA256 校验失败（期望 $_iv_sha，实际 $_iv_hash）"
      :  # 临时目录保留到安装结束统一清理
      return 1
    else
      ok "SHA256 校验通过"
    fi
  fi

  mkdir -p "$_iv_extract"
  if [ "$_iv_kind" = "zip" ]; then
    if ! unzip -q "$_iv_pkg" -d "$_iv_extract" 2>/dev/null; then
      bad "解压失败（unzip）"
      :  # 临时目录保留到安装结束统一清理
      return 1
    fi
  else
    if ! tar xzf "$_iv_pkg" -C "$_iv_extract" 2>/dev/null; then
      bad "解压失败（tar）"
      :  # 临时目录保留到安装结束统一清理
      return 1
    fi
  fi

  _iv_found=0
  for _iv_item in "$_iv_extract"/*; do
    [ -e "$_iv_item" ] || continue
    _iv_found=1
    _iv_name="$(basename "$_iv_item")"
    if [ "$_iv_name" = "data" ] && [ -e "$INSTALL_DIR/data" ]; then
      note "保留已有用户数据目录：$INSTALL_DIR/data"
      continue
    fi
    if [ -d "$_iv_item" ]; then
      mkdir -p "$INSTALL_DIR/$_iv_name"
      if ! cp -R "$_iv_item/." "$INSTALL_DIR/$_iv_name/" 2>/dev/null; then
        bad "写入失败：$INSTALL_DIR/$_iv_name"
        :  # 临时目录保留到安装结束统一清理
        return 1
      fi
    else
      if ! cp -f "$_iv_item" "$INSTALL_DIR/$_iv_name" 2>/dev/null; then
        bad "写入失败：$INSTALL_DIR/$_iv_name"
        :  # 临时目录保留到安装结束统一清理
        return 1
      fi
    fi
  done

  if [ "$_iv_found" -eq 0 ]; then
    bad "安装包内容为空"
    :  # 临时目录保留到安装结束统一清理
    return 1
  fi

  chmod +x "$INSTALL_DIR"/scweb-panel "$INSTALL_DIR"/scweb-daemon "$INSTALL_DIR"/scweb-updater 2>/dev/null || true

  # 关键自检：三个二进制必须都在；写入后消失通常是安全策略/权限问题
  _iv_missing=""
  for _iv_b in scweb-panel scweb-daemon scweb-updater; do
    [ -f "$INSTALL_DIR/$_iv_b" ] || _iv_missing="$_iv_missing $_iv_b"
  done
  if [ -n "$_iv_missing" ]; then
    bad "安装后缺少：$_iv_missing"
    note "文件写入后被删除或未能落盘，请检查目录权限 / 安全软件拦截后重试"
    return 1
  fi

  ok "已安装到 $INSTALL_DIR"
  return 0
}

# 清理安装过程中产生的临时目录（安装成功或安装器退出前调用）
cleanup_tmp() {
  for _ct_d in $TMP_DIRS; do
    [ -n "$_ct_d" ] && rm -rf "$_ct_d" 2>/dev/null
  done
  TMP_DIRS=""
  return 0
}

# 安装（带重试）：失败时询问是否重试（静默/JSON 模式直接返回失败）
install_with_retry() {
  _iwr_entry="$1"
  _iwr_n=0
  while :; do
    _iwr_n=$((_iwr_n + 1))
    [ "$_iwr_n" -gt 1 ] && note "重新尝试安装（第 $_iwr_n 次）"
    install_version "$_iwr_entry" && return 0
    [ "$MUTE" -eq 1 ] && return 1
    prompt_read "  是否重试安装？(y/n): "
    _iwr_ans="$(printf '%s' "$REPLY" | tr 'A-Z' 'a-z' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    case "$_iwr_ans" in
      y|yes) continue ;;
      *) note "已放弃本次安装；可稍后手动下载安装包解压到 $INSTALL_DIR"; return 1 ;;
    esac
  done
}

# 启动面板（带失败后的处理菜单）：最终启动成功返回 0
start_panel_with_retry() {
  while :; do
    start_panel && return 0
    [ "$MUTE" -eq 1 ] && return 1
    printf '\n  面板未启动成功，请选择下一步：\n'
    printf '    1) 重新尝试启动（例如已修复端口占用）\n'
    printf '    2) 重新下载并安装该版本\n'
    printf '    0) 放弃并退出安装器\n'
    prompt_read "  请输入 1 / 2 / 0: "
    _spw="$(printf '%s' "$REPLY" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    case "$_spw" in
      1) continue ;;
      2) install_with_retry "${SELECTED_ENTRY:-}" || return 1; continue ;;
      0) FAIL_MSG="面板启动失败，已放弃安装"; return 1 ;;
      *) bad "输入无效，请输入 1 / 2 / 0" ;;
    esac
  done
}

# ---------------------------- 进程控制 ----------------------------

stop_panel() {
  _sp_count=0
  # 优先按 runtime.json 里已验证存活的 pid 结束
  if [ -n "${RUNTIME_PID:-}" ] && kill -0 "$RUNTIME_PID" 2>/dev/null; then
    kill "$RUNTIME_PID" 2>/dev/null && _sp_count=$((_sp_count + 1))
  fi
  RUNTIME_PID=""

  for _sp_pid in "${PANEL_PID:-}" "${DAEMON_PID:-}"; do
    [ -n "$_sp_pid" ] || continue
    if kill -0 "$_sp_pid" 2>/dev/null; then
      kill "$_sp_pid" 2>/dev/null && _sp_count=$((_sp_count + 1))
    fi
  done
  PANEL_PID=""
  DAEMON_PID=""

  # 兜底：按可执行文件绝对路径匹配
  if command -v pgrep >/dev/null 2>&1; then
    for _sp_pid in $(pgrep -f "$INSTALL_DIR/scweb-panel" 2>/dev/null) $(pgrep -f "$INSTALL_DIR/scweb-daemon" 2>/dev/null); do
      kill "$_sp_pid" 2>/dev/null && _sp_count=$((_sp_count + 1))
    done
  fi
  sleep 1 2>/dev/null || true
  STOPPED_COUNT="$_sp_count"
  return 0
}

# RFC3339 时间串 -> epoch 秒（失败输出空）
rfc_epoch() {
  _re_ts="$1"
  case "$_re_ts" in
    *Z) _re_ts="$(printf '%s' "$_re_ts" | sed 's/Z$/+00:00/')" ;;
  esac
  date -d "$_re_ts" +%s 2>/dev/null
}

# 校验 data/runtime.json：面板被强杀时 defer 不执行，会残留旧端口，
# 因此必须同时满足 startedAt 距今 <= 5 分钟、pid 进程仍存活（且不是脚本自己）。
# 有效时设置 RUNTIME_PID / RUNTIME_PORT 并返回 0。
valid_runtime() {
  _vr_f="$1"
  [ -f "$_vr_f" ] || return 1
  _vr_pid="$(sed -n 's/.*"pid"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$_vr_f" 2>/dev/null | head -n 1)"
  _vr_port="$(sed -n 's/.*"port"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$_vr_f" 2>/dev/null | head -n 1)"
  _vr_started="$(sed -n 's/.*"startedAt"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$_vr_f" 2>/dev/null | head -n 1)"
  [ -n "$_vr_pid" ] || return 1
  [ -n "$_vr_port" ] || return 1
  [ -n "$_vr_started" ] || return 1
  [ "$_vr_pid" -ne "$$" ] || return 1
  kill -0 "$_vr_pid" 2>/dev/null || return 1
  _vr_epoch="$(rfc_epoch "$_vr_started")"
  [ -n "$_vr_epoch" ] || return 1
  _vr_now="$(date +%s 2>/dev/null)"
  [ -n "$_vr_now" ] || return 1
  _vr_age=$((_vr_now - _vr_epoch))
  if [ "$_vr_age" -lt -30 ] || [ "$_vr_age" -gt 300 ]; then
    return 1
  fi
  RUNTIME_PID="$_vr_pid"
  RUNTIME_PORT="$_vr_port"
  return 0
}

fallback_port() {
  for _fp_cfg in "$INSTALL_DIR/data/config.json" "$INSTALL_DIR/config.json" "$INSTALL_DIR/run/config.json"; do
    [ -f "$_fp_cfg" ] || continue
    _fp_port="$(sed -n 's/.*"httpPort"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$_fp_cfg" 2>/dev/null | head -n 1)"
    if [ -n "$_fp_port" ]; then
      echo "$_fp_port"
      return 0
    fi
  done
  echo "$DEFAULT_PORT"
}

start_panel() {
  step "启动面板"
  if [ ! -f "$INSTALL_DIR/scweb-daemon" ]; then
    bad "未找到 $INSTALL_DIR/scweb-daemon，安装包结构异常"
    return 1
  fi
  if [ ! -f "$INSTALL_DIR/scweb-panel" ]; then
    bad "未找到 $INSTALL_DIR/scweb-panel，安装包结构异常"
    return 1
  fi

  stop_panel >/dev/null 2>&1
  rm -f "$INSTALL_DIR/data/runtime.json" 2>/dev/null

  _sp_pwd="$(pwd)"
  cd "$INSTALL_DIR" 2>/dev/null || {
    bad "无法进入安装目录 $INSTALL_DIR"
    return 1
  }
  nohup "$INSTALL_DIR/scweb-daemon" -dir "$INSTALL_DIR" >"$INSTALL_DIR/daemon.log" 2>&1 &
  DAEMON_PID=$!
  ok "守护进程已启动（pid $DAEMON_PID）"
  sleep 2

  nohup "$INSTALL_DIR/scweb-panel" >"$INSTALL_DIR/panel.log" 2>&1 &
  PANEL_PID=$!
  cd "$_sp_pwd" 2>/dev/null || true
  ok "面板进程已启动（pid $PANEL_PID）"

  _port=""
  RUNTIME_PID=""
  RUNTIME_PORT=""
  _i=0
  while [ "$_i" -lt 40 ]; do
    if valid_runtime "$INSTALL_DIR/data/runtime.json"; then
      _port="$RUNTIME_PORT"
      break
    fi
    sleep 0.5 2>/dev/null || sleep 1
    _i=$((_i + 1))
  done

  if [ -z "$_port" ]; then
    _port="$(fallback_port)"
    RUNTIME_PID=""
    note "runtime.json 无效或为上次运行残留（pid 不在运行 / startedAt 超时），回退使用配置端口 $_port"
  else
    ok "已从 runtime.json 读取端口 $_port（pid $RUNTIME_PID）"
  fi
  PANEL_URL="http://127.0.0.1:$_port"

  if ! kill -0 "$PANEL_PID" 2>/dev/null; then
    bad "面板进程提前退出，日志如下："
    if [ "$MUTE" -eq 0 ]; then
      tail -n 30 "$INSTALL_DIR/panel.log" 2>/dev/null || true
      tail -n 30 "$INSTALL_DIR/daemon.log" 2>/dev/null || true
    fi
    return 1
  fi
  return 0
}

# ---------------------------- 完成提示 ----------------------------

show_success() {
  [ "$MUTE" -eq 1 ] && return 0
  printf '\n'
  sep
  printf '  安装完成\n'
  sep
  printf '  面板地址：%s\n' "$PANEL_URL"
  printf '  安装目录：%s\n' "$INSTALL_DIR"
  printf '  运行日志：%s/panel.log / daemon.log\n' "$INSTALL_DIR"
  printf '\n'
  printf '  ⚠ 面板尚未配置超级用户，任何能访问该地址的人都可以创建超级用户，\n'
  printf '    请立即访问并设置密码。\n'
  sep
}

# ---------------------------- 驻留菜单 ----------------------------

menu() {
  while :; do
    printf '\n==================== 安装器菜单 ====================\n'
    printf '  0) 退出安装器\n'
    printf '  1) 立即终止面板\n'
    printf '  2) 重新拉取面板（同版本重装并启动）\n'
    prompt_read "请选择 [0/1/2]: "
    _c="$(printf '%s' "$REPLY" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

    case "$_c" in
      0)
        printf '\n已退出安装器。面板地址：%s\n' "$PANEL_URL"
        printf '后续可通过 %s/scweb-daemon 与 %s/scweb-panel 重新启动。\n' "$INSTALL_DIR" "$INSTALL_DIR"
        return 0
        ;;
      1)
        stop_panel
        if [ "$STOPPED_COUNT" -gt 0 ]; then
          ok "已终止面板进程（$STOPPED_COUNT 个）"
        else
          note "没有检测到正在运行的面板进程"
        fi
        PANEL_URL=""
        ;;
      2)
        if install_version "$SELECTED_ENTRY"; then
          if start_panel; then
            show_success
          else
            bad "重新启动失败，请查看 $INSTALL_DIR/panel.log"
          fi
        else
          bad "重新拉取失败，请检查网络后重试"
        fi
        ;;
      *)
        printf '  输入无效，请输入 0、1 或 2\n'
        ;;
    esac
  done
}

# ---------------------------- 主流程 ----------------------------

main() {
  banner

  script_dir=""
  if [ -n "${BASH_SOURCE:-}" ]; then
    script_dir="$(cd "$(dirname "$BASH_SOURCE")" 2>/dev/null && pwd)" || script_dir=""
  fi
  if [ -z "$script_dir" ]; then
    case "${0:-}" in
      *install.sh)
        script_dir="$(cd "$(dirname "$0")" 2>/dev/null && pwd)" || script_dir="" ;;
    esac
  fi

  if ! check_env; then
    FAIL_MSG="环境检查未通过，安装中止"
    [ "$MUTE" -eq 1 ] || printf '\n环境检查未通过，安装中止。请按上面的提示处理后重新运行。\n'
    return 1
  fi

  # 系统版本门槛（低于要求时询问是否强制安装，-3 y 可跳过询问）
  os_gate
  if ! confirm_os_low; then
    return 1
  fi

  select_dir
  if [ -z "$INSTALL_DIR" ]; then
    FAIL_MSG="安装目录无效"
    return 1
  fi

  if ! load_versions; then
    FAIL_MSG="无法获取版本列表"
    [ "$MUTE" -eq 1 ] || printf '\n无法获取版本列表（仓库可能尚未发布），请稍后重试或手动输入版本号。\n'
    return 1
  fi

  select_version || return 1
  if [ -z "${SELECTED_ENTRY:-}" ]; then
    [ -n "$FAIL_MSG" ] || FAIL_MSG="未选择安装版本"
    return 1
  fi
  RESULT_VERSION="$(printf '%s' "$SELECTED_ENTRY" | cut -f1)"
  warn_prerelease "$RESULT_VERSION"

  if ! install_with_retry "$SELECTED_ENTRY"; then
    FAIL_MSG="安装失败（下载或写入失败）"
    [ "$MUTE" -eq 1 ] || printf '\n安装失败。请检查网络后重试，或手动下载安装包解压到 %s\n' "$INSTALL_DIR"
    return 1
  fi

  if ! start_panel_with_retry; then
    FAIL_MSG="面板启动失败，请查看 $INSTALL_DIR/panel.log / daemon.log"
    [ "$MUTE" -eq 1 ] || printf '\n启动失败。请查看 %s/panel.log / daemon.log\n' "$INSTALL_DIR"
    return 1
  fi

  record_install
  show_success
  # 静默/JSON 模式不进入驻留菜单
  [ "$MUTE" -eq 1 ] && return 0
  menu
  return 0
}

parse_args "$@"
if [ "$OPT_HELP" -eq 1 ]; then
  usage
  exit 0
fi

RESULT=0
main || RESULT=1

cleanup_tmp

if [ -n "$TL_FILE" ]; then rm -f "$TL_FILE" 2>/dev/null || true; fi
if [ -n "$TL_FLAT" ]; then rm -f "$TL_FLAT" 2>/dev/null || true; fi

if [ "$OPT_JSON" -eq 1 ]; then
  _ok="false"
  if [ "$RESULT" -eq 0 ] && [ -z "$FAIL_MSG" ]; then _ok="true"; fi
  json_result "$_ok" "$FAIL_MSG"
elif [ "$OPT_SILENT" -eq 1 ]; then
  if [ "$RESULT" -eq 0 ] && [ -z "$FAIL_MSG" ]; then
    printf '安装完成：版本 %s  面板 %s  目录 %s\n' "$RESULT_VERSION" "$PANEL_URL" "$INSTALL_DIR"
  else
    printf '安装失败：%s\n' "$FAIL_MSG"
  fi
fi

exit "$RESULT"
