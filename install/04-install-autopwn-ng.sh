#!/usr/bin/env bash
# ==========================================================================
#  نصب autopwn-ng در مسیر سیستم با مجوز اجرا
#  استفاده: sudo bash install/04-install-autopwn-ng.sh
# ==========================================================================
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$SRC_DIR/autopwn-ng.sh"
DEST="/usr/local/bin/autopwn-ng"

[ -f "$SRC" ] || { echo "[-] فایل پیدا نشد: $SRC" >&2; exit 1; }

if [ "$(id -u)" -ne 0 ]; then
  echo "[-] با sudo اجرا کن: sudo bash install/04-install-autopwn-ng.sh" >&2
  exit 1
fi

bash -n "$SRC" || { echo "[-] خطای سینتکس در $SRC" >&2; exit 1; }

install -m 755 -o root -g root "$SRC" "$DEST"

[ -x "$DEST" ] || { echo "[-] نصب ناموفق بود: $DEST" >&2; exit 1; }

echo "[+] نصب شد: $DEST"
echo "[+] اجرا: sudo autopwn-ng --help"
