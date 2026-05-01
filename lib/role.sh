#!/bin/bash

last_octet() {
    echo "$1" | awk -F'.' '{print $NF}'
}

net_prefix() {
    echo "$1" | awk -F'.' '{print $1"."$2"."$3}'
}

in_range() {
    local octet="$1" start end
    IFS='-' read -r start end <<< "$2"
    [ "$octet" -ge "$start" ] && [ "$octet" -le "$end" ]
}

detect_role() {
    local octet
    octet=$(last_octet "$1")
    if in_range "$octet" "$CONTROLLER_RANGE"; then
        echo "controller"
    elif in_range "$octet" "$COMPUTE_RANGE"; then
        echo "compute"
    elif in_range "$octet" "$BLOCK_RANGE"; then
        echo "block"
    else
        echo "unknown"
    fi
}

gen_hostname() {
    local role="$1" octet
    octet=$(last_octet "$2")
    case "$role" in
        controller) echo "controller" ;;
        compute)
            local start; IFS='-' read -r start _ <<< "$COMPUTE_RANGE"
            printf "compute%02d" $((octet - start + 1))
            ;;
        block)
            local start; IFS='-' read -r start _ <<< "$BLOCK_RANGE"
            printf "block%02d" $((octet - start + 1))
            ;;
        *) echo "node-$octet" ;;
    esac
}

find_controller_ip() {
    local prefix start end
    prefix=$(net_prefix "$MY_IP")
    IFS='-' read -r start end <<< "$CONTROLLER_RANGE"
    log_info "Controller IP 스캔 중 (${prefix}.${start} ~ ${prefix}.${end})..." >&2
    for i in $(seq "$start" "$end"); do
        local ip="${prefix}.${i}"
        if ping -c1 -W1 "$ip" &>/dev/null; then
            echo "$ip"
            return 0
        fi
    done
    return 1
}

# 지정 범위에서 살아있는 노드 IP 목록을 공백 구분으로 출력 (병렬 ping)
scan_live_nodes() {
    local range="$1"
    local prefix start end tmp
    prefix=$(net_prefix "$MY_IP")
    IFS='-' read -r start end <<< "$range"
    tmp=$(mktemp)
    for i in $(seq "$start" "$end"); do
        local ip="${prefix}.${i}"
        { ping -c1 -W1 "$ip" &>/dev/null && echo "$ip" >> "$tmp"; } &
    done
    wait
    sort -t. -k4 -n "$tmp"
    rm -f "$tmp"
}
