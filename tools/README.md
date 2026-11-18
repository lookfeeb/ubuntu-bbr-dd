# 维护工具

用户只运行根目录 `bbr.sh` / `dd.sh`；以下源码在发布前嵌入，服务器没有额外 Python 文件依赖。

交互菜单选定操作及必要参数后直接执行，仅 DD 重启保留确认。`test_menus.py` 使用真实 PTY 和隔离操作模拟，覆盖直接执行、任务成功/失败后返回、参数重置、强制退出及 DD 重启确认；测试不会安装软件或重启主机。

| 文件 | 用途 |
| --- | --- |
| `sync_embedded.py` | 同步维护源到两个单文件入口 |
| `kernel_patch.py` | 验证并应用固定 Google TCP 补丁 |
| `wan_recovery.py` | 生成和集成 Guard7 R2；保留 R1 热路径优化，增加实验性带宽骤降临时限速 |
| `dd_patch.py` | 固定重装引擎补丁、资源封装、最新 Ubuntu 日期快照选择与签名清单验证 |
| `dd_disk.sh` | 主机及安装环境共用的唯一目标盘选择、容量和 SERIAL/WWN 复核 |
| `recovery_smoke.py` | 实际内核包无盘启动、Guard 选择与旧算法缺失检查 |
| `package_recovery.py` | 检查本地 Guard7 R2 包及完整来宾验收证据，生成对应源码和发布清单；历史包使用对应 tag 工具 |
| `host_helpers.inc` | 共用主机检查、操作锁、HTTPS 校验下载和续传 |
| `release_helpers.inc` | 启动时解析本项目最新正式 Release，同 tag 校验脚本并切换运行；支持显式离线模式 |
| `cloud_helpers.inc` / `menu_helpers.inc` | 网卡与云识别、中文交互与失败处理 |
| `nginx_helpers.inc` | Nginx 安装、swap 及恢复 |
| `app_helpers.inc` / `app_payload.py` | 3X-UI / OpenList 官方最新稳定版查询与校验、初始化、服务与失败回退、私有凭据及实际登录验证 |
| `nginx_build.inc` / `nginx_package.py` | 共享源码构建、缓存和受限归档校验；发布前嵌入 bbr.sh |
| `build_nginx.sh` | 本地生成 Ubuntu 24.04 amd64 Nginx 预编译包及对应源码 |
| `nginx_vm.py` / `nginx_probe.py` | QEMU 来宾安装回退和实际 HTTP/2、HTTP/3、Brotli 验收 |
| `dd_resources.sh` / `dd_runtime.sh` / `dd_packages.sh` | DD 安装环境资源、写盘流程和软件包缓存 |

`google-bbr3.patch` 保留上游来源；`ubuntu-cloudimage-keyring.gpg` 是 Ubuntu 公开验签密钥。

## 修改与验证

在 Linux 开发环境安装 Python 3、Bash、C 编译器、BusyBox、GnuPG 和 ShellCheck。DD 回归使用固定上游 tar.gz，下载与 SHA-256 见 `.github/workflows/check.yml`。

```bash
python3 -B tools/sync_embedded.py
bash -n bbr.sh && bash -n dd.sh
shellcheck bbr.sh dd.sh tools/dd_resources.sh tools/dd_disk.sh tools/dd_runtime.sh tools/dd_packages.sh
python3 -B -m unittest discover -s tests -v
sha256sum bbr.sh dd.sh > SHA256SUMS
```

修改共享代码时编辑维护源，再同步根脚本；CI 验证同步一致。回归覆盖真实 C 边界与差分、菜单异常、下载中断、配置回滚、DD 清盘及验签门槛。测试仅使用隔离文件或来宾，不修改开发主机的引导和磁盘。

`test_apps.py` 覆盖最新 Release 解析、预发布/来源/校验异常、版本冻结、压缩包路径与架构、端口冲突、凭据权限、已有安装保护、失败撤回和当前信息读取。首次安装只查询一次官方 `releases/latest`，从同一响应确定具体 tag、完整架构包及资产 `digest` 中的 SHA-256；已有安装不查询或自动升级。适配更新时需验证 3X-UI 的 CSRF 登录以及 OpenList 的 `OPENLIST_ADMIN_PASSWORD` 首次初始化；仅进程启动不算验收通过。Python 维护源嵌入 `bbr.sh`，服务器只需下载单文件入口。

`test_hotpath_equivalence.py` 将 Guard7 热路径与冻结 R5 oracle 对比，覆盖返回值、socket 状态、时钟推进和回绕；共享 helper 固定散列，旧实验使用的输入文件保持不变。

`test_bbr_install.py` 对实际 BBR 安装函数做路径重定向和命令模拟，验证回退启动项、APT 禁止删除、配置事务、同版本重装及中断恢复。流程和恢复边界见 [BBR 安装与恢复](../docs/bbr-install.md)。

`test_bbr_cleanup.py` 验证启动后只保留当前 Guard7：清理原回退内核、无 pending / rollback 时手动运行、APT 连带删除保护、失败标记与重试、GRUB 和启动链接收尾。来宾验收在清理前完成实际旧内核回退，随后清理其他内核，再做第四次独立启动以检查单内核启动及重复清理。

`test_dd_identity.py` 使用实际补丁选盘/分区函数和文件模拟的硬件命令，覆盖克隆盘、设备改名、缓存、探测失败及清盘前再检查。`test_dd_snapshot.py` 使用模拟 HTTP 和真实 GPG 签名，覆盖发布切换、日期目录缺失、异常重定向、签名/条目/大小失败；不下载完整镜像。

每个正式 Release 必须同时上传 `bbr.sh`、`dd.sh`、固定内核 image / headers、对应源码和验收证据，以及完整 `SHA256SUMS`；`package_recovery.py` 会将内核和两个脚本一并纳入打包和清单。脚本使用同 tag 的内核资产，不能依赖准备删除的旧 Release；复用包时复制并核对整组产物和对应源码。自动更新只读取这些正式发布资源，不读取 main，也不自动递增内部依赖。开发版或固定历史版本的交互测试应设置 `BBR_DD_AUTO_UPDATE=0`；发布更新回归通过离线模拟覆盖版本切换、清单异常、下载失败、递归保护及子进程失败。

内核发布还需要 [完整构建、包启动及安装验证](../docs/recovery-build.md)。

这些 Python / Shell 维护源和回归均有实际调用，不能按扩展名清理。已结束任务的临时脚本及阶段性文档归档后移出工作区，原始日志、软件包、验收记录和测试依赖 `reinstall-8ac9db68.tar.gz` 保留。开发资料包内附原路径和逐文件 SHA-256 清单；历史文档还可通过固定 Git 提交查阅。运行回归时可设置 `PYTHONDONTWRITEBYTECODE=1`，避免生成 `__pycache__`。

`build_release.sh`、`release/config-amd64` 和 `release_vm.py` 负责本地正式构建及隔离来宾验收，`release/guest.sh` 只在来宾运行。构建器支持独立复制旧树以复用未改变的编译产物，并重新校验和覆盖源文件。全部检查通过后上传 GitHub Release；Actions 仅保留代码回归，不编译内核或自动发布。
