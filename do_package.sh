#!/bin/bash
set -e
apt-get update -qq && apt-get install -y -qq ciopfs
mkdir /windrive
ciopfs /real_c /windrive
cd /out
# Depot tools has package_from_installed.py
python3 run_packager.py 2022 -w 10.0.26100.0 || exit 1
