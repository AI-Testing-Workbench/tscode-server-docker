#!/bin/bash

set -euo pipefail

# OpenSandbox Chrome 沙盒启动脚本：
# 在 VNC 桌面(DISPLAY=:1) 上启动 Google Chrome，并开启 DevTools 远程调试端口 9222。
# 由 /root/.start.sh 在 TESTAGENT_ENABLE_CHROME=1 时后台调用。

flags=()

flags+=(--no-sandbox) # We can't use sandbox in a container

flags+=(--disable-gpu)           # We don't (normally) have a GPU
flags+=(--disable-dev-shm-usage) # We don't (normally) have a shared memory filesystem

flags+=(--no-default-browser-check) # Avoids hanging with a "set chrome as default browser" dialog
flags+=(--no-first-run)             # Avoids hanging with a "set chrome as default browser" dialog

flags+=(--start-maximized) # We're the only thing running, use the whole screen

flags+=(--disable-field-trial-config) # Keeps things consistent and a little faster

flags+=(--remote-debugging-port=9222)     # Enable remote debugging
flags+=(--user-data-dir=/tmp/chrome-data) # DevTools remote debugging requires a non-default data directory. Specify this using --user-data-dir.

# Launch Chrome
exec google-chrome "${flags[@]}" "https://www.google.com"
