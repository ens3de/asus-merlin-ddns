# Each resolver prints one canonical address. Explicit sources never fall back.
normalize_address() (
    family=$1; value=$2
    if [ "$family" = A ]; then filter='public_ipv4'; else filter='public_ipv6'; fi
    jq -nr -L "$LIB_DIR" --arg value "$value" "include \"ip\"; \$value | $filter" 2>/dev/null
)
interface_addresses() (
    family=$1; interface=$2
    if has_command ip; then
        if [ "$family" = A ]; then flag=-4; else flag=-6; fi
        raw=$(ip "$flag" -o addr show dev "$interface" scope global 2>/dev/null) || {
            log error "Unable to read interface $interface"; exit 1;
        }
    elif has_command ifconfig; then
        native=$(ifconfig "$interface" 2>/dev/null) || {
            log error "Unable to read interface $interface"; exit 1;
        }
        if [ "$family" = A ]; then
            raw=$(printf '%s\n' "$native" | awk '$1=="inet" {print "inet " $2 "/32"}')
        else
            raw=$(printf '%s\n' "$native" | awk '$1=="inet6" {
                prefix=128; for(i=1;i<NF;i++) if($i=="prefixlen") prefix=$(i+1)
                print "inet6 " $2 "/" prefix
            }')
        fi
    else
        log error 'Missing dependency: ip or ifconfig'; exit 1
    fi
    # Whole flag words only: mngtmpaddr is NOT itself a temporary address.
    printf '%s\n' "$raw" | awk '
      /(^|[[:space:]])(temporary|deprecated|tentative|dadfailed)([[:space:]]|$)/ {next}
      /preferred_lft 0(sec)?([[:space:]]|$)/ {next}
      {for(i=1;i<NF;i++) if($i=="inet" || $i=="inet6") print $(i+1)}'
)

# Print every usable public address as: INTERFACE<TAB>ADDRESS.
# This is used by the interactive manager only; normal updates still resolve
# the selected interface afresh, so the displayed address is never persisted.
available_interface_addresses() (
    family=$1
    if has_command ip; then
        if [ "$family" = A ]; then flag=-4; else flag=-6; fi
        raw=$(ip "$flag" -o addr show scope global 2>/dev/null) || {
            log error 'Unable to enumerate network interfaces'; exit 1;
        }
        candidates=$(printf '%s\n' "$raw" | awk '
            { iface=$2; sub(/@.*/, "", iface)
              for (i=1; i<NF; i++) if ($i=="inet" || $i=="inet6") {
                  print iface "\t" $(i+1); break
              }
            }')
    elif has_command ifconfig; then
        candidates=$(for interface in $(ifconfig -l 2>/dev/null); do
            interface_addresses "$family" "$interface" 2>/dev/null |
                while IFS= read -r cidr; do
                    [ -z "$cidr" ] || printf '%s\t%s\n' "$interface" "$cidr"
                done
        done)
    else
        log error 'Missing dependency: ip or ifconfig'; exit 1
    fi
    printf '%s\n' "$candidates" | while IFS="$(printf '\t')" read -r interface cidr; do
        [ -n "$interface" ] && [ -n "$cidr" ] || continue
        address=$(normalize_address "$family" "${cidr%/*}") || continue
        printf '%s\t%s\n' "$interface" "$address"
    done | sort -u
)

resolve_interface() (
    family=$1; interface=$2
    candidates=$(interface_addresses "$family" "$interface") || exit 1
    canonical=$(
        printf '%s\n' "$candidates" | while IFS= read -r cidr; do
            [ -n "$cidr" ] || continue
            normalize_address "$family" "${cidr%/*}" || :
        done
    )
    result=$(printf '%s\n' "$canonical" | jq -Rsc 'split("\n") | map(select(length>0)) | unique') || exit 1
    [ "$(printf '%s' "$result" | jq length)" -eq 1 ] || {
        log error "Interface $interface has zero or multiple usable $family addresses"; exit 1;
    }
    printf '%s' "$result" | jq -r '.[0]'
)
resolve_prefix_iid() (
    interface=$1; iid=$2
    candidates=$(interface_addresses AAAA "$interface") || exit 1
    prefixes=$(
        printf '%s\n' "$candidates" | while IFS= read -r cidr; do
            [ "${cidr##*/}" = 64 ] || continue
            normalized=$(normalize_address AAAA "${cidr%/*}") || continue
            printf '%s\n' "$normalized" | cut -d: -f1-4
        done
    )
    unique=$(printf '%s\n' "$prefixes" | jq -Rsc 'split("\n") | map(select(length>0)) | unique') || exit 1
    [ "$(printf '%s' "$unique" | jq length)" -eq 1 ] || {
        log error "Interface $interface has zero or multiple preferred global /64 prefixes"; exit 1;
    }
    prefix=$(printf '%s' "$unique" | jq -r '.[0]')
    normalize_address AAAA "$prefix:$iid"
)
resolve_http() (
    family=$1; source=$2
    url=$(printf '%s' "$source" | jq -r '.url')
    timeout=$(printf '%s' "$source" | jq -r --arg default "$HTTP_TIMEOUT_SECONDS" '.timeout_seconds // ($default|tonumber)')
    if [ "$family" = A ]; then flag=-4; else flag=-6; fi
    response=$(curl -q -fsS "$flag" --connect-timeout "$HTTP_CONNECT_TIMEOUT_SECONDS" \
        --max-time "$timeout" --max-filesize 65536 --url "$url" \
        --write-out '\n__DDNS_HTTP__%{http_code}' 2>/dev/null) || {
        log error 'HTTP address lookup failed'; exit 1;
    }
    code=${response##*__DDNS_HTTP__}
    [ "$code" = 200 ] || { log error 'HTTP address lookup did not return 200'; exit 1; }
    body=${response%__DDNS_HTTP__*}
    if printf '%s' "$source" | jq -e 'has("json_field")' >/dev/null; then
        field=$(printf '%s' "$source" | jq -r '.json_field')
        value=$(printf '%s' "$body" | jq -er --arg field "$field" '.[$field] | select(type=="string")') || exit 1
    else
        value=$(printf '%s' "$body" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    fi
    normalize_address "$family" "$value" || { log error 'HTTP returned an invalid public address'; exit 1; }
)
resolve_source() (
    family=$1; source=$2
    type=$(printf '%s' "$source" | jq -r '.type')
    case "$type" in
        argument)
            if [ "$family" = A ]; then value=${ARG_IPV4:-}; else value=${ARG_IPV6:-}; fi
            normalize_address "$family" "$value" || { log error "Missing/invalid $family argument"; exit 1; } ;;
        interface) resolve_interface "$family" "$(printf '%s' "$source" | jq -r '.interface')" ;;
        http) resolve_http "$family" "$source" ;;
        prefix_iid)
            [ "$family" = AAAA ] || exit 1
            resolve_prefix_iid "$(printf '%s' "$source" | jq -r '.interface')" "$(printf '%s' "$source" | jq -r '.iid')" ;;
        *) log error 'Unsupported address source'; exit 1 ;;
    esac
)
