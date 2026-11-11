# wifite4

مجموعه‌ای از اسکریپت‌های نصب و اجرا برای زنجیره‌ی تست نفوذ وای‌فای روی لینوکس، حول ابزار `autopwn-ng`.

> ⚠️ **فقط روی شبکه‌های خودت یا شبکه‌هایی که اجازه‌ی کتبی برای تستشان داری.** تست نفوذ وای‌فای بدون مجوز در بیشتر کشورها جرم است. مسئولیت استفاده با خودت است.

---

## ساختار مخزن

| مسیر | توضیح |
|---|---|
| [`autopwn-ng.sh`](autopwn-ng.sh) | خودِ ابزار: زنجیره‌ی کامل برداشت → کرک → evil twin → post-exploit و تولید گزارش |
| [`install/01-install-packages.sh`](install/01-install-packages.sh) | نصب بسته‌های پایه: `aircrack-ng`، `hcxtools`، `hcxdumptool`، `hashcat`، `reaver`، `mdk4`، `kismet`، `bettercap` و… |
| [`install/02-build-hostapd-mana.sh`](install/02-build-hostapd-mana.sh) | نصب پیش‌نیازهای کامپایل و ساخت `hostapd-mana` و نصب آن در `/usr/local/bin` |
| [`install/03-download-wordlists.sh`](install/03-download-wordlists.sh) | دانلود `rockyou`، `SecLists`، `Probable-Wordlists`، ruleهای تهاجمی و ساخت `kwp` در `/opt/wordlists` |
| [`install/04-install-autopwn-ng.sh`](install/04-install-autopwn-ng.sh) | نصب `autopwn-ng` در `/usr/local/bin/autopwn-ng` با مجوز اجرا (`755`) و بررسی سینتکس پیش از نصب |
| [`examples/run-autopwn-ng.sh`](examples/run-autopwn-ng.sh) | نمونه‌ی فراخوانی‌ها: پیش‌فرض، `stealth`، `brute`، هدف مشخص، بدون فازهای بلند |

---

## پیش‌نیازها

- لینوکس با `apt` (کالی، پارروت، اوبونتو و مشابه)
- `sudo` / دسترسی root
- **دو** دانگل وای‌فای برای فاز evil twin (یکی برای مانیتور مود، یکی برای AP قلابی)؛ با یک دانگل هم اجرا می‌شود ولی twin خودکار غیرفعال می‌شود
- فضای کافی برای وردلیست‌ها (چند صد مگابایت)

## نصب

```bash
sudo bash install/01-install-packages.sh
sudo bash install/02-build-hostapd-mana.sh
sudo bash install/03-download-wordlists.sh

# نصب ابزار در مسیر سیستم با مجوز اجرا
sudo bash install/04-install-autopwn-ng.sh
```

## استفاده

```bash
sudo autopwn-ng -i wlan1 -I wlan2                 # پیش‌فرض، همه‌ی فازها
sudo autopwn-ng -i wlan1 -p stealth               # برداشت طولانی‌تر، MAC رندوم
sudo autopwn-ng -i wlan1 -I wlan2 -p brute        # تهاجمی، workload بالا
sudo autopwn-ng -i wlan1 --target AA:BB:CC:DD:EE:FF
sudo autopwn-ng --no-twin --no-post -t 90
sudo autopwn-ng --help
```

### گزینه‌ها

| گزینه | توضیح | پیش‌فرض |
|---|---|---|
| `-p` | پروفایل: `stealth` \| `normal` \| `brute` | `normal` |
| `-t` | مدت برداشت به ثانیه | `120` |
| `-i` | اینترفیس اصلی (مانیتور مود) | اولین اینترفیس وای‌فای |
| `-I` | اینترفیس دوم برای evil twin | دومین اینترفیس |
| `-w` | فایل وردلیست اضافی | — |
| `-d` | پوشه‌ی دیکشنری‌ها | `/opt/wordlists` |
| `--target` | BSSID هدف | — |
| `--no-wps` | رد کردن فاز WPS | — |
| `--no-twin` | رد کردن فاز evil twin | — |
| `--no-post` | رد کردن فاز post-exploit | — |

خروجی‌ها و گزارش هر اجرا در یک پوشه‌ی موقت `/tmp/autopwn.XXXXXX/report/` ساخته می‌شود (`summary.md` و `summary.json`).

## فازهای اجرا

0. **آماده‌سازی** — انتخاب اینترفیس‌ها، تشخیص GPU برای hashcat، مانیتور مود، رندوم کردن MAC در حالت `stealth`
1. **برداشت** — `hcxdumptool` برای PMKID/EAPOL/EAP، `mdk4` برای دِاوث، `airodump-ng` برای اسکن موازی
2. **نرمال‌سازی** — `hcxpcapngtool` و `hcxhashtool` برای استخراج و حذف تکراری هش‌ها
3. **کرک** — لایه‌لایه با hashcat: دیکشنری مشتق از SSID، `rockyou`، ruleها، ماسک عددی/موبایل ایرانی، هیبرید، keyboard walk، و MSCHAPv2 برای Enterprise
4. **WPS** — Pixie Dust با `reaver`
5. **Evil Twin** — `hostapd-mana` (یا `wifiphisher`) و جمع‌آوری اعتبارنامه
6. **Post-exploit** — ساخت اسکریپت اتصال به شبکه کرک‌شده + MITM با `bettercap`

## نکات شناخته‌شده

- `-h/--help` با `sed -n '2,8p'` سرصفحه‌ی فایل را چاپ می‌کند، پس با تغییر هدر اسکریپت راهنما هم تغییر می‌کند.
- در انتخاب پروفایل، `CAPTURE=${CAPTURE:-240}` مقدار پیش‌فرض بالای فایل (`120`) را بازنویسی نمی‌کند؛ برای تغییر واقعی زمان برداشت از `-t` استفاده کن.
- استخراج رمز WPS با `grep -oP` انجام می‌شود و به `grep` با پشتیبانی PCRE نیاز دارد.
- فاز evil twin ۱۸۰ ثانیه منتظر قربانی می‌ماند؛ در محیط شلوغ ممکن است کافی نباشد.

## سلب مسئولیت

این ابزار برای تست نفوذ مجاز و آموزش ساخته شده است. استفاده‌ی آن روی شبکه‌هایی که مالکشان نیستی یا اجازه نداری، نقض قوانین است.
