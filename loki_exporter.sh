#!/bin/ash -u
#
# shellcheck shell=bash

LC_ALL=C

_TMPDIR="$(mktemp -d -p /tmp loki_exporter.XXXXXX)"
PIPE_NAME="${_TMPDIR}/loki_exporter.pipe"
BULK_DATA="${_TMPDIR}/loki_exporter.boot"
LOCAL_LOG="${_TMPDIR}/log"

# Generate a unique Boot ID (Unix timestamp) to prevent stream collisions
BOOT_ID_VAL="$(date +%s)"

# Define templates
LOKI_MSG_TEMPLATE="{\"streams\": [{\"stream\": {\"job\": \"openwrt_loki_exporter\", \"host\": \"${HOSTNAME}\", \"boot_id\": \"${BOOT_ID_VAL}\"}, \"values\": [[\"TIMESTAMP\", \"MESSAGE\"]]}]}"
LOKI_BULK_TEMPLATE_HEADER="{\"streams\": [{\"stream\": {\"job\": \"openwrt_loki_exporter\", \"host\": \"${HOSTNAME}\", \"boot_id\": \"${BOOT_ID_VAL}\"}, \"values\": ["
LOKI_BULK_TEMPLATE_MSG="[\"TIMESTAMP\", \"MESSAGE\"],"
LOKI_BULK_TEMPLATE_FOOTER="]}]}"

DATETIME_STR_FORMAT="%a %b %d %H:%M:%S %Y"
OS=$(uname -s | tr "[:upper:]" "[:lower:]")

USER_AGENT="openwrt-loki-exporter/%% VERSION %%"
BUILD_ID="%% BUILD_ID %%"

# Pre-calculate a literal tab character for substitution
TAB_CHAR="$(printf '\t')"

_escape_json_string() {
    # 1. Escape backslashes first (to avoid double escaping later)
    local s="${1//\\/\\\\}"
    # 2. Escape double quotes
    s="${s//\"/\\\"}"
    # 3. Escape tabs
    s="${s//${TAB_CHAR}/\\t}"
    echo "$s"
}

_curl_bulk_cmd() {
if [ "${AUTOTEST-0}" -eq 1 ]; then
    curl --no-progress-meter -v \
        -H "Content-Type: application/json" \
        -H "Content-Encoding: gzip" \
        -H "User-Agent: ${USER_AGENT}" \
        -H "Connection: close" \
        "$@"
else
    # -i included to capture HTTP headers/errors
    curl --no-progress-meter -i \
        -H "Content-Type: application/json" \
        -H "Content-Encoding: gzip" \
        -H "User-Agent: ${USER_AGENT}" \
        -H "Authorization: Basic ${LOKI_AUTH_HEADER}" \
        -H "Connection: close" \
        "$@"
fi
}

_curl_cmd() {
if [ "${AUTOTEST-0}" -eq 1 ]; then
    curl --no-progress-meter -v \
        -H "Content-Type: application/json" \
        -H "User-Agent: ${USER_AGENT}" \
        -H "Connection: close" \
        "$@"
else
    curl -sS \
        -H "Content-Type: application/json" \
        -H "User-Agent: ${USER_AGENT}" \
        -H "Authorization: Basic ${LOKI_AUTH_HEADER}" \
        -H "Connection: close" \
        "$@"
fi
}

_setup() {
    mkfifo "${PIPE_NAME}"
    echo "openwrt-loki-exporter/${BUILD_ID} started with BOOT=${BOOT}" >&2
}

_teardown() {
    if ! kill "${tailer_pid}"; then
        echo "tailer (${tailer_pid}) was already killed, exiting" >&2
    else
        echo "tailer ${tailer_pid} killed, exiting" >&2
    fi
    rm -f "${PIPE_NAME}"
    if [ "${AUTOTEST-0}" -eq 1 ]; then
        mkdir -p results
        cp -r "${_TMPDIR}" results/
        echo "LOG:"
        cat "${LOCAL_LOG}"
    fi
    rm -rf "${_TMPDIR}"
    exit 0
}

_rotate_local_log() {
    log_max_size=4096
    log_rotate=3
    llsize="$(wc -c "${LOCAL_LOG}" | awk '{print $1}')"
    if [ "${llsize}" -le "${log_max_size}" ]; then
         return
    fi
    for i in $(seq $((log_rotate - 1)) -1 1); do
        if [ ! -e "${LOCAL_LOG}.${i}" ]; then
            continue
        fi
        j=$((i + 1))
        mv "${LOCAL_LOG}.${i}" "${LOCAL_LOG}.${j}"
    done
    mv "${LOCAL_LOG}" "${LOCAL_LOG}.1"
    touch "${LOCAL_LOG}"
}

_do_bulk_post() {
    _log_file="$1"
    post_body="${LOKI_BULK_TEMPLATE_HEADER}"

    last_ts=0

    while read -r line; do
        ts="${line:26:14}"
        ts_ms="${ts/./}"

        # shellcheck disable=SC2116
        if ! ts_ns="$(echo $(( ts_ms * 1000 * 1000 )) )" ; then
            echo "PARSE ERROR: '${line}'" >>"${LOCAL_LOG}"
            continue
        fi

        # Enforce Monotonicity
        if [ "${ts_ns}" -le "${last_ts}" ]; then
             ts_ns=$((last_ts + 1))
        fi
        last_ts=${ts_ns}

        # Raw message
        msg_raw="${line:42:2000}"
        
        # Sanitize message
        msg="$(_escape_json_string "$msg_raw")"

        msg_payload="${LOKI_BULK_TEMPLATE_MSG}"
        msg_payload="${msg_payload/TIMESTAMP/$ts_ns}"
        msg_payload="${msg_payload/MESSAGE/$msg}"

        post_body="${post_body}${msg_payload}"
    done <"${_log_file}"

    post_body="${post_body:0:${#post_body}-1}${LOKI_BULK_TEMPLATE_FOOTER}"
    echo "${post_body}" | gzip >"${_log_file}.payload.gz"
    rm -f "${_log_file}"

    # RETRY LOOP
    max_retries=20
    attempt=0
    success=0
    while [ $attempt -lt $max_retries ]; do
        if _curl_bulk_cmd --data-binary "@${_log_file}.payload.gz" "${LOKI_PUSH_URL}" >"${_log_file}.payload.gz-response" 2>&1; then
            
            # Check for HTTP 400/500 errors even if curl exits 0
            if grep -q "400 Bad Request" "${_log_file}.payload.gz-response"; then
                 echo "BULK POST FAILED (400 Bad Request). Content:" >>"${LOCAL_LOG}"
                 cat "${_log_file}.payload.gz-response" >>"${LOCAL_LOG}"
                 break
            fi

            echo "BULK POST SUCCESS: Boot logs sent." >>"${LOCAL_LOG}"
            rm -f "${_log_file}.payload.gz" "${_log_file}.payload.gz-response"
            success=1
            break
        fi

        attempt=$((attempt+1))
        echo "BULK POST FAILED (Attempt $attempt/$max_retries): Retrying in 15s..." >>"${LOCAL_LOG}"
        sleep 15
    done

    if [ $success -eq 0 ]; then
        echo "BULK POST FAILED: Gave up." >>"${LOCAL_LOG}"
    fi
}

_check_for_skewed_timestamp() {
    _log_file="$1"
    delta_threshold_seconds="${SKEWED_TIMESTAMP_DELTA_THRESHOLD-3600}"
    delta_threshold=$((delta_threshold_seconds * 10**9))
    step=25000000

    prev_ts=0
    line_n=0
    line_n_synced=0
    while read -r line; do
        ts="${line:26:14}"
        ts_ms="${ts/./}"
        # shellcheck disable=SC2116
        if ! ts_ns="$(echo $(( ts_ms * 1000 * 1000 )) )" ; then
            continue
        fi
        line_n=$((line_n + 1))
        if [ "${prev_ts-0}" -eq 0 ]; then
            prev_ts=$ts_ns
        fi
        delta_t=$((ts_ns - prev_ts))
        if [ $delta_t -ge $delta_threshold ]; then
            line_n_synced=$line_n
            break
        fi
        prev_ts=$ts_ns
    done <"${_log_file}"

    if [ $line_n_synced -eq 0 ]; then
        return
    fi

    ts_ns=$((ts_ns / 1000000000))
    ts_ns=$((ts_ns * 1000000000))
    new_ts=$((ts_ns - step * (line_n_synced-1)))

    rm -f "${_log_file}.new"
    line_n=0
    while read -r line; do
        ts="${line:26:14}"
        ts_ms="${ts/./}"
        # shellcheck disable=SC2116
        if ! ts_ns="$(echo $(( ts_ms * 1000 * 1000 )) )" ; then
            continue
        fi
        line_n=$((line_n + 1))
        if [ $line_n -ge $line_n_synced ]; then
            printf "%s\n" "$line" >>"$1.new"
            continue
        fi
        msg="${line:42:2000}"
        new_ts_s=$((new_ts / 1000000000))
        case "${OS}" in
            darwin) datetime_str=$(date -r "${new_ts_s}" +"${DATETIME_STR_FORMAT}") ;;
            *) datetime_str=$(date -d @"${new_ts_s}" +"${DATETIME_STR_FORMAT}") ;;
        esac
        new_ts_ms_rounded=$((new_ts / 1000000))
        printf "%s [%s] %s\n" "${datetime_str}" "${new_ts_ms_rounded:0:10}.${new_ts_ms_rounded:10:13}" "${msg}" >>"${_log_file}.new"
        new_ts=$((new_ts + step))
    done <"${_log_file}"
    mv "${_log_file}.new" "${_log_file}"
}

_main_loop() {
    if [ "${BOOT}" -eq 1 ]; then
        TAILER_CMD="${LOGREAD} -l 50 -tf"
        BOOT=0
    else
        if [ "${EXTRA_ENTRIES}" -gt 0 ]; then
            TAILER_CMD="${LOGREAD} -l ${EXTRA_ENTRIES} -tf"
        else
            TAILER_CMD="${LOGREAD} -tf"
        fi
    fi

    ${TAILER_CMD} >"${PIPE_NAME}" 2>&1 &
    tailer_pid=$!

    while read -r line; do
        ts="${line:26:14}"
        ts_ms="${ts/./}"
        # shellcheck disable=SC2116
        if ! ts_ns="$(echo $(( ts_ms * 1000 * 1000 )) )" ; then
            echo "PARSE ERROR: '${line}'" >>"${LOCAL_LOG}"
            continue
        fi
        if [ "${MIN_TIMESTAMP}" -gt 0 ]; then
            if [ "${ts_ns}" -le "${MIN_TIMESTAMP}" ]; then
                continue
            fi
        fi
        
        msg_raw="${line:42:2000}"
        msg="$(_escape_json_string "$msg_raw")"

        post_body="${LOKI_MSG_TEMPLATE}"
        post_body="${post_body/TIMESTAMP/$ts_ns}"
        post_body="${post_body/MESSAGE/$msg}"
        if ! _curl_cmd -d "${post_body}" "${LOKI_PUSH_URL}" >>"${LOCAL_LOG}" 2>&1; then
            echo "POST FAILED: '${post_body}'" >>"${LOCAL_LOG}"
        fi
        MIN_TIMESTAMP="${ts_ns}"
        _rotate_local_log
    done <"${PIPE_NAME}"
}

if [ "${BOOT}" -eq 1 ]; then
    if [ "${START_DELAY_ON_BOOT-0}" -gt 0 ]; then
        echo "sleeping ${START_DELAY_ON_BOOT-0} seconds before proceeding" >&2
        sleep "${START_DELAY_ON_BOOT-0}"
    fi
fi

_setup

MIN_TIMESTAMP=0

if [ "${BOOT}" -eq 1 ]; then
    ${LOGREAD} -t >"${BULK_DATA}"
    last_line="$(tail -1 "${BULK_DATA}")"
    ts="${last_line:26:14}"
    ts_ms="${ts/./}"
    # shellcheck disable=SC2116
    if ! ts_ns="$(echo $(( ts_ms * 1000 * 1000 )) )" ; then
        echo "PARSE ERROR: '${last_line}'" >>"${LOCAL_LOG}"
    else
        MIN_TIMESTAMP=${ts_ns}
    fi
    _check_for_skewed_timestamp "${BULK_DATA}"
    _do_bulk_post "${BULK_DATA}"
fi

trap "_teardown" SIGINT SIGTERM EXIT

if [ "${BOOT}" -eq 1 ]; then
    EXTRA_ENTRIES=0
else
    EXTRA_ENTRIES=1
fi

while true; do
    _main_loop
    if [ "${AUTOTEST-0}" -eq 1 ]; then
        exit 0
    fi
    echo "tailer exited, starting over" >&2
    EXTRA_ENTRIES=3
    sleep 1
done
