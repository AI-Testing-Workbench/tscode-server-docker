#!/bin/bash

set -e

# 容器 SSH 指纹生成
# 不同容器的指纹不一致
mkdir -p /run/sshd
ssh-keygen -A

# --- Start ---

# 所有 helper 和本地凭证文件使用的私有目录。
GIT_HELPER_DIR=/root/.git-helper
# Git 标准 credential-store 明文凭证文件的固定路径。
GIT_CREDENTIAL_FILE=/root/.git-helper/.git-credentials
# 保存 type、用户名和邮箱的非密码元数据文件。
GIT_EXTRA_FILE=/root/.git-helper/.git-extra
# clone 阶段使用的 credential helper，负责从服务领取凭证。
GIT_INIT_HELPER=/root/.git-helper/init-credential-helper
# 初始化成功后使用的 credential helper，只处理本地凭证和可选同步。
GIT_RUNTIME_HELPER=/root/.git-helper/runtime-credential-helper
# 运行期认证被拒绝后的重新认证标记，不保存凭证或服务状态。
GIT_RUNTIME_REJECTED_FILE=/root/.git-helper/.runtime-credential-rejected
# 运行期 Git 命令入口；初始化完成前不放入 PATH。
GIT_RUNTIME_WRAPPER=/usr/local/bin/git
# Gitee URL construction and repository clone/retry orchestration.
GIT_CLONE_SCRIPT=/root/.git-clone.sh

# Gitee 仓库 clone 时使用的父工作目录。
GIT_APP_DIR=/app
# SSH 登录 shell 的默认工作目录；成功 clone 后切换为具体仓库目录。
SSH_LOGIN_WORKDIR="$GIT_APP_DIR"
SSH_REPOSITORY_CLONED=0

# 云端模式变量缺失时停止；存在但不是 1 时跳过云端初始化流程。
if [ -z "${TESTAGENT_CLOUD_MODE+x}" ]; then
    echo "[start] TESTAGENT_CLOUD_MODE 缺失" >&2
    exit 1
fi

if [ "$TESTAGENT_CLOUD_MODE" = "1" ]; then

# 仅在云端流程启用期间临时收紧文件默认权限，退出前恢复原值，避免影响后续启动逻辑。
GIT_OLD_UMASK=$(umask)
umask 077
echo "[start] 云端模式已启用，开始码云初始化"

# 启动最初只输出 TESTAGENT 前缀的环境变量，便于确认调用方注入的输入。
echo "[start] 启动时 TESTAGENT 环境变量开始" >&2
if ! env | LC_ALL=C sort | LC_ALL=C awk -F= '$1 ~ /^TESTAGENT/ { print "[start] 环境变量: " $0 }' >&2; then
    echo "[start] 启动时 TESTAGENT 环境变量输出失败" >&2
fi
echo "[start] 启动时 TESTAGENT 环境变量结束" >&2


# 校验初始化 helper 依赖的 Python 3 和 Git 命令。
if ! command -v python3 || ! python3 -c 'import sys; raise SystemExit(0 if sys.version_info[0] == 3 else 1)'; then
    echo "[start] Python 3 不可用" >&2
    exit 1
fi

if ! command -v git || ! command -v timeout; then
    echo "[start] Git 不可用" >&2
    exit 1
fi

# 校验 helper 将使用的 root 目录具备写权限。
if [ ! -d /root ] || [ ! -w /root ]; then
    echo "[start] root 目录不可写" >&2
    exit 1
fi

# 校验 Git API 身份和基础地址，避免向错误资源发送请求。
if [ -z "${TESTAGENT_CLOUD_SERVICE_USER:-}" ] || [ -z "${TESTAGENT_CLOUD_SERVICE_ID:-}" ] || [ -z "${TESTAGENT_CLOUD_SERVICE_URL:-}" ]; then
    echo "[start] Git 服务变量不完整" >&2
    exit 1
fi

if ! python3 - "${TESTAGENT_CLOUD_SERVICE_USER}" "${TESTAGENT_CLOUD_SERVICE_ID}" "${TESTAGENT_CLOUD_SERVICE_URL}" <<'PY'
import sys
from urllib.parse import urlsplit

service_user, service_id, service_url = sys.argv[1:]

def valid_identifier(value):
    return bool(value) and value == value.strip() and not any(
        character.isspace() or ord(character) < 32 or ord(character) == 127
        for character in value
    )

if not valid_identifier(service_user) or not valid_identifier(service_id):
    raise SystemExit(1)
if any(ord(character) < 32 or ord(character) == 127 for character in service_url):
    raise SystemExit(1)
if service_url != service_url.strip():
    raise SystemExit(1)
try:
    parsed = urlsplit(service_url)
    _ = parsed.port
    hostname = parsed.hostname
except ValueError:
    raise SystemExit(1)
if parsed.scheme not in ("http", "https") or not parsed.netloc or not hostname:
    raise SystemExit(1)
if parsed.username is not None or parsed.password is not None:
    raise SystemExit(1)
if parsed.query or parsed.fragment:
    raise SystemExit(1)
PY
then
    echo "[start] 码云服务地址或身份非法" >&2
    exit 1
fi
echo "[start] 基础环境和码云服务参数校验通过"

# 校验可选 PIP/NPM 镜像地址，防止把非法地址写入全局工具配置。
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

# 代理地址校验通过后才写入 pip 全局配置，避免污染当前用户环境。
if [ -n "${TESTAGENT_CLOUD_PIP_URL:-}" ]; then
    if ! python3 -m pip config --global set global.index-url "$TESTAGENT_CLOUD_PIP_URL"; then
        echo "[start] PIP 镜像配置失败" >&2
        exit 1
    fi
    echo "[start] PIP 全局镜像配置完成"
else
    echo "[start] 未配置 PIP 镜像，跳过"
fi

# npm 使用全局 registry 配置；空值表示调用方未要求覆盖镜像源。
if [ -n "${TESTAGENT_CLOUD_NPM_URL:-}" ]; then
    if ! command -v npm; then
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

# 创建并锁定凭证目录和文件，保留已有本地凭证以实现文件优先读取。
# 符号链接和多链接文件直接拒绝，防止启动流程改写目录外的目标。
if [ -L "$GIT_HELPER_DIR" ]; then
    echo "[start] Git helper 目录类型非法" >&2
    exit 1
fi
if ! mkdir -p "$GIT_HELPER_DIR"; then
    echo "[start] Git helper 目录准备失败" >&2
    exit 1
fi
if [ -L "$GIT_HELPER_DIR" ] || [ ! -d "$GIT_HELPER_DIR" ]; then
    echo "[start] Git helper 目录类型非法" >&2
    exit 1
fi
if ! chmod 0700 "$GIT_HELPER_DIR"; then
    echo "[start] Git helper 目录权限设置失败" >&2
    exit 1
fi
# Helpers must be the regular, image-provided executables; startup never generates or copies them.
if [ -L "$GIT_INIT_HELPER" ] || [ ! -f "$GIT_INIT_HELPER" ] || [ -L "$GIT_RUNTIME_HELPER" ] || [ ! -f "$GIT_RUNTIME_HELPER" ]; then
    echo "[start] Git credential helper 类型非法" >&2
    exit 1
fi
if [ "$(stat -c '%h' "$GIT_INIT_HELPER")" != "1" ] || [ "$(stat -c '%h' "$GIT_RUNTIME_HELPER")" != "1" ]; then
    echo "[start] Git credential helper 链接数非法" >&2
    exit 1
fi
if ! chmod 0700 "$GIT_INIT_HELPER" "$GIT_RUNTIME_HELPER"; then
    echo "[start] Git credential helper 权限设置失败" >&2
    exit 1
fi
if [ -L "$GIT_CREDENTIAL_FILE" ] || { [ -e "$GIT_CREDENTIAL_FILE" ] && [ ! -f "$GIT_CREDENTIAL_FILE" ]; }; then
    echo "[start] 码云凭证文件类型非法" >&2
    exit 1
fi
if [ -L "$GIT_EXTRA_FILE" ] || { [ -e "$GIT_EXTRA_FILE" ] && [ ! -f "$GIT_EXTRA_FILE" ]; }; then
    echo "[start] 码云身份文件类型非法" >&2
    exit 1
fi
if [ -e "$GIT_CREDENTIAL_FILE" ] && [ "$(stat -c '%h' "$GIT_CREDENTIAL_FILE")" != "1" ]; then
    echo "[start] 码云凭证文件链接数非法" >&2
    exit 1
fi
if [ -e "$GIT_EXTRA_FILE" ] && [ "$(stat -c '%h' "$GIT_EXTRA_FILE")" != "1" ]; then
    echo "[start] 码云身份文件链接数非法" >&2
    exit 1
fi
if ! rm -f -- "$GIT_RUNTIME_REJECTED_FILE"; then
    echo "[start] 运行期凭证状态文件清理失败" >&2
    exit 1
fi
if [ ! -e "$GIT_CREDENTIAL_FILE" ]; then
    if ! (umask 077; : > "$GIT_CREDENTIAL_FILE"); then
        echo "[start] 码云凭证文件创建失败" >&2
        exit 1
    fi
fi
if [ ! -e "$GIT_EXTRA_FILE" ]; then
    if ! (umask 077; : > "$GIT_EXTRA_FILE"); then
        echo "[start] 码云身份文件创建失败" >&2
        exit 1
    fi
fi
if ! chmod 0600 "$GIT_CREDENTIAL_FILE" || ! chmod 0600 "$GIT_EXTRA_FILE"; then
    echo "[start] Git 本地文件权限设置失败" >&2
    exit 1
fi

# Keep the original fixed-path extra-file validation before initialization uses the helpers.
if ! "$GIT_INIT_HELPER" --normalize-extra; then
    echo "[start] Git 身份文件整理失败" >&2
    exit 1
fi
echo "[start] Git helper 和本地凭证文件准备完成"

# 初始化 clone 前只启用初始化 helper，避免运行期询问逻辑提前触发。
# 先清除已有全局 helper，确保 Git 不会并行调用其他凭证来源。
git config --global --unset-all credential.helper || true
if ! git config --global credential.helper "$GIT_INIT_HELPER"; then
    echo "[start] 初始化 helper 全局配置失败" >&2
    exit 1
fi
echo "[start] 初始化 credential helper 已启用"

if ! "$GIT_INIT_HELPER" --report starting; then
    echo "[start] Git starting 状态上报失败" >&2
    "$GIT_INIT_HELPER" --report failed_service || true
    exit 1
fi
echo "[start] Git 状态 starting 已上报"

# Ensure the clone orchestration itself is the baked image file before invoking it.
if [ -L "$GIT_CLONE_SCRIPT" ] || [ ! -f "$GIT_CLONE_SCRIPT" ] || [ ! -x "$GIT_CLONE_SCRIPT" ]; then
    echo "[start] Git clone 脚本不可用" >&2
    "$GIT_INIT_HELPER" --report failed_container || true
    exit 1
fi
GIT_APP_CLONE_DIR=""
GIT_CLONE_RESULT=""
if ! GIT_CLONE_RESULT=$(
    "$GIT_CLONE_SCRIPT" \
        "$GIT_APP_DIR" \
        "$GIT_HELPER_DIR" \
        "$GIT_INIT_HELPER" \
        "$GIT_RUNTIME_HELPER" \
        "$GIT_CREDENTIAL_FILE" \
        "$GIT_EXTRA_FILE" \
        3>&1 1>&2
); then
    exit 1
fi
if [ -n "$GIT_CLONE_RESULT" ]; then
    GIT_APP_CLONE_DIR=${GIT_CLONE_RESULT%%$'\t'*}
    GIT_INIT_DEADLINE=${GIT_CLONE_RESULT#*$'\t'}
    case "$GIT_INIT_DEADLINE" in
        '' | *[!0-9]*)
            echo "[start] Git clone 返回 deadline 非法" >&2
            "$GIT_INIT_HELPER" --report failed_container || true
            exit 1
            ;;
    esac
    if [ "$GIT_APP_CLONE_DIR" != "$GIT_APP_DIR/${TESTAGENT_CLOUD_GITEE_REPOSITORY:-}" ]; then
        echo "[start] Git clone 返回目录非法" >&2
        "$GIT_INIT_HELPER" --report failed_container || true
        exit 1
    fi
    export GIT_INIT_DEADLINE
    SSH_REPOSITORY_CLONED=1
fi

# 运行期命令需要在认证失败后立即重跑一次；初始化阶段尚未安装此入口。
if [ -L "$GIT_RUNTIME_WRAPPER" ] || { [ -e "$GIT_RUNTIME_WRAPPER" ] && [ ! -f "$GIT_RUNTIME_WRAPPER" ]; }; then
    echo "[start] 运行期 Git 入口类型非法" >&2
    "$GIT_INIT_HELPER" --report failed_container || true
    exit 1
fi
if ! GIT_RUNTIME_WRAPPER_TEMP=$(mktemp "$GIT_HELPER_DIR/.runtime-git.XXXXXX"); then
    echo "[start] 运行期 Git 入口临时文件创建失败" >&2
    "$GIT_INIT_HELPER" --report failed_container || true
    exit 1
fi
if ! cat > "$GIT_RUNTIME_WRAPPER_TEMP" <<'SH'
#!/bin/bash

set -u

REAL_GIT=/usr/bin/git
REJECTED_FILE=__RUNTIME_REJECTED_FILE__
RETRY_OPERATION=0

for ARGUMENT in "$@"; do
    case "$ARGUMENT" in
        clone | fetch | pull | push | ls-remote | submodule)
            RETRY_OPERATION=1
            break
            ;;
    esac
done

if [ "$RETRY_OPERATION" -eq 0 ]; then
    exec "$REAL_GIT" "$@"
fi

if ! OUTPUT_FILE=$(mktemp "${TMPDIR:-/tmp}/tscode-runtime-git.XXXXXX"); then
    exec "$REAL_GIT" "$@"
fi

"$REAL_GIT" "$@" > >(tee "$OUTPUT_FILE") 2> >(tee -a "$OUTPUT_FILE" >&2)
GIT_STATUS=$?
wait

if [ "$GIT_STATUS" -eq 0 ]; then
    rm -f -- "$OUTPUT_FILE"
    exit 0
fi

if [ ! -f "$REJECTED_FILE" ] || ! grep -Eiq -- \
    'authentication failed|authentication required|invalid (username|user(name)?|password|token)|incorrect (username|password)|access denied|unauthorized|http basic:.*access denied|requested url returned error: (401|403)|remote:.*(401|403)' \
    "$OUTPUT_FILE"; then
    rm -f -- "$OUTPUT_FILE"
    exit "$GIT_STATUS"
fi

rm -f -- "$OUTPUT_FILE"
exec "$REAL_GIT" "$@"
SH
then
    rm -f -- "$GIT_RUNTIME_WRAPPER_TEMP" || true
    echo "[start] 运行期 Git 入口生成失败" >&2
    "$GIT_INIT_HELPER" --report failed_container || true
    exit 1
fi
if ! sed -i \
    -e "s|__RUNTIME_REJECTED_FILE__|$GIT_RUNTIME_REJECTED_FILE|g" \
    "$GIT_RUNTIME_WRAPPER_TEMP" || ! chmod 0755 "$GIT_RUNTIME_WRAPPER_TEMP" || ! mv -fT -- "$GIT_RUNTIME_WRAPPER_TEMP" "$GIT_RUNTIME_WRAPPER"; then
    rm -f -- "$GIT_RUNTIME_WRAPPER_TEMP" || true
    echo "[start] 运行期 Git 入口安装失败" >&2
    "$GIT_INIT_HELPER" --report failed_container || true
    exit 1
fi
echo "[start] 运行期 Git 认证失败自动重试已启用"
if ! "$GIT_INIT_HELPER" --report initialized; then
    echo "[start] Git initialized 状态上报失败" >&2
    "$GIT_INIT_HELPER" --report failed_initialize || true
    exit 1
fi
echo "[start] Git 状态 initialized 已上报"

unset GIT_INIT_DEADLINE
umask "$GIT_OLD_UMASK"
echo "[start] 云端码云初始化流程完成"
else
    echo "[start] TESTAGENT_CLOUD_MODE 非 1，跳过云端码云初始化"
fi

# 交互式 SSH 登录默认进入 /app；完成仓库 clone 后进入 /app 下的仓库目录。
# 使用 Bash printf 的 %q 安全转义仓库名，避免目录名被 profile 当作命令解释。
# 直接追加 Bash 提示符配置，确保用户配置加载完成后主机名仍显示为 sandbox。
if [ "$SSH_REPOSITORY_CLONED" -eq 1 ]; then
    SSH_LOGIN_WORKDIR="$GIT_APP_CLONE_DIR"
fi
SSH_BASHRC=/root/.bashrc
if ! {
    printf '%s\n' 'unset GIT_ASKPASS VSCODE_GIT_IPC_HANDLE VSCODE_GIT_ASKPASS_MAIN VSCODE_GIT_ASKPASS_NODE VSCODE_GIT_ASKPASS_EXTRA_ARGS GIT_TERMINAL_PROMPT'
    printf '%s\n' 'PS1='\''\u@sandbox:\w\$ '\'''
} >> "$SSH_BASHRC"; then
    echo "[start] SSH 提示符配置写入失败" >&2
    exit 1
fi
SSH_PROFILE_SCRIPT=/etc/profile.d/app.sh
if [ -L "$SSH_PROFILE_SCRIPT" ] || {
    [ -e "$SSH_PROFILE_SCRIPT" ] && [ ! -f "$SSH_PROFILE_SCRIPT" ]
}; then
    echo "[start] SSH 登录目录配置文件类型非法" >&2
    exit 1
fi
if ! SSH_PROFILE_TEMP=$(mktemp /etc/profile.d/.app.sh.XXXXXX); then
    echo "[start] SSH 登录目录配置临时文件创建失败" >&2
    exit 1
fi
if ! {
    # Remove VS Code's injected askpass environment before Git operations in SSH sessions.
    printf '%s\n' 'unset GIT_ASKPASS VSCODE_GIT_IPC_HANDLE VSCODE_GIT_ASKPASS_MAIN VSCODE_GIT_ASKPASS_NODE VSCODE_GIT_ASKPASS_EXTRA_ARGS GIT_TERMINAL_PROMPT'
    printf 'cd -- %q\n' "$SSH_LOGIN_WORKDIR"
} > "$SSH_PROFILE_TEMP" \
    || ! chmod 0644 "$SSH_PROFILE_TEMP" \
    || ! mv -fT -- "$SSH_PROFILE_TEMP" "$SSH_PROFILE_SCRIPT"; then
    rm -f -- "$SSH_PROFILE_TEMP"
    echo "[start] SSH 登录目录配置写入失败" >&2
    exit 1
fi
echo "[start] SSH 登录目录已设置为 $SSH_LOGIN_WORKDIR"
echo "[start] SSH 启动配置已禁用 VS Code Git askpass"

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

# sshd 为每个会话重新组装环境，不会自动继承父进程中的 TESTAGENT_* 变量。
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
    local sshd_setenv_line='SetEnv'

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
