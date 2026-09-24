#!/bin/bash

set -e
umask 077

GIT_CLONE_OUTPUT_FILE=""
GIT_CREDENTIAL_EVENT_FILE=""
trap 'if [ -n "$GIT_CLONE_OUTPUT_FILE" ]; then rm -f -- "$GIT_CLONE_OUTPUT_FILE"; fi; if [ -n "$GIT_CREDENTIAL_EVENT_FILE" ]; then rm -f -- "$GIT_CREDENTIAL_EVENT_FILE"; fi' EXIT

if [ "$#" -ne 6 ]; then
    echo "[git-clone] 启动参数无效" >&2
    exit 1
fi

GIT_APP_DIR=$1
GIT_HELPER_DIR=$2
GIT_INIT_HELPER=$3
GIT_RUNTIME_HELPER=$4
GIT_CREDENTIAL_FILE=$5
GIT_EXTRA_FILE=$6

# Clone timing, retries, and diagnostic limits belong to this orchestration.
GIT_INIT_TIMEOUT_SECONDS=600
GIT_MAX_ATTEMPTS=5
GIT_CREDENTIAL_POLL_INTERVAL_SECONDS=2
GIT_RETRY_DELAY_SECONDS=3
GIT_DIAGNOSTIC_MAX_LINES=120
GIT_DIAGNOSTIC_MAX_BYTES=16384
export -n GIT_MAX_ATTEMPTS
export GIT_INIT_TIMEOUT_SECONDS GIT_CREDENTIAL_POLL_INTERVAL_SECONDS

# Preserve normal progress logs on stderr; fd 4 is reserved for the optional repository path.
exec 4>&3
exec 3>&-
exec 1>&2

GITEE_URL="${TESTAGENT_CLOUD_GITEE_URL:-}"
GITEE_USER="${TESTAGENT_CLOUD_GITEE_USER:-}"
GITEE_REPOSITORY="${TESTAGENT_CLOUD_GITEE_REPOSITORY:-}"
GITEE_BRANCH="${TESTAGENT_CLOUD_GITEE_BRANCH:-}"

# Gitee fields must be entirely empty or complete; a branch only applies to a configured repository.
if [ -z "$GITEE_URL" ] && [ -z "$GITEE_USER" ] && [ -z "$GITEE_REPOSITORY" ]; then
    GIT_URL=""
    echo "[start] 未配置码云地址，跳过 Git clone 和凭证获取"
else
    if [ -z "$GITEE_URL" ] || [ -z "$GITEE_USER" ] || [ -z "$GITEE_REPOSITORY" ]; then
        echo "[start] 码云地址配置不完整" >&2
        "$GIT_INIT_HELPER" --report failed_initialize || true
        exit 1
    fi
    if ! GIT_URL=$(python3 - "$GITEE_URL" "$GITEE_USER" "$GITEE_REPOSITORY" "$GITEE_BRANCH" <<'PY'
import sys
from urllib.parse import urlsplit

prefix, user, repository, branch = sys.argv[1:]

def valid_component(value):
    return bool(value) and not any(
        character.isspace()
        or ord(character) < 32
        or ord(character) == 127
        or character in "/\\?#%"
        for character in value
    ) and value not in (".", "..") and ".." not in value

def valid_scp_prefix(value):
    if not value.startswith("git@") or not value.endswith(":"):
        return False
    authority = value[:-1]
    if authority.count("@") != 1:
        return False
    login, host = authority.split("@", 1)
    if not login or not host:
        return False
    if any(
        character.isspace()
        or ord(character) < 32
        or ord(character) == 127
        or character in "/\\?#%"
        for character in login + host
    ):
        return False
    return True

if not valid_component(user) or not valid_component(repository):
    raise SystemExit(1)
if branch and (
    any(character.isspace() or ord(character) < 32 or ord(character) == 127 for character in branch)
    or branch.startswith("-")
):
    raise SystemExit(1)
if any(ord(character) < 32 or ord(character) == 127 for character in prefix) or prefix != prefix.strip():
    raise SystemExit(1)
try:
    parsed = urlsplit(prefix)
    _ = parsed.port
    hostname = parsed.hostname
except ValueError:
    raise SystemExit(1)
# Preserve SSH scp-like syntax while appending the user and repository path.
if prefix.startswith("git@"):
    if not valid_scp_prefix(prefix):
        raise SystemExit(1)
    print(prefix + user + "/" + repository + ".git")
else:
    # HTTP(S) uses credential helpers; git:// remains a direct unauthenticated protocol.
    if parsed.scheme not in ("http", "https", "git") or not parsed.netloc or not hostname:
        raise SystemExit(1)
    if parsed.username is not None or parsed.password is not None or parsed.query or parsed.fragment:
        raise SystemExit(1)
    if ".." in parsed.path.split("/"):
        raise SystemExit(1)
    base = prefix.rstrip("/")
    print(base + "/" + user + "/" + repository + ".git")
PY
); then
        echo "[start] 码云地址或路径字段非法" >&2
        "$GIT_INIT_HELPER" --report failed_initialize || true
        exit 1
    fi
    GIT_APP_CLONE_DIR="$GIT_APP_DIR/$GITEE_REPOSITORY"
    echo "[start] 码云配置和码云地址校验通过"
fi

if [ -z "$GIT_URL" ]; then
    # No repository means no clone or credential API request; select the runtime helper for later Git commands.
    if ! git config --global --unset-all credential.helper; then
        :
    fi
    if ! git config --global credential.helper "$GIT_RUNTIME_HELPER"; then
        echo "[start] 运行 helper 全局配置失败" >&2
        "$GIT_INIT_HELPER" --report failed_initialize || true
        exit 1
    fi
    exit 0
fi

# Only a complete, validated repository configuration may take ownership of /app.
if [ ! -d "$GIT_APP_DIR" ]; then
    echo "[start] /app 不是目录" >&2
    "$GIT_INIT_HELPER" --report failed_container || true
    exit 1
fi
if ! cd "$GIT_APP_DIR"; then
    echo "[start] 无法进入 /app" >&2
    "$GIT_INIT_HELPER" --report failed_container || true
    exit 1
fi
if ! GIT_APP_BASELINE=$(find "$GIT_APP_DIR" -mindepth 1 -maxdepth 1 -print); then
    echo "[start] /app 内容检查失败" >&2
    "$GIT_INIT_HELPER" --report failed_container || true
    exit 1
fi
if [ -n "$GIT_APP_BASELINE" ]; then
    echo "[start] /app 非空，停止 Git 初始化" >&2
    "$GIT_INIT_HELPER" --report failed_initialize || true
    exit 1
fi
echo "[start] /app 已确认为空"
if ! "$GIT_INIT_HELPER" --report processing; then
    echo "[start] Git processing 状态上报失败" >&2
    "$GIT_INIT_HELPER" --report failed_service || true
    exit 1
fi
echo "[start] Git 状态 processing 已上报"

if ! GIT_INIT_START_SECONDS=$(date +%s); then
    echo "[start] 初始化计时器不可用" >&2
    "$GIT_INIT_HELPER" --report failed_container || true
    exit 1
fi
GIT_INIT_DEADLINE=$((GIT_INIT_START_SECONDS + GIT_INIT_TIMEOUT_SECONDS))
export GIT_INIT_DEADLINE
GIT_ATTEMPT=1
GIT_CLONE_SUCCESS=0
GIT_CREDENTIAL_REFRESH_PROVIDED=0
while [ "$GIT_ATTEMPT" -le "$GIT_MAX_ATTEMPTS" ]; do
    if ! GIT_NOW_SECONDS=$(date +%s); then
        echo "[start] 初始化计时器不可用" >&2
        "$GIT_INIT_HELPER" --report failed_container || true
        exit 1
    fi
    if [ "$GIT_NOW_SECONDS" -ge "$GIT_INIT_DEADLINE" ]; then
        echo "[start] Git 初始化超时" >&2
        "$GIT_INIT_HELPER" --report failed_timeout || true
        exit 1
    fi
    GIT_REMAINING_SECONDS=$((GIT_INIT_DEADLINE - GIT_NOW_SECONDS))
    if [ "$GIT_REMAINING_SECONDS" -lt 1 ]; then
        echo "[start] Git 初始化超时" >&2
        "$GIT_INIT_HELPER" --report failed_timeout || true
        exit 1
    fi

    # Stream sanitized clone output while retaining raw output privately for error classification.
    GIT_CLONE_STATUS=0
    GIT_CLONE_OK=0
    GIT_CREDENTIAL_REFRESHED=0
    if ! GIT_CREDENTIAL_EVENT_FILE=$(mktemp "$GIT_HELPER_DIR/.init-credential-event.XXXXXX"); then
        echo "[start] 初始化凭证事件文件创建失败" >&2
        "$GIT_INIT_HELPER" --report failed_container || true
        exit 1
    fi
    if ! GIT_CLONE_OUTPUT_FILE=$(mktemp "$GIT_HELPER_DIR/.git-clone-output.XXXXXX"); then
        rm -f -- "$GIT_CREDENTIAL_EVENT_FILE"
        echo "[start] Git clone 输出文件创建失败" >&2
        "$GIT_INIT_HELPER" --report failed_container || true
        exit 1
    fi
    echo "[start] Git clone 第 $GIT_ATTEMPT/$GIT_MAX_ATTEMPTS 次尝试"
    if [ -n "$GITEE_BRANCH" ]; then
        if (
            set -o pipefail
            GIT_CREDENTIAL_EVENT_FILE="$GIT_CREDENTIAL_EVENT_FILE" GIT_TERMINAL_PROMPT=0 GIT_ASKPASS= SSH_ASKPASS= GIT_CONFIG_NOSYSTEM=1 LC_ALL=C \
                timeout --signal=TERM "$GIT_REMAINING_SECONDS" git clone --progress --branch "$GITEE_BRANCH" "$GIT_URL" 2>&1 |
                tee "$GIT_CLONE_OUTPUT_FILE" |
                LC_ALL=C tr '\r' '\n' |
                LC_ALL=C tr -d '\000-\010\013\014\016-\037\177' |
                GIT_CLONE_URL="$GIT_URL" LC_ALL=C awk '
                    BEGIN { target = ENVIRON["GIT_CLONE_URL"] }
                    function redact_target(line, result, position) {
                        if (target == "") return line
                        result = ""
                        while ((position = index(line, target)) > 0) {
                            result = result substr(line, 1, position - 1) "<git-url>"
                            line = substr(line, position + length(target))
                        }
                        return result line
                    }
                    { print redact_target($0); fflush() }
                ' |
                LC_ALL=C sed -u -E \
                    -e 's#(["]?[[:alnum:]_.-]*(password|token|secret|authorization)[[:alnum:]_.-]*["]?[[:space:]]*[=:][[:space:]]*).*#\1<redacted>#Ig' >&2
        ); then
            GIT_CLONE_OK=1
        else
            GIT_CLONE_STATUS=$?
        fi
    else
        if (
            set -o pipefail
            GIT_CREDENTIAL_EVENT_FILE="$GIT_CREDENTIAL_EVENT_FILE" GIT_TERMINAL_PROMPT=0 GIT_ASKPASS= SSH_ASKPASS= GIT_CONFIG_NOSYSTEM=1 LC_ALL=C \
                timeout --signal=TERM "$GIT_REMAINING_SECONDS" git clone --progress "$GIT_URL" 2>&1 |
                tee "$GIT_CLONE_OUTPUT_FILE" |
                LC_ALL=C tr '\r' '\n' |
                LC_ALL=C tr -d '\000-\010\013\014\016-\037\177' |
                GIT_CLONE_URL="$GIT_URL" LC_ALL=C awk '
                    BEGIN { target = ENVIRON["GIT_CLONE_URL"] }
                    function redact_target(line, result, position) {
                        if (target == "") return line
                        result = ""
                        while ((position = index(line, target)) > 0) {
                            result = result substr(line, 1, position - 1) "<git-url>"
                            line = substr(line, position + length(target))
                        }
                        return result line
                    }
                    { print redact_target($0); fflush() }
                ' |
                LC_ALL=C sed -u -E \
                    -e 's#(["]?[[:alnum:]_.-]*(password|token|secret|authorization)[[:alnum:]_.-]*["]?[[:space:]]*[=:][[:space:]]*).*#\1<redacted>#Ig' >&2
        ); then
            GIT_CLONE_OK=1
        else
            GIT_CLONE_STATUS=$?
        fi
    fi
    if ! GIT_CLONE_OUTPUT=$(cat -- "$GIT_CLONE_OUTPUT_FILE"); then
        rm -f -- "$GIT_CLONE_OUTPUT_FILE" "$GIT_CREDENTIAL_EVENT_FILE"
        echo "[start] Git clone 输出读取失败" >&2
        "$GIT_INIT_HELPER" --report failed_container || true
        exit 1
    fi
    rm -f -- "$GIT_CLONE_OUTPUT_FILE"
    if [ "$GIT_CLONE_OK" -eq 1 ]; then
        GIT_CLONE_SUCCESS=1
        rm -f -- "$GIT_CREDENTIAL_EVENT_FILE"
        unset GIT_CLONE_OUTPUT
        echo "[start] Git clone 完成"
        break
    fi
    echo "[start] Git clone 失败：attempt=$GIT_ATTEMPT/$GIT_MAX_ATTEMPTS exit=$GIT_CLONE_STATUS" >&2
    if [ -n "$GIT_CLONE_OUTPUT" ]; then
        echo "[start] Git clone 详细诊断开始 (地址、凭证和敏感字段已脱敏)" >&2
        printf '%s\n' "$GIT_CLONE_OUTPUT" |
            LC_ALL=C tr '\r' '\n' |
            LC_ALL=C tr -d '\000-\010\013\014\016-\037\177' |
            GIT_CLONE_URL="$GIT_URL" LC_ALL=C awk '
                BEGIN { target = ENVIRON["GIT_CLONE_URL"] }
                function redact_target(line, result, position) {
                    if (target == "") return line
                    result = ""
                    while ((position = index(line, target)) > 0) {
                        result = result substr(line, 1, position - 1) "<git-url>"
                        line = substr(line, position + length(target))
                    }
                    return result line
                }
                { print redact_target($0) }
            ' |
            LC_ALL=C sed -E \
                -e 's#(["]?[[:alnum:]_.-]*(password|token|secret|authorization)[[:alnum:]_.-]*["]?[[:space:]]*[=:][[:space:]]*).*#\1<redacted>#Ig' |
            LC_ALL=C awk \
                -v max_lines="$GIT_DIAGNOSTIC_MAX_LINES" \
                -v max_bytes="$GIT_DIAGNOSTIC_MAX_BYTES" \
                '
                {
                    if (NR > max_lines || bytes >= max_bytes) {
                        truncated = 1
                        exit
                    }
                    available = max_bytes - bytes
                    if (length($0) + 1 > available) {
                        if (available > 1) {
                            print "[start] Git clone 诊断: " substr($0, 1, available - 1)
                        }
                        truncated = 1
                        exit
                    }
                    print "[start] Git clone 诊断: " $0
                    bytes += length($0) + 1
                }
                END {
                    if (truncated) {
                        print "[start] Git clone 详细诊断已截断"
                    }
                }' >&2
        echo "[start] Git clone 详细诊断结束" >&2
    else
        echo "[start] Git clone 未返回详细诊断输出" >&2
    fi

    # Remove only a repository directory confirmed to have been created by this clone.
    # Refuse cleanup if Git status, the baseline, or external content makes ownership uncertain.
    if [ -n "$GIT_APP_BASELINE" ]; then
        echo "[start] 无法确认失败 clone 的文件归属" >&2
        unset GIT_CLONE_OUTPUT
        "$GIT_INIT_HELPER" --report failed_initialize || true
        exit 1
    fi
    if ! GIT_APP_REMAINDER=$(find "$GIT_APP_DIR" -mindepth 1 -maxdepth 1 -print -quit); then
        echo "[start] 失败 clone 清理校验失败" >&2
        unset GIT_CLONE_OUTPUT
        "$GIT_INIT_HELPER" --report failed_container || true
        exit 1
    fi
    if [ -n "$GIT_APP_REMAINDER" ]; then
        if [ "$GIT_APP_REMAINDER" != "$GIT_APP_CLONE_DIR" ]; then
            echo "[start] 无法确认失败 clone 的文件归属" >&2
            unset GIT_CLONE_OUTPUT
            "$GIT_INIT_HELPER" --report failed_container || true
            exit 1
        fi
        if [ -L "$GIT_APP_CLONE_DIR" ] || [ ! -d "$GIT_APP_CLONE_DIR" ]; then
            echo "[start] 无法确认失败 clone 的文件归属" >&2
            unset GIT_CLONE_OUTPUT
            "$GIT_INIT_HELPER" --report failed_container || true
            exit 1
        fi
        if ! GIT_APP_GIT_STATUS=$(git -C "$GIT_APP_CLONE_DIR" status --porcelain=v1 --untracked-files=all --ignored=matching); then
            echo "[start] 无法确认失败 clone 的文件归属" >&2
            unset GIT_CLONE_OUTPUT
            "$GIT_INIT_HELPER" --report failed_container || true
            exit 1
        fi
        if [ -n "$GIT_APP_GIT_STATUS" ]; then
            echo "[start] 失败 clone 包含未确认内容" >&2
            unset GIT_CLONE_OUTPUT GIT_APP_GIT_STATUS
            "$GIT_INIT_HELPER" --report failed_initialize || true
            exit 1
        fi
        if ! GIT_APP_EMPTY_DIR=$(find "$GIT_APP_DIR" -mindepth 1 -type d -empty ! -path "$GIT_APP_CLONE_DIR" ! -path "$GIT_APP_CLONE_DIR/.git" ! -path "$GIT_APP_CLONE_DIR/.git/*" -print -quit); then
            echo "[start] 失败 clone 清理校验失败" >&2
            unset GIT_CLONE_OUTPUT GIT_APP_GIT_STATUS
            "$GIT_INIT_HELPER" --report failed_container || true
            exit 1
        fi
        if [ -n "$GIT_APP_EMPTY_DIR" ]; then
            echo "[start] 失败 clone 包含未确认目录" >&2
            unset GIT_CLONE_OUTPUT GIT_APP_GIT_STATUS GIT_APP_EMPTY_DIR
            "$GIT_INIT_HELPER" --report failed_initialize || true
            exit 1
        fi
        if ! rm -rf -- "$GIT_APP_CLONE_DIR"; then
            echo "[start] 失败 clone 清理失败" >&2
            unset GIT_CLONE_OUTPUT GIT_APP_GIT_STATUS
            "$GIT_INIT_HELPER" --report failed_container || true
            exit 1
        fi
    fi

    if [[ "$GIT_URL" == git://* || "$GIT_URL" == git@*:* ]]; then
        unset GIT_CLONE_OUTPUT
        echo "[start] 非 HTTP Git clone 失败，停止重试" >&2
        "$GIT_INIT_HELPER" --report failed_git || true
        exit 1
    fi
    GIT_CLONE_OUTPUT_LOWER="${GIT_CLONE_OUTPUT,,}"
    GIT_CREDENTIAL_WAS_PROVIDED=0
    if [ -s "$GIT_CREDENTIAL_EVENT_FILE" ]; then
        GIT_CREDENTIAL_WAS_PROVIDED=1
    fi
    if [ "$GIT_CREDENTIAL_REFRESH_PROVIDED" -eq 1 ]; then
        GIT_CREDENTIAL_WAS_PROVIDED=1
    fi
    rm -f -- "$GIT_CREDENTIAL_EVENT_FILE"
    if [ "$GIT_CLONE_STATUS" -eq 124 ] || [[ "$GIT_CLONE_OUTPUT_LOWER" == *"credential helper error: timeout"* ]] || [[ "$GIT_CLONE_OUTPUT_LOWER" == *"timed out"* ]]; then
        unset GIT_CLONE_OUTPUT GIT_CLONE_OUTPUT_LOWER
        echo "[start] Git clone 初始化超时" >&2
        "$GIT_INIT_HELPER" --report failed_timeout || true
        exit 1
    fi
    if [[ "$GIT_CLONE_OUTPUT_LOWER" == *"credential helper error: max_attempts"* ]]; then
        unset GIT_CLONE_OUTPUT GIT_CLONE_OUTPUT_LOWER
        echo "[start] 凭证获取达到重试上限" >&2
        "$GIT_INIT_HELPER" --report failed_max_attempts || true
        exit 1
    fi
    if [[ "$GIT_CLONE_OUTPUT_LOWER" == *"credential helper error: service"* ]] || [[ "$GIT_CLONE_OUTPUT_LOWER" == *"credential helper error: unauthorized"* ]] || [[ "$GIT_CLONE_OUTPUT_LOWER" == *"credential helper error: not_found"* ]]; then
        unset GIT_CLONE_OUTPUT GIT_CLONE_OUTPUT_LOWER
        echo "[start] 码云凭证服务处理失败" >&2
        "$GIT_INIT_HELPER" --report failed_service || true
        exit 1
    fi
    if [[ "$GIT_CLONE_OUTPUT_LOWER" == *"credential helper error: unexpected_state"* ]] || [[ "$GIT_CLONE_OUTPUT_LOWER" == *"credential helper error: invalid_credential"* ]]; then
        unset GIT_CLONE_OUTPUT GIT_CLONE_OUTPUT_LOWER
        echo "[start] 码云凭证状态异常" >&2
        "$GIT_INIT_HELPER" --report failed_unexpected_state || true
        exit 1
    fi
    if [[ "$GIT_CLONE_OUTPUT_LOWER" == *"credential helper error: local"* ]] || [[ "$GIT_CLONE_OUTPUT_LOWER" == *"credential helper error: internal"* ]]; then
        unset GIT_CLONE_OUTPUT GIT_CLONE_OUTPUT_LOWER
        echo "[start] 码云本地凭证处理失败" >&2
        "$GIT_INIT_HELPER" --report failed_container || true
        exit 1
    fi
    if [[ "$GIT_CLONE_OUTPUT_LOWER" == *"credential helper error: remote_failed"* ]]; then
        unset GIT_CLONE_OUTPUT GIT_CLONE_OUTPUT_LOWER
        echo "[start] 码云服务已返回失败终态" >&2
        exit 1
    fi
    if [[ "$GIT_CLONE_OUTPUT_LOWER" == *"requested url returned error: 400"* ]] \
        || [[ "$GIT_CLONE_OUTPUT_LOWER" == *"requested url returned error: 404"* ]] \
        || [[ "$GIT_CLONE_OUTPUT_LOWER" == *"couldn't find remote ref"* ]] \
        || [[ "$GIT_CLONE_OUTPUT_LOWER" == *"does not appear to be a git repository"* ]]; then
        unset GIT_CLONE_OUTPUT GIT_CLONE_OUTPUT_LOWER
        echo "[start] Git clone 返回不可恢复错误" >&2
        "$GIT_INIT_HELPER" --report failed_git || true
        exit 1
    fi

    if [[ "$GIT_CLONE_OUTPUT_LOWER" == *"repository not found"* ]] \
        || [[ "$GIT_CLONE_OUTPUT_LOWER" == *"repository"* && "$GIT_CLONE_OUTPUT_LOWER" == *"not found"* ]]; then
        GIT_CREDENTIAL_REFRESH_STATUS=credential_required
        if [ "$GIT_CREDENTIAL_WAS_PROVIDED" -eq 1 ]; then
            GIT_CREDENTIAL_REFRESH_STATUS=credential_rejected
        fi
        echo "[start] Git clone 返回 repository not found，凭证状态=$GIT_CREDENTIAL_REFRESH_STATUS，开始凭证刷新" >&2
        if ! printf 'url=%s\n\n' "$GIT_URL" |
            GIT_CREDENTIAL_EVENT_FILE="$GIT_CREDENTIAL_EVENT_FILE" \
            GIT_CREDENTIAL_REFRESH=1 \
            GIT_CREDENTIAL_REFRESH_STATUS="$GIT_CREDENTIAL_REFRESH_STATUS" \
            GIT_TERMINAL_PROMPT=0 GIT_CONFIG_NOSYSTEM=1 \
            git credential fill > /dev/null; then
            unset GIT_CLONE_OUTPUT GIT_CLONE_OUTPUT_LOWER GIT_CREDENTIAL_REFRESH_STATUS
            echo "[start] repository not found 后凭证刷新失败" >&2
            exit 1
        fi
        GIT_CREDENTIAL_REFRESH_PROVIDED=0
        if [ -s "$GIT_CREDENTIAL_EVENT_FILE" ]; then
            GIT_CREDENTIAL_REFRESH_PROVIDED=1
        fi
        rm -f -- "$GIT_CREDENTIAL_EVENT_FILE"
        GIT_CREDENTIAL_REFRESHED=1
        echo "[start] 凭证刷新完成，按原 Git clone 命令重试" >&2
    elif [[ "$GIT_CLONE_OUTPUT_LOWER" != *"authentication failed"* ]] \
        && [[ "$GIT_CLONE_OUTPUT_LOWER" != *"could not read username"* ]] \
        && [[ "$GIT_CLONE_OUTPUT_LOWER" != *"requested url returned error: 401"* ]] \
        && [[ "$GIT_CLONE_OUTPUT_LOWER" != *"requested url returned error: 403"* ]] \
        && [[ "$GIT_CLONE_OUTPUT_LOWER" != *"could not resolve host"* ]] \
        && [[ "$GIT_CLONE_OUTPUT_LOWER" != *"failed to connect"* ]] \
        && [[ "$GIT_CLONE_OUTPUT_LOWER" != *"couldn't connect"* ]] \
        && [[ "$GIT_CLONE_OUTPUT_LOWER" != *"could not connect"* ]] \
        && [[ "$GIT_CLONE_OUTPUT_LOWER" != *"connection refused"* ]] \
        && [[ "$GIT_CLONE_OUTPUT_LOWER" != *"connection reset"* ]] \
        && [[ "$GIT_CLONE_OUTPUT_LOWER" != *"network is unreachable"* ]] \
        && [[ "$GIT_CLONE_OUTPUT_LOWER" != *"temporary failure in name resolution"* ]] \
        && [[ "$GIT_CLONE_OUTPUT_LOWER" != *"could not resolve"* ]] \
        && [[ "$GIT_CLONE_OUTPUT_LOWER" != *"connection aborted"* ]] \
        && [[ "$GIT_CLONE_OUTPUT_LOWER" != *"recv failure"* ]] \
        && [[ "$GIT_CLONE_OUTPUT_LOWER" != *"operation timed out"* ]] \
        && [[ "$GIT_CLONE_OUTPUT_LOWER" != *"ssl_error_syscall"* ]] \
        && [[ "$GIT_CLONE_OUTPUT_LOWER" != *"gnutls"* ]] \
        && [[ "$GIT_CLONE_OUTPUT_LOWER" != *"tls connection"* ]] \
        && [[ "$GIT_CLONE_OUTPUT_LOWER" != *"proxyconnect"* ]] \
        && [[ "$GIT_CLONE_OUTPUT_LOWER" != *"proxy error"* ]] \
        && [[ "$GIT_CLONE_OUTPUT_LOWER" != *"network error"* ]] \
        && [[ "$GIT_CLONE_OUTPUT_LOWER" != *"early eof"* ]] \
        && [[ "$GIT_CLONE_OUTPUT_LOWER" != *"remote end hung up"* ]]; then
        unset GIT_CLONE_OUTPUT GIT_CLONE_OUTPUT_LOWER
        echo "[start] Git clone 返回不可分类错误" >&2
        "$GIT_INIT_HELPER" --report failed_git || true
        exit 1
    fi
    if [ "$GIT_CREDENTIAL_REFRESHED" -eq 0 ]; then
        GIT_CREDENTIAL_REFRESH_PROVIDED=0
    fi
    unset GIT_CLONE_OUTPUT GIT_CLONE_OUTPUT_LOWER
    if [ "$GIT_CREDENTIAL_REFRESHED" -eq 1 ]; then
        GIT_ATTEMPT=$((GIT_ATTEMPT + 1))
        continue
    fi
    if [ "$GIT_ATTEMPT" -ge "$GIT_MAX_ATTEMPTS" ]; then
        echo "[start] Git clone 达到重试上限" >&2
        "$GIT_INIT_HELPER" --report failed_max_attempts || true
        exit 1
    fi
    if ! GIT_NOW_SECONDS=$(date +%s); then
        echo "[start] 初始化计时器不可用" >&2
        "$GIT_INIT_HELPER" --report failed_container || true
        exit 1
    fi
    GIT_SLEEP_SECONDS="$GIT_RETRY_DELAY_SECONDS"
    GIT_REMAINING_SECONDS=$((GIT_INIT_DEADLINE - GIT_NOW_SECONDS))
    if [ "$GIT_REMAINING_SECONDS" -le 0 ]; then
        "$GIT_INIT_HELPER" --report failed_timeout || true
        exit 1
    fi
    if [ "$GIT_SLEEP_SECONDS" -gt "$GIT_REMAINING_SECONDS" ]; then
        GIT_SLEEP_SECONDS="$GIT_REMAINING_SECONDS"
    fi
    echo "[start] Git clone 将在 ${GIT_SLEEP_SECONDS} 秒后重试"
    if ! sleep "$GIT_SLEEP_SECONDS"; then
        echo "[start] Git 重试等待失败" >&2
        "$GIT_INIT_HELPER" --report failed_container || true
        exit 1
    fi
    GIT_ATTEMPT=$((GIT_ATTEMPT + 1))
done
if [ "$GIT_CLONE_SUCCESS" -ne 1 ]; then
    "$GIT_INIT_HELPER" --report failed_max_attempts || true
    exit 1
fi

# Apply the real identity after clone, then switch to the runtime helper before initialized is reported.
GIT_USERNAME=""
GIT_EMAIL=""
if [ -f "$GIT_EXTRA_FILE" ]; then
    if ! while IFS='=' read -r GIT_EXTRA_KEY GIT_EXTRA_VALUE; do
        case "$GIT_EXTRA_KEY" in
            git_username)
                GIT_USERNAME="$GIT_EXTRA_VALUE"
                ;;
            git_email)
                GIT_EMAIL="$GIT_EXTRA_VALUE"
                ;;
        esac
    done < "$GIT_EXTRA_FILE"; then
        echo "[start] 码云身份文件读取失败" >&2
        "$GIT_INIT_HELPER" --report failed_container || true
        exit 1
    fi
fi
if [ -n "$GIT_USERNAME" ]; then
    if ! git config --global user.name "$GIT_USERNAME" || ! git config --global user.email "$GIT_EMAIL"; then
        echo "[start] 码云用户身份配置失败" >&2
        "$GIT_INIT_HELPER" --report failed_initialize || true
        exit 1
    fi
    echo "[start] 码云用户身份配置完成"
else
    echo "[start] 未找到码云用户身份元数据，保持现有身份配置"
fi
if ! chmod 0600 "$GIT_CREDENTIAL_FILE" "$GIT_EXTRA_FILE"; then
    echo "[start] 码云本地文件权限校验失败" >&2
    "$GIT_INIT_HELPER" --report failed_container || true
    exit 1
fi
if [ "$(stat -c '%a' "$GIT_CREDENTIAL_FILE")" != "600" ] || [ "$(stat -c '%a' "$GIT_EXTRA_FILE")" != "600" ]; then
    echo "[start] 码云本地文件权限校验失败" >&2
    "$GIT_INIT_HELPER" --report failed_container || true
    exit 1
fi
echo "[start] 码云本地凭证文件权限确认完成"
if ! git config --global --unset-all credential.helper; then
    :
fi
if ! git config --global credential.helper "$GIT_RUNTIME_HELPER"; then
    echo "[start] 运行 helper 全局配置失败" >&2
    "$GIT_INIT_HELPER" --report failed_initialize || true
    exit 1
fi
echo "[start] 运行期 credential helper 已启用"

printf '%s\t%s\n' "$GIT_APP_CLONE_DIR" "$GIT_INIT_DEADLINE" >&4
