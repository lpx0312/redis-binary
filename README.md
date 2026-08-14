# redis-binary

使用 GitHub Actions 编译 Redis 官方源码，产出 Linux `amd64` / `arm64` 两个架构的
二进制离线包（`.tar.gz`），并发布到 GitHub Release。

构建方式参考 [kubekey](https://github.com/kubesphere/kubekey) 的多架构流水线：
Docker 多阶段构建 + QEMU + buildx 跨平台编译 + 按架构命名产物 + 上传 Release。

## 产物

每次构建会产出以下文件（以 `7.4.1` 为例）：

| 文件 | 说明 |
| ---- | ---- |
| `redis-7.4.1-linux-amd64.tar.gz` | x86_64 二进制包 |
| `redis-7.4.1-linux-arm64.tar.gz` | aarch64 二进制包 |
| `redis-7.4.1.sha256sum.txt` | 校验文件 |

tar 包目录结构：

```
redis-7.4.1-linux-amd64/
└── bin/
    ├── redis-server
    ├── redis-cli
    ├── redis-benchmark
    ├── redis-sentinel
    ├── redis-check-aof
    └── redis-check-rdb
```

- 基础镜像：`debian:bookworm-slim`（glibc，兼容绝大多数 Linux 发行版）
- 编译选项：`BUILD_TLS=yes`（启用 TLS），默认 jemalloc
- 源码来源：`https://download.redis.io/releases/redis-<version>.tar.gz`

## 使用方法

### 方式一：手动触发（推荐）

1. 进入 GitHub 仓库 → **Actions** → **BuildRedis** → **Run workflow**
2. 填写要编译的 Redis 版本号（如 `7.4.1`）
3. 运行完成后，到 Release 页面（tag 为 `v7.4.1`）下载产物

### 方式二：推送 tag 触发

```bash
git tag v7.4.1
git push origin v7.4.1
```

tag 去掉 `v` 前缀后作为 Redis 版本号。

## 本地构建（可选）

需要本地安装 Docker 并启用 buildx：

```bash
VERSION=7.4.1
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --build-arg REDIS_VERSION=${VERSION} \
  -f build/dockerfile.redis \
  --output type=local,dest=./output \
  build
```

产物在 `./output/linux_amd64/` 和 `./output/linux_arm64/` 下。
