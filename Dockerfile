# syntax=docker/dockerfile:1

FROM ubuntu:24.04

ARG NODE_VERSION=24.20.0
ARG BUN_VERSION=1.4.0

# 需要与 SSH 插件保持一致
ARG TSCODE_SERVER_COMMIT=tscode
ARG TSCODE_SERVER_APP_NAME=tscode-server
ARG TSCODE_SERVER_DATA_DIR=/root/.tscode-server

ARG DEBIAN_FRONTEND=noninteractive

# 验证编译环境位于 X64 环境下
RUN dpkg --print-architecture | grep -qx amd64

# 安装基础环境（含 OpenSandbox Chrome/VNC 沙盒所需 tigervnc/x11-utils/xdg-utils）
RUN export DEBIAN_FRONTEND="${DEBIAN_FRONTEND}" \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        build-essential \
        ca-certificates \
        cmake \
        curl \
        git \
        gzip \
        htop \
        iproute2 \
        jq \
        less \
        libstdc++6 \
        ninja-build \
        openjdk-8-jdk \
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
        sqlite3 \
        tar \
        tigervnc-standalone-server \
        unzip \
        util-linux \
        vim-tiny \
        wget \
        xdg-utils \
        x11-utils \
        xz-utils \
        zip \
    && rm -f /etc/ssh/ssh_host_* \
    && rm -rf /var/lib/apt/lists/*

# 安装 Node
RUN set -eux; \
    curl --fail --silent --show-error --location --retry 3 \
        --output /tmp/node-v${NODE_VERSION}-linux-x64.tar.xz \
        "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz"; \
    tar --extract --file /tmp/node-v${NODE_VERSION}-linux-x64.tar.xz --xz --directory /usr/local --strip-components=1; \
    rm -f /tmp/node-v${NODE_VERSION}-linux-x64.tar.xz; \
    node --version; \
    npm --version

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

# 配置启动脚本
COPY start.sh /root/.start.sh
COPY chrome.sh /chrome.sh

# 修改启动脚本换行符为 Linux LF
RUN sed -i 's/\r$//' /root/.start.sh \
    && chmod 0755 /root/.start.sh \
    && chmod 0755 /chrome.sh

# Chrome 沙盒模式下暴露 VNC(5901) 与 DevTools(9222) 端口
EXPOSE 22 5901 9222

ENTRYPOINT ["/root/.start.sh"]
CMD ["/usr/sbin/sshd", "-D", "-e"]
