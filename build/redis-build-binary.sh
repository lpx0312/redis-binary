#!/bin/bash
set -euo pipefail

# ============================================================
# Redis 编译 + 打包脚本(在编译镜像内执行)
# ---------------------------------------------------------------------------
# 环境变量(由 build/Dockerfile 的 ARG 注入):
#   REDIS_VERSION - Redis 版本号(必填,如 7.4.1)
#   ARCH          - 目标架构(必填,amd64 / arm64),只用于产物目录/文件名
#
# 编译基线:glibc 2.17(CentOS 7),产物可在所有 glibc >= 2.17 的系统上运行
# (CentOS 7/8、Rocky、Debian、Ubuntu、kylin v10、openEuler 等)。
#
# 产物:/root/output/redis-<ver>-linux-<arch>.tar.gz
#   redis-<ver>-linux-<arch>/
#   ├── bin/  redis-server redis-cli redis-benchmark
#   │         redis-sentinel redis-check-aof redis-check-rdb
#   └── lib/  libssl.so.1.1 libcrypto.so.1.1(TLS 运行时,自带,免装)
# ============================================================

REDIS_VERSION="${REDIS_VERSION:?ERROR: 必须设置 REDIS_VERSION}"
ARCH="${ARCH:?ERROR: 必须设置 ARCH(amd64 或 arm64)}"

case "$ARCH" in
    amd64|arm64) ;;
    *) echo "❌ 无效 ARCH: $ARCH(应为 amd64 或 arm64)"; exit 1 ;;
esac

# 启用 devtoolset(amd64=11 / arm64=10,基础镜像已建统一软链 /opt/rh/devtoolset)
# set -u 下 devtoolset 的 enable 脚本引用未定义变量会报 unbound variable,先设空默认值
export MANPATH="${MANPATH:-}" PERL5LIB="${PERL5LIB:-}" INFOPATH="${INFOPATH:-}"
if [ -f /opt/rh/devtoolset/enable ]; then source /opt/rh/devtoolset/enable; fi

echo "============================================"
echo "  编译 Redis ${REDIS_VERSION} (glibc 2.17, ${ARCH})"
echo "  gcc: $(gcc --version | head -1)"
echo "  glibc: $(ldd --version | head -1)"
echo "  openssl: $(openssl version)"
echo "============================================"

# 预检:Redis 7.x 的 Makefile 用 pkg-config 探测 OpenSSL,
# 探测不到会静默编译出无 TLS 的二进制或直接报错,提前失败更清晰
if ! pkg-config --modversion openssl >/dev/null 2>&1; then
    echo "❌ pkg-config 探测不到 openssl,检查基础镜像的 PKG_CONFIG_PATH 设置"
    exit 1
fi
echo "pkg-config openssl: $(pkg-config --modversion openssl)"
echo "pkg-config cflags:  $(pkg-config --cflags openssl)"
echo "pkg-config libs:    $(pkg-config --libs openssl)"

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
# 编译(BUILD_TLS=yes;jemalloc 默认静态链入)
# 注意:Redis 的 Makefile 里 OpenSSL 的头文件路径只认 OPENSSL_PREFIX 变量,
# pkg-config 仅用于链接参数(--libs),必须显式传 OPENSSL_PREFIX 才能找到 ssl.h
# ------------------------------------------------------------
TLS_ARGS="BUILD_TLS=yes"
if [ -d /usr/local/openssl-1.1 ]; then
    TLS_ARGS="${TLS_ARGS} OPENSSL_PREFIX=/usr/local/openssl-1.1"
fi
make -j"$(nproc)" ${TLS_ARGS}

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
# 兼容性自检:二进制引用的最高 GLIBC 符号版本必须 <= 2.17
# ------------------------------------------------------------
MAX_GLIBC=$(objdump -T "${STAGE}/bin/redis-server" | grep -o 'GLIBC_[0-9.]*' | sort -Vu | tail -1)
echo "==> 二进制要求的最高 GLIBC 符号版本: ${MAX_GLIBC}"
if [ "${MAX_GLIBC}" \> "GLIBC_2.17" ]; then
    echo "❌ 兼容性检查失败: ${MAX_GLIBC} > GLIBC_2.17,产物无法在 CentOS 7 上运行"
    exit 1
fi

# ------------------------------------------------------------
# 冒烟测试(在编译容器内验证能跑起来)
# ------------------------------------------------------------
"${STAGE}/bin/redis-server" --version
"${STAGE}/bin/redis-cli" --version
# 验证 RPATH 生效:解析到的 libssl 应来自包内 lib/
ldd "${STAGE}/bin/redis-server" | grep libssl

# ------------------------------------------------------------
# 打 tar.gz
# ------------------------------------------------------------
cd /root/output
TARBALL="${PKG_NAME}.tar.gz"
tar czf "${TARBALL}" "${PKG_NAME}"
rm -rf "${STAGE}"
ls -lh "${TARBALL}"
echo ""
echo "============================================"
echo "  ✅ Redis ${REDIS_VERSION} 编译打包完成"
echo "============================================"
tar tzf "${TARBALL}"
