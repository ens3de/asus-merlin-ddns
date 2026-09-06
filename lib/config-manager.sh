#!/bin/sh
# Configuration-manager module, loaded only by: cloudflare-ddns config
# All writes are validated, compact and atomic.
set -f
umask 077
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P) || exit 1
LIB_DIR="$SCRIPT_DIR/lib"
. "$LIB_DIR/common.sh"
. "$LIB_DIR/sources.sh"
. "$LIB_DIR/providers.sh"
CONFIG_FILE=${CONFIG_FILE:-"$SCRIPT_DIR/cloudflare-ddns.conf"}
if [ "${1:-}" = --config ]; then
    [ "$#" -ge 2 ] || exit 2
    CONFIG_FILE=$2; shift 2
fi
if [ "${1:-}" = --help ]; then
    printf '%s\n' 'cloudflare-ddns config [--config FILE] [COMMAND]' \
        'No command: interactive menu.' \
        'list | add | edit [DOMAIN]' \
        'enable [DOMAIN] | disable [DOMAIN] | delete [DOMAIN]' \
        'import DOMAIN FILE: import as a NEW disabled draft (never execute JSON).'
    exit 0
fi
load_settings || exit 2
require_tools jq cksum || exit 2
mkdir -p "$CONF_DIR" || exit 1
WORK_DIR=$(make_temp_dir "${TMPDIR:-/tmp}" ddns-manager) || exit 1
LOCK_HELD=0
cleanup() {
    [ "$LOCK_HELD" -eq 0 ] || release_config_lock
    [ -z "$WORK_DIR" ] || rm -rf -- "$WORK_DIR"
}
trap cleanup 0
trap 'exit 130' INT
trap 'exit 143' TERM HUP

task_path() (
    valid_task_name "$1" || { log error 'Identifier must be a canonical domain name'; exit 1; }
    printf '%s/%s.json\n' "$CONF_DIR" "$1"
)
existing_task() (
    path=$(task_path "$1") || exit 1
    [ -f "$path" ] && [ ! -L "$path" ] || { log error 'Task not found or is a symlink'; exit 1; }
    printf '%s\n' "$path"
)
fingerprint() { cksum < "$1"; }
ask() (
    printf '%s [%s]: ' "$1" "$2" >&2
    IFS= read -r answer || exit 1
    printf '%s\n' "${answer:-$2}"
)
ask_explicit() (
    printf '%s: ' "$1" >&2
    IFS= read -r answer || exit 1
    [ -n "$answer" ] || exit 2
    printf '%s\n' "$answer"
)
confirm() (
    printf '%s 输入 yes 确认: ' "$1" >&2
    IFS= read -r answer || exit 1
    [ "$answer" = yes ]
)
task_names() (
    set +f
    for file in "$CONF_DIR"/*.json; do
        [ -f "$file" ] && [ ! -L "$file" ] || continue
        task=${file##*/}; task=${task%.json}
        valid_task_name "$task" || continue
        printf '%s\n' "$task"
    done
)

configured_domain_names() (
    set +f
    for file in "$CONF_DIR"/*.json; do
        [ -f "$file" ] && [ ! -L "$file" ] || continue
        validate_record "$file" || continue
        jq -r '.name|ascii_downcase|rtrimstr(".")' "$file" 2>/dev/null || continue
    done | jq -Rsc 'split("\n") | map(select(length>0)) | unique'
)

record_local_content() (
    family=$1; source=$2
    type=$(printf '%s' "$source" | jq -r '.type') || exit 1
    case "$type" in
        argument) printf '%s\n' '<runtime-argument>' ;;
        http) printf '%s\n' '<http-source-not-queried>' ;;
        *) resolve_source "$family" "$source" 2>/dev/null || printf '%s\n' '<unresolved-locally>' ;;
    esac
)

list_tasks() (
    printf '\n已有 DDNS 配置：\n'
    # Header widths compensate for CJK display width; row values are ASCII DNS/IP.
    printf '%-4s %-62s %-8s %-46s %s\n' '序号' '域名' '类型' '当前 IP（本地）' '状态'
    number=0
    set +f
    for file in "$CONF_DIR"/*.json; do
        [ -f "$file" ] && [ ! -L "$file" ] || continue
        task=${file##*/}; task=${task%.json}
        if validate_record "$file"; then
            number=$((number + 1))
            name=$(jq -r '.name' "$file")
            state=$(jq -r 'if .enabled then "启用" else "停用" end' "$file")
            if [ "${#name}" -gt 60 ]; then
                short_name=$(printf '%.57s...' "$name")
            else
                short_name=$name
            fi
            first=yes
            for family in A AAAA; do
                source=$(jq -c --arg family "$family" '.[$family].source // empty' "$file")
                [ -n "$source" ] || continue
                content=$(record_local_content "$family" "$source")
                if [ "$first" = yes ]; then
                    printf '%-4s %-60s %-6s %-40s %s\n' "$number" "$short_name" "$family" "$content" "$state"
                    first=no
                else
                    printf '%-4s %-60s %-6s %-40s %s\n' '' '' "$family" "$content" ''
                fi
            done
        else printf '!. %s（配置无效）\n' "$task"; fi
    done
    [ "$number" -gt 0 ] || printf '  （暂无配置）\n'
    printf '\n'
)

choose_existing_task() (
    show_list=${1:-yes}
    [ "$show_list" = yes ] && list_tasks >&2
    tasks=$(task_names)
    count=$(printf '%s\n' "$tasks" | awk 'NF{n++} END{print n+0}')
    [ "$count" -gt 0 ] || { log error 'No existing DDNS configuration'; exit 1; }
    choice=$(ask_explicit '选择配置序号') || { log error 'A configuration selection is required'; exit 1; }
    printf '%s\n' "$choice" | grep -Eq '^[1-9][0-9]*$' || { log error 'Invalid configuration selection'; exit 1; }
    [ "$choice" -le "$count" ] || { log error 'Configuration selection is outside the list'; exit 1; }
    printf '%s\n' "$tasks" | sed -n "${choice}p"
)

choose_domain() (
    provider_validate_settings || exit 1
    require_tools curl || exit 1
    zone=$(provider_zone_name cloudflare) || exit 1
    names=$(provider_list_domain_names cloudflare "$zone") || exit 1
    configured=$(configured_domain_names) || exit 1
    names=$(printf '%s' "$names" | jq -c --argjson configured "$configured" \
        '[.[] as $name | select(($configured | index($name)) | not) | $name]') || exit 1
    count=$(printf '%s' "$names" | jq -r length) || exit 1
    printf '\n%s Zone 中已有的域名：\n' "$zone" >&2
    if [ "$count" -gt 0 ]; then
        printf '%s' "$names" | jq -r 'to_entries[] | "  \(.key+1). \(.value)"' >&2
    else
        printf '  （暂无 DNS 记录）\n' >&2
    fi
    new_number=$((count + 1))
    printf '  %s. 新增域名\n' "$new_number" >&2
    choice=$(ask_explicit '选择序号') || { log error 'A domain selection is required'; exit 1; }
    printf '%s\n' "$choice" | grep -Eq '^[1-9][0-9]*$' || { log error 'Invalid domain selection'; exit 1; }
    [ "$choice" -le "$new_number" ] || { log error 'Domain selection is outside the list'; exit 1; }
    if [ "$choice" -le "$count" ]; then
        printf '%s' "$names" | jq -r --argjson index "$((choice - 1))" '.[$index]'
        exit
    fi
    printf '\n新增域名：\n  示例: abc -> abc.%s\n  根域: 输入 @\n' "$zone" >&2
    host=$(ask_explicit '输入主机名') || { log error 'Host name is required'; exit 1; }
    host=$(printf '%s\n' "$host" | jq -Rr 'ascii_downcase|rtrimstr(".")') || exit 1
    if [ "$host" = @ ]; then
        domain=$zone
    else
        [ -n "$host" ] || { log error 'Host name cannot be empty'; exit 1; }
        case "$host" in
            "$zone"|*."$zone") log error 'Enter only the relative host name, not the full domain'; exit 1 ;;
        esac
        domain="$host.$zone"
    fi
    valid_domain_name "$domain" || { log error 'Invalid host name'; exit 1; }
    printf '%s\n' "$domain"
)

# expected is NEW or a checksum taken BEFORE the user's edit dialog.
commit_record() (
    task=$1; candidate=$2; expected=$3
    destination=$(task_path "$task") || exit 1
    validate_record "$candidate" || exit 1
    acquire_config_lock || exit 1
    stage=
    temporary=
    finish() {
        [ -z "$stage" ] || rm -rf -- "$stage"
        [ -z "$temporary" ] || rm -f -- "$temporary"
        release_config_lock
    }
    trap finish 0
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    if [ "$expected" = NEW ]; then
        [ ! -e "$destination" ] && [ ! -L "$destination" ] || { log error 'Task already exists'; exit 1; }
    else
        [ -f "$destination" ] && [ ! -L "$destination" ] && [ "$(fingerprint "$destination")" = "$expected" ] || {
            log error 'Task changed during editing; reopen it to avoid overwriting another change'; exit 1;
        }
    fi
    validate_directory "$CONF_DIR" || exit 1
    stage=$(make_temp_dir "$WORK_DIR" ddns-stage) || exit 1
    set +f
    for file in "$CONF_DIR"/*.json; do [ ! -f "$file" ] || cp "$file" "$stage/" || exit 1; done
    jq -c . "$candidate" > "$stage/$task.json" || exit 1
    validate_directory "$stage" || exit 1
    temporary=$(make_temp_file "$CONF_DIR" "$task") || exit 1
    cp "$stage/$task.json" "$temporary" && chmod 600 "$temporary" && mv -f -- "$temporary" "$destination" || exit 1
    printf '已保存 %s（紧凑 JSON）。启用的任务将在下次 DDNS 执行时生效。\n' "$task"
)

associate_record_id() (
    family=$1; domain=$2; previous=$3
    provider_validate_settings || exit 1
    require_tools curl || exit 1
    records=$(provider_list_records cloudflare "$domain" "$family") || exit 1
    count=$(printf '%s' "$records" | jq -r length) || exit 1
    if [ "$count" -eq 0 ]; then
        printf '%s\n' '__CREATE_AFTER_CONFIRM__'
        exit 0
    fi
    old_id=$(printf '%s' "$previous" | jq -r '.id // ""')
    if [ -n "$old_id" ] && [ "$old_id" != '__CREATE_AFTER_CONFIRM__' ]; then
        selected=$(printf '%s' "$records" | jq -c --arg id "$old_id" 'map(select(.id==$id)) | if length==1 then .[0] else empty end')
    elif [ "$count" -eq 1 ]; then
        selected=$(printf '%s' "$records" | jq -c '.[0]')
    else
        log error "Multiple $family records exist for $domain; automatic association is ambiguous"
        exit 1
    fi
    [ -n "$selected" ] || { log error "The configured $family record is no longer available for $domain"; exit 1; }
    if printf '%s' "$selected" | jq -e '.proxied == true' >/dev/null; then
        log error 'The matching record is proxied. Change it to DNS-only in Cloudflare first.'
        exit 1
    fi
    printf '%s' "$selected" | jq -r '.id'
)

choose_interface() (
    family=$1; previous=$2
    candidates=$(available_interface_addresses "$family") || exit 1
    choices=$(printf '%s\n' "$candidates" | jq -Rsc '
        split("\n") | map(select(length>0) | split("\t"))
        | group_by(.[0])
        | map({interface: .[0][0], addresses: (map(.[1]) | unique)})') || exit 1
    count=$(printf '%s' "$choices" | jq -r length) || exit 1
    printf '\n可用的本机 %s 网卡：\n' "$family" >&2
    if [ "$count" -gt 0 ]; then
        printf '%s' "$choices" | jq -r 'to_entries[] |
            "  \(.key + 1). \(.value.interface)  \(.value.addresses | join(", "))"' >&2
    else
        printf '  （当前设备没有可用的公网 %s 地址）\n' "$family" >&2
    fi
    manual_number=$((count + 1))
    printf '  %s. 手动输入网卡名称（为其他设备准备配置）\n' "$manual_number" >&2
    default=
    if [ -n "$previous" ]; then
        previous_index=$(printf '%s' "$choices" | jq -r --arg interface "$previous" \
            'map(.interface) | index($interface) // empty') || exit 1
        [ -z "$previous_index" ] || default=$((previous_index + 1))
    fi
    if [ -n "$default" ]; then
        choice=$(ask '选择本机网卡' "$default") || exit 1
    else
        choice=$(ask_explicit '选择本机网卡') || { log error 'An interface selection is required'; exit 1; }
    fi
    printf '%s\n' "$choice" | grep -Eq '^[1-9][0-9]*$' || { log error 'Invalid interface selection'; exit 1; }
    [ "$choice" -le "$manual_number" ] || { log error 'Interface selection is outside the list'; exit 1; }
    if [ "$choice" -eq "$manual_number" ]; then
        interface=$(ask_explicit '输入网卡名称') || { log error 'An interface name is required'; exit 1; }
        printf '%s\n' "$interface"
        exit 0
    fi
    printf '%s' "$choices" | jq -r --argjson index "$((choice - 1))" '.[$index].interface'
)

build_family() (
    family=$1; previous=$2; domain=$3
    default_type=$(printf '%s' "$previous" | jq -r '.source.type // "interface"')
    case "$default_type" in
        argument) default_source=1 ;; interface) default_source=2 ;; http) default_source=3 ;;
        prefix_iid) default_source=4 ;; *) default_source=2 ;;
    esac
    printf '\n%s 地址来源：\n' "$family" >&2
    printf '%s\n' \
        '  1. 命令参数' \
        '     地址由运行脚本时的 --ipv4/--ipv6 或 Merlin 参数传入；不会自动探测。' \
        '  2. 本机网卡' \
        '     从运行 DDNS 的这台设备指定网卡读取公网地址。' \
        '  3. HTTP 查询' \
        '     请求外部 IP 查询服务；得到的是该请求实际使用的出口地址。' >&2
    if [ "$family" = AAAA ]; then
        printf '%s\n' \
            '  4. LAN 前缀 + 固定 IID' \
            '     从本机 LAN 网卡取得 /64 前缀，再拼接目标设备固定后 64 位。' >&2
    fi
    source_choice=$(ask '选择来源' "$default_source") || exit 1
    case "$source_choice" in
        1) type=argument ;; 2) type=interface ;; 3) type=http ;;
        4) [ "$family" = AAAA ] && type=prefix_iid || { log error 'Source 4 is only available for AAAA'; exit 1; } ;;
        *) log error 'Invalid source selection'; exit 1 ;;
    esac
    case "$type" in
        argument) source='{"type":"argument"}' ;;
        interface)
            previous_interface=$(printf '%s' "$previous" | jq -r '.source.interface // ""') || exit 1
            interface=$(choose_interface "$family" "$previous_interface") || exit 1
            source=$(jq -nc --arg interface "$interface" '{type:"interface",interface:$interface}') ;;
        prefix_iid)
            [ "$family" = AAAA ] || { log error 'prefix_iid only supports AAAA'; exit 1; }
            interface=$(ask 'LAN 网卡（请先确认）' "$(printf '%s' "$previous" | jq -r '.source.interface // "br0"')") || exit 1
            iid=$(ask '固定后 64 位（四组十六进制）' "$(printf '%s' "$previous" | jq -r '.source.iid // ""')") || exit 1
            source=$(jq -nc --arg interface "$interface" --arg iid "$iid" '{type:"prefix_iid",interface:$interface,iid:$iid}') ;;
        http)
            url=$(ask 'IP 查询 URL（不是代理出口）' "$(printf '%s' "$previous" | jq -r '.source.url // ""')") || exit 1
            case "$url" in http://*|https://*) ;; *) url="https://$url" ;; esac
            timeout=$(ask '查询超时秒数' "$(printf '%s' "$previous" | jq -r '.source.timeout_seconds // 10')") || exit 1
            positive_integer "$timeout" || { log error 'Invalid timeout'; exit 1; }
            field=$(ask 'JSON 顶层字段（纯文本填 -）' "$(printf '%s' "$previous" | jq -r '.source.json_field // "-"')") || exit 1
            [ "$field" != - ] || field=
            source=$(jq -nc --arg url "$url" --argjson timeout "$timeout" --arg field "$field" \
                '{type:"http",url:$url,timeout_seconds:$timeout} + (if $field=="" then {} else {json_field:$field} end)') ;;
        *) log error 'Unknown source'; exit 1 ;;
    esac
    id=$(associate_record_id "$family" "$domain" "$previous") || exit 1
    jq -nc --arg id "$id" --argjson source "$source" '{id:$id,source:$source}'
)

choose_families() (
    action=$1; current=$2; domain=$3
    if [ "$action" = add ]; then
        provider_validate_settings || exit 1
        require_tools curl || exit 1
        a_records=$(provider_list_records cloudflare "$domain" A) || exit 1
        aaaa_records=$(provider_list_records cloudflare "$domain" AAAA) || exit 1
        a_count=$(printf '%s' "$a_records" | jq -r length) || exit 1
        aaaa_count=$(printf '%s' "$aaaa_records" | jq -r length) || exit 1
        if [ "$a_count" -gt 0 ] && [ "$aaaa_count" -gt 0 ]; then default=3
        elif [ "$a_count" -gt 0 ]; then default=1
        elif [ "$aaaa_count" -gt 0 ]; then default=2
        else default=3
        fi
    else
        has_a=$(printf '%s' "$current" | jq -r 'has("A")') || exit 1
        has_aaaa=$(printf '%s' "$current" | jq -r 'has("AAAA")') || exit 1
        if [ "$has_a" = true ] && [ "$has_aaaa" = true ]; then default=3
        elif [ "$has_a" = true ]; then default=1
        else default=2
        fi
    fi
    printf '\n管理的 DNS 记录类型：\n' >&2
    printf '  1. A\n  2. AAAA\n  3. A 和 AAAA\n' >&2
    choice=$(ask '选择' "$default") || exit 1
    case "$choice" in 1|2|3) printf '%s\n' "$choice" ;; *) log error 'Invalid record type selection'; exit 1 ;; esac
)

preview_create_address() (
    family=$1; source=$2
    type=$(printf '%s' "$source" | jq -r '.type') || exit 1
    if [ "$type" = argument ]; then
        value=$(ask_explicit "新建 $family 记录的初始地址") || { log error 'Initial address is required'; exit 1; }
        normalize_address "$family" "$value" || { log error 'Invalid initial address'; exit 1; }
        exit 0
    fi
    # A configuration may be prepared on a Mac for later deployment to a router.
    # If this host cannot inspect the configured interface, accept one explicit
    # Cloudflare initial value instead of failing the whole interactive flow.
    value=$(resolve_source "$family" "$source" 2>/dev/null) && { printf '%s\n' "$value"; exit 0; }
    printf '无法从当前设备解析 %s 地址。\n' "$family" >&2
    printf '请填写要用于新建 Cloudflare 记录的初始公网地址。\n' >&2
    value=$(ask_explicit '初始地址') || { log error 'Initial address is required'; exit 1; }
    normalize_address "$family" "$value" || { log error 'Invalid initial address'; exit 1; }
)

prepare_dns_plan() (
    candidate=$1; plan=$2
    : > "$plan"
    name=$(jq -r '.name' "$candidate") || exit 1
    for family in A AAAA; do
        definition=$(jq -c --arg family "$family" '.[$family] // empty' "$candidate") || exit 1
        [ -n "$definition" ] || continue
        id=$(printf '%s' "$definition" | jq -r '.id') || exit 1
        source=$(printf '%s' "$definition" | jq -c '.source') || exit 1
        if [ "$id" = '__CREATE_AFTER_CONFIRM__' ]; then
            content=$(preview_create_address "$family" "$source") || exit 1
            jq -nc --arg family "$family" --arg name "$name" --arg content "$content" \
                --argjson source "$source" '{family:$family,name:$name,content:$content,source:$source,proxy:"DNS-only",ttl:"Auto",operation:"create"}' >> "$plan" || exit 1
        else
            record=$(provider_get_record cloudflare "$id") || exit 1
            printf '%s' "$record" | jq -e --arg id "$id" --arg name "$name" --arg family "$family" '
                .id==$id and (.name|ascii_downcase|rtrimstr("."))==$name and .type==$family and .proxied==false' >/dev/null || {
                log error "Cloudflare record metadata no longer matches $family $name"; exit 1;
            }
            content=$(printf '%s' "$record" | jq -r '.content') || exit 1
            jq -nc --arg family "$family" --arg name "$name" --arg content "$content" \
                --arg id "$id" --argjson source "$source" '{family:$family,name:$name,content:$content,id:$id,source:$source,proxy:"DNS-only",ttl:"Auto",operation:"reuse"}' >> "$plan" || exit 1
        fi
    done
)

show_save_preview() (
    candidate=$1; plan=$2
    printf '\n本地配置（新建任务默认启用）：\n'
    jq '. as $config | walk(if type=="string" and .=="__CREATE_AFTER_CONFIRM__" then "<创建后自动填入>" else . end)' "$candidate"
    printf '\nCloudflare DNS 记录预览：\n'
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        printf '%s\n' "$entry" | jq -r '
            "  Type: \(.family)\n  Name: \(.name)\n  Content: \(.content)\n  Proxy: \(.proxy)\n  TTL: \(.ttl)\n  Action: " +
            (if .operation=="create" then "Create DNS-only record" else "Use existing DNS-only record" end) + "\n"'
    done < "$plan"
)

apply_pending_records() (
    candidate=$1; plan=$2
    for family in A AAAA; do
        entry=$(jq -c --arg family "$family" 'select(.family==$family and .operation=="create")' "$plan") || exit 1
        [ -n "$entry" ] || continue
        name=$(printf '%s' "$entry" | jq -r '.name')
        content=$(printf '%s' "$entry" | jq -r '.content')
        id=$(provider_create_record cloudflare "$name" "$family" "$content") || exit 1
        updated=$(make_temp_file "$WORK_DIR" candidate-update) || exit 1
        jq -c --arg family "$family" --arg id "$id" '.[$family].id=$id' "$candidate" > "$updated" || exit 1
        mv -f -- "$updated" "$candidate" || exit 1
    done
)

wizard() (
    requested_task=$1; action=$2
    if [ "$action" = add ]; then
        current='{"schema_version":1,"enabled":true,"provider":"cloudflare","name":""}'
        name=$(choose_domain) || exit 1
        valid_domain_name "$name" || { log error 'Invalid domain name'; exit 1; }
        name=$(jq -nr --arg name "$name" '$name|ascii_downcase|rtrimstr(".")') || exit 1
        task=$name
        file=$(task_path "$task") || exit 1
        [ ! -e "$file" ] && [ ! -L "$file" ] || { log error 'A local configuration already exists for this domain'; exit 1; }
        expected=NEW
    else
        task=$requested_task
        file=$(existing_task "$task") || exit 1
        # Read checksum around the copy to detect a concurrent writer.
        expected=$(fingerprint "$file")
        current=$(jq -c . "$file") || exit 1
        [ "$(fingerprint "$file")" = "$expected" ] || exit 1
        name=$(printf '%s' "$current" | jq -r .name) || exit 1
    fi
    current=$(printf '%s' "$current" | jq -c --arg name "$name" '.name=$name') || exit 1
    family_choice=$(choose_families "$action" "$current" "$name") || exit 1
    for family in A AAAA; do
        previous=$(printf '%s' "$current" | jq -c --arg f "$family" '.[$f] // {}')
        case "$family:$family_choice" in A:1|A:3|AAAA:2|AAAA:3)
                definition=$(build_family "$family" "$previous" "$name") || exit 1
                current=$(printf '%s' "$current" | jq -c --arg f "$family" --argjson d "$definition" '.[$f]=$d') || exit 1 ;;
            *)
                if [ "$previous" != '{}' ]; then
                    confirm "停止管理 $family（不删除云端记录）？" || exit 1
                fi
                current=$(printf '%s' "$current" | jq -c --arg f "$family" 'del(.[$f])') || exit 1 ;;
        esac
    done
    candidate=$(make_temp_file "$WORK_DIR" candidate) || exit 1
    printf '%s\n' "$current" > "$candidate"
    validate_record "$candidate" || exit 1
    plan=$(make_temp_file "$WORK_DIR" dns-plan) || exit 1
    prepare_dns_plan "$candidate" "$plan" || exit 1
    show_save_preview "$candidate" "$plan"
    confirm '应用以上配置和 DNS 计划？' || exit 1
    apply_pending_records "$candidate" "$plan" || exit 1
    validate_record "$candidate" || exit 1
    commit_record "$task" "$candidate" "$expected"
)

set_enabled() (
    task=$1; enabled=$2
    file=$(existing_task "$task") || exit 1
    expected=$(fingerprint "$file")
    candidate=$(make_temp_file "$WORK_DIR" candidate) || exit 1
    jq -c --argjson enabled "$enabled" '.enabled=$enabled' "$file" > "$candidate" || exit 1
    [ "$(fingerprint "$file")" = "$expected" ] || exit 1
    if [ "$enabled" = true ]; then
        confirm '启用后，下一次定时任务可能立即更新 DNS。已预览地址并确认？' || exit 1
    fi
    commit_record "$task" "$candidate" "$expected"
)
delete_task() (
    task=$1
    file=$(existing_task "$task") || exit 1
    expected=$(fingerprint "$file")
    confirm "删除本地任务 ${task}？不删除云端 DNS，恢复需重新创建配置。" || exit 1
    acquire_config_lock || exit 1
    trap release_config_lock 0
    [ -f "$file" ] && [ ! -L "$file" ] && [ "$(fingerprint "$file")" = "$expected" ] || exit 1
    rm -- "$file" || exit 1
    printf '已删除 %s 的本地配置；云端记录保留。\n' "$task"
)
dispatch() {
    case "${1:-}" in
        list) list_tasks ;;
        add)
            [ "$#" -eq 1 ] || { log error 'Usage: cloudflare-ddns config add'; return 2; }
            wizard '' add ;;
        edit)
            [ "$#" -le 2 ] || { log error 'Usage: cloudflare-ddns config edit [DOMAIN]'; return 2; }
            task=${2:-}; [ -n "$task" ] || task=$(choose_existing_task yes) || return 1
            wizard "$task" edit ;;
        enable|disable|delete)
            [ "$#" -le 2 ] || { log error "Usage: cloudflare-ddns config $1 [DOMAIN]"; return 2; }
            action=$1; task=${2:-}; [ -n "$task" ] || task=$(choose_existing_task yes) || return 1
            case "$action" in enable) set_enabled "$task" true ;; disable) set_enabled "$task" false ;; delete) delete_task "$task" ;; esac ;;
        import)
            [ "$#" -eq 3 ] || { log error 'Usage: import TASK FILE'; return 1; }
            validate_record "$3" || return 1
            candidate=$(make_temp_file "$WORK_DIR" import) || return 1
            jq -c '.enabled=false' "$3" > "$candidate" || return 1
            commit_record "$2" "$candidate" NEW ;;
        *) log error 'Unknown command; use --help'; return 2 ;;
    esac
}

if [ "$#" -gt 0 ]; then dispatch "$@"; exit $?; fi
while :; do
    list_tasks
    printf '%s\n' '1 新增  2 修改  3 启用  4 停用  5 删除'
    printf '%s' '选择（直接回车刷新列表）: '
    IFS= read -r choice || exit 0
    case "$choice" in '') continue ;; 1) dispatch add; continue ;; esac
    case "$choice" in 2|3|4|5) ;; *) printf '无效选择\n'; continue ;; esac
    task=$(choose_existing_task no) || continue
    case "$choice" in
        2) dispatch edit "$task" ;; 3) dispatch enable "$task" ;;
        4) dispatch disable "$task" ;; 5) dispatch delete "$task" ;;
    esac
done
