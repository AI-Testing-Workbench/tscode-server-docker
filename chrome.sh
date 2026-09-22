#!/bin/bash

set -euo pipefail

# OpenSandbox Chrome 沙盒启动脚本：
# 在 VNC 桌面(DISPLAY=:1) 上启动 Google Chrome，DevTools 内部监听 127.0.0.1:9222。
# 由 /root/.start.sh 在 TESTAGENT_ENABLE_CHROME=1 时后台调用，并由 start.sh 用
# socat 把 9222 转发到 0.0.0.0:9922，供容器外按 IP 访问。

flags=()

flags+=(--no-sandbox) # We can't use sandbox in a container

flags+=(--disable-gpu)           # We don't (normally) have a GPU
flags+=(--disable-dev-shm-usage) # We don't (normally) have a shared memory filesystem

flags+=(--no-default-browser-check) # Avoids hanging with a "set chrome as default browser" dialog
flags+=(--no-first-run)             # Avoids hanging with a "set chrome as default browser" dialog

flags+=(--start-maximized) # We're the only thing running, use the whole screen

flags+=(--disable-field-trial-config) # Keeps things consistent and a little faster

# Chrome >= 130 出于安全考虑已停用 --remote-debugging-address，
# DevTools 一律只监听 127.0.0.1，无法直接绑定 0.0.0.0。
# 对外暴露由 start.sh 的 socat(0.0.0.0:9922 -> 127.0.0.1:9222) 完成。
flags+=(--remote-debugging-port=9222)     # Enable remote debugging (仅 loopback)
flags+=(--remote-allow-origins=*)         # 允许任意 Origin 的 DevTools WebSocket 连接(CHROME >= 111 默认校验)
flags+=(--user-data-dir=/tmp/chrome-data) # DevTools remote debugging requires a non-default data directory. Specify this using --user-data-dir.

# Launch Chrome
exec google-chrome "${flags[@]}" "https://www.google.com"
