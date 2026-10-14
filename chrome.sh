#!/bin/bash

set -euo pipefail

# OpenSandbox Chrome 沙盒启动脚本：
# 在 VNC 桌面(DISPLAY=:1) 上启动 Google Chrome，DevTools 内部监听 127.0.0.1:9222。
# 由 /root/.start.sh 在 TESTAGENT_ENABLE_CHROME=1 时后台调用，并由 start.sh 用
# socat 把 9222 转发到 0.0.0.0:9922，供容器外按 IP 访问。

# 浏览器界面语言默认使用中文；Chromium 会优先读取 LANGUAGE 决定 UI 语言。
# 允许外部通过注入 LANGUAGE 覆盖默认值。
export LANGUAGE="${LANGUAGE:-zh_CN.UTF-8}"

flags=()

flags+=(--no-sandbox) # We can't use sandbox in a container

flags+=(--disable-gpu)           # We don't (normally) have a GPU
flags+=(--disable-dev-shm-usage) # We don't (normally) have a shared memory filesystem

flags+=(--no-default-browser-check) # Avoids hanging with a "set chrome as default browser" dialog
flags+=(--no-first-run)             # Avoids hanging with a "set chrome as default browser" dialog

# 容器内没有窗口管理器，--start-maximized 不会生效，会留下右侧黑边。
# 显式指定窗口尺寸与位置铺满 VNC 桌面（需与 start.sh 中 Xtigervnc 的 -geometry 1280x1024 一致）。
flags+=(--window-size=1280,1024)
flags+=(--window-position=0,0)

flags+=(--disable-field-trial-config) # Keeps things consistent and a little faster

# 允许访问 http 地址：关闭 Chrome 自动把 http 升级为 https 的相关特性。
flags+=(--disable-features=AutoupgradeHttps,HttpsUpgrades,UpgradeInsecureRequests)

# Chrome >= 130 出于安全考虑已停用 --remote-debugging-address，
# DevTools 一律只监听 127.0.0.1，无法直接绑定 0.0.0.0。
# 对外暴露由 start.sh 的 socat(0.0.0.0:9922 -> 127.0.0.1:9222) 完成。
flags+=(--remote-debugging-port=9222)     # Enable remote debugging (仅 loopback)
flags+=(--remote-allow-origins=*)         # 允许任意 Origin 的 DevTools WebSocket 连接(CHROME >= 111 默认校验)
flags+=(--user-data-dir=/tmp/chrome-data) # DevTools remote debugging requires a non-default data directory. Specify this using --user-data-dir.

# Launch Chrome
exec google-chrome "${flags[@]}" "https://www.google.com"
