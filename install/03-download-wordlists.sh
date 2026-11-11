#!/usr/bin/env bash

sudo mkdir -p /opt/wordlists && cd /opt/wordlists

# rockyou
wget -q https://github.com/brannondorsey/naive-hashcat/releases/download/data/rockyou.txt

# SecLists (پسوردهای پیش‌فرض روترها)
git clone --depth 1 https://github.com/danielmiessler/SecLists

# Probable-Wordlists
git clone --depth 1 https://github.com/berzerk0/Probable-Wordlists

# rule های تهاجمی
git clone --depth 1 https://github.com/NotSoSecure/password_cracking_rules
sudo cp password_cracking_rules/OneRuleToRuleThemAll.rule /usr/share/hashcat/rules/

# keyboard walk
git clone https://github.com/hashcat/kwprocessor && cd kwprocessor && make
sudo cp kwp /usr/local/bin/ && sudo cp keyboard-base.txt keyboard-rules.txt /opt/wordlists/
