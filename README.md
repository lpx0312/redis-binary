# redis-binary

使用 GitHub Actions 编译 Redis 官方源码，产出便携式二进制离线包并发布到 GitHub Release。

结构与 [xtrabackup-binary](../xtrabackup-binary) 一致：**按 glibc 版本分档**（不按发行版），
`glibc2.17`（CentOS 7 基线）/ `glibc2.28`（Rocky 8 基线）× `amd64` / `arm64`。

> 为什么按 glibc 而不是按系统（kubekey 那种一系统一个 Dockerfile）？
> kubekey 的产物是各发行版仓库里的**原生 RPM/DEB 包**，与系统强绑定，必须逐系统做；
> 而这里是**从源码编译的 ELF 二进制**，兼容性只取决于编译机的 glibc 版本
> （编译机 glibc ≤ 运行机 glibc 即可），与发行版无关 —— glibc 2.17 编出的包能跑在
> CentOS 7/8、Rocky、Ubuntu 16+、kylin v10、openEuler 等所有主流系统上。

## 产物

每次构建产出（以 `7.4.1` + `2.28` 为例）：

| 文件 | 说明 |
| ---- | ---- |
| `redis-7.4.1-linux-amd64.glibc2.28.tar.gz` | x86_64 包 |
| `redis-7.4.1-linux-arm64.glibc2.28.tar.gz` | aarch64 包 |
| `redis-7.4.1.sha256sum.txt` | 校验文件 |

tar 包目录结构（TLS 运行库打进包内 `lib/`，通过 RPATH 引用，目标机**无需安装 openssl**）：

```
redis-7.4.1-linux-amd64/
├── bin/
│   ├── redis-server
│   ├── redis-cli
│   ├── redis-benchmark
│   ├── redis-sentinel
│   ├── redis-check-aof
│   └── redis-check-rdb
└── lib/
    ├── libssl.so.1.1
    └── libcrypto.so.1.1
```

- 编译选项：`BUILD_TLS=yes`，默认 jemalloc，`strip` 瘦身
- 源码来源：`https://download.redis.io/releases/redis-<version>.tar.gz`（GitHub 兜底）
- 编译完在容器内做冒烟测试（`redis-server --version` 等）才打包

## 仓库结构

```
redis-binary/
├── base/
│   ├── Dockerfile-glib2.17    # CentOS 7 基线(devtoolset-11/10 + 自编译 OpenSSL 1.1.1w)
│   └── Dockerfile-glib2.28    # Rocky 8 基线(gcc-toolset-12 + 系统 OpenSSL 1.1.1)
├── build/
│   ├── Dockerfile             # 编译镜像(下载源码 → make → 打包)
│   ├── redis-build-binary.sh  # 容器内编译+打包脚本(含 RPATH 设置与冒烟测试)
│   └── ci-build-binary.sh     # CI 编排脚本(建基础镜像 → 建编译镜像 → 提取产物)
└── .github/workflows/build-binary.yml
```

### 两种 glibc 基线的差异

| | glibc 2.17 | glibc 2.28 |
| --- | --- | --- |
| 基础镜像 | CentOS 7.9（已 EOL，源指向 vault 存档） | Rocky Linux 8.9 |
| 编译器 | devtoolset-11（amd64）/ devtoolset-10（arm64） | gcc-toolset-12 |
| OpenSSL | 系统自带 1.0.2 太老，**自编译 1.1.1w** 装到 /usr/local | 系统 1.1.1k 够用 |
| 适用目标机 | CentOS 7/8、kylin v10、openEuler 20.03 等老系统 | Rocky 8/9、Ubuntu 20.04+、Debian 10+ 等 |

两者都自带 patchelf 0.19.1，用于给二进制设置 RPATH `$ORIGIN/../lib`。

## 使用方法

1. 进入 GitHub 仓库 → **Actions** → **Build Binary & Release** → **Run workflow**
2. 填写两个参数：
   - **redis_version**：要编译的 Redis 版本号（如 `7.4.1`）
   - **glib_version**：`2.28`（默认）或 `2.17`
3. 运行完成后，到 Release 页面（tag 为 `v7.4.1`）下载产物

同一个 Redis 版本可以**多次触发选不同 glib 版本**，tarball 文件名带 `.glibc2xx`
后缀不会冲突，产物会累积到同一个 Release 下，最终凑齐 4 个包：

```
redis-7.4.1-linux-amd64.glibc2.17.tar.gz
redis-7.4.1-linux-arm64.glibc2.17.tar.gz
redis-7.4.1-linux-amd64.glibc2.28.tar.gz
redis-7.4.1-linux-arm64.glibc2.28.tar.gz
```

### CI 流水线

- `compile-amd64`：`ubuntu-latest` 原生编译
- `compile-arm64`：`ubuntu-24.04-arm` **原生 arm64 runner**（免费，不走 QEMU 模拟，快且稳）
- `release`：合并两架构 tarball + 生成 sha256 校验，发到 Release tag `v<版本>`
- 基础镜像不推外部 registry，直接在 runner 本地构建，用 buildx 的 **gha 缓存**加速
  （第二次构建基础镜像层直接命中缓存，秒过）

## 本地构建（可选）

需要本地安装 Docker 并启用 buildx（在仓库根目录执行）：

```bash
VERSION=7.4.1
GLIB=2.28
ARCH=amd64   # 与本机架构一致

# 1. 构建基础镜像
docker buildx build --load \
  --build-arg TARGETARCH=${ARCH} \
  -t redis-binary:base-glib-${GLIB} \
  -f base/Dockerfile-glib${GLIB} .

# 2. 构建编译镜像并提取产物
docker buildx build --load \
  --build-arg BASE_SYSTEM_VERSION=redis-binary:base-glib-${GLIB} \
  --build-arg REDIS_VERSION=${VERSION} \
  --build-arg GLIBC_VERSION=${GLIB} \
  --build-arg TARGETARCH=${ARCH} \
  -t redis-binary-build:${VERSION}-glib${GLIB}-${ARCH} \
  -f build/Dockerfile build/

# 3. 提取产物
docker create --name redis-extract redis-binary-build:${VERSION}-glib${GLIB}-${ARCH} /bin/true
mkdir -p output && docker cp redis-extract:/root/output/. output/
docker rm -f redis-extract
```

国内网络可给第 1 步加 `--build-arg ZONE=cn`（yum 源走南大镜像）。

## 安装示例

```bash
tar -xzf redis-7.4.1-linux-amd64.glibc2.28.tar.gz -C /usr/local/
export PATH=/usr/local/redis-7.4.1-linux-amd64/bin:$PATH
redis-server --version
redis-cli --version
```
