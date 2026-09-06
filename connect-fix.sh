#!/bin/bash
#
# 修复 OpenSandbox 沙盒容器的 SSH 可达性, 供 testagent-cloud-remote-ssh 使用。
#
# 背景: OpenSandbox(docker bridge) 只把容器内 44772(execd HTTP 入口)/8080 发布到宿主机,
#       容器内 sshd(22) 并未发布; 扩展实际连接的是宿主机上映射到 44772 的那个端口,
#       而 44772 被 execd 占用, 直接连会收到 HTTP 应答导致 SSH "Connection closed"。
# 解决: 杀掉 execd 释放 44772, 再额外启动一个监听 44772 的 sshd。
#
# 用法: 每次在 VS Code 插件里新建容器后, 在宿主机(能 docker ps 看到 sandbox-* 的那台)执行:
#       ./connect-fix.sh
# 可重复执行(幂等): 未改动容器内系统配置, 只是额外起了一个 sshd 进程。
set -u

CONFIG="${HOME}/.local/share/testagent/config"
[ -f "$CONFIG" ] || { echo "未找到配置文件: $CONFIG"; exit 1; }

# 解析 config (ssh-config 格式), 提取每个 Host 段的 ContainerId 和 Port;
# 可能有历史残留段, 只挑当前 docker 中正在运行的 sandbox 容器。
pick=$(
    awk '
        /^[Hh][Oo][Ss][Tt][ \t]/ {
            if (id != "") print id "\t" port;
            id = ""; port = "";
        }
        /^[ \t]*[Cc][Oo][Nn][Tt][Aa][Ii][Nn][Ee][Rr][Ii][Dd][ \t]+/ { id = $2; }
        /^[ \t]*[Pp][Oo][Rr][Tt][ \t]+/ { port = $2; }
        END { if (id != "") print id "\t" port; }
    ' "$CONFIG"
)

CID=""
HOST_PORT=""
while read -r cid port; do
    [ -n "$cid" ] || continue
    if docker ps --format '{{.Names}}' | grep -qx "sandbox-$cid"; then
        CID="$cid"
        HOST_PORT="$port"
        break
    fi
done <<< "$pick"

if [ -z "$CID" ]; then
    echo "未找到正在运行的 sandbox 容器, 请先在 VS Code 中创建 TestAgent Cloud 服务"
    exit 1
fi
if [ -z "$HOST_PORT" ]; then
    echo "配置中未找到 Port, 请检查 $CONFIG"
    exit 1
fi

CNAME="sandbox-$CID"
echo "目标容器: $CNAME  宿主 SSH 端口: $HOST_PORT"

docker exec "$CNAME" sh -c '
    # 1) execd 可能占用 44772, 有则杀掉并等它释放。
    #    用 -x 按进程名匹配, 避免 -f 模式串出现在本 shell 命令行里把自己也杀掉。
    pkill -x execd 2>/dev/null || true
    # 仅在 execd 仍占着 44772 时等待其退出; 若是我们自己启动的 sshd 在听则直接跳过
    i=0
    while ss -lntp 2>/dev/null | grep ":44772 " | grep -q "execd"; do
        i=$((i + 1))
        [ "$i" -gt 20 ] && { echo "44772 端口仍被 execd 占用, 中止"; exit 1; }
        sleep 0.5
    done

    # 2) 若 44772 上还没有 sshd, 额外启动一个监听 44772 的 sshd。
    #    不改写 sshd_config, 也不影响原有 22 端口的 sshd。
    if ! ss -lnt 2>/dev/null | grep -q ":44772 "; then
        mkdir -p /run/sshd
        /usr/sbin/sshd -o "Port=44772" -o "PidFile=/run/sshd-44772.pid" 2>/dev/null || true
        sleep 1
    fi

    if ss -lnt 2>/dev/null | grep -q ":44772 "; then
        echo "OK: 容器内 sshd 已监听 44772"
    else
        echo "FAIL: sshd 未能监听 44772" >&2
        exit 1
    fi
' || exit 1

echo "=== 从宿主机验证 SSH ==="
ssh -o PreferredAuthentications=none -o PubkeyAuthentication=no \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=5 \
    -p "$HOST_PORT" root@127.0.0.1 "echo SSH_OK && hostname" \
    && echo "验证通过, 现在可以在 TSCode 里重试连接"
