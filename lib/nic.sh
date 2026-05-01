#!/bin/bash

list_nics() {
    ip link show \
        | awk -F': ' '/^[0-9]+: / && !/lo:/ && !/docker/ && !/veth/ && !/br-/ && !/virbr/ {print $2}' \
        | sed 's/@.*//'
}

get_nic_ip() {
    ip -4 addr show "$1" 2>/dev/null \
        | awk '/inet / {print $2}' \
        | cut -d'/' -f1 \
        | head -1
}

nic_exists() {
    ip link show "$1" &>/dev/null
}

test_promisc() {
    local nic="$1"
    ip link set "$nic" promisc on 2>/dev/null
    if ip link show "$nic" 2>/dev/null | grep -q "PROMISC"; then
        ip link set "$nic" promisc off 2>/dev/null
        return 0
    fi
    ip link set "$nic" promisc off 2>/dev/null
    return 1
}

select_nic() {
    local prompt="$1" exclude="$2"
    local nics=() i=1

    while IFS= read -r nic; do
        [ "$nic" = "$exclude" ] && continue
        nics+=("$nic")
    done < <(list_nics)

    [ ${#nics[@]} -eq 0 ] && die "사용 가능한 NIC가 없습니다."

    echo -e "\n  사용 가능한 NIC 목록:" >&2
    for nic in "${nics[@]}"; do
        local ip
        ip=$(get_nic_ip "$nic")
        if [ -n "$ip" ]; then
            echo "    $i) $nic  (IP: $ip)" >&2
        else
            echo "    $i) $nic  (IP 없음)" >&2
        fi
        ((i++))
    done

    local choice
    while true; do
        read -rp "$(echo -e "  ${BOLD}${prompt}${NC} [1-${#nics[@]}]: ")" choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#nics[@]}" ]; then
            echo "${nics[$((choice-1))]}"
            return 0
        fi
        echo "  올바른 번호를 입력하세요." >&2
    done
}
