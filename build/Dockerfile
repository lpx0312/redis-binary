# syntax=docker/dockerfile:1
###############################################################################
# Redis 编译镜像 —— 下载源码、编译、打包(glib2.17 / 2.28 通用)
# ---------------------------------------------------------------------------
# 基于 base/ 下的基础镜像(已装好 devtoolset/gcc-toolset、patchelf、
# glib2.17 场景还有自编译的 OpenSSL 1.1.1)。
#
# 构建上下文:
#   redis-binary/build/
#   ├── Dockerfile
#   ├── redis-build-binary.sh
#   └── ci-build-binary.sh
#
# 构建示例(先构建好本地基础镜像 redis-binary:base-glib-2.28):
#   docker build -f build/Dockerfile \
#       --build-arg BASE_SYSTEM_VERSION=redis-binary:base-glib-2.28 \
#       --build-arg REDIS_VERSION=7.4.1 \
#       --build-arg GLIBC_VERSION=2.28 \
#       --build-arg TARGETARCH=amd64 \
#       -t redis-binary-build:7.4.1-glib2.28-amd64 build/
#
# 产物位置(镜像内):/root/output/redis-<ver>-linux-<arch>.glibc<ver>.tar.gz
###############################################################################

# 基础镜像(本地构建,无需外部 registry)
ARG BASE_SYSTEM_VERSION=redis-binary:base-glib-2.28
FROM ${BASE_SYSTEM_VERSION}

WORKDIR /root

# 必填:Redis 版本号(如 7.4.1)
ARG REDIS_VERSION
# 必填:glibc 版本(2.17 / 2.28),用于产物文件名后缀
ARG GLIBC_VERSION
# 必填:目标架构(amd64 / arm64),CI 显式传入
ARG TARGETARCH
# 可选:下载代理(内网构建时可设)
ARG DOWNLOAD_PROXY=""

RUN test -n "$REDIS_VERSION" || { echo "ERROR: 需要 --build-arg REDIS_VERSION= 指定版本(如 7.4.1)"; exit 1; } && \
    test -n "$GLIBC_VERSION" || { echo "ERROR: 需要 --build-arg GLIBC_VERSION= 指定 glibc 版本(2.17/2.28)"; exit 1; } && \
    test -n "$TARGETARCH" || { echo "ERROR: 需要 --build-arg TARGETARCH= 指定架构(amd64/arm64)"; exit 1; }

# 配置下载代理(若提供)。无条件先 touch 创建 proxy.sh,避免后续 source
# 一个不存在的文件 —— 在 set -e 下 source 不存在文件会让整个 RUN 退出。
RUN touch /etc/profile.d/proxy.sh && \
    if [ -n "$DOWNLOAD_PROXY" ]; then \
        echo "==> 使用下载代理: $DOWNLOAD_PROXY"; \
        echo "export http_proxy=$DOWNLOAD_PROXY"  >> /etc/profile.d/proxy.sh; \
        echo "export https_proxy=$DOWNLOAD_PROXY" >> /etc/profile.d/proxy.sh; \
        echo "export HTTP_PROXY=$DOWNLOAD_PROXY"  >> /etc/profile.d/proxy.sh; \
        echo "export HTTPS_PROXY=$DOWNLOAD_PROXY" >> /etc/profile.d/proxy.sh; \
    fi

# 拷贝编译+打包脚本
COPY redis-build-binary.sh /root/redis-build-binary.sh

# 编译 + 打包 + 冒烟测试
ENV REDIS_VERSION=${REDIS_VERSION} \
    GLIBC_VERSION=${GLIBC_VERSION} \
    ARCH=${TARGETARCH}
RUN chmod +x /root/redis-build-binary.sh && \
    { [ -f /etc/profile.d/proxy.sh ] && source /etc/profile.d/proxy.sh 2>/dev/null || true; } && \
    bash /root/redis-build-binary.sh
