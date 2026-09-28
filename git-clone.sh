#!/bin/bash

set -e
# Keep Git and credential-helper diagnostics on the clone command's stdout.
exec 2>&1
umask 077

# 镜像内固定路径；start.sh 不准备或调用 Git。
APP_DIR=/app
HELPER_DIR=/root/.git-helper
# init helper 从服务轮询凭证，runtime helper 处理后续 Git 操作。
INIT_HELPER=$HELPER_DIR/init-credential-helper
RUNTIME_HELPER=$HELPER_DIR/runtime-credential-helper
# credential-store 保存密码；.git-extra 只保存身份元数据。
CREDENTIAL_FILE=$HELPER_DIR/.git-credentials
EXTRA_FILE=$HELPER_DIR/.git-extra
# 运行期 Git 入口根据此标记判断是否重试被拒绝的远程操作。
REJECTED_FILE=$HELPER_DIR/.runtime-credential-rejected
# 手动初始化完成后才安装运行期 Git 入口。
RUNTIME_GIT=/usr/local/bin/git
SSH_PROFILE=/etc/profile.d/app.sh
SSH_BASHRC=/root/.bashrc

# 总 deadline 同时约束 clone 执行和等待凭证 API。
GIT_INIT_TIMEOUT_SECONDS=600
# 此上限只统计 git clone 次数，不统计 helper 内的 API 轮询。
GIT_MAX_ATTEMPTS=5
GIT_CREDENTIAL_POLL_INTERVAL_SECONDS=2
# 可重试的网络或认证失败之间的等待时间。
GIT_RETRY_DELAY_SECONDS=3
# 限制容器日志中的失败诊断行数和字节数。
GIT_DIAGNOSTIC_MAX_LINES=120
GIT_DIAGNOSTIC_MAX_BYTES=16384

REPORT_READY=0
CLONE_LOG_FILE=""
CREDENTIAL_EVENT_FILE=""
cleanup_temporary_files() {
    [ -z "$CLONE_LOG_FILE" ] || rm -f -- "$CLONE_LOG_FILE"
    [ -z "$CREDENTIAL_EVENT_FILE" ] || rm -f -- "$CREDENTIAL_EVENT_FILE"
}
trap cleanup_temporary_files EXIT

fail() {
    local status=$1
    shift
    echo "[git-clone] $*" >&2
    if [ "$REPORT_READY" -eq 1 ] && [ -n "$status" ]; then
        "$INIT_HELPER" --report "$status" || true
    fi
    exit 1
}

sanitize_git_output() {
    local git_url=$1
    GIT_CLONE_URL="$git_url" python3 -u -c '
import os
import re
import sys

url = os.environ.get("GIT_CLONE_URL", "")
secret_field = re.compile(r"""([\"]?[A-Za-z0-9_.-]*(?:password|token|secret|authorization)[A-Za-z0-9_.-]*[\"]?[ \t]*[=:][ \t]*).*""", re.IGNORECASE)

for raw_line in sys.stdin:
    for line in raw_line.rstrip("\n").replace("\r", "\n").split("\n"):
        line = "".join(character for character in line if character == "\t" or (ord(character) >= 32 and ord(character) != 127))
        if url:
            line = line.replace(url, "<git-url>")
        line = secret_field.sub(lambda match: match.group(1) + "<redacted>", line)
        print(line, flush=True)
'
}

limit_diagnostics() {
    LC_ALL=C awk -v max_lines="$GIT_DIAGNOSTIC_MAX_LINES" -v max_bytes="$GIT_DIAGNOSTIC_MAX_BYTES" '
        {
            if (NR > max_lines || bytes >= max_bytes) {
                truncated = 1
                exit
            }
            available = max_bytes - bytes
            if (length($0) + 1 > available) {
                if (available > 1) {
                    print "[git-clone] Git clone 诊断: " substr($0, 1, available - 1)
                }
                truncated = 1
                exit
            }
            print "[git-clone] Git clone 诊断: " $0
            bytes += length($0) + 1
        }
        END {
            if (truncated) {
                print "[git-clone] Git clone 详细诊断已截断"
            }
        }'
}

classify_clone_failure() {
    # helper 错误和不可恢复错误优先于可重试的网络错误判断。
    python3 - "$1" "$2" <<'PY'
import pathlib
import re
import sys

log_path, exit_status = sys.argv[1:]
text = pathlib.Path(log_path).read_bytes()[-1_000_000:].decode("utf-8", "replace").lower()

def has_any(*markers):
    return any(marker in text for marker in markers)

if exit_status == "124" or has_any("credential helper error: timeout", "timed out"):
    result = "timeout"
elif "credential helper error: max_attempts" in text:
    result = "max_attempts"
elif has_any(
    "credential helper error: service",
    "credential helper error: unauthorized",
    "credential helper error: not_found",
):
    result = "service"
elif has_any(
    "credential helper error: unexpected_state",
    "credential helper error: invalid_credential",
):
    result = "unexpected_state"
elif has_any("credential helper error: local", "credential helper error: internal"):
    result = "container"
elif "credential helper error: remote_failed" in text:
    result = "remote_failed"
elif has_any(
    "requested url returned error: 400",
    "requested url returned error: 404",
    "couldn't find remote ref",
    "does not appear to be a git repository",
):
    result = "fatal_git"
elif "repository not found" in text or ("repository" in text and "not found" in text):
    result = "repository_not_found"
elif has_any(
    "authentication failed",
    "could not read username",
    "requested url returned error: 401",
    "requested url returned error: 403",
    "could not resolve host",
    "failed to connect",
    "couldn't connect",
    "could not connect",
    "connection refused",
    "connection reset",
    "network is unreachable",
    "temporary failure in name resolution",
    "could not resolve",
    "connection aborted",
    "recv failure",
    "operation timed out",
    "ssl_error_syscall",
    "gnutls",
    "tls connection",
    "proxyconnect",
    "proxy error",
    "network error",
    "early eof",
    "remote end hung up",
):
    result = "retry"
else:
    result = "fatal_git"

print(result)
PY
}

cleanup_partial_clone() {
    # 返回 2 表示无法确认目录归属；调用方此时不得删除目录。
    local remaining git_status empty_directory

    if ! remaining=$(find "$APP_DIR" -mindepth 1 -maxdepth 1 -print -quit); then
        return 1
    fi
    [ -z "$remaining" ] && return 0
    [ "$remaining" = "$CLONE_DIR" ] || return 2
    [ ! -L "$CLONE_DIR" ] && [ -d "$CLONE_DIR" ] || return 2

    if ! git_status=$(/usr/bin/git -C "$CLONE_DIR" status --porcelain=v1 --untracked-files=all --ignored=matching); then
        return 1
    fi
    [ -z "$git_status" ] || return 2

    if ! empty_directory=$(find "$APP_DIR" -mindepth 1 -type d -empty \
        ! -path "$CLONE_DIR" \
        ! -path "$CLONE_DIR/.git" \
        ! -path "$CLONE_DIR/.git/*" -print -quit); then
        return 1
    fi
    [ -z "$empty_directory" ] || return 2
    rm -rf -- "$CLONE_DIR"
}

install_runtime_git() {
    local temporary_file

    if [ -L "$RUNTIME_GIT" ] || { [ -e "$RUNTIME_GIT" ] && [ ! -f "$RUNTIME_GIT" ]; }; then
        return 1
    fi
    temporary_file=$(mktemp "$HELPER_DIR/.runtime-git.XXXXXX") || return 1
    if ! cat > "$temporary_file" <<'SH'
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
        rm -f -- "$temporary_file"
        return 1
    fi
    if ! sed -i "s|__REJECTED_FILE__|$REJECTED_FILE|g" "$temporary_file" \
        || ! chmod 0755 "$temporary_file" \
        || ! mv -fT -- "$temporary_file" "$RUNTIME_GIT"; then
        rm -f -- "$temporary_file"
        return 1
    fi
}

configure_ssh_login() {
    local workdir=$APP_DIR
    local temporary_file

    if [ -n "$CLONE_DIR" ]; then
        workdir=$CLONE_DIR
    fi
    if ! printf '%s\n' 'unset GIT_ASKPASS VSCODE_GIT_IPC_HANDLE VSCODE_GIT_ASKPASS_MAIN VSCODE_GIT_ASKPASS_NODE VSCODE_GIT_ASKPASS_EXTRA_ARGS GIT_TERMINAL_PROMPT' >> "$SSH_BASHRC"; then
        return 1
    fi
    if [ -L "$SSH_PROFILE" ] || { [ -e "$SSH_PROFILE" ] && [ ! -f "$SSH_PROFILE" ]; }; then
        return 1
    fi
    temporary_file=$(mktemp /etc/profile.d/.app.sh.XXXXXX) || return 1
    if ! {
        printf '%s\n' 'unset GIT_ASKPASS VSCODE_GIT_IPC_HANDLE VSCODE_GIT_ASKPASS_MAIN VSCODE_GIT_ASKPASS_NODE VSCODE_GIT_ASKPASS_EXTRA_ARGS GIT_TERMINAL_PROMPT'
        printf 'cd -- %q\n' "$workdir"
    } > "$temporary_file" || ! chmod 0644 "$temporary_file" || ! mv -fT -- "$temporary_file" "$SSH_PROFILE"; then
        rm -f -- "$temporary_file"
        return 1
    fi
    echo "[git-clone] 后续 SSH 登录目录设为 $workdir"
}

# 阶段一：校验手动调用条件并准备凭证 helper。
if [ "$#" -ne 0 ]; then
    fail "" "不接受命令行参数"
fi
if [ -z "${TESTAGENT_CLOUD_MODE+x}" ]; then
    fail "" "TESTAGENT_CLOUD_MODE 缺失"
fi
if [ "$TESTAGENT_CLOUD_MODE" != "1" ]; then
    echo "[git-clone] TESTAGENT_CLOUD_MODE 非 1，跳过 Git 初始化"
    exit 0
fi

if ! command -v python3 >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1 \
    || ! command -v timeout >/dev/null 2>&1; then
    fail "" "Python 3、Git 或 timeout 不可用"
fi
if [ ! -w /root ]; then
    fail "" "root 目录不可写"
fi
if [ -z "${TESTAGENT_CLOUD_SERVICE_USER:-}" ] \
    || [ -z "${TESTAGENT_CLOUD_SERVICE_ID:-}" ] \
    || [ -z "${TESTAGENT_CLOUD_SERVICE_URL:-}" ]; then
    fail "" "Git 服务变量不完整"
fi

if [ -L "$HELPER_DIR" ]; then
    fail "" "Git helper 目录类型非法"
fi
mkdir -p "$HELPER_DIR" || fail "" "Git helper 目录准备失败"
[ -d "$HELPER_DIR" ] && chmod 0700 "$HELPER_DIR" || fail "" "Git helper 目录权限设置失败"

for helper in "$INIT_HELPER" "$RUNTIME_HELPER"; do
    [ ! -L "$helper" ] && [ -f "$helper" ] || fail "" "Credential helper 类型非法"
    [ "$(stat -c '%h' "$helper")" = "1" ] || fail "" "Credential helper 链接数非法"
done
chmod 0700 "$INIT_HELPER" "$RUNTIME_HELPER" || fail "" "Credential helper 权限设置失败"

EXTRA_FILE_PREEXISTED=0
[ ! -e "$EXTRA_FILE" ] && [ ! -L "$EXTRA_FILE" ] || EXTRA_FILE_PREEXISTED=1
for file in "$CREDENTIAL_FILE" "$EXTRA_FILE"; do
    [ ! -L "$file" ] && { [ ! -e "$file" ] || [ -f "$file" ]; } || fail "" "本地凭证文件类型非法"
    if [ -e "$file" ] && [ "$(stat -c '%h' "$file")" != "1" ]; then
        fail "" "本地凭证文件链接数非法"
    fi
    [ -e "$file" ] || : > "$file" || fail "" "本地凭证文件创建失败"
done
chmod 0600 "$CREDENTIAL_FILE" "$EXTRA_FILE" || fail "" "本地凭证文件权限设置失败"

[ ! -L "$REJECTED_FILE" ] && { [ ! -e "$REJECTED_FILE" ] || [ -f "$REJECTED_FILE" ]; } \
    || fail "" "运行期认证标记类型非法"
rm -f -- "$REJECTED_FILE" || fail "" "运行期认证标记清理失败"
if [ "$EXTRA_FILE_PREEXISTED" -eq 0 ]; then
    "$INIT_HELPER" --normalize-extra || fail "" "Git 身份文件整理失败"
fi

git config --global --unset-all credential.helper || true
REPORT_READY=1
"$INIT_HELPER" --report starting || fail failed_service "Git starting 状态上报失败"

# 阶段二：解析仓库配置，并在同一个 deadline 内处理 clone 重试。
export -n GIT_MAX_ATTEMPTS
export GIT_INIT_TIMEOUT_SECONDS GIT_CREDENTIAL_POLL_INTERVAL_SECONDS

GITEE_URL=${TESTAGENT_CLOUD_GITEE_URL:-}
GITEE_USER=${TESTAGENT_CLOUD_GITEE_USER:-}
GITEE_REPOSITORY=${TESTAGENT_CLOUD_GITEE_REPOSITORY:-}
GITEE_BRANCH=${TESTAGENT_CLOUD_GITEE_BRANCH:-}
GIT_URL=""
CLONE_DIR=""
CLONE_SKIPPED=0
CLONE_SUCCEEDED=0

if [ -n "$GITEE_URL$GITEE_USER$GITEE_REPOSITORY" ]; then
    if [ -z "$GITEE_URL" ] || [ -z "$GITEE_USER" ] || [ -z "$GITEE_REPOSITORY" ]; then
        fail failed_initialize "码云地址配置不完整"
    fi
    if ! GIT_URL=$(python3 - "$GITEE_URL" "$GITEE_USER" "$GITEE_REPOSITORY" "$GITEE_BRANCH" <<'PY'
import sys
from urllib.parse import urlsplit

prefix, user, repository, branch = sys.argv[1:]
for component in (user, repository):
    if not component or component in (".", "..") or ".." in component:
        raise SystemExit(1)
    if any(character.isspace() or ord(character) < 32 or ord(character) == 127 or character in "/\\?#%" for character in component):
        raise SystemExit(1)
if branch and (branch.startswith("-") or any(character.isspace() or ord(character) < 32 or ord(character) == 127 for character in branch)):
    raise SystemExit(1)
if prefix != prefix.strip() or any(ord(character) < 32 or ord(character) == 127 for character in prefix):
    raise SystemExit(1)

if prefix.startswith("git@"):
    if not prefix.endswith(":") or prefix[:-1].count("@") != 1:
        raise SystemExit(1)
    login, host = prefix[:-1].split("@", 1)
    if not login or not host or any(character.isspace() or ord(character) < 32 or ord(character) == 127 or character in "/\\?#%" for character in login + host):
        raise SystemExit(1)
    print(prefix + user + "/" + repository + ".git")
else:
    try:
        parsed = urlsplit(prefix)
        _ = parsed.port
        hostname = parsed.hostname
    except ValueError:
        raise SystemExit(1)
    if parsed.scheme not in ("http", "https", "git") or not parsed.netloc or not hostname:
        raise SystemExit(1)
    if parsed.username is not None or parsed.password is not None or parsed.query or parsed.fragment:
        raise SystemExit(1)
    if ".." in parsed.path.split("/"):
        raise SystemExit(1)
    print(prefix.rstrip("/") + "/" + user + "/" + repository + ".git")
PY
    ); then
        fail failed_initialize "码云地址或路径字段非法"
    fi
    CLONE_DIR="$APP_DIR/$GITEE_REPOSITORY"
    echo "[git-clone] 码云地址校验通过"

    [ -d "$APP_DIR" ] || fail failed_container "/app 不是目录"
    if [ -L "$CLONE_DIR" ] || { [ -e "$CLONE_DIR" ] && [ ! -d "$CLONE_DIR" ]; }; then
        fail failed_initialize "Git clone 目标目录类型非法"
    fi
    if [ -d "$CLONE_DIR" ]; then
        if ! CLONE_CONTENT=$(find "$CLONE_DIR" -mindepth 1 -maxdepth 1 -print -quit); then
            fail failed_container "Git clone 目标目录内容检查失败"
        fi
        if [ -n "$CLONE_CONTENT" ]; then
            CLONE_SKIPPED=1
            echo "[git-clone] clone 目标目录非空，跳过 clone"
        else
            rmdir -- "$CLONE_DIR" || fail failed_initialize "Git clone 空目标目录清理失败"
        fi
    fi
    if [ "$CLONE_SKIPPED" -eq 0 ]; then
        if ! APP_CONTENT=$(find "$APP_DIR" -mindepth 1 -maxdepth 1 -print -quit); then
            fail failed_container "/app 内容检查失败"
        fi
        [ -z "$APP_CONTENT" ] || fail failed_initialize "/app 非空，拒绝 clone"
    fi
    "$INIT_HELPER" --report processing || fail failed_service "Git processing 状态上报失败"

    if [ "$CLONE_SKIPPED" -eq 0 ]; then
        if ! START_SECONDS=$(date +%s); then
            fail failed_container "初始化计时器不可用"
        fi
        GIT_INIT_DEADLINE=$((START_SECONDS + GIT_INIT_TIMEOUT_SECONDS))
        export GIT_INIT_DEADLINE
    fi
    ATTEMPT=1
    REFRESH_PROVIDED=0

    while [ "$CLONE_SKIPPED" -eq 0 ] && [ "$ATTEMPT" -le "$GIT_MAX_ATTEMPTS" ]; do
        if ! NOW_SECONDS=$(date +%s); then
            fail failed_container "初始化计时器不可用"
        fi
        REMAINING_SECONDS=$((GIT_INIT_DEADLINE - NOW_SECONDS))
        [ "$REMAINING_SECONDS" -gt 0 ] || fail failed_timeout "Git 初始化超时"

        CLONE_LOG_FILE=$(mktemp "$HELPER_DIR/.git-clone-output.XXXXXX") \
            || fail failed_container "Git clone 输出文件创建失败"
        CREDENTIAL_EVENT_FILE=$(mktemp "$HELPER_DIR/.init-credential-event.XXXXXX") \
            || fail failed_container "凭证事件文件创建失败"
        CLONE_COMMAND=(git clone --progress)
        [ -z "$GITEE_BRANCH" ] || CLONE_COMMAND+=(--branch "$GITEE_BRANCH")
        CLONE_EXIT=0
        echo "[git-clone] clone 第 $ATTEMPT/$GIT_MAX_ATTEMPTS 次尝试"

        if (
            set -o pipefail
            GIT_CREDENTIAL_EVENT_FILE="$CREDENTIAL_EVENT_FILE" \
            GIT_TERMINAL_PROMPT=0 GIT_ASKPASS= SSH_ASKPASS= GIT_CONFIG_NOSYSTEM=1 LC_ALL=C \
                timeout --signal=TERM "$REMAINING_SECONDS" "${CLONE_COMMAND[@]}" "$GIT_URL" 2>&1 \
                | tee "$CLONE_LOG_FILE" \
                | sanitize_git_output "$GIT_URL" >&2
        ); then
            CLONE_SUCCEEDED=1
            rm -f -- "$CLONE_LOG_FILE" "$CREDENTIAL_EVENT_FILE"
            CLONE_LOG_FILE=""
            CREDENTIAL_EVENT_FILE=""
            echo "[git-clone] clone 完成"
            break
        else
            CLONE_EXIT=$?
        fi

        echo "[git-clone] clone 失败：attempt=$ATTEMPT/$GIT_MAX_ATTEMPTS exit=$CLONE_EXIT" >&2
        sanitize_git_output "$GIT_URL" < "$CLONE_LOG_FILE" | limit_diagnostics >&2
        if [[ "$GIT_URL" == git://* || "$GIT_URL" == git@*:* ]]; then
            fail failed_git "非 HTTP Git clone 失败，不重试"
        fi

        if ! FAILURE_KIND=$(classify_clone_failure "$CLONE_LOG_FILE" "$CLONE_EXIT"); then
            fail failed_container "Git clone 失败类型判断失败"
        fi
        if cleanup_partial_clone; then
            :
        else
            CLEANUP_STATUS=$?
            [ "$CLEANUP_STATUS" -eq 2 ] \
                && fail failed_initialize "无法确认失败 clone 目录归属，拒绝删除"
            fail failed_container "失败 clone 清理校验失败"
        fi

        CREDENTIAL_WAS_PROVIDED=$REFRESH_PROVIDED
        [ ! -s "$CREDENTIAL_EVENT_FILE" ] || CREDENTIAL_WAS_PROVIDED=1
        case "$FAILURE_KIND" in
            timeout)
                fail failed_timeout "Git clone 或凭证获取超时"
                ;;
            max_attempts)
                fail failed_max_attempts "凭证获取达到重试上限"
                ;;
            service)
                fail failed_service "码云凭证服务处理失败"
                ;;
            unexpected_state)
                fail failed_unexpected_state "码云凭证状态异常"
                ;;
            container)
                fail failed_container "码云本地凭证处理失败"
                ;;
            remote_failed)
                fail "" "码云服务已返回失败终态"
                ;;
            fatal_git)
                fail failed_git "Git clone 返回不可恢复错误"
                ;;
            repository_not_found)
                [ "$ATTEMPT" -lt "$GIT_MAX_ATTEMPTS" ] \
                    || fail failed_max_attempts "Git clone 达到重试上限"
                REFRESH_STATUS=credential_required
                [ "$CREDENTIAL_WAS_PROVIDED" -eq 0 ] || REFRESH_STATUS=credential_rejected
                rm -f -- "$CREDENTIAL_EVENT_FILE"
                if ! printf 'url=%s\n\n' "$GIT_URL" \
                    | GIT_CREDENTIAL_EVENT_FILE="$CREDENTIAL_EVENT_FILE" \
                    GIT_CREDENTIAL_REFRESH=1 \
                    GIT_CREDENTIAL_REFRESH_STATUS="$REFRESH_STATUS" \
                    GIT_TERMINAL_PROMPT=0 GIT_CONFIG_NOSYSTEM=1 \
                    git credential fill > /dev/null; then
                    fail "" "repository not found 后凭证刷新失败"
                fi
                REFRESH_PROVIDED=0
                [ ! -s "$CREDENTIAL_EVENT_FILE" ] || REFRESH_PROVIDED=1
                rm -f -- "$CREDENTIAL_EVENT_FILE" "$CLONE_LOG_FILE"
                CREDENTIAL_EVENT_FILE=""
                CLONE_LOG_FILE=""
                echo "[git-clone] 凭证刷新完成，准备重试"
                ATTEMPT=$((ATTEMPT + 1))
                continue
                ;;
            retry)
                REFRESH_PROVIDED=0
                ;;
            *)
                fail failed_git "Git clone 返回不可恢复错误"
                ;;
        esac

        rm -f -- "$CREDENTIAL_EVENT_FILE" "$CLONE_LOG_FILE"
        CREDENTIAL_EVENT_FILE=""
        CLONE_LOG_FILE=""
        [ "$ATTEMPT" -lt "$GIT_MAX_ATTEMPTS" ] || fail failed_max_attempts "Git clone 达到重试上限"
        if ! NOW_SECONDS=$(date +%s); then
            fail failed_container "初始化计时器不可用"
        fi
        REMAINING_SECONDS=$((GIT_INIT_DEADLINE - NOW_SECONDS))
        [ "$REMAINING_SECONDS" -gt 0 ] || fail failed_timeout "Git 初始化超时"
        SLEEP_SECONDS=$GIT_RETRY_DELAY_SECONDS
        [ "$SLEEP_SECONDS" -le "$REMAINING_SECONDS" ] || SLEEP_SECONDS=$REMAINING_SECONDS
        echo "[git-clone] ${SLEEP_SECONDS} 秒后重试"
        sleep "$SLEEP_SECONDS" || fail failed_container "Git 重试等待失败"
        ATTEMPT=$((ATTEMPT + 1))
    done
    [ "$CLONE_SKIPPED" -eq 1 ] || [ "$CLONE_SUCCEEDED" -eq 1 ] \
        || fail failed_max_attempts "Git clone 未成功"

    USERNAME=""
    EMAIL=""
    if ! while IFS='=' read -r key value; do
        case "$key" in
            git_username) USERNAME=$value ;;
            git_email) EMAIL=$value ;;
        esac
    done < "$EXTRA_FILE"; then
        fail failed_container "Git 身份文件读取失败"
    fi
    if [ -n "$USERNAME" ]; then
        git config --global --replace-all user.name "$USERNAME" \
            && git config --global --replace-all user.email "$EMAIL" \
            || fail failed_initialize "Git 用户身份配置失败"
    fi
    echo "码云凭证文件权限确认"
fi

# 阶段三：切换到运行期配置并上报初始化完成。
chmod 0600 "$CREDENTIAL_FILE" "$EXTRA_FILE" || fail failed_container "本地凭证文件权限设置失败"
[ "$(stat -c '%a' "$CREDENTIAL_FILE")" = 600 ] \
    && [ "$(stat -c '%a' "$EXTRA_FILE")" = 600 ] \
    || fail failed_container "本地凭证文件权限校验失败"

git config --global --unset-all credential.helper || true
git config --global credential.helper "$RUNTIME_HELPER" \
    || fail failed_initialize "运行期 helper 配置失败"
install_runtime_git || fail failed_container "运行期 Git 入口安装失败"
configure_ssh_login || fail failed_container "SSH 登录环境配置失败"
"$INIT_HELPER" --report initialized || fail failed_initialize "Git initialized 状态上报失败"

unset GIT_INIT_DEADLINE
