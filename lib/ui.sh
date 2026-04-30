#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

PREFLIGHT_ERRORS=0
PREFLIGHT_WARNS=0

log_ok()     { echo -e "${GREEN}[✓]${NC} $1"; }
log_warn()   { echo -e "${YELLOW}[!]${NC} $1"; ((PREFLIGHT_WARNS++)) || true; }
log_error()  { echo -e "${RED}[✗]${NC} $1"; ((PREFLIGHT_ERRORS++)) || true; }
log_info()   { echo -e "${BLUE}[→]${NC} $1"; }
log_step()   { echo -e "\n${BOLD}── $1${NC}"; }
log_header() {
    echo -e "\n${BOLD}${BLUE}══════════════════════════════════════${NC}"
    echo -e "${BOLD}${BLUE}  $1${NC}"
    echo -e "${BOLD}${BLUE}══════════════════════════════════════${NC}\n"
}

die() {
    echo -e "${RED}[✗] 오류: $1${NC}" >&2
    exit 1
}

prompt_input() {
    local msg="$1" default="$2" result
    if [ -n "$default" ]; then
        read -rp "$(echo -e "  ${BOLD}${msg}${NC} [${default}]: ")" result
        echo "${result:-$default}"
    else
        read -rp "$(echo -e "  ${BOLD}${msg}${NC}: ")" result
        echo "$result"
    fi
}

prompt_secret() {
    local msg="$1" result
    read -rsp "$(echo -e "  ${BOLD}${msg}${NC}: ")" result
    echo >&2
    echo "$result"
}

prompt_confirm() {
    local msg="$1" answer
    read -rp "$(echo -e "  ${BOLD}${msg}${NC} [Y/n]: ")" answer
    [[ "${answer,,}" =~ ^(n|no)$ ]] && return 1 || return 0
}

check_root() {
    [ "$(id -u)" -eq 0 ] || die "root 권한으로 실행하세요: sudo $0"
}
