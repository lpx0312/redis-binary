#!/bin/bash
set -euo pipefail

# ============================================================
# CI 编译脚本:构建基础镜像 → 构建编译镜像 → 提取 tarball
# ---------------------------------------------------------------------------
# 环境变量:
#   REDIS_VERSION - Redis 版本号(必填,如 7.4.1)
#   GLIB_VERSION  - glibc 版本(必填,2.17 / 2.28),决定用哪个基础镜像
#   ARCH          - 目标架构(必填,amd64 / arm64)
#   ZONE          - 可选,cn=国内源加速;空=官方源
#
# 与 xtrabackup-binary 不同的是:基础镜像不推外部 registry,直接在 runner
# 本地构建(buildx gha 缓存加速,第二次构建几乎秒过)。
# 前提:runner 与目标镜像同架构 —— 由原生 runner 保证:
#   amd64 job 用 ubuntu-latest,arm64 job 用 ubuntu-24.04-arm
#
# 产物:output/redis-<ver>-linux-<arch>.glibc<ver>.tar.gz
# ============================================================

REDIS_VERSION="${REDIS_VERSION:?ERROR: 必须设置 REDIS_VERSION(如 7.4.1)}"
GLIB_VERSION="${GLIB_VERSION:?ERROR: 必须设置 GLIB_VERSION(2.17 或 2.28)}"
ARCH="${ARCH:?ERROR: 必须设置 ARCH(amd64 或 arm64)}"
ZONE="${ZONE:-}"

case "$ARCH" in
    amd64|arm64) ;;
    *) echo "❌ 无效 ARCH: $ARCH(应为 amd64 或 arm64)"; exit 1 ;;
esac

case "$GLIB_VERSION" in
    2.17|2.28) ;;
    *) echo "❌ 无效 GLIB_VERSION: $GLIB_VERSION(应为 2.17 或 2.28)"; exit 1 ;;
esac

BASE_TAG="redis-binary:base-glib-${GLIB_VERSION}"
BUILD_IMAGE_TAG="redis-binary-build:${REDIS_VERSION}-glib${GLIB_VERSION}-${ARCH}"

echo "============================================"
echo "  编译 Redis 二进制"
echo "============================================"
echo "  Redis 版本:  ${REDIS_VERSION}"
echo "  glibc 版本:  ${GLIB_VERSION}"
echo "  目标架构:    ${ARCH}"
echo "  基础镜像:    ${BASE_TAG}(本地构建)"
echo "============================================"

# ------------------------------------------------------------
# Step 1: 本地构建基础镜像(gha 缓存加速)
# 注意:基础镜像没有发行版下划线差异,文件名为 base/Dockerfile-glib2.17 形式
# ------------------------------------------------------------
echo ""
echo ">>> 构建基础镜像 ${BASE_TAG}..."
docker buildx build \
    --load \
    --build-arg "TARGETARCH=${ARCH}" \
    ${ZONE:+--build-arg "ZONE=${ZONE}"} \
    --cache-from type=gha \
    --cache-to type=gha,mode=max \
    -t "${BASE_TAG}" \
    -f "base/Dockerfile-glib${GLIB_VERSION}" \
    .

# ------------------------------------------------------------
# Step 2: 构建编译镜像(内含下载源码+编译+打包+冒烟测试)
# 单架构构建,--load 载入本地 docker,再用 docker create + docker cp 提取产物
# ------------------------------------------------------------
echo ""
echo ">>> 构建编译镜像并提取产物..."
docker buildx build \
    --load \
    --build-arg "BASE_SYSTEM_VERSION=${BASE_TAG}" \
    --build-arg "REDIS_VERSION=${REDIS_VERSION}" \
    --build-arg "GLIBC_VERSION=${GLIB_VERSION}" \
    --build-arg "TARGETARCH=${ARCH}" \
    -t "${BUILD_IMAGE_TAG}" \
    -f build/Dockerfile \
    build/

# ------------------------------------------------------------
# Step 3: 从镜像提取产物(docker create + docker cp)
# ------------------------------------------------------------
EXTRACT_CID="redis-extract-$$"
echo ""
echo ">>> 从镜像提取产物..."
docker create --name "${EXTRACT_CID}" "${BUILD_IMAGE_TAG}" /bin/true >/dev/null

mkdir -p output
docker cp "${EXTRACT_CID}:/root/output/." output/
docker rm -f "${EXTRACT_CID}" >/dev/null

# 只保留 tarball
find output/ ! -name '*.tar.gz' -type f -delete 2>/dev/null || true
find output/ -type d -empty -delete 2>/dev/null || true

# 最终校验
REAL_TARBALL="$(ls output/redis-${REDIS_VERSION}-linux-${ARCH}.glibc${GLIB_VERSION}.tar.gz 2>/dev/null | head -1 || true)"
if [ -z "${REAL_TARBALL}" ]; then
    echo "❌ 未能从镜像提取 redis-${REDIS_VERSION}-linux-${ARCH}.glibc${GLIB_VERSION}.tar.gz 产物"
    ls -la output/ || true
    exit 1
fi

echo ""
echo "============================================"
echo "  ✅ 编译完成!产物列表:"
echo "============================================"
ls -lh output/
echo "============================================"

# 清理编译镜像(腾出空间,避免 runner 磁盘爆;基础镜像保留供缓存复用)
docker rmi "${BUILD_IMAGE_TAG}" 2>/dev/null || true
