#!/bin/bash

set -e
# Container diagnostics must share stdout with the startup messages.
exec 2>&1

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
        pip_trusted_host=$(python3 -c 'import sys; from urllib.parse import urlsplit; print(urlsplit(sys.argv[1]).netloc)' "$TESTAGENT_CLOUD_PIP_URL")
        if ! python3 -m pip config --global set global.index-url "$TESTAGENT_CLOUD_PIP_URL"; then
            echo "[start] PIP 镜像配置失败" >&2
            exit 1
        fi
        if ! python3 -m pip config --global set global.trusted-host "$pip_trusted_host"; then
            echo "[start] PIP trusted-host 配置失败" >&2
            exit 1
        fi
        unset pip_trusted_host
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
        if ! npm config set strict-ssl false --global; then
            echo "[start] NPM strict-ssl 配置失败" >&2
            exit 1
        fi
        echo "[start] NPM 全局镜像配置完成"
    else
        echo "[start] 未配置 NPM 镜像，跳过"
    fi
    unset TESTAGENT_CLOUD_PIP_URL TESTAGENT_CLOUD_NPM_URL
fi

install_git_helpers() {
    local helper helper_source helper_target helper_temp
    local helper_dir=/root/.git-helper
    local helper_temp_dir=/root/.git-helper-temp

    if [ -L "$helper_temp_dir" ] || {
        [ -e "$helper_temp_dir" ] && [ ! -d "$helper_temp_dir" ]
    }; then
        echo "[start] Git helper 暂存目录类型非法" >&2
        return 1
    fi
    if [ -L "$helper_dir" ] || { [ -e "$helper_dir" ] && [ ! -d "$helper_dir" ]; }; then
        echo "[start] Git helper 目录类型非法" >&2
        return 1
    fi
    if ! install -d -m 0700 "$helper_dir"; then
        echo "[start] Git helper 目录创建失败" >&2
        return 1
    fi

    if [ ! -d "$helper_temp_dir" ]; then
        for helper in init-credential-helper runtime-credential-helper; do
            helper_target=$helper_dir/$helper
            if [ -L "$helper_target" ] || [ ! -f "$helper_target" ]; then
                echo "[start] Git helper 缺失或类型非法: $helper_target" >&2
                return 1
            fi
        done
        return 0
    fi

    for helper in init-credential-helper runtime-credential-helper; do
        helper_source=$helper_temp_dir/$helper
        helper_target=$helper_dir/$helper
        if [ -L "$helper_source" ] || [ ! -f "$helper_source" ]; then
            echo "[start] Git helper 暂存文件缺失或类型非法: $helper_source" >&2
            return 1
        fi
        if [ -L "$helper_target" ] || {
            [ -e "$helper_target" ] && [ ! -f "$helper_target" ]
        }; then
            echo "[start] Git helper 目标类型非法: $helper_target" >&2
            return 1
        fi

        helper_temp=$(mktemp "$helper_dir/.${helper}.XXXXXX") || {
            echo "[start] Git helper 临时文件创建失败" >&2
            return 1
        }
        if ! cat -- "$helper_source" > "$helper_temp" \
            || ! chmod 0700 "$helper_temp" \
            || ! mv -fT -- "$helper_temp" "$helper_target"; then
            rm -f -- "$helper_temp"
            echo "[start] Git helper 安装失败: $helper_target" >&2
            return 1
        fi
    done

    if ! chmod 0700 "$helper_dir" || ! rm -rf -- "$helper_temp_dir"; then
        echo "[start] Git helper 暂存目录清理失败" >&2
        return 1
    fi
}

if ! install_git_helpers; then
    exit 1
fi

# 启动时启用运行期 Git 认证入口；后续手动 Git 初始化会临时切换到 init helper。
GIT_HELPER_DIR=/root/.git-helper
GIT_RUNTIME_HELPER=$GIT_HELPER_DIR/runtime-credential-helper
GIT_REJECTED_FILE=$GIT_HELPER_DIR/.runtime-credential-rejected
RUNTIME_GIT=/usr/local/bin/git

if [ ! -x /usr/bin/git ] || [ ! -x "$GIT_RUNTIME_HELPER" ]; then
    echo "[start] Git 或运行期 credential helper 不可用" >&2
    exit 1
fi
if [ -L "$RUNTIME_GIT" ] || { [ -e "$RUNTIME_GIT" ] && [ ! -f "$RUNTIME_GIT" ]; }; then
    echo "[start] 运行期 Git 入口类型非法" >&2
    exit 1
fi

runtime_git_temp=$(mktemp "$GIT_HELPER_DIR/.runtime-git.XXXXXX") || {
    echo "[start] 运行期 Git 入口临时文件创建失败" >&2
    exit 1
}
if ! cat > "$runtime_git_temp" <<'SH'
#!/bin/bash

set -u
REAL_GIT=/usr/bin/git
REJECTED_FILE=__REJECTED_FILE__
REMOTE_OPERATION=0

for argument in "$@"; do
    case "$argument" in
        clone | fetch | pull | push | ls-remote | submodule)
            REMOTE_OPERATION=1
            break
            ;;
    esac
done

if [ "$REMOTE_OPERATION" -eq 0 ]; then
    exec "$REAL_GIT" "$@"
fi

OUTPUT_FILE=$(mktemp "${TMPDIR:-/tmp}/tscode-runtime-git.XXXXXX") || exec "$REAL_GIT" "$@"
"$REAL_GIT" "$@" > >(tee "$OUTPUT_FILE") 2> >(tee -a "$OUTPUT_FILE" >&2)
GIT_STATUS=$?
wait

if [ "$GIT_STATUS" -eq 0 ] || [ ! -f "$REJECTED_FILE" ] || ! grep -Eiq -- \
    'authentication failed|authentication required|invalid (username|user(name)?|password|token)|incorrect (username|password)|access denied|unauthorized|http basic:.*access denied|requested url returned error: (401|403)|remote:.*(401|403)' \
    "$OUTPUT_FILE"; then
    rm -f -- "$OUTPUT_FILE"
    exit "$GIT_STATUS"
fi

rm -f -- "$OUTPUT_FILE"
exec "$REAL_GIT" "$@"
SH
then
    rm -f -- "$runtime_git_temp"
    echo "[start] 运行期 Git 入口写入失败" >&2
    exit 1
fi
if ! sed -i "s|__REJECTED_FILE__|$GIT_REJECTED_FILE|g" "$runtime_git_temp" \
    || ! chmod 0755 "$runtime_git_temp" \
    || ! mv -fT -- "$runtime_git_temp" "$RUNTIME_GIT"; then
    rm -f -- "$runtime_git_temp"
    echo "[start] 运行期 Git 入口安装失败" >&2
    exit 1
fi

if ! /usr/bin/git config --global --replace-all credential.helper "$GIT_RUNTIME_HELPER"; then
    echo "[start] 运行期 credential helper 配置失败" >&2
    exit 1
fi
echo "[start] 运行期 Git 入口和 credential helper 已启用"

# 从已挂载的身份文件恢复 Git 身份；身份缺失时不设置占位值。
GIT_EXTRA_FILE=$GIT_HELPER_DIR/.git-extra
if [ -L "$GIT_EXTRA_FILE" ] || { [ -e "$GIT_EXTRA_FILE" ] && [ ! -f "$GIT_EXTRA_FILE" ]; }; then
    echo "[start] Git 身份文件类型非法" >&2
    exit 1
fi
if [ -f "$GIT_EXTRA_FILE" ]; then
    if [ "$(stat -c '%h' "$GIT_EXTRA_FILE")" != "1" ]; then
        echo "[start] Git 身份文件链接数非法" >&2
        exit 1
    fi
    GIT_USERNAME=""
    GIT_EMAIL=""
    while IFS='=' read -r key value; do
        case "$key" in
            git_username) GIT_USERNAME=$value ;;
            git_email) GIT_EMAIL=$value ;;
        esac
    done < "$GIT_EXTRA_FILE"
    if [ -n "$GIT_USERNAME" ]; then
        if [[ "$GIT_USERNAME" == *[[:cntrl:]]* || "$GIT_EMAIL" == *[[:cntrl:]]* ]]; then
            echo "[start] Git 身份包含控制字符" >&2
            exit 1
        fi
        if ! /usr/bin/git config --global --replace-all user.name "$GIT_USERNAME" \
            || ! /usr/bin/git config --global --replace-all user.email "$GIT_EMAIL"; then
            echo "[start] Git 用户身份配置失败" >&2
            exit 1
        fi
        echo "[start] 已从本地身份文件恢复 Git 用户身份"
    else
        echo "[start] 本地身份文件没有用户名，跳过 Git 身份配置"
    fi
    unset GIT_USERNAME GIT_EMAIL key value
else
    echo "[start] 未找到本地 Git 身份文件，跳过 Git 身份配置"
fi

# SSH 登录时清理 IDE 注入的 askpass 环境，避免覆盖 credential helper。
SSH_BASHRC=/root/.bashrc
SSH_ASKPASS_UNSET='unset GIT_ASKPASS VSCODE_GIT_IPC_HANDLE VSCODE_GIT_ASKPASS_MAIN VSCODE_GIT_ASKPASS_NODE VSCODE_GIT_ASKPASS_EXTRA_ARGS GIT_TERMINAL_PROMPT'
if [ -L "$SSH_BASHRC" ] || { [ -e "$SSH_BASHRC" ] && [ ! -f "$SSH_BASHRC" ]; }; then
    echo "[start] SSH bashrc 文件类型非法" >&2
    exit 1
fi
if ! grep -Fqx -- "$SSH_ASKPASS_UNSET" "$SSH_BASHRC" 2>/dev/null; then
    if ! printf '%s\n' "$SSH_ASKPASS_UNSET" >> "$SSH_BASHRC"; then
        echo "[start] SSH askpass 环境清理配置写入失败" >&2
        exit 1
    fi
fi

# 有已挂载仓库时进入仓库目录；否则继续使用镜像默认的 /app。
GITEE_REPOSITORY=${TESTAGENT_CLOUD_GITEE_REPOSITORY:-}
SSH_WORKDIR=/app
case "$GITEE_REPOSITORY" in
    "" | . | .. | *..* | */* | *\\* | *\?* | *\#* | *\%* | *[[:space:]]* | *[[:cntrl:]]*)
        echo "[start] 仓库目录未配置或名称非法，使用默认 SSH 登录目录 /app"
        ;;
    *)
        GIT_REPOSITORY_DIR=/app/$GITEE_REPOSITORY
        if [ -d "$GIT_REPOSITORY_DIR" ] && [ ! -L "$GIT_REPOSITORY_DIR" ]; then
            SSH_WORKDIR=$GIT_REPOSITORY_DIR
        else
            echo "[start] 预期仓库目录不存在，使用默认 SSH 登录目录 /app"
        fi
        ;;
esac

SSH_PROFILE=/etc/profile.d/app.sh
if [ -L "$SSH_PROFILE" ] || { [ -e "$SSH_PROFILE" ] && [ ! -f "$SSH_PROFILE" ]; }; then
    echo "[start] SSH profile 文件类型非法" >&2
    exit 1
fi
ssh_profile_temp=$(mktemp /etc/profile.d/.app.sh.XXXXXX) || {
    echo "[start] SSH profile 临时文件创建失败" >&2
    exit 1
}
if ! {
    printf '%s\n' "$SSH_ASKPASS_UNSET"
    printf 'cd -- %q\n' "$SSH_WORKDIR"
} > "$ssh_profile_temp" \
    || ! chmod 0644 "$ssh_profile_temp" \
    || ! mv -fT -- "$ssh_profile_temp" "$SSH_PROFILE"; then
    rm -f -- "$ssh_profile_temp"
    echo "[start] SSH 登录环境配置失败" >&2
    exit 1
fi
echo "[start] SSH 登录目录设为 $SSH_WORKDIR"

# 配置 SSH 提示符。
if ! printf '%s\n' 'PS1='\''\u@sandbox:\w\$ '\''' >> /root/.bashrc; then
    echo "[start] SSH 提示符配置写入失败" >&2
    exit 1
fi

# --- End ---

# 解析容器外可达的 host，与 tscode 扩展的 resolveShareHost（"复制 Web UI 连接"）保持一致：
# 优先 TESTAGENT_SHARE_HOST 覆盖，否则取第一个非 loopback 的 IPv4，最后回退 127.0.0.1。
resolve_share_host() {
    if [ -n "${TESTAGENT_SHARE_HOST:-}" ]; then
        printf '%s' "$TESTAGENT_SHARE_HOST"
        return
    fi
    local ip
    ip="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -v '^127\.' | grep -v '^$' | head -n1)"
    if [ -z "$ip" ]; then
        ip="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)"
    fi
    printf '%s' "${ip:-127.0.0.1}"
}

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

    # 守护式启动 Chrome：窗口被关闭（进程退出）后自动重新拉起，保证 VNC 上始终有浏览器。
    (
        while true; do
            # `|| true` 防止 set -e 因 Chrome 非 0 退出（如崩溃）而终止该守护循环。
            DISPLAY=:1 /root/.chrome.sh >>/tmp/chrome.log 2>&1 || true
            echo "[start] Chrome 已退出，1 秒后自动重启 $(date '+%F %T')" >>/tmp/chrome.log
            sleep 1
        done
    ) &

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

    # 常驻 Chrome 的 CDP 端点：容器内插件/工具走 loopback:9222，容器外走 socat:9922。
    # 由 write_sshd_environment_config 的 TESTAGENT* SetEnv 逻辑自动注入 SSH 会话，
    # 供 tscode 扩展(TestAgent)与用户自己的自动化工具（如 Playwright connectOverCDP）复用同一浏览器。
    # 仅在门控命中、Chrome 已就绪时设置，端点缺失即代表可回退到自启动浏览器。
    # 对外地址里的 host 用实际可达 IP（与插件"复制 Web UI 连接"同一套解析逻辑）。
    local cdp_host
    cdp_host="$(resolve_share_host)"
    export TESTAGENT_CDP_ENDPOINT=http://127.0.0.1:9222
    export TESTAGENT_CDP_EXTERNAL="http://${cdp_host}:9922"
    # noVNC 可视化地址：host 与 CDP 对外地址一致，指向 websockify(6080)，
    # autoconnect=true 让打开页面后自动连上 VNC。
    export TESTAGENT_VNC_URL="http://${cdp_host}:6080/vnc.html?autoconnect=true"

    echo "[start] VNC 与 Chrome 已在后台启动，日志见 /tmp/vnc.log、/tmp/chrome.log、/tmp/socat.log、/tmp/novnc.log"
    echo "[start] CDP 端点: TESTAGENT_CDP_ENDPOINT=${TESTAGENT_CDP_ENDPOINT} TESTAGENT_CDP_EXTERNAL=${TESTAGENT_CDP_EXTERNAL} TESTAGENT_VNC_URL=${TESTAGENT_VNC_URL}"
}

case "${TESTAGENT_ENABLE_CHROME:-}" in
    1 | true | TRUE | yes | YES | on | ON)
        start_browser
        ;;
esac

# sshd 为每个会话重新组装环境；传递调用方注入的 TESTAGENT_* 配置。
# 主 SSH 服务监听 2222；读取同一 sshd 配置的会话使用相同环境变量。
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
    local sshd_setenv_line='SetEnv LANG="C.UTF-8" LC_ALL="C.UTF-8" OPENSSL_CONF="/etc/ssl/tscode-openssl.cnf" NODE_OPTIONS="--require /usr/local/lib/tscode/tls-legacy-renegotiation.cjs"'

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

nohup bash /root/.custom.sh > /root/.custom.log 2>&1 </dev/null &

# 启动 SSH 服务
if [ "$#" -eq 0 ]; then
    set -- /usr/sbin/sshd -D -e
fi

exec "$@"
