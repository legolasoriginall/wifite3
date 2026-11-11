#!/usr/bin/env bash

sudo apt install -y libssl-dev libnl-3-dev libnl-genl-3-dev pkg-config make gcc
git clone https://github.com/sensepost/hostapd-mana
cd hostapd-mana/hostapd && make -j"$(nproc)" && sudo cp hostapd /usr/local/bin/hostapd-mana
