#!/bin/sh
# Interactive initializer loaded only by: cloudflare-ddns init
set -f
umask 077
# Keep init self-contained when it is run from Merlin's restricted DDNS hook.
# Do not rely on the parent launcher retaining its PATH while sourcing us.
PATH="${PATH:-/sbin:/bin:/usr/sbin:/usr/bin}:/opt/bin:/opt/sbin"
export PATH
CURL_BIN=${CURL_BIN:-curl}
[ ! -x /usr/sbin/curl ] || CURL_BIN=/usr/sbin/curl
CONFIG_FILE=${CONFIG_FILE:-"$SCRIPT_DIR/cloudflare-ddns.conf"}
if [ "${1:-}" = --config ]; then
    [ "$#" -eq 2 ] || { printf '%s\n' 'Usage: cloudflare-ddns init [--config FILE]' >&2; exit 2; }
    CONFIG_FILE=$2
    shift 2
elif [ "$#" -ne 0 ]; then
    printf '%s\n' 'Usage: cloudflare-ddns init [--config FILE]' >&2
    exit 2
fi

init_die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
init_has_command() { type "$1" >/dev/null 2>&1; }
init_require() {
    for init_tool do init_has_command "$init_tool" || init_die "Missing dependency: $init_tool"; done
}
init_ask() (
    printf '%s [%s]: ' "$1" "$2" >&2
    IFS= read -r init_answer || exit 1
    printf '%s\n' "${init_answer:-$2}"
)
init_secret() {
    init_label=$1
    init_has_old=$2
    if [ -t 0 ] && init_has_command stty; then
        printf '%s%s: ' "$init_label" "$( [ "$init_has_old" = yes ] && printf '（回车保留现有值）' )" >&2
        init_old_stty=$(stty -g 2>/dev/null) || init_old_stty=
        [ -z "$init_old_stty" ] || stty -echo
        IFS= read -r init_secret_value
        init_status=$?
        [ -z "$init_old_stty" ] || stty "$init_old_stty"
        printf '\n' >&2
        [ "$init_status" -eq 0 ] || return 1
    else
        printf '%s%s: ' "$init_label" "$( [ "$init_has_old" = yes ] && printf '（回车保留现有值）' )" >&2
        IFS= read -r init_secret_value || return 1
    fi
}
init_confirm() (
    printf '%s 输入 yes 确认: ' "$1" >&2
    IFS= read -r init_answer || exit 1
    [ "$init_answer" = yes ]
)
init_positive() { printf '%s\n' "$1" | grep -Eq '^[1-9][0-9]{0,8}$'; }
init_shell_quote() (
    # Single-quoted POSIX-shell literal. Newlines are forbidden by validation.
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
)

init_require jq curl mktemp grep sed mkdir chmod mv dirname
[ "$CONFIG_FILE" != / ] && [ -n "$CONFIG_FILE" ] && [ ! -L "$CONFIG_FILE" ] || init_die 'Unsafe configuration path'
init_parent=$(dirname -- "$CONFIG_FILE")
[ -d "$init_parent" ] || init_die 'Configuration directory does not exist'
init_target=$CONFIG_FILE

# Existing common configuration is trusted in the same way as normal updates.
init_old_token=
init_old_zone=
init_old_conf_dir="$SCRIPT_DIR/conf.d"
init_old_state="$SCRIPT_DIR/cloudflare-ddns.state"
init_old_log_level=info
init_old_log_tag=cloudflare-ddns
init_old_log_file=
init_old_refresh=43200
init_old_connect=5
init_old_timeout=10
init_old_bark_url=https://api.day.app
init_old_bark_key=
init_old_bark_title=cloudflare-ddns
init_old_bark_group=
if [ -r "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    . "$CONFIG_FILE" || init_die 'Existing common configuration could not be loaded'
    init_old_token=${CF_API_TOKEN:-}
    init_old_zone=${CF_ZONE_ID:-}
    init_old_conf_dir=${CONF_DIR:-$init_old_conf_dir}
    init_old_state=${STATE_FILE:-$init_old_state}
    init_old_log_level=${LOG_LEVEL:-$init_old_log_level}
    init_old_log_tag=${LOG_TAG:-$init_old_log_tag}
    init_old_log_file=${LOG_FILE:-$init_old_log_file}
    init_old_refresh=${REFRESH_INTERVAL_SECONDS:-${NO_CHANGE_WINDOW_SECONDS:-$init_old_refresh}}
    init_old_connect=${HTTP_CONNECT_TIMEOUT_SECONDS:-$init_old_connect}
    init_old_timeout=${HTTP_TIMEOUT_SECONDS:-$init_old_timeout}
    init_old_bark_url=${BARK_URL:-$init_old_bark_url}
    init_old_bark_key=${BARK_KEY:-$init_old_bark_key}
    init_old_bark_title=${BARK_TITLE:-$init_old_bark_title}
    init_old_bark_group=${BARK_GROUP:-$init_old_bark_group}
fi
# A trusted old file may assign CONFIG_FILE; the command-line target still wins.
CONFIG_FILE=$init_target

if [ -n "$init_old_token" ]; then init_secret 'Cloudflare API Token' yes || exit 1
else init_secret 'Cloudflare API Token' no || exit 1; fi
init_token=${init_secret_value:-$init_old_token}
printf '%s\n' "$init_token" | grep -Eq '^[A-Za-z0-9_-]+$' || init_die 'Invalid or missing Cloudflare API Token'

init_zones='[]'
init_page=1
while :; do
    init_response=$(
        printf 'header = "Authorization: Bearer %s"\n' "$init_token" |
            "$CURL_BIN" -q --config - --silent --show-error --connect-timeout 5 --max-time 15 \
                --url "https://api.cloudflare.com/client/v4/zones?per_page=50&page=$init_page" \
                --write-out '\n__DDNS_HTTP__%{http_code}' 2>/dev/null
    ) || init_die 'Could not query Cloudflare Zones'
    init_status=${init_response##*__DDNS_HTTP__}
    init_body=${init_response%__DDNS_HTTP__*}
    [ "$init_status" = 200 ] && printf '%s' "$init_body" |
        jq -e '.success==true and (.result|type=="array")' >/dev/null 2>&1 ||
        init_die "Cloudflare Zone query failed (HTTP $init_status); response suppressed"
    init_page_zones=$(printf '%s' "$init_body" |
        jq -c '[.result[] | select(.id|type=="string") | select(.name|type=="string") | {id,name,status:(.status//"unknown")}]') || exit 1
    init_zones=$(jq -cn --argjson old "$init_zones" --argjson new "$init_page_zones" '$old+$new') || exit 1
    init_total_pages=$(printf '%s' "$init_body" | jq -r '.result_info.total_pages // 1') || exit 1
    printf '%s\n' "$init_total_pages" | grep -Eq '^[0-9]{1,4}$' || init_die 'Cloudflare returned invalid pagination metadata'
    [ "$init_page" -lt "$init_total_pages" ] || break
    init_page=$((init_page + 1))
done
init_count=$(printf '%s' "$init_zones" | jq length) || exit 1
[ "$init_count" -gt 0 ] || init_die 'Token has no visible Zones; grant Zone Read for the intended Zone'
printf '\n可用 Cloudflare Zone：\n' >&2
printf '%s' "$init_zones" | jq -r 'to_entries[] | "  \(.key+1). \(.value.name)  [\(.value.status)]"' >&2
init_old_index=$(printf '%s' "$init_zones" | jq -r --arg id "$init_old_zone" 'map(.id)|index($id)|if .==null then empty else .+1 end')
init_zone_choice=$(init_ask '选择序号' "${init_old_index:-1}") || exit 1
printf '%s\n' "$init_zone_choice" | grep -Eq '^[1-9][0-9]*$' || init_die 'Invalid Zone selection'
[ "$init_zone_choice" -le "$init_count" ] || init_die 'Zone selection is outside the list'
init_zone=$(printf '%s' "$init_zones" | jq -c --argjson index "$((init_zone_choice - 1))" '.[$index]') || exit 1
init_zone_id=$(printf '%s' "$init_zone" | jq -r .id)
init_zone_name=$(printf '%s' "$init_zone" | jq -r .name)
printf '%s\n' "$init_zone_id" | grep -Eq '^[A-Za-z0-9_-]{1,128}$' || init_die 'Cloudflare returned an invalid Zone ID'

init_conf_dir=$(init_ask '记录目录 CONF_DIR' "$init_old_conf_dir") || exit 1
init_state=$(init_ask '状态文件 STATE_FILE' "$init_old_state") || exit 1
init_log_level=$(init_ask '日志级别 debug/info/error' "$init_old_log_level") || exit 1
case "$init_log_level" in debug|info|error) ;; *) init_die 'Invalid log level' ;; esac
init_log_tag=$(init_ask '系统日志标签' "$init_old_log_tag") || exit 1
init_log_file=$(init_ask '额外日志文件（- 表示不使用）' "${init_old_log_file:--}") || exit 1
[ "$init_log_file" != - ] || init_log_file=
init_refresh=$(init_ask '地址不变时的重新提交间隔（秒）' "$init_old_refresh") || exit 1
init_connect=$(init_ask 'HTTP 连接超时（秒）' "$init_old_connect") || exit 1
init_timeout=$(init_ask 'HTTP 总超时（秒）' "$init_old_timeout") || exit 1
for init_number in "$init_refresh" "$init_connect" "$init_timeout"; do init_positive "$init_number" || init_die 'Timeouts must be positive integers'; done
[ "$init_timeout" -ge "$init_connect" ] || init_die 'HTTP total timeout must be at least the connect timeout'

if [ -n "$init_old_bark_key" ]; then init_bark_default=y; else init_bark_default=n; fi
init_bark=$(init_ask '启用 Bark 通知? y/n' "$init_bark_default") || exit 1
case "$init_bark" in
    y|Y)
        init_bark_url=$(init_ask 'Bark URL' "$init_old_bark_url") || exit 1
        if [ -n "$init_old_bark_key" ]; then init_secret 'Bark Key' yes || exit 1
        else init_secret 'Bark Key' no || exit 1; fi
        init_bark_key=${init_secret_value:-$init_old_bark_key}
        [ -n "$init_bark_key" ] || init_die 'Missing Bark Key'
        init_bark_title=$(init_ask 'Bark 标题' "$init_old_bark_title") || exit 1
        init_bark_group=$(init_ask 'Bark 分组（- 表示不使用）' "${init_old_bark_group:--}") || exit 1
        [ "$init_bark_group" != - ] || init_bark_group= ;;
    n|N)
        init_bark_url=$init_old_bark_url; init_bark_key=; init_bark_title=$init_old_bark_title; init_bark_group= ;;
    *) init_die 'Please enter y or n' ;;
esac

for init_text in "$init_conf_dir" "$init_state" "$init_log_tag" "$init_log_file" "$init_bark_url" "$init_bark_key" "$init_bark_title" "$init_bark_group"; do
    case "$init_text" in
        *'
'*) init_die 'Configuration values cannot contain line breaks' ;;
    esac
    printf '%s' "$init_text" | LC_ALL=C grep -q "$(printf '\r')" &&
        init_die 'Configuration values cannot contain line breaks'
done
[ -n "$init_conf_dir" ] && [ "$init_conf_dir" != / ] && [ ! -L "$init_conf_dir" ] || init_die 'Unsafe CONF_DIR'
[ -n "$init_state" ] && [ "$init_state" != / ] && [ ! -L "$init_state" ] || init_die 'Unsafe STATE_FILE'

init_candidate=$(mktemp "$init_parent/.cloudflare-ddns.conf.XXXXXX") || exit 1
init_candidate_live=1
init_cleanup() {
    [ "${init_candidate_live:-0}" -eq 0 ] || rm -f -- "$init_candidate"
    [ -z "${init_old_stty:-}" ] || stty "$init_old_stty" 2>/dev/null || :
}
trap init_cleanup 0
trap 'exit 130' INT
trap 'exit 143' TERM HUP
{
    printf '# Generated by cloudflare-ddns init. Re-run init instead of editing this file.\n'
    printf 'CF_API_TOKEN=%s\n' "$(init_shell_quote "$init_token")"
    printf 'CF_ZONE_ID=%s\n' "$(init_shell_quote "$init_zone_id")"
    printf 'CONF_DIR=%s\n' "$(init_shell_quote "$init_conf_dir")"
    printf 'STATE_FILE=%s\n' "$(init_shell_quote "$init_state")"
    printf 'LOG_LEVEL=%s\n' "$(init_shell_quote "$init_log_level")"
    printf 'LOG_TAG=%s\n' "$(init_shell_quote "$init_log_tag")"
    printf 'LOG_FILE=%s\n' "$(init_shell_quote "$init_log_file")"
    printf 'REFRESH_INTERVAL_SECONDS=%s\n' "$(init_shell_quote "$init_refresh")"
    printf 'HTTP_CONNECT_TIMEOUT_SECONDS=%s\n' "$(init_shell_quote "$init_connect")"
    printf 'HTTP_TIMEOUT_SECONDS=%s\n' "$(init_shell_quote "$init_timeout")"
    printf 'BARK_URL=%s\n' "$(init_shell_quote "$init_bark_url")"
    printf 'BARK_KEY=%s\n' "$(init_shell_quote "$init_bark_key")"
    printf 'BARK_TITLE=%s\n' "$(init_shell_quote "$init_bark_title")"
    printf 'BARK_GROUP=%s\n' "$(init_shell_quote "$init_bark_group")"
} > "$init_candidate" || exit 1
chmod 600 "$init_candidate" || exit 1
sh -n "$init_candidate" || init_die 'Generated configuration failed shell syntax validation'

printf '\n全局配置预览：\n' >&2
printf '  配置文件: %s\n' "$CONFIG_FILE" >&2
printf '  Cloudflare Token: <已隐藏>\n  Zone: %s\n  CONF_DIR: %s\n  STATE_FILE: %s\n' "$init_zone_name" "$init_conf_dir" "$init_state" >&2
printf '  LOG_LEVEL: %s\n  LOG_FILE: %s\n  刷新间隔: %s 秒\n  HTTP 超时: %s/%s 秒\n' \
    "$init_log_level" "${init_log_file:--}" "$init_refresh" "$init_connect" "$init_timeout" >&2
if [ -n "$init_bark_key" ]; then printf '  Bark: 已启用（Key 已隐藏）\n' >&2; else printf '  Bark: 未启用\n' >&2; fi
init_confirm '确认写入以上配置?' || exit 1
mkdir -p -- "$init_conf_dir" || init_die 'CONF_DIR could not be created; global configuration was not changed'
mv -f -- "$init_candidate" "$CONFIG_FILE" || exit 1
init_candidate_live=0
chmod 600 "$CONFIG_FILE" || exit 1
printf '初始化完成：%s（权限 600）。下一步运行 cloudflare-ddns config。\n' "$CONFIG_FILE"
exit 0
