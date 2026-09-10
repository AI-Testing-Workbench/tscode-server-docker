#!/bin/bash

set -e

# 容器 SSH 指纹生成
# 不同容器的指纹不一致
mkdir -p /run/sshd
ssh-keygen -A

# --- Start ---

echo  "环境变量测试"
printenv | grep '^TESTAGENT'

# --- End ---

# OpenSandbox Chrome 沙盒：容器创建时注入 TESTAGENT_ENABLE_CHROME=1 即启用。
# 在 VNC 桌面 :1(5901) 上后台拉起 Google Chrome(DevTools 9222)，并启动
# noVNC/websockify(6080) 供宿主机浏览器实时查看；sshd 照常作为主进程；
# 启动失败时只记录日志，不影响 SSH 功能。
start_browser() {
    local i
    echo "[start] TESTAGENT_ENABLE_CHROME=1: 启动 VNC(:1/5901) 与 Google Chrome(9222)"

    Xtigervnc :1 -geometry 1280x1024 -SecurityTypes None >/tmp/vnc.log 2>&1 &
    for i in $(seq 1 100); do
        if xdpyinfo -display :1 >/dev/null 2>&1; then
            break
        fi
        sleep 0.2
    done
    if ! xdpyinfo -display :1 >/dev/null 2>&1; then
        echo "[start] VNC 未在超时内就绪，日志如下：" >&2
        cat /tmp/vnc.log >&2 || true
        return 0
    fi

    DISPLAY=:1 /root/.chrome.sh >/tmp/chrome.log 2>&1 &

    # noVNC/websockify：把 VNC(5901) 转成 HTTP/WebSocket，宿主机浏览器经
    # execd /proxy/6080 打开 vnc.html 即可实时查看容器内 Chrome。
    if command -v websockify >/dev/null 2>&1; then
        websockify --web=/usr/share/novnc 6080 localhost:5901 >/tmp/novnc.log 2>&1 &
    else
        echo "[start] 未找到 websockify，跳过 noVNC(6080) 启动" >&2
    fi

    echo "[start] VNC 与 Chrome 已在后台启动，日志见 /tmp/vnc.log、/tmp/chrome.log、/tmp/novnc.log"
}

case "${TESTAGENT_ENABLE_CHROME:-}" in
    1 | true | TRUE | yes | YES | on | ON)
        start_browser
        ;;
esac

# 启动 SSH 服务
if [ "$#" -eq 0 ]; then
    set -- /usr/sbin/sshd -D -e
fi

exec "$@"
