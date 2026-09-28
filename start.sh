#!/bin/bash

set -e

# 容器 SSH 指纹生成
# 不同容器的指纹不一致
mkdir -p /run/sshd
ssh-keygen -A

# --- Start ---

# 容器启动只处理可选的软件镜像配置。
if [ "${TESTAGENT_CLOUD_MODE:-}" = "1" ]; then
    if ! python3 - "${TESTAGENT_CLOUD_PIP_URL:-}" "${TESTAGENT_CLOUD_NPM_URL:-}" <<'PY'
import sys
from urllib.parse import urlsplit

for value in sys.argv[1:]:
    if not value:
        continue
    if any(ord(character) < 32 or ord(character) == 127 for character in value):
        raise SystemExit(1)
    if value != value.strip():
        raise SystemExit(1)
    try:
        parsed = urlsplit(value)
        _ = parsed.port
        hostname = parsed.hostname
    except ValueError:
        raise SystemExit(1)
    if parsed.scheme not in ("http", "https") or not parsed.netloc or not hostname:
        raise SystemExit(1)
    if parsed.username is not None or parsed.password is not None:
        raise SystemExit(1)
PY
    then
        echo "[start] PIP/NPM 镜像地址非法" >&2
        exit 1
    fi

    if [ -n "${TESTAGENT_CLOUD_PIP_URL:-}" ]; then
        if ! python3 -m pip config --global set global.index-url "$TESTAGENT_CLOUD_PIP_URL"; then
            echo "[start] PIP 镜像配置失败" >&2
            exit 1
        fi
        echo "[start] PIP 全局镜像配置完成"
    else
        echo "[start] 未配置 PIP 镜像，跳过"
    fi

    if [ -n "${TESTAGENT_CLOUD_NPM_URL:-}" ]; then
        if ! command -v npm >/dev/null 2>&1; then
            echo "[start] NPM 不可用" >&2
            exit 1
        fi
        if ! npm config set registry "$TESTAGENT_CLOUD_NPM_URL" --global; then
            echo "[start] NPM 镜像配置失败" >&2
            exit 1
        fi
        echo "[start] NPM 全局镜像配置完成"
    else
        echo "[start] 未配置 NPM 镜像，跳过"
    fi
    unset TESTAGENT_CLOUD_PIP_URL TESTAGENT_CLOUD_NPM_URL
fi

# 配置 SSH 提示符。
if ! printf '%s\n' 'PS1='\''\u@sandbox:\w\$ '\''' >> /root/.bashrc; then
    echo "[start] SSH 提示符配置写入失败" >&2
    exit 1
fi

# --- End ---

# OpenSandbox Chrome 沙盒：容器创建时注入 TESTAGENT_ENABLE_CHROME=1 即启用。
# 在 VNC 桌面 :1(5901) 上后台拉起 Google Chrome(DevTools 内部 127.0.0.1:9222)，用
# socat 暴露为 0.0.0.0:9922 供容器外按 IP 访问，并启动 noVNC/websockify(6080)
# 供宿主机浏览器实时查看；sshd 照常作为主进程；启动失败时只记录日志，不影响 SSH 功能。
start_browser() {
    local i
    echo "[start] TESTAGENT_ENABLE_CHROME=1: 启动 VNC(:1/5901) 与 Google Chrome(0.0.0.0:9922 -> 127.0.0.1:9222)"

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

    # Chrome >= 130 的 DevTools 只监听 loopback，用 socat 转发到 0.0.0.0:9922。
    # 客户端需以 IP(或 localhost) 访问，Chrome 不接受非 IP/localhost 的 Host。
    if command -v socat >/dev/null 2>&1; then
        socat TCP-LISTEN:9922,fork,reuseaddr TCP:127.0.0.1:9222 >/tmp/socat.log 2>&1 &
    else
        echo "[start] 未找到 socat，Chrome DevTools 无法暴露到 0.0.0.0:9922" >&2
    fi

    # noVNC/websockify：把 VNC(5901) 转成 HTTP/WebSocket，宿主机浏览器经
    # execd /proxy/6080 打开 vnc.html 即可实时查看容器内 Chrome。
    if command -v websockify >/dev/null 2>&1; then
        websockify --web=/usr/share/novnc 6080 localhost:5901 >/tmp/novnc.log 2>&1 &
    else
        echo "[start] 未找到 websockify，跳过 noVNC(6080) 启动" >&2
    fi

    echo "[start] VNC 与 Chrome 已在后台启动，日志见 /tmp/vnc.log、/tmp/chrome.log、/tmp/socat.log、/tmp/novnc.log"
}

case "${TESTAGENT_ENABLE_CHROME:-}" in
    1 | true | TRUE | yes | YES | on | ON)
        start_browser
        ;;
esac

# sshd 为每个会话重新组装环境；传递调用方注入的 TESTAGENT_* 配置。
# 使用 SetEnv 让 22 端口和 connect-fix.sh 启动的额外 sshd 共享同一份环境配置。
write_sshd_environment_config() {
    local sshd_config=/etc/ssh/sshd_config
    local sshd_config_dir=/etc/ssh/sshd_config.d
    local sshd_environment_config="$sshd_config_dir/99-testagent-cloud-env.conf"
    local sshd_environment_temp
    local sshd_config_temp
    local sshd_environment_entry
    local sshd_environment_name
    local sshd_environment_value
    # 固定注入 TLS 旧式重协商兜底：OPENSSL_CONF 供 curl/git/系统 OpenSSL 使用；
    # NODE_OPTIONS 预加载补丁，让 tscode-server 与扩展宿主的 tls.connect 带上
    # SSL_OP_LEGACY_SERVER_CONNECT（Node 不会应用 OpenSSL 的 system_default）。
    local sshd_setenv_line='SetEnv OPENSSL_CONF="/etc/ssl/tscode-openssl.cnf" NODE_OPTIONS="--require /usr/local/lib/tscode/tls-legacy-renegotiation.cjs"'

    if [ ! -f "$sshd_config" ]; then
        echo "[start] 未找到 SSHD 主配置: $sshd_config" >&2
        return 1
    fi
    if [ -L "$sshd_config_dir" ]; then
        echo "[start] SSHD drop-in 配置目录不能是符号链接" >&2
        return 1
    fi
    if ! mkdir -p "$sshd_config_dir"; then
        echo "[start] SSHD drop-in 配置目录创建失败" >&2
        return 1
    fi

    # Ubuntu 默认配置包含这一行；若基础镜像变更导致缺失，启动时补到顶层。
    if ! awk '
        BEGIN { found = 0; in_match = 0 }
        /^[[:space:]]*#/ { next }
        {
            directive = tolower($1)
            if (directive == "match") {
                in_match = 1
            } else if (!in_match && directive == "include" && NF == 2 && $2 == "/etc/ssh/sshd_config.d/*.conf") {
                found = 1
            }
        }
        END { exit(found ? 0 : 1) }
    ' "$sshd_config"; then
        if ! sshd_config_temp=$(mktemp /etc/ssh/.sshd_config.XXXXXX); then
            echo "[start] SSHD 主配置临时文件创建失败" >&2
            return 1
        fi
        if ! {
            printf '%s\n' 'Include /etc/ssh/sshd_config.d/*.conf'
            cat "$sshd_config"
        } > "$sshd_config_temp"; then
            rm -f -- "$sshd_config_temp"
            echo "[start] SSHD Include 配置写入失败" >&2
            return 1
        fi
        if ! chmod --reference="$sshd_config" "$sshd_config_temp" || ! mv -f -- "$sshd_config_temp" "$sshd_config"; then
            rm -f -- "$sshd_config_temp"
            echo "[start] SSHD 主配置更新失败" >&2
            return 1
        fi
    fi

    if [ -L "$sshd_environment_config" ] || {
        [ -e "$sshd_environment_config" ] && [ ! -f "$sshd_environment_config" ]
    }; then
        echo "[start] SSHD 环境配置文件类型非法" >&2
        return 1
    fi
    if ! sshd_environment_temp=$(mktemp "$sshd_config_dir/.99-testagent-cloud-env.conf.XXXXXX"); then
        echo "[start] SSHD 环境配置临时文件创建失败" >&2
        return 1
    fi
    if ! chmod 0644 "$sshd_environment_temp"; then
        rm -f -- "$sshd_environment_temp"
        echo "[start] SSHD 环境配置权限设置失败" >&2
        return 1
    fi

    # SetEnv 的值使用双引号包裹，并转义反斜杠和双引号；控制字符一律拒绝。
    write_sshd_setenv() {
        local environment_name=$1
        local environment_value=$2
        local escaped_value
        local LC_ALL=C

        if [[ ! "$environment_name" =~ ^TESTAGENT[A-Za-z0-9_]*$ ]]; then
            echo "[start] 非法的 SSHD 环境变量名: $environment_name" >&2
            return 1
        fi
        if [[ "$environment_value" == *[[:cntrl:]]* ]]; then
            echo "[start] SSHD 环境变量包含控制字符: $environment_name" >&2
            return 1
        fi

        escaped_value=${environment_value//\\/\\\\}
        escaped_value=${escaped_value//\"/\\\"}
        sshd_setenv_line+=" ${environment_name}=\"${escaped_value}\""
    }

    # 只保留当前环境中符合命名规则的变量；env -0 可安全读取值中的普通空格。
    while IFS= read -r -d '' sshd_environment_entry; do
        sshd_environment_name=${sshd_environment_entry%%=*}
        case "$sshd_environment_name" in
            TESTAGENT*)
                ;;
            *)
                continue
                ;;
        esac
        if [[ ! "$sshd_environment_name" =~ ^TESTAGENT[A-Za-z0-9_]*$ ]]; then
            echo "[start] 非法的 SSHD 环境变量名: $sshd_environment_name" >&2
            rm -f -- "$sshd_environment_temp"
            return 1
        fi
        sshd_environment_value=${sshd_environment_entry#*=}
        if ! write_sshd_setenv "$sshd_environment_name" "$sshd_environment_value"; then
            rm -f -- "$sshd_environment_temp"
            return 1
        fi
    done < <(env -0)

    if [ "$sshd_setenv_line" = 'SetEnv' ]; then
        if ! rm -f -- "$sshd_environment_temp" "$sshd_environment_config"; then
            echo "[start] 空 SSHD 环境配置清理失败" >&2
            return 1
        fi
        echo "[start] 未注入 TESTAGENT 环境变量，跳过 SSH SetEnv 配置"
        return 0
    fi
    if ! printf '%s\n' "$sshd_setenv_line" > "$sshd_environment_temp"; then
        rm -f -- "$sshd_environment_temp"
        echo "[start] SSHD 环境配置写入失败" >&2
        return 1
    fi
    if ! mv -f -- "$sshd_environment_temp" "$sshd_environment_config"; then
        rm -f -- "$sshd_environment_temp"
        echo "[start] SSHD 环境配置安装失败" >&2
        return 1
    fi
    if ! /usr/sbin/sshd -t; then
        echo "[start] SSHD 配置校验失败" >&2
        return 1
    fi
    echo "[start] SSHD TESTAGENT 环境配置已生成并通过校验"
}

if ! write_sshd_environment_config; then
    exit 1
fi

# 启动 SSH 服务
if [ "$#" -eq 0 ]; then
    set -- /usr/sbin/sshd -D -e
fi

exec "$@"
