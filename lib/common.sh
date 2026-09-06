# Helpers with scratch variables use subshells to avoid leaking POSIX sh globals.
# Only load_settings intentionally sets shared configuration variables.
has_command() { type "$1" >/dev/null 2>&1; }
log() (
    level=$1; shift
    case "${LOG_LEVEL:-info}:$level" in error:info|error:debug|info:debug) exit 0 ;; esac
    printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*" >&2
    if [ -n "${LOG_FILE:-}" ]; then
        printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*" >> "$LOG_FILE"
    elif has_command logger; then
        logger -t "${LOG_TAG:-cloudflare-ddns}" "$*" 2>/dev/null || :
    fi
)
die() { log error "$*"; exit 2; }
ensure_entware_path() {
    # A trusted common configuration may set PATH. Restore Entware's standard
    # locations afterwards because Merlin's non-interactive hooks omit them.
    PATH="/opt/bin:/opt/sbin:${PATH:-/sbin:/bin:/usr/sbin:/usr/bin}"
    export PATH
}
require_tools() (
    for tool do has_command "$tool" || { log error "Missing dependency: $tool"; exit 1; }; done
)
valid_task_name() {
    # A task is a DNS name, and its exact canonical name is its filename.
    valid_domain_name "$1" && case "$1" in \*.*|*.) return 1 ;; *) return 0 ;; esac
}
valid_domain_name() {
    jq -en --arg name "$1" '$name|length<=253 and
      test("^(\\*\\.)?([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\\.)+[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\\.?$")' \
      >/dev/null 2>&1
}
positive_integer() { printf '%s\n' "$1" | grep -Eq '^[1-9][0-9]{0,8}$'; }
load_settings() {
    [ -r "$CONFIG_FILE" ] || { log error 'Cannot read common configuration'; return 1; }
    # The .conf is trusted executable shell. JSON is never sourced.
    # shellcheck disable=SC1090
    . "$CONFIG_FILE" || { log error 'Common configuration could not be loaded'; return 1; }
    ensure_entware_path
    CONF_DIR=${CONF_DIR:-"$SCRIPT_DIR/conf.d"}
    STATE_FILE=${STATE_FILE:-"$SCRIPT_DIR/cloudflare-ddns.state"}
    LOCK_DIR="${CONF_DIR}.lock"
    REFRESH_INTERVAL_SECONDS=${REFRESH_INTERVAL_SECONDS:-${NO_CHANGE_WINDOW_SECONDS:-43200}}
    HTTP_CONNECT_TIMEOUT_SECONDS=${HTTP_CONNECT_TIMEOUT_SECONDS:-5}
    HTTP_TIMEOUT_SECONDS=${HTTP_TIMEOUT_SECONDS:-10}
    LOG_LEVEL=${LOG_LEVEL:-info}
    case "$LOG_LEVEL" in debug|info|error) ;; *) log error 'Invalid LOG_LEVEL'; return 1 ;; esac
    for settings_number in "$REFRESH_INTERVAL_SECONDS" "$HTTP_CONNECT_TIMEOUT_SECONDS" "$HTTP_TIMEOUT_SECONDS"; do
        positive_integer "$settings_number" || { log error 'Intervals must be positive integers'; return 1; }
    done
    [ "$CONF_DIR" != / ] && [ -n "$CONF_DIR" ] && [ ! -L "$CONF_DIR" ] || {
        log error 'Invalid or symbolic-link CONF_DIR'; return 1;
    }
}
acquire_config_lock() {
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        log error "DDNS/config operation locked: $LOCK_DIR (verify no process is running before removing a stale lock)"
        return 1
    fi
    printf '%s\n' "$$" > "$LOCK_DIR/pid"
}
release_config_lock() { rm -f -- "$LOCK_DIR/pid"; rmdir "$LOCK_DIR" 2>/dev/null || :; }
validate_record() (
    jq -e -s 'length == 1' "$1" >/dev/null 2>&1 &&
        jq -e -f "$LIB_DIR/schema.jq" "$1" >/dev/null 2>&1 || {
            log error 'Invalid record schema: check version, fields, address family and source parameters'; exit 1;
        }
)
validate_directory() (
    dir=$1
    [ -d "$dir" ] || { log error "Missing conf.d directory: $dir"; exit 1; }
    list=$(mktemp "${TMPDIR:-/tmp}/ddns-validation.XXXXXX") || exit 1
    trap 'rm -f -- "$list"' 0
    set +f
    for file in "$dir"/*.json; do
        [ -e "$file" ] || [ -L "$file" ] || continue
        name=${file##*/}; name=${name%.json}
        valid_task_name "$name" && [ -f "$file" ] && [ ! -L "$file" ] || {
            log error 'Record filenames must be canonical domain.json regular files, not symlinks'; exit 1;
        }
        validate_record "$file" || { log error "Task $name failed validation"; exit 1; }
        record_name=$(jq -r '.name|ascii_downcase|rtrimstr(".")' "$file") || exit 1
        [ "$name" = "$record_name" ] || {
            log error "Record filename $name.json must match its JSON domain $record_name"; exit 1;
        }
        jq -c . "$file" >> "$list" || exit 1
    done
    # Catch collisions in disabled drafts as well, before enabling them.
    jq -es '
      [ .[] as $r | ["A","AAAA"][] as $f | select($r|has($f))
        | {id:[$r.provider,$r[$f].id], key:[$r.provider,($r.name|ascii_downcase|rtrimstr(".")),$f]} ] as $e
      | ($e|length) == ($e|unique_by(.id)|length)
        and ($e|length) == ($e|unique_by(.key)|length)
    ' "$list" >/dev/null || { log error 'Duplicate DNS record ID or domain/type across tasks'; exit 1; }
)
snapshot_tasks() (
    output=$1
    : > "$output"
    found=0
    set +f
    for file in "$CONF_DIR"/*.json; do
        [ -f "$file" ] || continue
        name=${file##*/}; name=${name%.json}
        [ -z "${SELECT_TASK:-}" ] || [ "$SELECT_TASK" = "$name" ] || continue
        jq -c --arg task "$name" '{task:$task,record:.}' "$file" >> "$output" || exit 1
        found=$((found + 1))
    done
    [ "$found" -gt 0 ] || { log error 'No matching task files; create one with cloudflare-ddns config'; exit 1; }
)
state_load() (
    target=$1
    if [ ! -e "$STATE_FILE" ]; then printf '{}\n' > "$target"; exit; fi
    # Never source the legacy shell state. A fresh DNS update is safe.
    if jq -e 'type == "object" and all(.[]; type == "object" and (.ip|type=="string") and (.updated_at|type=="number"))' "$STATE_FILE" >/dev/null 2>&1; then
        cp "$STATE_FILE" "$target"
    elif grep -q '^LAST_IPV[46]=' "$STATE_FILE"; then
        log info 'Legacy family-wide state ignored; per-record state starts fresh'
        printf '{}\n' > "$target"
    else log error 'Invalid state file; refusing to overwrite'; exit 1; fi
)
state_is_fresh() (
    jq -e --arg k "$2" --arg ip "$3" --argjson now "$(date +%s)" \
        --argjson window "$REFRESH_INTERVAL_SECONDS" \
        '.[$k] != null and .[$k].ip == $ip and ($now - .[$k].updated_at >= 0) and ($now - .[$k].updated_at < $window)' "$1" >/dev/null
)
state_store() (
    snapshot=$1; key=$2; address=$3
    parent=$(dirname -- "$STATE_FILE")
    [ -d "$parent" ] || { log error 'State directory does not exist'; exit 1; }
    [ ! -L "$STATE_FILE" ] || { log error 'State file must not be a symlink'; exit 1; }
    temporary=$(mktemp "$parent/.ddns-state.XXXXXX") || exit 1
    trap 'rm -f -- "$temporary"' 0
    jq --arg k "$key" --arg ip "$address" --argjson now "$(date +%s)" \
        '.[$k]={ip:$ip,updated_at:$now}' "$snapshot" > "$temporary" &&
        mv -f -- "$temporary" "$STATE_FILE" && cp "$STATE_FILE" "$snapshot"
)
notify_merlin() {
    [ ! -x /sbin/ddns_custom_updated ] || /sbin/ddns_custom_updated "$1"
}
send_bark() (
    [ -n "${BARK_KEY:-}" ] || exit 0
    curl -q -sS --get --connect-timeout 3 --max-time 5 \
        --data-urlencode "title=${BARK_TITLE:-cloudflare-ddns}" \
        --data-urlencode "body=$1" --data-urlencode "group=${BARK_GROUP:-}" \
        "${BARK_URL:-https://api.day.app}/$BARK_KEY" >/dev/null 2>&1 || :
)
