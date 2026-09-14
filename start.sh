#!/bin/bash

set -e

# 容器 SSH 指纹生成
# 不同容器的指纹不一致
mkdir -p /run/sshd
ssh-keygen -A

# --- Start ---

# 接下来的初始化流程的总可用时间
GIT_INIT_TIMEOUT_SECONDS=900

# 获取 git 凭证允许主动尝试的最大次数。
GIT_MAX_ATTEMPTS=10

# 服务端暂未提供凭证时，两次 credential GET 之间的等待时间。
GIT_CREDENTIAL_POLL_INTERVAL_SECONDS=2

# 可恢复 Git 网络错误的两次 clone 尝试之间的等待时间。
GIT_RETRY_DELAY_SECONDS=3
# 单次 clone 失败时写入容器日志的最大诊断行数。
GIT_DIAGNOSTIC_MAX_LINES=120
# 单次 clone 失败时写入容器日志的最大诊断字节数。
GIT_DIAGNOSTIC_MAX_BYTES=16384

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

# Gitee 仓库必须直接 clone 到的工作目录。
GIT_APP_DIR=/app

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

# 校验初始化 helper 依赖的 Python 3 和 Git 命令。
if ! command -v python3 >/dev/null 2>&1 || ! python3 -c 'import sys; raise SystemExit(0 if sys.version_info[0] == 3 else 1)' >/dev/null 2>&1; then
    echo "[start] Python 3 不可用" >&2
    exit 1
fi

if ! command -v git >/dev/null 2>&1 || ! command -v timeout >/dev/null 2>&1; then
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
    if ! python3 -m pip config --global set global.index-url "$TESTAGENT_CLOUD_PIP_URL" >/dev/null 2>&1; then
        echo "[start] PIP 镜像配置失败" >&2
        exit 1
    fi
    echo "[start] PIP 全局镜像配置完成"
else
    echo "[start] 未配置 PIP 镜像，跳过"
fi

# npm 使用全局 registry 配置；空值表示调用方未要求覆盖镜像源。
if [ -n "${TESTAGENT_CLOUD_NPM_URL:-}" ]; then
    if ! command -v npm >/dev/null 2>&1; then
        echo "[start] NPM 不可用" >&2
        exit 1
    fi
    if ! npm config set registry "$TESTAGENT_CLOUD_NPM_URL" --global >/dev/null 2>&1; then
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
if [ -L "$GIT_CREDENTIAL_FILE" ] || { [ -e "$GIT_CREDENTIAL_FILE" ] && [ ! -f "$GIT_CREDENTIAL_FILE" ]; }; then
    echo "[start] 码云凭证文件类型非法" >&2
    exit 1
fi
if [ -L "$GIT_EXTRA_FILE" ] || { [ -e "$GIT_EXTRA_FILE" ] && [ ! -f "$GIT_EXTRA_FILE" ]; }; then
    echo "[start] 码云身份文件类型非法" >&2
    exit 1
fi
if [ -e "$GIT_CREDENTIAL_FILE" ] && [ "$(stat -c '%h' "$GIT_CREDENTIAL_FILE" 2>/dev/null)" != "1" ]; then
    echo "[start] 码云凭证文件链接数非法" >&2
    exit 1
fi
if [ -e "$GIT_EXTRA_FILE" ] && [ "$(stat -c '%h' "$GIT_EXTRA_FILE" 2>/dev/null)" != "1" ]; then
    echo "[start] 码云身份文件链接数非法" >&2
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

# 生成两个阶段共用协议实现的 Python credential helper；参数由上方常量注入。
# 先写入私有临时文件，再原子替换最终 helper，避免覆盖外部链接目标。
if ! GIT_INIT_HELPER_TEMP=$(mktemp "$GIT_HELPER_DIR/.init-credential-helper.XXXXXX"); then
    echo "[start] 初始化 helper 临时文件创建失败" >&2
    exit 1
fi
if ! cat > "$GIT_INIT_HELPER_TEMP" <<'PY'
#!/usr/bin/env python3
"""Git credential protocol adapter used during container initialization.

The same file is copied to the runtime helper.  Its basename selects the
phase, while all credential persistence remains in the two fixed local files.
"""

import json
import os
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

# These placeholders are replaced by the shell constants before installation.
CREDENTIAL_FILE = "__CREDENTIAL_FILE__"
EXTRA_FILE = "__EXTRA_FILE__"
INIT_TIMEOUT_SECONDS = __INIT_TIMEOUT_SECONDS__
MAX_ATTEMPTS = __MAX_ATTEMPTS__
POLL_INTERVAL_SECONDS = __POLL_INTERVAL_SECONDS__
# Bound every individual service request even when the caller is interactive.
HTTP_TIMEOUT_SECONDS = 10
MAX_RESPONSE_BYTES = 65536
# Git passes the helper basename as argv[0]; init and runtime have different API rules.
HELPER_PHASE = (
    "init"
    if os.path.basename(sys.argv[0]) == "init-credential-helper"
    else "runtime"
)

WAITING_STATES = {"starting", "credential_required", "credential_rejected"}
FINAL_FAILURE_STATES = {
    "failed_timeout",
    "failed_max_attempts",
    "failed_unexpected_state",
    "failed_git",
    "failed_service",
    "failed_container",
    "failed_initialize",
    "failed_user_cancelled",
}
REPORT_STATES = WAITING_STATES | FINAL_FAILURE_STATES | {"starting", "processing", "initialized"}
EXTRA_KEYS = ("type", "git_username", "git_email")


class _NoRedirectHandler(HTTPRedirectHandler):
    # Never forward service headers or a credential request to another host.
    def redirect_request(self, request, file, code, msg, headers, new_url):
        return None


HTTP_CLIENT = build_opener(_NoRedirectHandler)


def _error(category):
    print(
        "git credential helper error: " + category + " phase=" + HELPER_PHASE,
        file=sys.stderr,
    )


def _progress(message):
    print(
        "git credential helper progress: phase=" + HELPER_PHASE + " " + message,
        file=sys.stderr,
    )


def _safe_protocol_value(value):
    return isinstance(value, str) and "\x00" not in value and "\r" not in value and "\n" not in value


def _safe_identity_value(value):
    return _safe_protocol_value(value) and not any(
        ord(character) < 32 or ord(character) == 127 for character in value
    )


def _read_request():
    # Git credential helpers receive key/value records terminated by a blank line.
    fields = {}
    for raw_line in sys.stdin.buffer:
        if raw_line in (b"\n", b"\r\n"):
            break
        raw_line = raw_line.rstrip(b"\r\n")
        if b"=" not in raw_line:
            continue
        raw_key, raw_value = raw_line.split(b"=", 1)
        try:
            key = raw_key.decode("utf-8", "surrogateescape")
            value = raw_value.decode("utf-8", "surrogateescape")
        except UnicodeError:
            continue
        fields[key] = value
    return fields


def _credential_protocol(fields):
    lines = []
    for key in ("protocol", "host", "path", "username", "password"):
        if key not in fields:
            continue
        value = fields[key]
        if not _safe_protocol_value(value):
            return None
        lines.append(key + "=" + value + "\n")
    lines.append("\n")
    return "".join(lines).encode("utf-8", "surrogateescape")


def _regular_file(path):
    try:
        if os.path.islink(path):
            return False
        metadata = os.lstat(path)
        return stat.S_ISREG(metadata.st_mode) and metadata.st_nlink == 1
    except FileNotFoundError:
        return False
    except OSError:
        return False


def _prepare_credential_file(create):
    if os.path.lexists(CREDENTIAL_FILE):
        if not _regular_file(CREDENTIAL_FILE):
            return False
    elif create:
        try:
            fd = os.open(CREDENTIAL_FILE, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
            os.close(fd)
        except OSError:
            return False
    else:
        return True
    try:
        os.chmod(CREDENTIAL_FILE, 0o600)
    except OSError:
        return False
    return True


def _credential_store(operation, fields):
    # Delegate encoding and matching to Git's standard credential-store format.
    payload = _credential_protocol(fields)
    if payload is None:
        return False, ""
    try:
        completed = subprocess.run(
            ["git", "credential-store", "--file", CREDENTIAL_FILE, operation],
            input=payload,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=10,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return False, ""
    try:
        output = completed.stdout.decode("utf-8", "replace")
    except AttributeError:
        output = ""
    if completed.returncode != 0:
        return False, output
    if operation in ("store", "erase") and not _prepare_credential_file(False):
        return False, output
    return True, output


def _parse_protocol_output(output):
    fields = {}
    for line in output.splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        fields[key] = value
    return fields


def _read_local_credential(request):
    if not _prepare_credential_file(False):
        return False, {}
    ok, output = _credential_store("get", request)
    if not ok:
        return False, {}
    return True, _parse_protocol_output(output)


def _is_initialization_target(request):
    # During clone, only the configured Gitee host may trigger a service GET.
    if HELPER_PHASE != "init":
        return True
    prefix = os.environ.get("TESTAGENT_CLOUD_GITEE_URL", "")
    user = os.environ.get("TESTAGENT_CLOUD_GITEE_USER", "")
    repository = os.environ.get("TESTAGENT_CLOUD_GITEE_REPOSITORY", "")
    if not prefix or not user or not repository:
        return False
    try:
        target = urlsplit(prefix)
        _ = target.port
        target_hostname = target.hostname
    except ValueError:
        return False
    protocol = request.get("protocol", "").lower()
    host = request.get("host", "")
    if (
        target.scheme not in ("http", "https")
        or target.username is not None
        or target.password is not None
        or target.query
        or target.fragment
        or protocol != target.scheme
    ):
        return False
    if not target_hostname or not host or not _safe_protocol_value(host):
        return False
    try:
        requested = urlsplit(protocol + "://" + host)
        _ = requested.port
        requested_hostname = requested.hostname
    except ValueError:
        return False
    if (
        requested.path
        or requested.query
        or requested.fragment
        or requested.username is not None
        or requested.password is not None
    ):
        return False
    target_port = target.port or (443 if target.scheme == "https" else 80)
    requested_port = requested.port or (443 if protocol == "https" else 80)
    if (
        not requested_hostname
        or requested_hostname.lower().rstrip(".") != target_hostname.lower().rstrip(".")
        or requested_port != target_port
    ):
        return False
    request_path = request.get("path", "")
    if request_path:
        target_path = target.path.rstrip("/") + "/" + user + "/" + repository + ".git"
        if request_path != target_path and not request_path.startswith(target_path + "/"):
            return False
    return True


def _read_extra():
    if not os.path.lexists(EXTRA_FILE):
        return {}
    if not _regular_file(EXTRA_FILE):
        raise OSError("invalid extra file")
    values = {}
    with open(EXTRA_FILE, "r", encoding="utf-8", errors="replace") as stream:
        for line in stream:
            line = line.rstrip("\r\n")
            if "=" not in line:
                continue
            key, value = line.split("=", 1)
            if key in EXTRA_KEYS and _safe_identity_value(value):
                if key == "type" and value != "password":
                    continue
                values[key] = value
    return values


def _write_extra(values):
    # Replace metadata atomically; the file never contains the password field.
    clean_values = []
    for key in EXTRA_KEYS:
        if key not in values:
            continue
        value = values[key]
        if not isinstance(value, str):
            return False
        if not _safe_identity_value(value):
            return False
        # An empty email is valid; type and username remain meaningful only when set.
        if not value and key != "git_email":
            continue
        clean_values.append((key, value))
    directory = str(Path(EXTRA_FILE).parent)
    temporary_path = None
    file_descriptor = None
    try:
        file_descriptor, temporary_path = tempfile.mkstemp(
            prefix=".git-extra.", dir=directory
        )
        os.fchmod(file_descriptor, 0o600)
        with os.fdopen(file_descriptor, "w", encoding="utf-8", newline="\n") as stream:
            file_descriptor = None
            for key, value in clean_values:
                stream.write(key + "=" + value + "\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary_path, EXTRA_FILE)
        temporary_path = None
        os.chmod(EXTRA_FILE, 0o600)
        return True
    except (OSError, ValueError):
        return False
    finally:
        if file_descriptor is not None:
            try:
                os.close(file_descriptor)
            except OSError:
                pass
        if temporary_path is not None:
            try:
                os.unlink(temporary_path)
            except OSError:
                pass


def _git_config_value(key):
    try:
        completed = subprocess.run(
            ["git", "config", "--global", "--get", key],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=10,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return ""
    if completed.returncode != 0:
        return ""
    try:
        value = completed.stdout.decode("utf-8", "replace").rstrip("\r\n")
    except AttributeError:
        return ""
    return value if _safe_identity_value(value) else ""


def _apply_initial_identity():
    if HELPER_PHASE != "init":
        return True
    try:
        extra = _read_extra()
    except OSError:
        return True
    username = extra.get("git_username", "")
    email = extra.get("git_email", "")
    if not username:
        return True
    try:
        for key, value in (("user.name", username), ("user.email", email)):
            completed = subprocess.run(
                ["git", "config", "--global", key, value],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=10,
                check=False,
            )
            if completed.returncode != 0:
                return False
    except (OSError, subprocess.SubprocessError):
        return False
    return True


def _output_credential(request, stored):
    password = stored.get("password", "")
    if not _safe_protocol_value(password) or not password:
        return False
    try:
        extra = _read_extra()
    except OSError:
        extra = {}
    username = stored.get("username") or extra.get("git_username") or request.get("username", "")
    if username and not _safe_protocol_value(username):
        return False
    if username:
        sys.stdout.write("username=" + username + "\n")
    sys.stdout.write("password=" + password + "\n\n")
    sys.stdout.flush()
    return True


def _valid_api_base(value):
    if not isinstance(value, str) or not value or value != value.strip():
        return False
    if any(ord(character) < 32 or ord(character) == 127 for character in value):
        return False
    try:
        parsed = urlsplit(value)
        _ = parsed.port
        hostname = parsed.hostname
    except ValueError:
        return False
    return (
        parsed.scheme in ("http", "https")
        and bool(parsed.netloc)
        and bool(hostname)
        and parsed.username is None
        and parsed.password is None
        and not parsed.query
        and not parsed.fragment
    )


def _api_context(action):
    service_url = os.environ.get("TESTAGENT_CLOUD_SERVICE_URL", "")
    service_id = os.environ.get("TESTAGENT_CLOUD_SERVICE_ID", "")
    operator_user = os.environ.get("TESTAGENT_CLOUD_SERVICE_USER", "")
    if not _valid_api_base(service_url):
        raise ValueError("invalid service url")
    if not service_id or not _safe_identity_value(service_id):
        raise ValueError("invalid service id")
    if not operator_user or not _safe_identity_value(operator_user):
        raise ValueError("invalid operator")
    url = service_url.rstrip("/") + "/git/" + quote(service_id, safe="") + "/" + action
    return url, operator_user


def _request(method, action, payload=None, read_body=True):
    # Centralize API headers, bounded response reads, and redirect prevention.
    try:
        url, operator_user = _api_context(action)
        request_timeout = HTTP_TIMEOUT_SECONDS
        deadline_value = os.environ.get("GIT_INIT_DEADLINE", "")
        if deadline_value:
            try:
                remaining = float(deadline_value) - time.time()
            except ValueError:
                return None, b""
            if remaining <= 0:
                return None, b""
            request_timeout = min(request_timeout, remaining)
        data = None
        headers = {
            "Accept": "application/json",
            "X-Operator-User-ID": operator_user,
        }
        if payload is not None:
            data = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
            headers["Content-Type"] = "application/json"
        request = Request(url, data=data, headers=headers, method=method)
        with HTTP_CLIENT.open(request, timeout=request_timeout) as response:
            status = response.getcode()
            body = response.read(MAX_RESPONSE_BYTES) if read_body else b""
            _progress("api action=" + action + " http_status=" + str(status))
            return status, body
    except HTTPError as error:
        body = b""
        if read_body:
            try:
                body = error.read(MAX_RESPONSE_BYTES)
            except OSError:
                body = b""
        _progress("api action=" + action + " http_status=" + str(error.code))
        return error.code, body
    except (OSError, URLError, TimeoutError, ValueError):
        _progress("api action=" + action + " transport_failed")
        return None, b""


def _json_object(body):
    try:
        value = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError, TypeError):
        return None
    return value if isinstance(value, dict) else None


def _report_status(status):
    # A report is accepted only when the server echoes the requested state.
    if status not in REPORT_STATES:
        return False
    response_status, body = _request(
        "POST", "report", {"git_status": status}, read_body=True
    )
    if response_status != 200:
        return False
    response = _json_object(body)
    return response is not None and response.get("git_status") == status


def _best_effort_report(status):
    _report_status(status)


def _credential_from_response(body):
    # Validate the complete API credential before persisting any part of it.
    response = _json_object(body)
    if response is None:
        return None
    credential_type = response.get("type")
    username = response.get("git_username")
    email = response.get("git_email")
    password = response.get("git_password")
    if credential_type != "password":
        return None
    if not isinstance(username, str) or not isinstance(email, str) or not isinstance(password, str):
        return None
    username = username.strip()
    email = email.strip()
    if not username or not password or not password.strip():
        return None
    if response.get("git_email") and not email:
        return None
    if not _safe_identity_value(username) or not _safe_identity_value(email):
        return None
    if not _safe_protocol_value(password):
        return None
    return {
        "type": "password",
        "git_username": username,
        "git_email": email,
        "git_password": password,
    }


def _save_api_credential(request, credential):
    local_request = dict(request)
    local_request["username"] = credential["git_username"]
    local_request["password"] = credential["git_password"]
    if not _prepare_credential_file(True):
        return False
    ok, _ = _credential_store("store", local_request)
    if not ok:
        return False
    return _write_extra(credential)


def _handle_init_get(request):
    # Initialization is file-first; the service is consulted only for a target miss.
    local_ok, stored = _read_local_credential(request)
    if not local_ok:
        _error("local")
        return 1
    if stored.get("password"):
        if not _apply_initial_identity():
            _error("local")
            return 1
        if _output_credential(request, stored):
            return 0
        _error("local")
        return 1
    if not _is_initialization_target(request):
        return 0

    deadline = time.monotonic() + INIT_TIMEOUT_SECONDS
    deadline_value = os.environ.get("GIT_INIT_DEADLINE", "")
    if deadline_value:
        try:
            remaining = float(deadline_value) - time.time()
        except ValueError:
            remaining = 0
        deadline = min(deadline, time.monotonic() + max(0, remaining))
    attempts = 0
    while True:
        if time.monotonic() >= deadline:
            _best_effort_report("failed_timeout")
            _error("timeout")
            return 1
        if attempts >= MAX_ATTEMPTS:
            _best_effort_report("failed_max_attempts")
            _error("max_attempts")
            return 1
        attempts += 1
        response_status, body = _request("GET", "credential", read_body=True)
        if response_status == 200:
            credential = _credential_from_response(body)
            if credential is None:
                _best_effort_report("failed_unexpected_state")
                _error("invalid_credential")
                return 1
            if not _save_api_credential(request, credential):
                _best_effort_report("failed_container")
                _error("local")
                return 1
            local_ok, stored = _read_local_credential(request)
            if not local_ok or not _apply_initial_identity() or not _output_credential(request, stored):
                _best_effort_report("failed_container")
                _error("local")
                return 1
            return 0
        if response_status == 409:
            response = _json_object(body)
            state = response.get("git_status") if response is not None else None
            if not isinstance(state, str):
                state = None
            if state in WAITING_STATES:
                if not _report_status(state):
                    _error("service")
                    return 1
                if attempts >= MAX_ATTEMPTS:
                    _best_effort_report("failed_max_attempts")
                    _error("max_attempts")
                    return 1
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    _best_effort_report("failed_timeout")
                    _error("timeout")
                    return 1
                time.sleep(min(POLL_INTERVAL_SECONDS, remaining))
                continue
            if state in FINAL_FAILURE_STATES or state == "initialized":
                _error("remote_failed")
                return 1
            _best_effort_report("failed_unexpected_state")
            _error("unexpected_state")
            return 1
        if response_status == 401:
            _best_effort_report("failed_service")
            _error("unauthorized")
            return 1
        if response_status == 404:
            _best_effort_report("failed_service")
            _error("not_found")
            return 1
        _best_effort_report("failed_service")
        _error("service")
        return 1


def _handle_runtime_get(request):
    # Runtime get must never re-enter the initialization API polling state machine.
    local_ok, stored = _read_local_credential(request)
    if not local_ok:
        _error("local")
        return 1
    if not stored.get("password"):
        _progress("runtime credential miss; returning control to Git")
        return 0
    if _output_credential(request, stored):
        return 0
    _error("local")
    return 1


def _handle_store(request):
    # Local persistence is mandatory; runtime service synchronization is delegated to the CLI.
    password = request.get("password", "")
    if not password:
        return 0
    if not _safe_protocol_value(password):
        _error("invalid_credential")
        return 0
    try:
        extra = _read_extra()
    except OSError:
        extra = {}
    username = (
        request.get("username", "")
        or request.get("git_username", "")
        or _git_config_value("user.name")
        or extra.get("git_username", "")
    )
    email = (
        request.get("git_email", "")
        or _git_config_value("user.email")
        or extra.get("git_email", "")
    )
    local_request = dict(request)
    if username:
        local_request["username"] = username
    else:
        local_request.pop("username", None)
    local_request["password"] = password
    if not _prepare_credential_file(True):
        _error("local")
        return 1
    ok, _ = _credential_store("store", local_request)
    if not ok:
        _error("local")
        return 1
    if not _write_extra(
        {"type": "password", "git_username": username, "git_email": email}
    ):
        _error("local")
        return 1
    if HELPER_PHASE != "runtime":
        return 0

    # 运行期不在 credential helper 内读取终端；用户需要显式执行上传命令。
    _progress("runtime local credential store complete")
    print(
        "\033[1;33m[TS Code] 码云凭证已保存至本地，并且将随着云端服务的销毁而删除，如需持久化使用，请手动执行 upload_to_testagent 命令以加密上传至 TestAgent Cloud 数据库\033[0m",
        file=sys.stderr,
    )
    return 0


def _handle_erase(request):
    # Erase removes only local matching data; init additionally reports rejection.
    if not _prepare_credential_file(True):
        _error("local")
        return 1
    ok, _ = _credential_store("erase", request)
    extra_ok = _write_extra({})
    if not ok or not extra_ok:
        _error("local")
        return 1
    if HELPER_PHASE == "init" and not _report_status("credential_rejected"):
        _error("service")
    return 0


def _main():
    operation = sys.argv[1] if len(sys.argv) > 1 else "get"
    if operation == "--normalize-extra":
        try:
            values = _read_extra()
        except OSError:
            _error("local")
            return 1
        if not _write_extra(values):
            _error("local")
            return 1
        return 0
    if operation == "--report":
        if len(sys.argv) != 3 or not _report_status(sys.argv[2]):
            _error("service")
            return 1
        return 0
    request = _read_request()
    if operation == "get":
        if HELPER_PHASE == "init":
            return _handle_init_get(request)
        return _handle_runtime_get(request)
    if operation == "store":
        return _handle_store(request)
    if operation == "erase":
        return _handle_erase(request)
    _error("unsupported_operation")
    return 1


try:
    sys.exit(_main())
except (KeyboardInterrupt, SystemExit):
    raise
except Exception:
    _error("internal")
    sys.exit(1)
PY
then
    rm -f -- "$GIT_INIT_HELPER_TEMP" || true
    echo "[start] 初始化 helper 生成失败" >&2
    exit 1
fi
if ! sed -i \
    -e "s|__CREDENTIAL_FILE__|$GIT_CREDENTIAL_FILE|g" \
    -e "s|__EXTRA_FILE__|$GIT_EXTRA_FILE|g" \
    -e "s|__INIT_TIMEOUT_SECONDS__|$GIT_INIT_TIMEOUT_SECONDS|g" \
    -e "s|__MAX_ATTEMPTS__|$GIT_MAX_ATTEMPTS|g" \
    -e "s|__POLL_INTERVAL_SECONDS__|$GIT_CREDENTIAL_POLL_INTERVAL_SECONDS|g" \
    "$GIT_INIT_HELPER_TEMP" || ! chmod 0700 "$GIT_INIT_HELPER_TEMP" || ! mv -fT -- "$GIT_INIT_HELPER_TEMP" "$GIT_INIT_HELPER"; then
    rm -f -- "$GIT_INIT_HELPER_TEMP" || true
    echo "[start] 初始化 helper 权限设置失败" >&2
    exit 1
fi
if ! GIT_RUNTIME_HELPER_TEMP=$(mktemp "$GIT_HELPER_DIR/.runtime-credential-helper.XXXXXX"); then
    echo "[start] 运行 helper 临时文件创建失败" >&2
    exit 1
fi
if ! cp "$GIT_INIT_HELPER" "$GIT_RUNTIME_HELPER_TEMP" || ! chmod 0700 "$GIT_RUNTIME_HELPER_TEMP" || ! mv -fT -- "$GIT_RUNTIME_HELPER_TEMP" "$GIT_RUNTIME_HELPER"; then
    rm -f -- "$GIT_RUNTIME_HELPER_TEMP" || true
    echo "[start] 运行 helper 生成失败" >&2
    exit 1
fi
if ! "$GIT_INIT_HELPER" --normalize-extra </dev/null >/dev/null 2>&1; then
    echo "[start] Git 身份文件整理失败" >&2
    exit 1
fi
echo "[start] Git helper 和本地凭证文件准备完成"

# 初始化 clone 前只启用初始化 helper，避免运行期询问逻辑提前触发。
# 先清除已有全局 helper，确保 Git 不会并行调用其他凭证来源。
git config --global --unset-all credential.helper >/dev/null 2>&1 || true
if ! git config --global credential.helper "$GIT_INIT_HELPER" >/dev/null 2>&1; then
    echo "[start] 初始化 helper 全局配置失败" >&2
    exit 1
fi
echo "[start] 初始化 credential helper 已启用"

if ! "$GIT_INIT_HELPER" --report starting </dev/null >/dev/null 2>&1; then
    echo "[start] Git starting 状态上报失败" >&2
    "$GIT_INIT_HELPER" --report failed_service </dev/null >/dev/null 2>&1 || true
    exit 1
fi
echo "[start] Git 状态 starting 已上报"

# Gitee 三项必须整体为空或整体存在；分支只在仓库配置完整时生效。
GITEE_URL="${TESTAGENT_CLOUD_GITEE_URL:-}"
GITEE_USER="${TESTAGENT_CLOUD_GITEE_USER:-}"
GITEE_REPOSITORY="${TESTAGENT_CLOUD_GITEE_REPOSITORY:-}"
GITEE_BRANCH="${TESTAGENT_CLOUD_GITEE_BRANCH:-}"

if [ -z "$GITEE_URL" ] && [ -z "$GITEE_USER" ] && [ -z "$GITEE_REPOSITORY" ]; then
    GIT_URL=""
    echo "[start] 未配置码云地址，跳过 Git clone 和凭证获取"
else
    if [ -z "$GITEE_URL" ] || [ -z "$GITEE_USER" ] || [ -z "$GITEE_REPOSITORY" ]; then
        echo "[start] 码云地址配置不完整" >&2
        "$GIT_INIT_HELPER" --report failed_initialize </dev/null >/dev/null 2>&1 || true
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
# `git@host:` is SSH's scp-like Git syntax, so preserve the prefix and append directly.
if prefix.startswith("git@"):
    if not valid_scp_prefix(prefix):
        raise SystemExit(1)
    print(prefix + user + "/" + repository + ".git")
else:
    # http 和 https 都使用 Git 的 HTTP credential 流程；git 仅表示直连协议。
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
        "$GIT_INIT_HELPER" --report failed_initialize </dev/null >/dev/null 2>&1 || true
        exit 1
    fi
    echo "[start] 码云配置和码云地址校验通过"
fi

if [ -z "$GIT_URL" ]; then
    # 没有仓库配置时跳过 clone 和凭证 API，直接完成初始化状态上报。
    if ! git config --global --unset-all credential.helper >/dev/null 2>&1; then
        :
    fi
    if ! git config --global credential.helper "$GIT_RUNTIME_HELPER" >/dev/null 2>&1; then
        echo "[start] 运行 helper 全局配置失败" >&2
        "$GIT_INIT_HELPER" --report failed_initialize </dev/null >/dev/null 2>&1 || true
        exit 1
    fi
    if ! "$GIT_INIT_HELPER" --report initialized </dev/null >/dev/null 2>&1; then
        echo "[start] Git initialized 状态上报失败" >&2
        "$GIT_INIT_HELPER" --report failed_initialize </dev/null >/dev/null 2>&1 || true
        exit 1
    fi
    echo "[start] Git 状态 initialized 已上报"
else
    # 完整仓库配置才允许接管 /app，并在 clone 前上报 processing。
    if [ ! -d "$GIT_APP_DIR" ]; then
        echo "[start] /app 不是目录" >&2
        "$GIT_INIT_HELPER" --report failed_container </dev/null >/dev/null 2>&1 || true
        exit 1
    fi
    if ! cd "$GIT_APP_DIR"; then
        echo "[start] 无法进入 /app" >&2
        "$GIT_INIT_HELPER" --report failed_container </dev/null >/dev/null 2>&1 || true
        exit 1
    fi
    if ! GIT_APP_BASELINE=$(find "$GIT_APP_DIR" -mindepth 1 -maxdepth 1 -print); then
        echo "[start] /app 内容检查失败" >&2
        "$GIT_INIT_HELPER" --report failed_container </dev/null >/dev/null 2>&1 || true
        exit 1
    fi
    if [ -n "$GIT_APP_BASELINE" ]; then
        echo "[start] /app 非空，停止 Git 初始化" >&2
        "$GIT_INIT_HELPER" --report failed_initialize </dev/null >/dev/null 2>&1 || true
        exit 1
    fi
    echo "[start] /app 已确认为空"
    if ! "$GIT_INIT_HELPER" --report processing </dev/null >/dev/null 2>&1; then
        echo "[start] Git processing 状态上报失败" >&2
        "$GIT_INIT_HELPER" --report failed_service </dev/null >/dev/null 2>&1 || true
        exit 1
    fi
    echo "[start] Git 状态 processing 已上报"

    if ! GIT_INIT_START_SECONDS=$(date +%s); then
        echo "[start] 初始化计时器不可用" >&2
        "$GIT_INIT_HELPER" --report failed_container </dev/null >/dev/null 2>&1 || true
        exit 1
    fi
    GIT_INIT_DEADLINE=$((GIT_INIT_START_SECONDS + GIT_INIT_TIMEOUT_SECONDS))
    export GIT_INIT_DEADLINE
    GIT_ATTEMPT=1
    GIT_CLONE_SUCCESS=0
    GIT_ENV_DUMPED=0
    while [ "$GIT_ATTEMPT" -le "$GIT_MAX_ATTEMPTS" ]; do
        if ! GIT_NOW_SECONDS=$(date +%s); then
            echo "[start] 初始化计时器不可用" >&2
            "$GIT_INIT_HELPER" --report failed_container </dev/null >/dev/null 2>&1 || true
            exit 1
        fi
        if [ "$GIT_NOW_SECONDS" -ge "$GIT_INIT_DEADLINE" ]; then
            echo "[start] Git 初始化超时" >&2
            "$GIT_INIT_HELPER" --report failed_timeout </dev/null >/dev/null 2>&1 || true
            exit 1
        fi
        GIT_REMAINING_SECONDS=$((GIT_INIT_DEADLINE - GIT_NOW_SECONDS))
        if [ "$GIT_REMAINING_SECONDS" -lt 1 ]; then
            echo "[start] Git 初始化超时" >&2
            "$GIT_INIT_HELPER" --report failed_timeout </dev/null >/dev/null 2>&1 || true
            exit 1
        fi

        # 暂存输出供错误分类；失败后输出限长、脱敏的诊断，避免只剩退出码。
        GIT_CLONE_STATUS=0
        GIT_CLONE_OK=0
        echo "[start] Git clone 第 $GIT_ATTEMPT/$GIT_MAX_ATTEMPTS 次尝试"
        if [ -n "$GITEE_BRANCH" ]; then
            if GIT_CLONE_OUTPUT=$(GIT_TERMINAL_PROMPT=0 GIT_ASKPASS= SSH_ASKPASS= GIT_CONFIG_NOSYSTEM=1 LC_ALL=C timeout --signal=TERM "$GIT_REMAINING_SECONDS" git clone --branch "$GITEE_BRANCH" "$GIT_URL" . 2>&1); then
                GIT_CLONE_OK=1
            else
                GIT_CLONE_STATUS=$?
            fi
        else
            if GIT_CLONE_OUTPUT=$(GIT_TERMINAL_PROMPT=0 GIT_ASKPASS= SSH_ASKPASS= GIT_CONFIG_NOSYSTEM=1 LC_ALL=C timeout --signal=TERM "$GIT_REMAINING_SECONDS" git clone "$GIT_URL" . 2>&1); then
                GIT_CLONE_OK=1
            else
                GIT_CLONE_STATUS=$?
            fi
        fi
        if [ "$GIT_CLONE_OK" -eq 1 ]; then
            GIT_CLONE_SUCCESS=1
            unset GIT_CLONE_OUTPUT
            echo "[start] Git clone 完成"
            break
        fi
        echo "[start] Git clone 失败：attempt=$GIT_ATTEMPT/$GIT_MAX_ATTEMPTS exit=$GIT_CLONE_STATUS" >&2
        if [ "$GIT_ENV_DUMPED" -eq 0 ]; then
            echo "[start] Git clone 失败时的环境变量" >&2
            if ! env | LC_ALL=C sort | LC_ALL=C awk -F= '
                {
                    variable_name = tolower($1)
                    if (variable_name ~ /password/) {
                        print "[start] 环境变量: " $1 "=<redacted>"
                    } else {
                        print "[start] 环境变量: " $0
                    }
                }' >&2; then
                echo "[start] Git clone 失败时环境变量输出失败" >&2
            fi
            echo "[start] Git clone 失败时环境变量结束" >&2
            GIT_ENV_DUMPED=1
        fi
        if [ -n "$GIT_CLONE_OUTPUT" ]; then
            echo "[start] Git clone 详细诊断开始 (地址、凭证和敏感字段已脱敏)" >&2
            printf '%s\n' "$GIT_CLONE_OUTPUT" |
                LC_ALL=C tr -d '\000-\010\013\014\015\016-\037\177' |
                LC_ALL=C sed -E \
                    -e 's#(password|token|secret|authorization)[[:space:]]*[=:][[:space:]]*[^[:space:]]*#\1=<redacted>#Ig' |
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

        # 只清理已确认属于本次 clone 的内容；基线或 Git 归属异常时拒绝删除。
        # Git 状态必须没有未跟踪项，空目录也必须不存在，才能执行删除。
        if [ -n "$GIT_APP_BASELINE" ]; then
            echo "[start] 无法确认失败 clone 的文件归属" >&2
            unset GIT_CLONE_OUTPUT
            "$GIT_INIT_HELPER" --report failed_initialize </dev/null >/dev/null 2>&1 || true
            exit 1
        fi
        if ! GIT_APP_REMAINDER=$(find "$GIT_APP_DIR" -mindepth 1 -maxdepth 1 -print -quit); then
            echo "[start] 失败 clone 清理校验失败" >&2
            unset GIT_CLONE_OUTPUT
            "$GIT_INIT_HELPER" --report failed_container </dev/null >/dev/null 2>&1 || true
            exit 1
        fi
        if [ -n "$GIT_APP_REMAINDER" ]; then
            if [ -L "$GIT_APP_DIR/.git" ] || { [ ! -d "$GIT_APP_DIR/.git" ] && [ ! -f "$GIT_APP_DIR/.git" ]; }; then
                echo "[start] 无法确认失败 clone 的文件归属" >&2
                unset GIT_CLONE_OUTPUT
                "$GIT_INIT_HELPER" --report failed_container </dev/null >/dev/null 2>&1 || true
                exit 1
            fi
            if ! GIT_APP_GIT_STATUS=$(git -C "$GIT_APP_DIR" status --porcelain=v1 --untracked-files=all --ignored=matching 2>/dev/null); then
                echo "[start] 无法确认失败 clone 的文件归属" >&2
                unset GIT_CLONE_OUTPUT
                "$GIT_INIT_HELPER" --report failed_container </dev/null >/dev/null 2>&1 || true
                exit 1
            fi
            if [ -n "$GIT_APP_GIT_STATUS" ]; then
                echo "[start] 失败 clone 包含未确认内容" >&2
                unset GIT_CLONE_OUTPUT GIT_APP_GIT_STATUS
                "$GIT_INIT_HELPER" --report failed_initialize </dev/null >/dev/null 2>&1 || true
                exit 1
            fi
            if ! GIT_APP_EMPTY_DIR=$(find "$GIT_APP_DIR" -mindepth 1 -type d -empty ! -path "$GIT_APP_DIR/.git" ! -path "$GIT_APP_DIR/.git/*" -print -quit); then
                echo "[start] 失败 clone 清理校验失败" >&2
                unset GIT_CLONE_OUTPUT GIT_APP_GIT_STATUS
                "$GIT_INIT_HELPER" --report failed_container </dev/null >/dev/null 2>&1 || true
                exit 1
            fi
            if [ -n "$GIT_APP_EMPTY_DIR" ]; then
                echo "[start] 失败 clone 包含未确认目录" >&2
                unset GIT_CLONE_OUTPUT GIT_APP_GIT_STATUS GIT_APP_EMPTY_DIR
                "$GIT_INIT_HELPER" --report failed_initialize </dev/null >/dev/null 2>&1 || true
                exit 1
            fi
            while IFS= read -r -d '' GIT_APP_ENTRY; do
                if ! rm -rf -- "$GIT_APP_ENTRY"; then
                    echo "[start] 失败 clone 清理失败" >&2
                    unset GIT_CLONE_OUTPUT GIT_APP_GIT_STATUS
                    "$GIT_INIT_HELPER" --report failed_container </dev/null >/dev/null 2>&1 || true
                    exit 1
                fi
            done < <(find "$GIT_APP_DIR" -mindepth 1 -maxdepth 1 -print0)
        fi

        if [[ "$GIT_URL" == git://* || "$GIT_URL" == git@*:* ]]; then
            unset GIT_CLONE_OUTPUT
            echo "[start] 非 HTTP Git clone 失败，停止重试" >&2
            "$GIT_INIT_HELPER" --report failed_git </dev/null >/dev/null 2>&1 || true
            exit 1
        fi
        GIT_CLONE_OUTPUT_LOWER="${GIT_CLONE_OUTPUT,,}"
        if [ "$GIT_CLONE_STATUS" -eq 124 ] || [[ "$GIT_CLONE_OUTPUT_LOWER" == *"credential helper error: timeout"* ]] || [[ "$GIT_CLONE_OUTPUT_LOWER" == *"timed out"* ]]; then
            unset GIT_CLONE_OUTPUT GIT_CLONE_OUTPUT_LOWER
            echo "[start] Git clone 初始化超时" >&2
            "$GIT_INIT_HELPER" --report failed_timeout </dev/null >/dev/null 2>&1 || true
            exit 1
        fi
        if [[ "$GIT_CLONE_OUTPUT_LOWER" == *"credential helper error: max_attempts"* ]]; then
            unset GIT_CLONE_OUTPUT GIT_CLONE_OUTPUT_LOWER
            echo "[start] 凭证获取达到重试上限" >&2
            "$GIT_INIT_HELPER" --report failed_max_attempts </dev/null >/dev/null 2>&1 || true
            exit 1
        fi
        if [[ "$GIT_CLONE_OUTPUT_LOWER" == *"credential helper error: service"* ]] || [[ "$GIT_CLONE_OUTPUT_LOWER" == *"credential helper error: unauthorized"* ]] || [[ "$GIT_CLONE_OUTPUT_LOWER" == *"credential helper error: not_found"* ]]; then
            unset GIT_CLONE_OUTPUT GIT_CLONE_OUTPUT_LOWER
            echo "[start] 码云凭证服务处理失败" >&2
            "$GIT_INIT_HELPER" --report failed_service </dev/null >/dev/null 2>&1 || true
            exit 1
        fi
        if [[ "$GIT_CLONE_OUTPUT_LOWER" == *"credential helper error: unexpected_state"* ]] || [[ "$GIT_CLONE_OUTPUT_LOWER" == *"credential helper error: invalid_credential"* ]]; then
            unset GIT_CLONE_OUTPUT GIT_CLONE_OUTPUT_LOWER
            echo "[start] 码云凭证状态异常" >&2
            "$GIT_INIT_HELPER" --report failed_unexpected_state </dev/null >/dev/null 2>&1 || true
            exit 1
        fi
        if [[ "$GIT_CLONE_OUTPUT_LOWER" == *"credential helper error: local"* ]] || [[ "$GIT_CLONE_OUTPUT_LOWER" == *"credential helper error: internal"* ]]; then
            unset GIT_CLONE_OUTPUT GIT_CLONE_OUTPUT_LOWER
            echo "[start] 码云本地凭证处理失败" >&2
            "$GIT_INIT_HELPER" --report failed_container </dev/null >/dev/null 2>&1 || true
            exit 1
        fi
        if [[ "$GIT_CLONE_OUTPUT_LOWER" == *"credential helper error: remote_failed"* ]]; then
            unset GIT_CLONE_OUTPUT GIT_CLONE_OUTPUT_LOWER
            echo "[start] 码云服务已返回失败终态" >&2
            exit 1
        fi
        if [[ "$GIT_CLONE_OUTPUT_LOWER" == *"requested url returned error: 400"* ]] \
            || [[ "$GIT_CLONE_OUTPUT_LOWER" == *"requested url returned error: 404"* ]] \
            || [[ "$GIT_CLONE_OUTPUT_LOWER" == *"repository not found"* ]] \
            || [[ "$GIT_CLONE_OUTPUT_LOWER" == *"repository"* && "$GIT_CLONE_OUTPUT_LOWER" == *"not found"* ]] \
            || [[ "$GIT_CLONE_OUTPUT_LOWER" == *"couldn't find remote ref"* ]] \
            || [[ "$GIT_CLONE_OUTPUT_LOWER" == *"does not appear to be a git repository"* ]]; then
            unset GIT_CLONE_OUTPUT GIT_CLONE_OUTPUT_LOWER
            echo "[start] Git clone 返回不可恢复错误" >&2
            "$GIT_INIT_HELPER" --report failed_git </dev/null >/dev/null 2>&1 || true
            exit 1
        fi

        if [[ "$GIT_CLONE_OUTPUT_LOWER" != *"authentication failed"* ]] \
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
            "$GIT_INIT_HELPER" --report failed_git </dev/null >/dev/null 2>&1 || true
            exit 1
        fi
        unset GIT_CLONE_OUTPUT GIT_CLONE_OUTPUT_LOWER
        if [ "$GIT_ATTEMPT" -ge "$GIT_MAX_ATTEMPTS" ]; then
            echo "[start] Git clone 达到重试上限" >&2
            "$GIT_INIT_HELPER" --report failed_max_attempts </dev/null >/dev/null 2>&1 || true
            exit 1
        fi
        if ! GIT_NOW_SECONDS=$(date +%s); then
            echo "[start] 初始化计时器不可用" >&2
            "$GIT_INIT_HELPER" --report failed_container </dev/null >/dev/null 2>&1 || true
            exit 1
        fi
        GIT_SLEEP_SECONDS="$GIT_RETRY_DELAY_SECONDS"
        GIT_REMAINING_SECONDS=$((GIT_INIT_DEADLINE - GIT_NOW_SECONDS))
        if [ "$GIT_REMAINING_SECONDS" -le 0 ]; then
            "$GIT_INIT_HELPER" --report failed_timeout </dev/null >/dev/null 2>&1 || true
            exit 1
        fi
        if [ "$GIT_SLEEP_SECONDS" -gt "$GIT_REMAINING_SECONDS" ]; then
            GIT_SLEEP_SECONDS="$GIT_REMAINING_SECONDS"
        fi
        echo "[start] Git clone 将在 ${GIT_SLEEP_SECONDS} 秒后重试"
        if ! sleep "$GIT_SLEEP_SECONDS"; then
            echo "[start] Git 重试等待失败" >&2
            "$GIT_INIT_HELPER" --report failed_container </dev/null >/dev/null 2>&1 || true
            exit 1
        fi
        GIT_ATTEMPT=$((GIT_ATTEMPT + 1))
    done
    if [ "$GIT_CLONE_SUCCESS" -ne 1 ]; then
        "$GIT_INIT_HELPER" --report failed_max_attempts </dev/null >/dev/null 2>&1 || true
        exit 1
    fi

    # clone 成功后才从本地元数据写入真实 Git 身份，禁止生成占位身份。
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
            "$GIT_INIT_HELPER" --report failed_container </dev/null >/dev/null 2>&1 || true
            exit 1
        fi
    fi
    if [ -n "$GIT_USERNAME" ]; then
        if ! git config --global user.name "$GIT_USERNAME" >/dev/null 2>&1 || ! git config --global user.email "$GIT_EMAIL" >/dev/null 2>&1; then
            echo "[start] 码云用户身份配置失败" >&2
            "$GIT_INIT_HELPER" --report failed_initialize </dev/null >/dev/null 2>&1 || true
            exit 1
        fi
        echo "[start] 码云用户身份配置完成"
    else
        echo "[start] 未找到码云用户身份元数据，保持现有身份配置"
    fi
    if ! chmod 0600 "$GIT_CREDENTIAL_FILE" "$GIT_EXTRA_FILE"; then
        echo "[start] 码云本地文件权限校验失败" >&2
        "$GIT_INIT_HELPER" --report failed_container </dev/null >/dev/null 2>&1 || true
        exit 1
    fi
    if [ "$(stat -c '%a' "$GIT_CREDENTIAL_FILE" 2>/dev/null)" != "600" ] || [ "$(stat -c '%a' "$GIT_EXTRA_FILE" 2>/dev/null)" != "600" ]; then
        echo "[start] 码云本地文件权限校验失败" >&2
        "$GIT_INIT_HELPER" --report failed_container </dev/null >/dev/null 2>&1 || true
        exit 1
    fi
    echo "[start] 码云本地凭证文件权限确认完成"
    # 初始化成功门禁：先切换 runtime helper，再确认服务端接受 initialized。
    if ! git config --global --unset-all credential.helper >/dev/null 2>&1; then
        :
    fi
    if ! git config --global credential.helper "$GIT_RUNTIME_HELPER" >/dev/null 2>&1; then
        echo "[start] 运行 helper 全局配置失败" >&2
        "$GIT_INIT_HELPER" --report failed_initialize </dev/null >/dev/null 2>&1 || true
        exit 1
    fi
    echo "[start] 运行期 credential helper 已启用"
    if ! "$GIT_INIT_HELPER" --report initialized </dev/null >/dev/null 2>&1; then
        echo "[start] Git initialized 状态上报失败" >&2
        "$GIT_INIT_HELPER" --report failed_initialize </dev/null >/dev/null 2>&1 || true
        exit 1
    fi
    echo "[start] Git 状态 initialized 已上报"
fi

# initialized 已确认后清理只用于启动的输入变量；服务身份变量继续保留给 runtime helper。
unset TESTAGENT_CLOUD_USER_ID \
    TESTAGENT_CLOUD_GITEE_URL \
    TESTAGENT_CLOUD_GITEE_USER \
    TESTAGENT_CLOUD_GITEE_REPOSITORY \
    TESTAGENT_CLOUD_GITEE_BRANCH \
    TESTAGENT_CLOUD_PIP_URL \
    TESTAGENT_CLOUD_NPM_URL
unset GITEE_URL GITEE_USER GITEE_REPOSITORY GITEE_BRANCH GIT_URL
unset GIT_INIT_DEADLINE
umask "$GIT_OLD_UMASK"
echo "[start] 云端码云初始化流程完成"
else
    echo "[start] TESTAGENT_CLOUD_MODE 非 1，跳过云端码云初始化"
fi

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
