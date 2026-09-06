# Only explicit, allowlisted provider dispatch; JSON cannot name shell commands.
provider_validate_settings() (
    printf '%s\n' "${CF_ZONE_ID:-}" | grep -Eq '^[A-Za-z0-9_-]{1,128}$' || {
        log error 'Missing/invalid CF_ZONE_ID'; exit 1;
    }
    printf '%s\n' "${CF_API_TOKEN:-}" | grep -Eq '^[A-Za-z0-9_-]+$' || {
        log error 'Missing/invalid CF_API_TOKEN'; exit 1;
    }
)
cloudflare_api() (
    method=$1; endpoint=$2; payload=${3:-}; result_type=${4:-object}
    # Secret goes through stdin, not argv. Never log curl config or API bodies.
    response=$(
        printf 'header = "Authorization: Bearer %s"\n' "$CF_API_TOKEN" |
            "$CURL_BIN" -q --config - --silent --show-error \
                --connect-timeout "$HTTP_CONNECT_TIMEOUT_SECONDS" --max-time "$HTTP_TIMEOUT_SECONDS" \
                --request "$method" --header 'Content-Type: application/json' \
                --url "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID${endpoint:+/$endpoint}" \
                --data "$payload" --write-out '\n__DDNS_HTTP__%{http_code}' 2>/dev/null
    ) || { log error 'Cloudflare transport request failed'; exit 1; }
    status=${response##*__DDNS_HTTP__}
    body=${response%__DDNS_HTTP__*}
    [ "$status" = 200 ] && printf '%s' "$body" | jq -e --arg result_type "$result_type" \
        '.success == true and (.result|type) == $result_type' >/dev/null 2>&1 || {
        log error "Cloudflare rejected request (HTTP $status); response body suppressed"; exit 1;
    }
    printf '%s' "$body" | jq -c '.result'
)
cloudflare_record() { cloudflare_api "$1" "dns_records/$2" "${3:-}" object; }

provider_get_record() (
    provider=$1; id=$2
    case "$provider" in
        cloudflare)
            record=$(cloudflare_record GET "$id") || exit 1
            printf '%s' "$record" | jq -c '{id,name,type,content,proxied:(.proxied//false),ttl:(.ttl//1)}' ;;
        *) log error 'Unsupported DNS provider'; exit 1 ;;
    esac
)

provider_zone_name() (
    provider=$1
    case "$provider" in
        cloudflare)
            zone_result=$(cloudflare_api GET '' '' object) || exit 1
            zone=$(printf '%s' "$zone_result" | jq -r '.name // empty') || exit 1
            valid_domain_name "$zone" || { log error 'Cloudflare returned an invalid Zone name'; exit 1; }
            printf '%s\n' "$zone" | jq -Rr 'ascii_downcase|rtrimstr(".")'
            ;;
        *) log error 'Unsupported DNS provider'; exit 1 ;;
    esac
)

provider_list_domain_names() (
    provider=$1; zone=$2
    case "$provider" in
        cloudflare)
            # Request 5,000 records in one page (below Cloudflare's documented
            # maximum). This is ample here; fail closed on an invalid response.
            records=$(cloudflare_api GET 'dns_records?per_page=5000&page=1' '' array) || exit 1
            printf '%s' "$records" | jq -c --arg zone "$zone" '[.[]
                    | select(.type == "A" or .type == "AAAA") | .name
                    | ascii_downcase | rtrimstr(".")
                    | select(. == $zone or endswith("." + $zone))] | unique'
            ;;
        *) log error 'Unsupported DNS provider'; exit 1 ;;
    esac
)

provider_list_records() (
    provider=$1; name=$2; family=$3
    case "$provider" in
        cloudflare)
            # name/family have already passed the strict record schema.
            records=$(cloudflare_api GET "dns_records?type=$family&name=$name&per_page=100" '' array) || exit 1
            printf '%s' "$records" | jq -c '[.[] | {id,name,type,content,proxied:(.proxied // false)}]'
            ;;
        *) log error 'Unsupported DNS provider'; exit 1 ;;
    esac
)

provider_create_record() (
    provider=$1; name=$2; family=$3; address=$4
    case "$provider" in
        cloudflare)
            payload=$(jq -nc --arg type "$family" --arg name "$name" --arg content "$address" \
                '{type:$type,name:$name,content:$content,ttl:1,proxied:false}')
            created=$(cloudflare_api POST dns_records "$payload" object) || exit 1
            printf '%s' "$created" | jq -e --arg name "$name" --arg family "$family" '
                select((.name|ascii_downcase|rtrimstr("."))==$name and .type==$family and .proxied==false)
                | .id | select(type=="string" and test("^[A-Za-z0-9_-]{1,128}$"))' >/dev/null || exit 1
            returned=$(printf '%s' "$created" | jq -r '.content')
            returned=$(normalize_address "$family" "$returned") || exit 1
            [ "$returned" = "$address" ] || { log error 'Cloudflare created a record with unexpected content'; exit 1; }
            printf '%s' "$created" | jq -r '.id'
            ;;
        *) log error 'Unsupported DNS provider'; exit 1 ;;
    esac
)
provider_update() (
    provider=$1; id=$2; name=$3; family=$4; address=$5
    case "$provider" in
        cloudflare)
            current=$(cloudflare_record GET "$id") || exit 1
            printf '%s' "$current" | jq -e --arg name "$name" --arg family "$family" --arg id "$id" \
                '.id == $id and (.name|ascii_downcase|rtrimstr(".")) == $name and .type == $family' >/dev/null || {
                log error 'Cloudflare record ID does not match configured domain/type'; exit 1;
            }
            if printf '%s' "$current" | jq -e '.proxied == true' >/dev/null; then
                log error 'Cloudflare record is proxied; use DNS-only for this VPN DDNS updater'; exit 1
            fi
            payload=$(jq -nc --arg content "$address" '{content:$content}')
            updated=$(cloudflare_record PATCH "$id" "$payload") || exit 1
            printf '%s' "$updated" | jq -e --arg id "$id" --arg name "$name" --arg family "$family" \
                '.id==$id and (.name|ascii_downcase|rtrimstr("."))==$name and .type==$family' >/dev/null || exit 1
            returned=$(printf '%s' "$updated" | jq -r '.content')
            returned=$(normalize_address "$family" "$returned") || exit 1
            [ "$returned" = "$address" ] || { log error 'Cloudflare returned an unexpected address'; exit 1; }
            ;;
        *) log error 'Unsupported DNS provider'; exit 1 ;;
    esac
)
