# syntax=docker/dockerfile:1

FROM ubuntu:24.04

ARG BUN_VERSION=1.4.0

# 需要与 SSH 插件保持一致
ARG TSCODE_SERVER_COMMIT=tscode
ARG TSCODE_SERVER_APP_NAME=tscode-server
ARG TSCODE_SERVER_DATA_DIR=/root/.tscode-server

ARG DEBIAN_FRONTEND=noninteractive

# 固定为 UTF-8 locale，避免 Java 在 POSIX locale 下把 file.encoding 退化为
# ANSI_X3.4-1968(ASCII)，导致中文日志写入文件后乱码
ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

# 固定时区为中国上海，保证容器内时间戳正确
ENV TZ=Asia/Shanghai

# 验证编译环境位于 X64 环境下
RUN dpkg --print-architecture | grep -qx amd64

# 先固定安装 Node.js 24.20.0，确保后续 novnc 依赖使用 NodeSource 的 nodejs 包
RUN set -eux; \
    export DEBIAN_FRONTEND="${DEBIAN_FRONTEND}"; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg; \
    curl --fail --silent --show-error --location --retry 3 \
        --output /tmp/nodesource-setup.sh \
        https://deb.nodesource.com/setup_24.x; \
    bash /tmp/nodesource-setup.sh; \
    rm -f /tmp/nodesource-setup.sh; \
    apt-get update; \
    apt-get install -y --no-install-recommends nodejs=24.20.0-1nodesource1; \
    test "$(node --version)" = v24.20.0; \
    test "$(/usr/bin/node --version)" = v24.20.0; \
    npm --version; \
    rm -rf /var/lib/apt/lists/*

# 安装基础环境
RUN export DEBIAN_FRONTEND="${DEBIAN_FRONTEND}" \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        build-essential \
        cmake \
        git \
        gzip \
        htop \
        iproute2 \
        jq \
        less \
        libstdc++6 \
        ninja-build \
        openssh-server \
        passwd \
        pkg-config \
        procps \
        python-is-python3 \
        python3-pip \
        python3.12 \
        python3.12-dev \
        python3.12-venv \
        rsync \
        socat \
        sqlite3 \
        tar \
        tzdata \
        unzip \
        util-linux \
        vim-tiny \
        wget \
        xz-utils \
        zip \
    && ln -snf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime \
    && printf '%s\n' 'Asia/Shanghai' > /etc/timezone \
    && dpkg-reconfigure --frontend noninteractive tzdata \
    && rm -f /etc/ssh/ssh_host_* \
    && rm -rf /var/lib/apt/lists/*

# 允许不安全的旧式 TLS 重新协商（OpenSSL 3 起默认禁用 SSL_OP_LEGACY_SERVER_CONNECT）。
# 部分代理/旧服务端在握手时不发送 RFC 5746 扩展，会让 curl、git 等系统 OpenSSL 工具报
# "write EPROTO ... final_renegotiate:unsafe legacy renegotiation disabled"。
# 该配置由 start.sh 通过 sshd SetEnv 注入 OPENSSL_CONF，仅影响 SSH 会话派生的进程。
# Node 侧不走 system_default（实测不生效），改用 tscode-tls-legacy-renegotiation.cjs
# 预加载补丁，nodejs_conf 仅作为个别 Node 构建的兜底。
RUN printf '%s\n' \
    'openssl_conf = openssl_init' \
    'nodejs_conf = openssl_init' \
    '' \
    '[openssl_init]' \
    'ssl_conf = ssl_sect' \
    '' \
    '[ssl_sect]' \
    'system_default = system_default_sect' \
    '' \
    '[system_default_sect]' \
    'Options = UnsafeLegacyRenegotiation' \
    > /etc/ssl/tscode-openssl.cnf

# 安装 Java
RUN export DEBIAN_FRONTEND="${DEBIAN_FRONTEND}" \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        openjdk-8-jdk \
    && rm -rf /var/lib/apt/lists/*

# 安装 Bun
RUN set -eux; \
    export BUN_INSTALL=/tmp/bun-install; \
    export PATH="/tmp/bun-install/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"; \
    curl --fail --silent --show-error --location --retry 3 \
        --output /tmp/bun-install.sh \
        https://bun.sh/install; \
    bash /tmp/bun-install.sh "bun-v${BUN_VERSION}"; \
    install -m 0755 /tmp/bun-install/bin/bun /usr/local/bin/bun; \
    rm -rf /tmp/bun-install /tmp/bun-install.sh; \
    bun --version

# 安装 OpenSandbox Chrome/VNC 沙盒依赖。
# novnc 依赖 nodejs，此时使用前面已安装的 NodeSource 包，不会引入 Ubuntu Node 18。
RUN export DEBIAN_FRONTEND="${DEBIAN_FRONTEND}" \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        novnc \
        tigervnc-standalone-server \
        websockify \
        xdg-utils \
        x11-utils \
    && test "$(node --version)" = v24.20.0 \
    && test "$(/usr/bin/node --version)" = v24.20.0 \
    && rm -rf /var/lib/apt/lists/*

# 声明当前处于云端模式
RUN touch /etc/tscode-cloud-mode

# 从本地文件安装 tscode
RUN --mount=type=bind,source=vscode-server-linux-x64.tar.gz,target=/tmp/vscode-server-linux-x64.tar.gz,readonly \
    set -eux; \
    mkdir -p "${TSCODE_SERVER_DATA_DIR}/bin/${TSCODE_SERVER_COMMIT}"; \
    tar --extract --file /tmp/vscode-server-linux-x64.tar.gz --gzip \
        --directory "${TSCODE_SERVER_DATA_DIR}/bin/${TSCODE_SERVER_COMMIT}" \
        --strip-components=1; \
    test -x "${TSCODE_SERVER_DATA_DIR}/bin/${TSCODE_SERVER_COMMIT}/bin/${TSCODE_SERVER_APP_NAME}"; \
    test -f "${TSCODE_SERVER_DATA_DIR}/bin/${TSCODE_SERVER_COMMIT}/product.json"

# 从本地文件安装额外的 tscode 插件
RUN --mount=type=bind,source=.,target=/tmp/build-context,readonly \
    set -eux; \
    mkdir -p "${TSCODE_SERVER_DATA_DIR}/bin/${TSCODE_SERVER_COMMIT}/extensions"; \
    find /tmp/build-context -maxdepth 1 -type f -name '*.vsix' -print0 \
        | xargs -0 -r -n 1 \
            "${TSCODE_SERVER_DATA_DIR}/bin/${TSCODE_SERVER_COMMIT}/bin/${TSCODE_SERVER_APP_NAME}" \
            --extensions-dir "${TSCODE_SERVER_DATA_DIR}/bin/${TSCODE_SERVER_COMMIT}/extensions" \
            --install-extension

# 为 tscode 扩展中的原生二进制增加执行权限
# test-workbench_change: 只用 node 版运行时(testagent-node wrapper);bun 版(bin/testagent)可选,
# 缺失时不再让镜像构建失败(为后续移除 bun 版做准备)。
RUN set -eux; \
    EXT="${TSCODE_SERVER_DATA_DIR}/bin/${TSCODE_SERVER_COMMIT}/extensions/test-tech.testagent"; \
    chmod 0755 "${EXT}/bin/testagent-node" 2>/dev/null || echo "[warn] bin/testagent-node not found"; \
    chmod 0755 "${EXT}/bin/testagent" 2>/dev/null || true; \
    chmod 0755 "${EXT}/bin/testflow" 2>/dev/null || true

# test-workbench_change: 双保险 —— 在扩展 env-path 写入 TestAgent 之前,预置到登录 shell,
# 使 SSH 远端 agent host(`bash -l -c` 登录 shell)在扩展尚未激活时也能解析到 node 版 wrapper。
RUN set -eux; \
    EXT="${TSCODE_SERVER_DATA_DIR}/bin/${TSCODE_SERVER_COMMIT}/extensions/test-tech.testagent"; \
    printf 'export TestAgent="%s/bin"\nexport PATH="$TestAgent:$PATH"\n' "$EXT" > /etc/profile.d/testagent-env.sh; \
    chmod 0644 /etc/profile.d/testagent-env.sh

# 预装 ripgrep（静态 musl 二进制），避免 testagent 运行期联网下载
# 安装到 /usr/local/bin 供 PATH 查找，同时预置 opencode 缓存目录兜底
RUN --mount=type=bind,source=builtin,target=/tmp/builtin,readonly \
    set -eux; \
    mkdir -p /tmp/rg-extract; \
    tar --extract --file /tmp/builtin/ripgrep-15.1.0-x86_64-unknown-linux-musl.tar.gz --gzip \
        --directory /tmp/rg-extract; \
    install -m 0755 /tmp/rg-extract/ripgrep-15.1.0-x86_64-unknown-linux-musl/rg /usr/local/bin/rg; \
    install -d -m 0755 /root/.cache/opencode/bin; \
    install -m 0755 /tmp/rg-extract/ripgrep-15.1.0-x86_64-unknown-linux-musl/rg /root/.cache/opencode/bin/rg; \
    rm -rf /tmp/rg-extract; \
    rg --version

# 安装 Google Chrome（Ubuntu 24.04 仓库无 chromium 二进制包，仅有指向 snap 的过渡包，
# 故改用官方 deb 安装真 Chrome，供 OpenSandbox Chrome 沙盒使用）
RUN set -eux; \
    curl --fail --silent --show-error --location --retry 3 \
        --output /tmp/google-chrome-stable_current_amd64.deb \
        https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb; \
    export DEBIAN_FRONTEND="${DEBIAN_FRONTEND}"; \
    apt-get update; \
    apt-get install -y --no-install-recommends /tmp/google-chrome-stable_current_amd64.deb; \
    rm -f /tmp/google-chrome-stable_current_amd64.deb; \
    rm -rf /var/lib/apt/lists/*; \
    google-chrome --version

# 配置 SSH
RUN mkdir -p /run/sshd \
    && sed -i -E '/^[[:space:]]*#?[[:space:]]*(AuthenticationMethods|PasswordAuthentication|PermitRootLogin|PermitEmptyPasswords|PubkeyAuthentication|KbdInteractiveAuthentication|ChallengeResponseAuthentication|HostbasedAuthentication|GSSAPIAuthentication|UsePAM|AllowTcpForwarding|AllowStreamLocalForwarding)[[:space:]]+/d' /etc/ssh/sshd_config \
    && printf '\nAuthenticationMethods none\nPasswordAuthentication yes\nPermitRootLogin yes\nPermitEmptyPasswords yes\nPubkeyAuthentication no\nKbdInteractiveAuthentication no\nChallengeResponseAuthentication no\nHostbasedAuthentication no\nGSSAPIAuthentication no\nUsePAM no\nAllowTcpForwarding yes\nAllowStreamLocalForwarding yes\n' >> /etc/ssh/sshd_config \
    && passwd --delete root

# 创建用户工作目录
RUN install -d -m 0777 /app \
    && printf '%s\n' 'cd /app' > /etc/profile.d/app.sh \
    && chmod 0644 /etc/profile.d/app.sh

WORKDIR /app

# 预创建 X11 socket 目录（VNC/Chrome 沙盒使用）
RUN mkdir -p /tmp/.X11-unix \
    && chmod 1777 /tmp/.X11-unix

# 设置 TestAgent Cloud 命令
COPY testagent-cloud /usr/local/bin/testagent-cloud
RUN sed -i 's/\r$//' /usr/local/bin/testagent-cloud \
    && chmod 0755 /usr/local/bin/testagent-cloud

# Node TLS 补丁：补上 SSL_OP_LEGACY_SERVER_CONNECT（OpenSSL 的 system_default 不会
# 作用于 Node 自身的 SSL_CTX，故 Node 侧改用 --require 预加载补丁）。
COPY tscode-tls-legacy-renegotiation.cjs /usr/local/lib/tscode/tls-legacy-renegotiation.cjs
RUN chmod 0644 /usr/local/lib/tscode/tls-legacy-renegotiation.cjs

# 配置启动脚本
COPY start.sh /root/.start.sh
COPY chrome.sh /root/.chrome.sh

# 修改启动脚本换行符为 Linux LF
RUN sed -i 's/\r$//' /root/.start.sh \
    && sed -i 's/\r$//' /root/.chrome.sh \
    && chmod 0755 /root/.start.sh \
    && chmod 0755 /root/.chrome.sh

# Chrome 沙盒模式下暴露 VNC(5901) 与 DevTools(9922) 端口
EXPOSE 22 5901 9922

ENTRYPOINT ["/root/.start.sh"]
CMD ["/usr/sbin/sshd", "-D", "-e"]
