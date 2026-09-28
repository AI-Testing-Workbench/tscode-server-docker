// 为 Node 进程的 TLS 客户端连接补上 SSL_OP_LEGACY_SERVER_CONNECT。
//
// 部分代理/旧服务端在握手时不发送 RFC 5746 扩展，OpenSSL 3 默认拒绝此类连接，
// Node 会报：write EPROTO ... final_renegotiate:unsafe legacy renegotiation disabled。
// OpenSSL 的 [system_default] Options = UnsafeLegacyRenegotiation 只对 curl/git 生效，
// Node 不会把 system_default 应用到自己的 SSL_CTX，因此这里通过 --require 预加载，
// 在 tls.connect/tls.createSecureContext 的 options 上显式 OR 该 SSL_OP 位。
//
// 由 start.sh 通过 sshd SetEnv 注入 NODE_OPTIONS 生效，覆盖 tscode-server 与扩展宿主。
"use strict";

const tls = require("node:tls");
const { SSL_OP_LEGACY_SERVER_CONNECT } = require("node:crypto").constants;

// OpenSSL 中该选项固定为 0x4；个别裁剪版 Node 可能不导出该常量，用字面量兜底。
const LEGACY = SSL_OP_LEGACY_SERVER_CONNECT || 0x4;

function apply(options) {
  if (!options || typeof options !== "object") return;
  const value = options.secureOptions;
  if (typeof value === "bigint") {
    options.secureOptions = value | BigInt(LEGACY);
    return;
  }
  options.secureOptions = (typeof value === "number" ? value : 0) | LEGACY;
}

const connect = tls.connect;
tls.connect = function (...args) {
  const first = args[0];
  if (typeof first === "number") {
    // connect(port[, host][, options][, callback])
    for (const arg of args.slice(1)) {
      if (arg && typeof arg === "object" && !Array.isArray(arg)) {
        apply(arg);
        break;
      }
    }
  } else {
    apply(first);
  }
  return connect.apply(this, args);
};

const createSecureContext = tls.createSecureContext;
tls.createSecureContext = function (options) {
  apply(options);
  return createSecureContext.apply(this, arguments);
};
