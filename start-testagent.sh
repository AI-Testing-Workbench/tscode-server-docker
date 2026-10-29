#!/bin/sh
set -eu

NODE=/root/.tscode-server/bin/tscode/node
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/testagent"
STATE_FILE=$DATA_DIR/server.json
LOG_FILE=$DATA_DIR/server.log

if [ ! -x "$NODE" ]; then
  printf 'TestAgent Node executable not found: %s\n' "$NODE" >&2
  exit 1
fi

umask 077
mkdir -p "$DATA_DIR"

if "$NODE" - "$STATE_FILE" <<'NODE'
const fs = require("node:fs")

;(async () => {
  const file = process.argv[2]
  const state = JSON.parse(fs.readFileSync(file, "utf8"))
  const auth = Buffer.from(`opencode:${state.password}`).toString("base64")
  const res = await fetch(`http://127.0.0.1:${state.port}/global/health`, {
    headers: { Authorization: `Basic ${auth}` },
    signal: AbortSignal.timeout(3000),
  })
  if (!res.ok) process.exitCode = 1
  else process.stdout.write(`TestAgent cloud server already running: PID ${state.pid}, port ${state.port}\n`)
})().catch(() => {
  process.exitCode = 1
})
NODE
then
  exit 0
fi

rm -f "$STATE_FILE"

EXTENSION_DIR=$("$NODE" -e '
const fs = require("node:fs")
const path = require("node:path")
const root = "/root/.tscode-server/bin/tscode/extensions"
const collator = new Intl.Collator("en", { numeric: true })
const dirs = fs.readdirSync(root).flatMap((name) => {
  const dir = path.join(root, name)
  try {
    const pkg = JSON.parse(fs.readFileSync(path.join(dir, "package.json"), "utf8"))
    if (pkg.publisher?.toLowerCase() !== "test-tech") return []
    if (pkg.name?.toLowerCase() !== "testagent") return []
    if (!fs.existsSync(path.join(dir, "nodejs-server", "cli.mjs"))) return []
    return [{ dir, version: pkg.version }]
  } catch {
    return []
  }
})
dirs.sort((a, b) => collator.compare(a.version, b.version))
if (!dirs.length) {
  process.stderr.write(`TestAgent Node extension not found under ${root}\n`)
  process.exit(1)
}
process.stdout.write(dirs[dirs.length - 1].dir)
')
ENTRY=$EXTENSION_DIR/nodejs-server/cli.mjs
VERSION=$("$NODE" -e 'process.stdout.write(JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8")).version)' "$EXTENSION_DIR/package.json")
if [ ! -f "$ENTRY" ]; then
  printf 'TestAgent Node bundle not found: %s\n' "$ENTRY" >&2
  exit 1
fi

PORT=$("$NODE" -e '
const net = require("node:net")
const pick = (port, attempt) => {
  const srv = net.createServer()
  srv.once("error", () => {
    if (attempt >= 100) {
      process.stderr.write("No free port found for TestAgent cloud server.\n")
      process.exit(1)
    }
    pick(port + 1, attempt + 1)
  })
  srv.listen(port, "127.0.0.1", () => {
    const addr = srv.address()
    srv.close(() => process.stdout.write(String(addr.port)))
  })
}
pick(4096, 0)
')
PASSWORD=$("$NODE" -e 'process.stdout.write(require("node:crypto").randomBytes(32).toString("hex"))')

export OPENCODE_SERVER_PASSWORD="$PASSWORD"
export OPENCODE_SERVER_USERNAME=opencode
if [ "${TESTAGENT_CLOUD_MODE:-}" = 1 ] || [ -f /etc/tscode-cloud-mode ]; then
  export TESTAGENT_SERVER_AUTH_PUBLIC=1
fi
export LANG="${LANG:-en_US.UTF-8}"
export LC_ALL="${LC_ALL:-en_US.UTF-8}"
export KILO_CLIENT=tscode
export KILOCODE_FEATURE=tscode-extension
export KILO_PLATFORM=tscode
export KILO_APP_NAME=testagent
export KILO_APP_VERSION="$VERSION"

cd /root
nohup setsid "$NODE" --experimental-sqlite "$ENTRY" \
  --port "$PORT" \
  --password "$PASSWORD" \
  --hostname 0.0.0.0 \
  >> "$LOG_FILE" 2>&1 </dev/null &
PID=$!

if TESTAGENT_PORT="$PORT" TESTAGENT_PASSWORD="$PASSWORD" "$NODE" -e '
const port = Number(process.env.TESTAGENT_PORT)
const password = process.env.TESTAGENT_PASSWORD
const deadline = Date.now() + 30_000
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))
const probe = () => fetch(`http://127.0.0.1:${port}/global/health`, {
  headers: { Authorization: `Basic ${Buffer.from(`opencode:${password}`).toString("base64")}` },
  signal: AbortSignal.timeout(3000),
}).then((res) => res.ok).catch(() => false)

;(async () => {
  while (Date.now() < deadline) {
    if (await probe()) return
    await sleep(500)
  }
  process.stderr.write("TestAgent cloud server did not become healthy within 30 seconds.\n")
  process.exitCode = 1
})().catch((err) => {
  process.stderr.write(`${err.message}\n`)
  process.exitCode = 1
})
'; then
  :
else
  kill "$PID" 2>/dev/null || true
  printf 'TestAgent cloud startup failed. Log: %s\n' "$LOG_FILE" >&2
  tail -n 60 "$LOG_FILE" >&2 || true
  exit 1
fi

STARTED_AT=$("$NODE" -p 'Date.now()')
STATE_TMP=$STATE_FILE.tmp.$$
printf '{\n  "port": %s,\n  "password": "%s",\n  "pid": %s,\n  "version": "%s",\n  "runtime": "nodejs",\n  "startedAt": %s\n}\n' \
  "$PORT" "$PASSWORD" "$PID" "$VERSION" "$STARTED_AT" > "$STATE_TMP"
chmod 600 "$STATE_TMP"
mv "$STATE_TMP" "$STATE_FILE"

OWNER_PID=$("$NODE" -e '
const fs = require("node:fs")
const token = "--type" + "=" + "extensionHost"
for (const pid of fs.readdirSync("/proc")) {
  if (!/^\d+$/.test(pid)) continue
  try {
    const args = fs.readFileSync(`/proc/${pid}/cmdline`, "utf8")
    if (!args.includes(token)) continue
    const status = fs.readFileSync(`/proc/${pid}/status`, "utf8")
    const owner = status.match(/^PPid:\s+(\d+)/m)?.[1]
    if (owner && Number(owner) > 1) {
      process.stdout.write(owner)
      break
    }
  } catch {}
}
')

if [ -n "$OWNER_PID" ]; then
  nohup setsid "$NODE" -e '
const owner = Number(process.argv[1])
const daemon = Number(process.argv[2]) || 0
const alive = (pid) => {
  if (!pid) return true
  try { process.kill(pid, 0); return true }
  catch (err) { return !!err && err.code === "EPERM" }
}
const kill = (pid) => {
  if (!pid) return
  try { process.kill(pid, "SIGKILL") }
  catch (err) { if (err.code !== "ESRCH") process.stderr.write(`${err.message}\n`) }
}
const tick = () => {
  if (!alive(owner) || (daemon && !alive(daemon))) {
    kill(daemon)
    process.exit(0)
  }
}
tick()
setInterval(tick, 3000)
' "$OWNER_PID" "$PID" >/dev/null 2>&1 </dev/null &
fi

printf 'TestAgent cloud server ready\nPID: %s\nPort: %s\nHost: 0.0.0.0\nState: %s\nLog: %s\n' \
  "$PID" "$PORT" "$STATE_FILE" "$LOG_FILE"
