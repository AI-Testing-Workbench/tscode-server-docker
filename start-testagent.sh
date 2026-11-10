#!/usr/bin/env bash

set -Eeuo pipefail
exec 2>&1

log() {
    printf '[start-testagent] %s\n' "$*"
}

fail() {
    log "ERROR: $*" >&2
    exit 1
}

TSCODE_SERVER_ROOT=/root/.tscode-server/bin/tscode
EXTENSIONS_DIR=$TSCODE_SERVER_ROOT/extensions
REGISTRY_NODE=$TSCODE_SERVER_ROOT/node

resolve_extension_dir() {
    [[ -x "$REGISTRY_NODE" ]] || fail "TSCode Node executable not found: $REGISTRY_NODE"

    "$REGISTRY_NODE" - "$EXTENSIONS_DIR" <<'NODE'
const fs = require("node:fs")
const path = require("node:path")
const root = process.argv[2]
const builtin = path.resolve(root, "test-tech.testagent")
const collator = new Intl.Collator("en", { numeric: true })

function validExtension(dir) {
  try {
    const pkg = JSON.parse(fs.readFileSync(path.join(dir, "package.json"), "utf8"))
    return String(pkg.publisher).toLowerCase() === "test-tech" &&
      String(pkg.name).toLowerCase() === "testagent"
  } catch {
    return false
  }
}

let entries = []
try {
  entries = JSON.parse(fs.readFileSync(path.join(root, "extensions.json"), "utf8"))
} catch {}

const candidates = []
for (const entry of entries) {
  if (String(entry.identifier?.id).toLowerCase() !== "test-tech.testagent") continue
  const location = entry.location?.fsPath || entry.location?.path
  if (typeof location !== "string") continue
  const dir = path.resolve(location)
  if (!fs.statSync(dir, { throwIfNoEntry: false })?.isDirectory() || !validExtension(dir)) continue
  candidates.push({
    dir,
    isBuiltin: entry.metadata?.isBuiltin === true,
    source: entry.metadata?.source,
    installedAt: Number(entry.metadata?.installedTimestamp || 0),
    version: String(entry.version || "0"),
  })
}

const userInstall = candidates.filter((item) =>
  item.isBuiltin === false || (item.source === "vsix" && path.resolve(item.dir) !== builtin),
)
const pool = userInstall.length ? userInstall : candidates
pool.sort((a, b) => b.installedAt - a.installedAt || collator.compare(a.version, b.version))

let selected = pool[0]?.dir
let source = userInstall.length ? "registered user install" : "registered extension"
if (!selected && validExtension(builtin)) {
  selected = builtin
  source = "bundled fallback"
}
if (!selected) {
  process.stderr.write(`No registered or bundled TestAgent extension under ${root}\n`)
  process.exit(1)
}

process.stdout.write(`${selected}\t${source}`)
NODE
}

inject_cli_environment() {
    local bin_dir=$1
    local profile_file=/etc/profile.d/testagent-env.sh
    local profile_dir temporary

    if [[ "$bin_dir" == *'"'* || "$bin_dir" == *$'\n'* || "$bin_dir" == *$'\r'* ]]; then
        fail "TestAgent CLI bin 路径包含不支持的字符"
    fi

    export TestAgent=$bin_dir
    case ":${PATH:-}:" in
        *":$TestAgent:"*) ;;
        *) export PATH="$TestAgent${PATH:+:$PATH}" ;;
    esac

    profile_dir=$(dirname -- "$profile_file")
    mkdir -p -- "$profile_dir"
    if [[ -L "$profile_file" || ( -e "$profile_file" && ! -f "$profile_file" ) ]]; then
        fail "TestAgent profile 文件类型非法: $profile_file"
    fi
    temporary=$(mktemp "$profile_dir/.testagent-env.XXXXXX")
    if ! printf '%s\n' \
        '# TestAgent CLI Environment Variable' \
        "export TestAgent=\"$bin_dir\"" \
        'case ":${PATH:-}:" in *":$TestAgent:"*) ;; *) export PATH="$TestAgent${PATH:+:$PATH}" ;; esac' \
        > "$temporary"; then
        rm -f -- "$temporary"
        fail "无法写入 TestAgent profile: $profile_file"
    fi
    chmod 0644 -- "$temporary"
    mv -f -- "$temporary" "$profile_file"
    log "已注入 TestAgent=$bin_dir 并更新 PATH（当前进程及后续登录 shell）"
}

EXTENSION_SELECTION=$(resolve_extension_dir) || fail "无法解析活动的 TestAgent 扩展"
IFS=$'\t' read -r EXTENSION_DIR EXTENSION_SOURCE <<<"$EXTENSION_SELECTION"
[[ -n "$EXTENSION_DIR" ]] || fail "TestAgent 扩展路径为空"
log "选择 TestAgent 扩展: $EXTENSION_DIR ($EXTENSION_SOURCE)"

CLI_BIN_DIR=$EXTENSION_DIR/bin
if [[ -d "$CLI_BIN_DIR" ]]; then
    inject_cli_environment "$CLI_BIN_DIR"
    if [[ ! -x "$CLI_BIN_DIR/testagent" && ! -x "$CLI_BIN_DIR/testagent-node" ]]; then
        log "所选扩展没有可执行的 Linux testagent/testagent-node；PATH 已设置，但命令不可执行"
    fi
else
    log "所选扩展没有 bin 目录，跳过 CLI PATH 注入: $CLI_BIN_DIR"
fi

if [[ "${TESTAGENT_CLOUD_MODE:-}" != "1" && ! -f /etc/tscode-cloud-mode ]]; then
    log "云端模式未启用，跳过 Node 服务启动"
    exit 0
fi
export TESTAGENT_ZH_ANSWER_ENABLED=1
log "ZH answer feature is globally enabled for the TestAgent daemon"

umask 077

DATA_DIR=${XDG_DATA_HOME:-/root/.local/share}/testagent
STATE_FILE=$DATA_DIR/server.json
LOG_FILE=$DATA_DIR/server.log
LOCK_FILE=$DATA_DIR/start.lock

if [[ -L "$DATA_DIR" || ( -e "$DATA_DIR" && ! -d "$DATA_DIR" ) ]]; then
    fail "数据目录类型非法: $DATA_DIR"
fi
mkdir -p -- "$DATA_DIR"
chmod 0700 -- "$DATA_DIR"
for managed_file in "$LOG_FILE" "$LOCK_FILE"; do
    if [[ -L "$managed_file" || ( -e "$managed_file" && ! -f "$managed_file" ) ]]; then
        fail "运行时文件类型非法: $managed_file"
    fi
done
touch -- "$LOG_FILE"
chmod 0600 -- "$LOG_FILE"

command -v flock >/dev/null 2>&1 || fail "未找到 flock，无法保证并发启动安全"
command -v setsid >/dev/null 2>&1 || fail "未找到 setsid，无法启动 detached daemon"
exec 9>"$LOCK_FILE"
flock -x 9

resolve_node() {
    local candidate version major minor major_num minor_num
    local candidates=()

    candidates+=("$TSCODE_SERVER_ROOT/node")
    if command -v node >/dev/null 2>&1; then
        candidates+=("$(command -v node)")
    fi
    candidates+=(/usr/local/bin/node /usr/bin/node)

    for candidate in "${candidates[@]}"; do
        if [[ "$candidate" != */* ]]; then
            candidate=$(command -v -- "$candidate" 2>/dev/null || true)
        fi
        [[ -n "$candidate" && -x "$candidate" ]] || continue
        version=$("$candidate" --version 2>/dev/null || true)
        if [[ ! "$version" =~ ^v?([0-9]+)\.([0-9]+)\.([0-9]+) ]]; then
            continue
        fi
        major=${BASH_REMATCH[1]}
        minor=${BASH_REMATCH[2]}
        while [[ ${#major} -gt 1 && ${major:0:1} == 0 ]]; do major=${major#0}; done
        while [[ ${#minor} -gt 1 && ${minor:0:1} == 0 ]]; do minor=${minor#0}; done
        major_num=$((major))
        minor_num=$((minor))
        if (( major_num > 22 || (major_num == 22 && minor_num >= 5) )); then
            NODE=$candidate
            log "使用 Node.js $version: $NODE"
            return 0
        fi
        log "忽略过旧的 Node.js $version: $candidate"
    done

    fail "未找到 Node.js >= 22.5.0"
}

resolve_node

read_state() {
    "$NODE" - "$STATE_FILE" 2>/dev/null <<'NODE'
const fs = require("node:fs")

try {
  const file = process.argv[2]
  const stat = fs.lstatSync(file)
  if (!stat.isFile() || stat.isSymbolicLink()) process.exit(1)
  const state = JSON.parse(fs.readFileSync(file, "utf8"))
  if (!Number.isInteger(state.port) || state.port < 1 || state.port > 65535) process.exit(1)
  if (typeof state.password !== "string" || !/^[a-f0-9]{64}$/i.test(state.password)) process.exit(1)
  const pid = Number.isSafeInteger(state.pid) && state.pid > 0 ? state.pid : 0
  const version = typeof state.version === "string" && !/[\t\r\n]/.test(state.version) ? state.version : "unknown"
  process.stdout.write(`${state.port}\t${state.password}\t${pid}\t${version}\n`)
} catch {
  process.exitCode = 1
}
NODE
}

probe_server() {
    # These short-lived helper variables are internal arguments, not operator configuration.
    _TA_HELPER_PROBE_PORT=$1 _TA_HELPER_PROBE_PASSWORD=$2 "$NODE" - 2>/dev/null <<'NODE'
const port = Number(process.env._TA_HELPER_PROBE_PORT)
const password = process.env._TA_HELPER_PROBE_PASSWORD
const auth = Buffer.from(`opencode:${password}`).toString("base64")

fetch(`http://127.0.0.1:${port}/global/health`, {
  headers: { Authorization: `Basic ${auth}` },
  signal: AbortSignal.timeout(3000),
}).then((response) => {
  if (!response.ok) process.exitCode = 1
}).catch(() => {
  process.exitCode = 1
})
NODE
}

set_zh_answer_enabled() {
    # Existing daemons cannot inherit this script's startup environment; apply
    # the same process-level toggle used by the VS Code extension.
    _TA_HELPER_PORT=$1 _TA_HELPER_PASSWORD=$2 "$NODE" - <<'NODE'
const port = Number(process.env._TA_HELPER_PORT)
const password = process.env._TA_HELPER_PASSWORD
const auth = Buffer.from(`opencode:${password}`).toString("base64")

fetch(`http://127.0.0.1:${port}/testagent/zh-answer`, {
  method: "POST",
  headers: {
    Authorization: `Basic ${auth}`,
    "Content-Type": "application/json",
  },
  body: JSON.stringify({ enabled: true }),
  signal: AbortSignal.timeout(5000),
}).then(async (response) => {
  if (!response.ok) {
    process.stderr.write(`ZH answer toggle failed: HTTP ${response.status}\n`)
    process.exitCode = 1
  }
  await response.arrayBuffer()
}).catch((error) => {
  process.stderr.write(`ZH answer toggle failed: ${error.message}\n`)
  process.exitCode = 1
})
NODE
}

start_owner_watcher() {
    local daemon_pid=$1
    local owner_pid=

    # The container entrypoint is PID 1. Track it because this script runs before
    # the extension host exists.
    if [[ "$PPID" == "1" ]]; then
        owner_pid=1
    fi
    if [[ ! "$owner_pid" =~ ^[1-9][0-9]*$ ]]; then
        log "未设置容器 owner PID，跳过 owner watcher"
        return 0
    fi
    if [[ ! "$daemon_pid" =~ ^[1-9][0-9]*$ ]]; then
        log "daemon PID 不可用，跳过 owner watcher"
        return 0
    fi

    nohup setsid env -u OPENCODE_SERVER_PASSWORD -u OPENCODE_SERVER_USERNAME "$NODE" -e '
const owner = Number(process.argv[1])
const daemon = Number(process.argv[2])
const alive = (pid) => {
  try { process.kill(pid, 0); return true }
  catch (error) { return !!error && error.code === "EPERM" }
}
const stopDaemon = () => {
  try { process.kill(daemon, "SIGTERM") }
  catch {}
}
const tick = () => {
  if (!alive(owner)) {
    stopDaemon()
    process.exit(0)
  }
  if (!alive(daemon)) process.exit(0)
}
tick()
setInterval(tick, 3000)
' "$owner_pid" "$daemon_pid" 9>&- >/dev/null 2>&1 </dev/null &
    log "已启动 owner watcher: owner=$owner_pid daemon=$daemon_pid"
}

ENTRY=$EXTENSION_DIR/nodejs-server/cli.mjs
PACKAGE_FILE=$EXTENSION_DIR/package.json
[[ -f "$ENTRY" ]] || fail "Node 服务入口不存在: $ENTRY"
VERSION=$("$NODE" -p 'JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8")).version' "$PACKAGE_FILE")
[[ -n "$VERSION" ]] || fail "无法读取 TestAgent 扩展版本: $PACKAGE_FILE"

if [[ -e "$STATE_FILE" || -L "$STATE_FILE" ]]; then
    if EXISTING_STATE=$(read_state); then
        IFS=$'\t' read -r EXISTING_PORT EXISTING_PASSWORD EXISTING_PID EXISTING_VERSION <<<"$EXISTING_STATE"
        if probe_server "$EXISTING_PORT" "$EXISTING_PASSWORD"; then
            set_zh_answer_enabled "$EXISTING_PORT" "$EXISTING_PASSWORD" || \
                fail "已有 Node 服务健康，但无法通过 /testagent/zh-answer 启用 ZH 功能"
            if [[ "$EXISTING_VERSION" != "unknown" && "$EXISTING_VERSION" != "" ]]; then
                if [[ "$VERSION" != "$EXISTING_VERSION" ]]; then
                    log "已有服务版本为 $EXISTING_VERSION，当前扩展版本为 $VERSION；为避免中断任务继续复用"
                fi
            fi
            log "发现健康的 TestAgent Node 服务，复用 PID=$EXISTING_PID PORT=$EXISTING_PORT"
            start_owner_watcher "$EXISTING_PID"
            exit 0
        fi
        log "状态文件中的服务不可达，准备重新启动"
    else
        log "状态文件无效，准备重新启动"
    fi
    rm -f -- "$STATE_FILE"
fi

SPAWN_CWD=/app

PORT=$("$NODE" - <<'NODE'
const net = require("node:net")
const pick = (port, attempt) => {
  const server = net.createServer()
  server.once("error", () => {
    try { server.close() } catch {}
    if (attempt >= 100) {
      process.stderr.write("未找到可用的 TestAgent 云端端口\n")
      process.exit(1)
    }
    pick(port + 1, attempt + 1)
  })
  server.listen(port, "127.0.0.1", () => {
    const address = server.address()
    const selected = typeof address === "object" && address ? address.port : port
    server.close(() => process.stdout.write(String(selected)))
  })
}
pick(4096, 0)
NODE
) || fail "无法分配 TestAgent 云端端口"
PASSWORD=$("$NODE" -p 'require("node:crypto").randomBytes(32).toString("hex")')

export OPENCODE_SERVER_PASSWORD=$PASSWORD
export OPENCODE_SERVER_USERNAME=opencode
export TESTAGENT_SERVER_AUTH_PUBLIC=1
export LANG=${LANG:-en_US.UTF-8}
export LC_ALL=${LC_ALL:-en_US.UTF-8}
export KILO_CLIENT=tscode
export KILOCODE_FEATURE=tscode-extension
export KILO_PLATFORM=tscode
export KILO_APP_NAME=testagent
export KILO_APP_VERSION=$VERSION
export KILO_TELEMETRY_LEVEL=${KILO_TELEMETRY_LEVEL:-off}
export OPENSSL_CONF=${OPENSSL_CONF:-/etc/ssl/tscode-openssl.cnf}
TLS_NODE_PATCH=/usr/local/lib/tscode/tls-legacy-renegotiation.cjs
if [[ -f "$TLS_NODE_PATCH" && " ${NODE_OPTIONS:-} " != *" --require $TLS_NODE_PATCH "* ]]; then
    export NODE_OPTIONS="${NODE_OPTIONS:+$NODE_OPTIONS }--require $TLS_NODE_PATCH"
fi
PRODUCT_FILE=$TSCODE_SERVER_ROOT/product.json
if [[ -f "$PRODUCT_FILE" ]]; then
    KILO_EDITOR_NAME=$("$NODE" -p '(() => { const p = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8")); return p.nameLong || p.nameShort || "tscode-server" })()' "$PRODUCT_FILE")
    KILO_VSCODE_VERSION=$("$NODE" -p 'JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8")).version || "unknown"' "$PRODUCT_FILE")
else
    KILO_EDITOR_NAME=tscode-server
    KILO_VSCODE_VERSION=unknown
fi
export KILO_EDITOR_NAME KILO_VSCODE_VERSION
export KILOCODE_EDITOR_NAME="$KILO_EDITOR_NAME $KILO_VSCODE_VERSION"
if [[ -s /root/.tscode-server/data/machineid ]]; then
    KILO_MACHINE_ID=$(< /root/.tscode-server/data/machineid)
fi
if [[ -n "${KILO_MACHINE_ID:-}" ]]; then
    export KILO_MACHINE_ID
fi

log "扩展目录: $EXTENSION_DIR"
log "启动 Node 服务: version=$VERSION port=$PORT host=0.0.0.0 cwd=$SPAWN_CWD"

stop_server() {
    local pid=$1
    local attempt
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 0
    kill -TERM "$pid" 2>/dev/null || true
    for attempt in {1..10}; do
        kill -0 "$pid" 2>/dev/null || return 0
        sleep 0.5
    done
    kill -KILL "$pid" 2>/dev/null || true
}

SERVER_PID=
SERVER_PERSISTED=0
cleanup_unpersisted_server() {
    local status=$?
    trap - EXIT
    if (( SERVER_PERSISTED == 0 )) && [[ -n "$SERVER_PID" ]]; then
        stop_server "$SERVER_PID"
    fi
    exit "$status"
}
trap cleanup_unpersisted_server EXIT

ORIGINAL_CWD=$PWD
cd -- "$SPAWN_CWD"
nohup setsid "$NODE" --experimental-sqlite "$ENTRY" \
    --port "$PORT" \
    --password "$PASSWORD" \
    --hostname 0.0.0.0 \
    9>&- >>"$LOG_FILE" 2>&1 </dev/null &
SERVER_PID=$!
cd -- "$ORIGINAL_CWD"

deadline=$((SECONDS + 30))
READY=0
while (( SECONDS < deadline )); do
    if probe_server "$PORT" "$PASSWORD"; then
        READY=1
        break
    fi
    sleep 0.5
done

if (( READY == 0 )); then
    log "Node 服务在 30 秒内未通过健康检查；停止 PID=$SERVER_PID"
    log "启动失败，日志末尾如下: $LOG_FILE"
    tail -n 60 "$LOG_FILE" >&2 || true
    exit 1
fi

# Pass state only to this short-lived writer process; these are not startup options.
_TA_HELPER_STATE_FILE=$STATE_FILE \
_TA_HELPER_STATE_PORT=$PORT \
_TA_HELPER_STATE_PASSWORD=$PASSWORD \
_TA_HELPER_STATE_PID=$SERVER_PID \
_TA_HELPER_STATE_VERSION=$VERSION \
"$NODE" - 9>&- <<'NODE'
const fs = require("node:fs")

const destination = process.env._TA_HELPER_STATE_FILE
const temporary = `${destination}.tmp.${process.pid}`
const state = {
  port: Number(process.env._TA_HELPER_STATE_PORT),
  password: process.env._TA_HELPER_STATE_PASSWORD,
  pid: Number(process.env._TA_HELPER_STATE_PID),
  version: process.env._TA_HELPER_STATE_VERSION,
  runtime: "nodejs",
  startedAt: Date.now(),
}

let fd
try {
  fd = fs.openSync(temporary, "wx", 0o600)
  fs.writeFileSync(fd, JSON.stringify(state, null, 2))
  fs.fsyncSync(fd)
  fs.closeSync(fd)
  fd = undefined
  fs.renameSync(temporary, destination)
  fs.chmodSync(destination, 0o600)
} catch (error) {
  if (fd !== undefined) fs.closeSync(fd)
  try { fs.unlinkSync(temporary) } catch {}
  process.stderr.write(`写入 TestAgent 状态文件失败: ${error.message}\n`)
  process.exit(1)
}
NODE
SERVER_PERSISTED=1

start_owner_watcher "$SERVER_PID"
log "TestAgent Node 服务已就绪: PID=$SERVER_PID PORT=$PORT HOST=0.0.0.0"
log "状态文件: $STATE_FILE"
log "服务日志: $LOG_FILE"
