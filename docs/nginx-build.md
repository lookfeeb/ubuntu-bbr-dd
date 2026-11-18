# Nginx 本地构建与预编译安装

构建在本地 Linux / WSL 完成；GitHub 仅存放手动发布的产物。当前发布目标是 **Ubuntu 24.04 amd64**，不会把本机二进制标成通用于 Debian、Ubuntu 26.04 或 arm64 的包。其他平台使用菜单 5 → 2 源码编译。

## 构建

在 Ubuntu 24.04 amd64 准备依赖：

```bash
sudo apt-get update
sudo apt-get install --no-install-recommends build-essential cmake git curl ca-certificates perl pkg-config python3 gnupg libpcre2-dev zlib1g-dev libmaxminddb-dev
python3 -B tools/sync_embedded.py
bash tools/build_nginx.sh /var/tmp/local-nginx
cat /var/tmp/local-nginx/latest-assets
```

构建器不安装软件包，不创建 swap，不修改系统 Nginx，也不发布。每次在独立 `work.*` 目录保留日志；同一构建目录使用文件锁。先获取官网 stable 并验签，再按源码 SHA-256、构建函数、系统版本、架构、编译器、链接器和已安装依赖版本生成缓存身份。缓存命中时校验产物和对应源码散列，再解包复用；源码或构建输入变化时重新编译。失败工作目录和日志保留供诊断，完成缓存位于 `cache/`；其校验失败时停止，不静默使用损坏文件。

首次构建包括 OpenSSL 3.5.7、固定提交的 Brotli 和 GeoIP2。OpenSSL 使用 `no-apps no-tests`，不裁剪 TLS 算法；Brotli 仅构建编码器和 common 库。Nginx 保留 HTTP/2、HTTP/3、stream、Brotli 和 GeoIP2，使用通用 amd64 编译参数，不用 `-march=native`。并发按可用内存、CPU affinity 和 cgroup v2 限制估算；最低一个任务，不把 swap 当物理内存。缓存主要加速重复构建，不能用于推算首次构建或网络下载速度。

`latest-assets` 指向本次输出目录，其中有：

- `nginx-ubuntu-24.04-amd64.tar.gz`：Nginx、四个动态模块、mime.types、包内构建清单；无安装钩子。
- `nginx-ubuntu-24.04-amd64-sources.tar.gz`：对应 Nginx、OpenSSL 原始归档，以及模块源码和上游许可证。
- `nginx-ubuntu-24.04-amd64-build.json`：平台、Nginx 版本、构建身份和每个文件的大小与散列。
- `NGINX_SHA256SUMS`：上述资产的 SHA-256。

## 隔离验收

实际安装仅在 QEMU 来宾执行。本机需要 KVM / QEMU、cloud-image-utils、OpenSSH client；准备已经验证 Ubuntu 官方签名及散列的 Ubuntu 24.04 amd64 cloud image：

```bash
python3 -B tools/nginx_vm.py \
  --assets "$(cat /var/tmp/local-nginx/latest-assets)" \
  --base /绝对路径/ubuntu-24.04-cloud.img \
  --base-sha256 官方已验证的64位SHA256 \
  --out /var/tmp/nginx-validation-new
```

验收工具复核镜像散列、拒绝外部 backing/data file，创建独立 overlay；使用 1 GiB / 2 vCPU 来宾验证安装、无 gcc/无新 swap、HTTP/2、带证书校验的 HTTP/3、Brotli 解压一致性、GeoIP2、重装配置保留，以及注入服务启动失败后的原二进制和服务恢复。失败和成功日志都保存在 `evidence/`，结果绑定安装脚本与实际包散列。虚拟磁盘和 SSH 私钥仅在 `private/`，不得上传。

## 安装与发布

开发验证或内网分发可复制整套资产，再执行：

```bash
sudo env BBR_DD_AUTO_UPDATE=0 NGINX_PACKAGE_DIR=/绝对路径/assets bash bbr.sh
# 选择菜单 5 → 1 即开始安装
```

本地资产模式信任用户指定的本地清单，仍校验归档和内部文件。预编译安装需要系统已有 Python 3 和 curl（标准 Ubuntu cloud image 已提供），用于安装前校验。普通用户无需设置该变量；脚本使用自身版本对应的同一个 GitHub Release，读取 `NGINX_SHA256SUMS` 后下载包。缺包、重复散列、平台不符、文件损坏、链接或越界归档均停止，发生这些失败时不执行 APT 或替换现有 Nginx。

用户明确要求发版后，将运行包、对应源码和 `NGINX_SHA256SUMS` 单独上传到与新版脚本相同的 Release；构建信息和验收 `evidence/` 统一放入开发资料包，不再拆成多个附件。按项目发版规则更新脚本版本及根目录 `SHA256SUMS`，发布后实测下载入口与资产散列。v3.3.9 首次发布 Nginx 预编译包；v3.3.10 清理旧 Release 后，将未变更的 Guard7 内核包和对应源码也迁至同一 Release，两个安装入口均不依赖旧 Release。

预编译安装不会查询官网最新 Nginx；最新版是本项目最近一次验收并发布的构建。需要更新 upstream 时，本地重跑构建及来宾验收后再发布。OpenSSL 静态链接，也需要随新构建更新。已有第三方动态模块必须与新 Nginx 兼容，否则配置检查失败并尝试恢复；APT 安装的运行依赖不回滚，断电和 SIGKILL 不在自动恢复保证内。
