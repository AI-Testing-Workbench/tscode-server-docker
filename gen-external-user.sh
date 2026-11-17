#!/usr/bin/env bash

set -Eeuo pipefail
exec 2>&1
umask 077

if [ -z "${TESTAGENT_CLOUD_SERVICE_USER:-}" ]; then
    echo "[gen-external-user] 缺少 TESTAGENT_CLOUD_SERVICE_USER，跳过 token 获取" >&2
    exit 1
fi

DATA_DIR=/root/.local/share/testagent
USER_FILE=$DATA_DIR/external-user.json
if [ -e "$USER_FILE" ] || [ -L "$USER_FILE" ]; then
    echo "[gen-external-user] external-user.json 已存在，跳过 token 获取"
    exit 0
fi

if [ -L "$DATA_DIR" ] || { [ -e "$DATA_DIR" ] && [ ! -d "$DATA_DIR" ]; }; then
    echo "[gen-external-user] TestAgent 数据目录类型非法" >&2
    exit 1
fi
if ! install -d -m 0700 "$DATA_DIR" || ! chmod 0700 "$DATA_DIR"; then
    echo "[gen-external-user] TestAgent 数据目录准备失败" >&2
    exit 1
fi

GATEWAY_HOST=$(printf '%s' 'dGVzdGh1Yi1nYXRld2F5LnBhYXMuY21iY2hpbmEuY24=' | base64 --decode) || {
    echo "[gen-external-user] 网关地址解码失败" >&2
    exit 1
}
RESPONSE_FILE=$(mktemp "$DATA_DIR/.external-user-response.XXXXXX") || {
    echo "[gen-external-user] 响应临时文件创建失败" >&2
    exit 1
}
OUTPUT_FILE=$(mktemp "$DATA_DIR/.external-user-json.XXXXXX") || {
    rm -f -- "$RESPONSE_FILE"
    echo "[gen-external-user] 用户文件临时文件创建失败" >&2
    exit 1
}
trap 'rm -f -- "$RESPONSE_FILE" "$OUTPUT_FILE"' EXIT

CURL_ARGS=(
    --silent
    --show-error
    --connect-timeout 3
    --max-time 12
    --output "$RESPONSE_FILE"
    --write-out '%{http_code}'
    --get
    --data-urlencode "userId=$TESTAGENT_CLOUD_SERVICE_USER"
)
if ! HTTP_STATUS=$(curl "${CURL_ARGS[@]}" "https://$GATEWAY_HOST/login/get-token"); then
    echo "[gen-external-user] token 请求失败（网络或 TLS 错误）" >&2
    exit 1
fi
if [ "$HTTP_STATUS" != "200" ]; then
    echo "[gen-external-user] token 请求返回 HTTP $HTTP_STATUS" >&2
    exit 1
fi

if ! python3 - "$RESPONSE_FILE" "$OUTPUT_FILE" "$TESTAGENT_CLOUD_SERVICE_USER" <<'PY'
import base64
import json
import os
import sys

response_path, output_path, user_id = sys.argv[1:]
required_claims = (
    "userName",
    "employeeId",
    "enterpriseId",
    "enterpriseName",
    "joinedEnterpriseIds",
    "netEnv",
    "openId",
    "originPathId",
    "pathId",
    "pathName",
    "rtcId",
    "sapId",
    "ystId",
)

try:
    with open(response_path, encoding="utf-8") as response_file:
        envelope = json.load(response_file)
    if envelope.get("returnCode") != "SUC0000":
        raise ValueError("unsuccessful returnCode")

    token = envelope.get("body")
    if not isinstance(token, str) or not token:
        raise ValueError("empty token body")
    parts = token.split(".")
    if len(parts) != 3:
        raise ValueError("invalid JWT shape")

    payload_segment = parts[1]
    payload_bytes = base64.urlsafe_b64decode(payload_segment + "=" * (-len(payload_segment) % 4))
    payload = json.loads(payload_bytes.decode("utf-8"))
    claims = payload.get("token")
    if isinstance(claims, str):
        claims = json.loads(claims)
    if not isinstance(claims, dict):
        raise ValueError("invalid token claims")

    user = {"token": token, "userId": user_id}
    for key in required_claims:
        value = claims.get(key)
        if not isinstance(value, str) or not value:
            raise ValueError("missing user claim")
        user[key] = value

    with open(output_path, "w", encoding="utf-8") as output_file:
        json.dump(user, output_file, ensure_ascii=False, indent=2)
        output_file.write("\n")
        output_file.flush()
        os.fsync(output_file.fileno())
    os.chmod(output_path, 0o600)
except Exception as error:
    print(f"[gen-external-user] 响应解析或用户文件生成失败（{type(error).__name__}）", file=sys.stderr)
    sys.exit(1)
PY
then
    exit 1
fi

if ! mv -fT -- "$OUTPUT_FILE" "$USER_FILE"; then
    echo "[gen-external-user] external-user.json 安装失败" >&2
    exit 1
fi
echo "[gen-external-user] external-user.json 已生成"
