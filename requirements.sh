#!/data/data/com.termux/files/usr/bin/bash
# Install the packages required by Zaidon / wormgpt_lite on Termux.
set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

if [[ -z "${PREFIX:-}" || ! -x "${PREFIX}/bin/pkg" ]]; then
    printf '%bError: this installer is intended for Termux on Android.%b\n' "$RED" "$NC" >&2
    exit 1
fi

printf '%bUpdating package lists...%b\n' "$YELLOW" "$NC"
pkg update -y

PACKAGES=(bash curl jq coreutils ca-certificates git)
printf '%bInstalling required packages...%b\n' "$YELLOW" "$NC"
pkg install -y "${PACKAGES[@]}"

for cmd in bash curl jq; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        printf '%bRequired command not found after installation: %s%b\n' "$RED" "$cmd" "$NC" >&2
        exit 1
    fi
done

printf '%bDependencies installed successfully.%b\n' "$GREEN" "$NC"
printf 'Next run: bash wormgpt_lite.sh\n'
