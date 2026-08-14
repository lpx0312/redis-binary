#!/bin/bash
set -euo pipefail

# ============================================================
# Redis 编译 + 打包脚本(在编译镜像内执行)
# ---------------------------------------------------------------------------
# 环境变量(由 build/Dockerfile 的 ARG 注入):
#   REDIS_VERSION - Redis 版本号(必填,如 7.4.1)
#   GLIBC_VERSION - glibc 版本(必填,2.17 / 2.28),只用于产物文件名后缀
#   ARCH          - 目标架构(必填,amd64 / arm64),只用于产物目录/文件名
#
# 产物:/root/output/redis-<ver>-linux-<arch>.glibc<ver>.tar.gz
#   redis-<ver>-linux-<arch>/
#   ├── bin/  redis-server redis-cli redis-benchmark
#   │         redis-sentinel redis-check-aof redis-check-rdb
#   └── lib/  libssl.so.1.1 libcrypto.so.1.1(TLS 运行时,自带,免装)
# ============================================================

REDIS_VERSION="${REDIS_VERSION:?ERROR: 必须设置 REDIS_VERSION}"
GLIBC_VERSION="${GLIBC_VERSION:?ERROR: 必须设置 GLIBC_VERSION(2.17 或 2.28)}"
ARCH="${ARCH:?ERROR: 必须设置 ARCH(amd64 或 arm64)}"

case "$ARCH" in
    amd64|arm64) ;;
    *) echo "❌ 无效 ARCH: $ARCH(应为 amd64 或 arm64)"; exit 1 ;;
esac

# 启用新工具链(两种基础镜像哪个存在用哪个)
if   [ -f /opt/rh/devtoolset/enable ];    then source /opt/rh/devtoolset/enable; fi
if   [ -f /opt/rh/gcc-toolset-12/enable ]; then source /opt/rh/gcc-toolset-12/enable; fi

echo "============================================"
echo "  编译 Redis ${REDIS_VERSION} (glibc ${GLIBC_VERSION}, ${ARCH})"
echo "  gcc: $(gcc --version | head -1)"
echo "  glibc: $(ldd --version | head -1)"
echo "  openssl: $(openssl version)"
echo "============================================"

WORKDIR=/root/build
mkdir -p "${WORKDIR}" && cd "${WORKDIR}"

# ------------------------------------------------------------
# 下载 Redis 源码(官方源优先,GitHub 兜底)
# ------------------------------------------------------------
SRC_TARBALL="redis-${REDIS_VERSION}.tar.gz"
if curl -fsSL --retry 5 --retry-delay 10 -o "${SRC_TARBALL}" \
        "https://download.redis.io/releases/${SRC_TARBALL}"; then
    echo "==> 已从 download.redis.io 下载源码"
else
    echo "==> download.redis.io 失败,改用 GitHub 兜底"
    curl -fsSL --retry 5 --retry-delay 10 -o "${SRC_TARBALL}" \
        "https://github.com/redis/redis/archive/refs/tags/${REDIS_VERSION}.tar.gz"
fi

tar xzf "${SRC_TARBALL}"
rm -f "${SRC_TARBALL}"
SRC_DIR="redis-${REDIS_VERSION}"
[ -d "${SRC_DIR}" ] || { echo "❌ 解压后未找到 ${SRC_DIR}"; ls -la; exit 1; }
cd "${SRC_DIR}"

# ------------------------------------------------------------
# 编译(BUILD_TLS=yes;jemalloc 默认)
# ------------------------------------------------------------
make -j"$(nproc)" BUILD_TLS=yes

# ------------------------------------------------------------
# 收集二进制 + TLS 运行库,打包
# ------------------------------------------------------------
PKG_NAME="redis-${REDIS_VERSION}-linux-${ARCH}"
STAGE="/root/output/${PKG_NAME}"
mkdir -p "${STAGE}/bin" "${STAGE}/lib"

BINS="redis-server redis-cli redis-benchmark redis-sentinel redis-check-aof redis-check-rdb"
for bin in ${BINS}; do
    if [ ! -f "src/${bin}" ] && [ "${bin}" = "redis-sentinel" ]; then
        # 老版本 make 不单独产出 sentinel,复制 redis-server 即可(官方发布包也是这么做的)
        cp src/redis-server "src/${bin}"
    fi
    [ -f "src/${bin}" ] || { echo "❌ 缺少编译产物 src/${bin}"; exit 1; }
    strip "src/${bin}"
    cp "src/${bin}" "${STAGE}/bin/"
done

# TLS 链接库(libssl/libcrypto)打进 lib/,目标机无需安装 openssl
# (glibc 自身的 libpthread/libdl/libm/libc 不打包 —— 由目标系统的 glibc 提供)
ldd "${STAGE}/bin/redis-server" | awk '/=> \// {print $3}' | grep -E 'lib(ssl|crypto)' | sort -u | \
    while read -r so; do
        echo "==> 打包运行库: ${so}"
        cp -L "${so}" "${STAGE}/lib/"
    done

# RPATH 指向包内 lib/,解压即用,不依赖系统 openssl
patchelf --set-rpath '$ORIGIN/../lib' "${STAGE}"/bin/*

# ------------------------------------------------------------
# 冒烟测试(在编译容器内验证能跑起来)
# ------------------------------------------------------------
"${STAGE}/bin/redis-server" --version
"${STAGE}/bin/redis-cli" --version
if [ -f "${STAGE}/lib/libssl.so.1.1" ]; then
    # 验证 RPATH 生效:解析到的 libssl 应来自包内 lib/
    ldd "${STAGE}/bin/redis-server" | grep libssl
fi

# ------------------------------------------------------------
# 打 tar.gz
# ------------------------------------------------------------
cd /root/output
TARBALL="${PKG_NAME}.glibc${GLIBC_VERSION}.tar.gz"
tar czf "${TARBALL}" "${PKG_NAME}"
rm -rf "${STAGE}"
ls -lh "${TARBALL}"
echo ""
echo "============================================"
echo "  ✅ Redis ${REDIS_VERSION} 编译打包完成"
echo "============================================"
tar tzf "${TARBALL}"
