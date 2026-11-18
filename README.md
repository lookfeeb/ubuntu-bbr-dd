# Ubuntu BBR / DD 一键工具

两个独立脚本，中文数字菜单，输入 `0` 退出：`bbr.sh` 管理实验性 Guard 内核、网络参数、Nginx，并安装 3X-UI / OpenList；`dd.sh` 重装 Ubuntu 24.04 / 26.04。

菜单按操作类型着色，终端内不重复显示颜色图例；`NO_COLOR=1`、`TERM=dumb` 或重定向输出时不使用 ANSI 颜色。状态页显示运行内核、平台、网卡地址与当前算法，安装时再显示对应平台的操作提示。

v3.3.13 精简 BBR / DD 菜单与状态页，DD 固定 root 密码登录、SSH 22，重启前显示实际用户名和密码。**Linux 7.3.5 + Guard7 R2** 与 Nginx 沿用 v3.3.12 已验收的相同包，核对原散列后随本版发布，本次没有重新编译或做整机安装验收。R2 仍属实验算法；延迟实验有收益，但完整性能门槛尚未通过，不保证吞吐提升或非劣。

改动范围和性能边界见 [Release 发布说明](https://github.com/lookfeeb/ubuntu-bbr-dd/releases/tag/v3.3.13)，详细研究报告及原始数据保留在开发资料包中。

Release 仅单独提供安装脚本、安装包、对应源码和必要校验清单；日志、验收报告、研究数据与补丁统一放在 [开发资料包](https://github.com/lookfeeb/ubuntu-bbr-dd/releases/download/v3.3.13/development-details-v3.3.13.tar.gz)。下文提到的 `kernel-validation.json` 等资料位于该包内，日常安装无需下载开发资料。

> [!IMPORTANT]
> ### AI 辅助开发的个人定制项目，按“现状”提供，不保证安装成功、性能提升或持续安全更新。

> [!CAUTION]
> ### DD 会清空目标系统盘；内核和网络改动可能导致无法启动或 SSH 失联。

> [!WARNING]
> ### 使用前备份数据并准备快照、串行控制台或救援方案。
>
> ### 使用风险自行承担；在适用法律允许的范围内，作者及维护者不承担由此产生的损失，也不承诺恢复或赔偿。

## 版本与启动

| 使用来源 | 实际内容 |
| --- | --- |
| v3.3.13 的 `bbr.sh` | BBR 3.3.13；精简菜单与状态页，安装时自动配置 Guard + fq；内核与 Nginx 包核验后复用 |
| v3.3.13 的 `dd.sh` | DD 2.4.9；系统选择子菜单、固定 root 密码登录与 SSH 22，重启前双色显示登录信息 |

下面的地址始终下载本项目最新正式 Release，无需手改版本号。需要 Bash、curl、sha256sum 和 CA 证书；普通用户先执行 `sudo -i`，服务器无需下载 `tools/`。

BBR：

```bash
curl -fsSLO https://github.com/lookfeeb/ubuntu-bbr-dd/releases/latest/download/bbr.sh && bash bbr.sh
```

DD：

```bash
curl -fsSLO https://github.com/lookfeeb/ubuntu-bbr-dd/releases/latest/download/dd.sh && bash dd.sh
```

Guard7 R2 内核与 Nginx 预编译包、对应源码、验收记录和 SHA-256 清单均见 [最新 Release](https://github.com/lookfeeb/ubuntu-bbr-dd/releases/latest)。Guard 和 Nginx 的预编译安装使用与脚本同 tag 的资产，不依赖旧 Release。同时需要重装和 BBR 时，先 DD，确认新系统和 SSH 可用后，再安装 BBR 内核。

支持自动更新的脚本启动时会检查最新 Release，确定一个具体 tag 后下载该版本的 `SHA256SUMS` 和对应脚本，校验通过才进入新版菜单；不会在运行中再次切换版本，也不覆盖原来的本地文件。检查失败会停止，不静默使用旧版。内核、Guard 算法、DD 引擎等内部依赖仍采用该 Release 已验证的版本，不追踪上游最新提交。

需要离线查看状态、取消重装或测试本地改动时，使用 `BBR_DD_AUTO_UPDATE=0 bash bbr.sh` 或 `BBR_DD_AUTO_UPDATE=0 bash dd.sh`。通过 `source` 加载函数不会联网；已经安装的内核健康检查服务继续运行安装时的版本。v3.3.7 及更早脚本没有自动检查功能，需要用上方地址重新下载一次包含此功能的新版。

## BBR

```text
1、安装 Guard7 R2（预编译 / 源码）
2、查看系统与算法状态
3、恢复原有网络参数
4、清理其他内核（仅保留当前 BBR）
5、安装 Nginx（预编译 / 源码）
6、安装 3X-UI 面板
7、安装 OpenList 网盘
8、查看应用登录信息
9、重启系统
0、退出
```

菜单 1 和菜单 5 各提供两种安装方式：`1` 下载预编译包，`2` 从源码编译。Guard 预编译支持 amd64，源码支持 amd64 / arm64；Nginx 预编译支持 Ubuntu 24.04 amd64，源码使用官网最新稳定版。

选项及必要参数选定后直接执行，不再显示“执行 / 仅预览”二次菜单。每项操作完成、取消或失败后都会返回主菜单，可以连续操作；各级菜单及参数输入均支持 `0` 退出，也可按 `Ctrl+C` / `Ctrl+D` 强制结束。失败会停止本次操作，不继续后续安装步骤。BBR 菜单 `9` 直接重启服务器并断开连接，只有 DD 菜单 `4` 保留重启确认。

安装要求 Ubuntu 24.04 / 26.04、systemd、GRUB，并关闭 Secure Boot；拒绝容器和 WSL。

| 安装方式 | 资源要求 |
| --- | --- |
| 预编译，amd64 | 至少 512 MiB 可用内存、2 GiB 可用磁盘、512 MiB 可用 `/boot` 空间 |
| 源码，amd64 / arm64 | 至少约 1.5 GiB 可用内存，内存与 swap 合计 4 GiB，30 GiB 构建空间，512 MiB 可用 `/boot` 空间 |

只编译 BBR 系列中的 `bbrguard`，保留 CUBIC / Reno。安装自动配置 Guard + fq，重启进入新内核后生效，无需手动启用。预编译包从与脚本同 tag 的 `SHA256SUMS` 读取唯一有效散列，再核对包内容、元数据和实际网卡、磁盘驱动；中断下载保留部分文件，校验完成才安装。

Guard7 R2 在 R1 热路径优化基础上，确认交付带宽下降且排队增长后临时限制 pacing/cwnd，模型收敛或排队消退时退出；保留 ECN、RTO 与 PROBE_RTT 的控制权，未纳入此前的 64 包补偿。骤降实验 p95 延迟约降低 66%，但原短窗吞吐退化约 10%，部分回归采集及同算法对照不合格，不能据此承诺普遍提速。正式包在本地 Linux / WSL 编译，在独立 Ubuntu 24.04 来宾完成安装、启动、SSH/HTTPS、headers 编译、旧内核回退和清理后启动才发布；具体记录见 Release 的 `kernel-validation.json`。构建身份与验证边界见 [构建说明](docs/recovery-build.md)。

本版本在安装前固定已验证的回退内核为默认启动项，并禁止 APT 为安装删除依赖包。新内核、驱动、initramfs、GRUB 和健康检查服务全部准备成功后才确认完成；中途失败会恢复启动项及本工具配置，保留已安装包和阶段记录供排查。重装正在运行的同版本内核时，必须另有已记录且检查通过的回退内核。

若安装被强制终止，菜单会阻止重启与清理旧内核；再次执行安装时先恢复未完成事务。恢复失败或备份缺失则停止，不能直接删除状态记录继续。此机制不回滚 APT/dpkg 软件包事务，也不保证断电或磁盘损坏后的恢复；详见 [BBR 安装与恢复](docs/bbr-install.md)。

安装不会自动重启。新内核首次启动前保留原内核，供安装失败时回退；启动约 3 分钟后，定时器检查当前 Guard7、image / headers、启动文件、驱动、SSH 和默认路由，再预演卸载其他内核。**清理完成后只保留正在运行的 BBR 内核及其模块、headers，原回退内核也会删除，不再保留备用内核。** APT 若要连带删除当前内核或非内核软件包，清理会停止。

菜单 4 可重复运行；已有安装即使没有待清理标记或回退记录，也可以通过新版菜单清理。成功后更新 GRUB 和启动链接、移除旧回退记录；中途失败会保留任务标记，菜单重启被阻止，修复原因后再执行菜单 4。只卸载软件包管理的内核，发现残留或手工安装的其他内核时报告未完成。本机检查不能代替外部 SSH 和业务验收。

手动启用入口已移除，安装时自动保存 Guard + fq 配置。菜单 3 恢复首次备份的网络参数，不卸载内核。默认 fq 设置不会强制重建现有网卡队列。测速和使用说明已从 BBR 菜单移除，操作说明保留在本文档。

### Nginx

菜单 5 → 1 下载本项目与脚本同 tag 的 Nginx 预编译包，通过 SHA-256、包内文件清单、系统版本和 ELF 架构检查后安装。首批目标为 Ubuntu 24.04 amd64；只安装运行依赖，不安装编译工具，不创建 swap，至少需要 512 MiB 可用磁盘。包内包含 HTTP/2、HTTP/3、Brotli、GeoIP2 和 stream，OpenSSL 静态链接。它使用该 Release 验证过的 Nginx 版本，不保证每天跟随官网更新。

菜单 5 → 2 保留官网最新 stable 的源码编译，验证 GPG 签名；OpenSSL 与第三方模块仍固定版本或提交。源码路径需要至少 8 GiB 可用磁盘，会创建永久 2 GiB swap：`/var/lib/bbr-nginx/swapfile`，失败也保留激活的 swap。已完成的构建按源码散列、构建规则、系统、架构、工具链和依赖版本校验复用；输入变化会重新编译。缓存位于 `/var/lib/bbr-nginx/cache`，不会因安装失败而删除。OpenSSL 跳过命令行工具和测试构建，并发按可用内存和 CPU 限制选择。

若对应 Release 缺少预编译包，预编译安装会停止并返回主菜单，可重新选择源码方式，不自动改为耗时编译。也可设置 `NGINX_PACKAGE_DIR=/绝对路径/资产目录` 使用自己本地构建、校验过的包；开发版同时设置 `BBR_DD_AUTO_UPDATE=0`。本地构建和隔离验收见 [Nginx 构建说明](docs/nginx-build.md)。

安装前备份配置、二进制、模块、数据库、安装记录和服务，保留已有站点配置与 GeoIP 数据库；配置检查或启动失败时尝试恢复。升级会短暂重启服务，域名、证书及防火墙仍需自行配置。自编译 OpenSSL 不随系统 OpenSSL 包自动升级，安全更新需要重新构建发布。恢复不撤销 APT 依赖安装，也不保证断电或 SIGKILL 后自动恢复。

### 3X-UI / OpenList

菜单 `6` 安装 [3X-UI](https://github.com/MHSanaei/3x-ui)，菜单 `7` 安装 [OpenList](https://github.com/OpenListTeam/OpenList)。选中对应菜单后自动下载官方二进制、校验 SHA-256 与架构、初始化管理员、生成随机密码与 HTTPS 自签证书、启用 systemd 开机启动，并验证实际 HTTPS 登录。支持本工具所接受的 Debian / Ubuntu amd64、arm64 主机，不依赖 Docker 或 Nginx。

**每次首次安装都自动查询相应官方仓库的最新稳定 Release**，无需手动修改应用版本号。查询成功后冻结本次版本、对应架构的发布包地址和官方 SHA-256，校验通过才安装；不使用预发布版，不在安装过程中切换版本。查询失败、缺少匹配包或有效 SHA-256 时停止并返回菜单，不回退到旧版。不会直接运行上游安装脚本。3X-UI 默认管理端口 `2053`，OpenList 默认 `5244`；占用时自动选取空闲端口，以安装结束显示的值为准。

安装后一次汇总访问地址、实际用户名、密码、端口、数据目录、服务管理和日志命令。凭据保存于 `/var/lib/bbr-apps/x-ui.json` 或 `/var/lib/bbr-apps/openlist.json`，目录权限 `700`、文件权限 `600`；菜单 `8` 可再次查看。已修改的密码无法从数据库反推出明文；旧初始密码未通过验证时不会显示为可用密码，也不会自动重置。

| 应用 | 程序目录 | 数据目录 | 服务 |
| --- | --- | --- | --- |
| 3X-UI | `/usr/local/x-ui` | `/etc/x-ui` | `x-ui.service` |
| OpenList | `/opt/openlist` | `/opt/openlist/data` | `openlist.service` |

自签证书会产生浏览器信任提示，可换成自己的正式证书。云防火墙需放行输出的 TCP 管理端口，NAT 主机还需端口映射；自动检测的出口 IP 不代表已验证公网可达。3X-UI 的代理入站及订阅、OpenList 的网盘授权与挂载需要登录后按自己的用途配置；首次安装不启用 3X-UI 订阅监听。

重复选择本工具已安装的应用会显示现有信息，不自动升级、不覆盖数据或重置密码；检测到外部安装则停止覆盖。安装记录保存实际版本、官方发布包地址及 SHA-256。普通失败和可捕获中断会撤回本次新增的服务与文件，并保存仅 root 可读的失败记录；APT 依赖保留，断电或 SIGKILL 后的残留不会自动覆盖。应用回归使用隔离目录和服务模拟；已验证 3X-UI v3.11.0 / OpenList v4.2.9 官方 amd64 二进制的初始化、HTTPS 和真实登录，未来上游版本仍以安装时实际验证结果为准，arm64 未做整机运行验收。

## DD 重装

```text
1、重装系统
2、查看系统与网卡状态
3、取消待执行重装
4、重启系统
0、退出
```

“重装系统”内选择 Ubuntu 24.04 或 26.04。平台与缓存自动判断，固定 root 密码登录、SSH 端口 22，重启后自动安装。

支持 Debian / Ubuntu 主机上的 amd64 / arm64 标准单系统盘；拒绝多盘根卷、iSCSI、容器及 Secure Boot。最低标称 512 MiB 内存；磁盘缓存至少需要 16 GiB 系统盘，实际还须通过镜像和安装空间检查。

本版本在准备、安装环境选盘和清盘前复核分区表 ID、容量及可用的 SERIAL/WWN；同 ID 克隆盘同时存在即停止，不按设备顺序选择。设备名变化时重新识别，旧选盘缓存不能跳过检查。未提供 SERIAL/WWN 的平台只能核对唯一 ID 和容量，无法区分所有替换磁盘。

每次准备自动查询所选 Ubuntu 版本的最新官方发布构建，再把本次镜像 URL、签名清单和大小固定到 `release-日期/` 快照。重启后仍使用这个快照，避免准备后官方更新 `release/` 导致镜像漂移；下次准备会重新查询最新构建。快照缺失或验证失败即停止。

选好 Ubuntu 版本后直接准备重装，显示唯一目标整盘、分区及清盘说明，再设置 root 密码；输入时不回显，留空生成随机密码。无需选择登录方式、SSH 端口、云平台、缓存或安装流程。自行放行 SSH 22；菜单 `4` 重启前再次显示登录信息，用户名为青色、密码为黄色，确认后才重启。非彩色终端显示纯文本。

| 缓存模式 | 清盘时机与限制 |
| --- | --- |
| RAM | 完整下载并验证镜像、计划内 Ubuntu 包后才清盘；原系统内存需达到镜像大小加约 2.25 GiB |
| 磁盘 | 先验签、检查网络和容量，再清盘建立缓存与 2 GiB swap；之后下载或校验失败无法还原原系统 |
| auto | 按实际内存选择上述模式；选择结果固定到安装环境 |

准备完成不会自行重启，保存登录信息后选菜单 4，再确认重启；也可取消重启并返回主菜单。自动安装会清盘、安装并启动新系统；首次重启前可用菜单 3 取消待执行重装。登录密码记录仅 root 可读，供再次打开脚本时显示；取消重装成功后删除。普通重启没有待执行重装时，不显示或猜测当前系统密码。

当前安装器记录阶段、退出码和首次写盘边界。同次启动中，清盘后失败会拒绝直接重跑，避免再次分区；查看 `/reinstall.log` 和 `/run/ubuntu-dd-install`，不要直接重启未完成的目标。磁盘缓存模式保留缓存分区和 swap，新系统挂载于 `/var/lib/ubuntu-dd/scratch`。完整验证链见 [DD 设计](docs/dd-hardening.md)。

## 平台条件与实测范围

驱动按 sysfs 实际设备检查，不按网卡名称猜测。DD 清除整盘，包括现有工具和自定义内核；云代理、OS Login 和网页 SSH 集成不自动恢复。

| 平台 | 使用条件 |
| --- | --- |
| GCP | 检查 gVNIC / VirtIO，关闭 Secure Boot，放行 SSH；DD 不恢复 Guest Agent / OS Login，准备快照和串行控制台 |
| AWS / Lightsail | 检查 ENA / Xen / VirtIO 与 NVMe；Lightsail 可手动标注，网页 SSH 不是独立救援控制台 |
| OCI | 镜像架构匹配，保留实际 VirtIO 等驱动，拒绝 iSCSI 和多盘根卷；核对 DHCP、NSG 与安全列表 |

官方资料：[GCP gVNIC](https://cloud.google.com/compute/docs/networking/using-gvnic)、[GCP Guest Environment](https://cloud.google.com/compute/docs/images/guest-environment)、[Lightsail 快照](https://docs.aws.amazon.com/lightsail/latest/userguide/understanding-snapshots-in-amazon-lightsail.html)、[OCI 自定义镜像](https://docs.oracle.com/en-us/iaas/Content/Compute/References/bringyourownimage.htm)。

2026-11-16 已有本地整机验收覆盖 Ubuntu 24.04 amd64、QEMU/KVM、2 GiB、VirtIO/BIOS：R5 实际包安装、首次启动、外部新建 SSH、出站 HTTPS、headers 模块编译，以及阻断新 SSH 后保留并启动旧内核、返回 R5，均通过。DD 磁盘模式全盘重装、SSH、swap 和第二次启动通过；此前运行时另有真实 loop 磁盘失败及重试验证。

2026-11-17 另完成 GCP `custom-1-1024`（1 核 / 1 GiB）、amd64、UEFI、gVNIC 实测：BBR 预编译安装、实际旧内核回退及返回 Guard 通过；Nginx 预编译安装约 14 秒，协议、配置保留及故障恢复通过；DD 本地修复版全盘重装 Ubuntu 24.04 / 26.04，外部 SSH、gVNIC、HTTPS、2 GiB swap 和后续重启通过。Nginx 26.04 预编译平台保护也通过。本轮 5 项兼容修复纳入 v3.3.10，详见 [历史实测报告](https://github.com/lookfeeb/ubuntu-bbr-dd/blob/923da13f3b12515c01e62b937e9af63d257f26ab/docs/gcp-validation-20261117.md)。

v3.3.13 的 336 项回归及 ShellCheck 通过，覆盖精简菜单、DD 实际密码回传与重启保护、R2 布局与控制路径、BBR 安装事务和本地包校验、DD 磁盘身份和资源校验故障，以及 3X-UI / OpenList 安装保护。此前官方 24.04/26.04 的 amd64/arm64 日期快照、签名清单及 HEAD 大小检查通过；元数据检查不等于 arm64 启动验收。

其他云平台、arm64、512 MiB 整机和 RAM 模式完整 DD 未在本轮重测；未做源码编译或公网吞吐压测，HTTP/3 在来宾内部验证。资源最低门槛不等于整机验收。

R5 针对小窗口发送节奏及单包探测分支一致性做了修正，保留排队、双包损失、ECN、RTO 和时效保护。本地 128 组恢复对照相对 R4：前 5 秒吞吐配对中位 +213.88%，低速时间减少 2.08 秒，整段 +2.66%（103/128 改善）。这不能代表公网普遍提速；原计时校验失败及采样复验情况见 [构建与验证说明](docs/recovery-build.md)。自定义内核不自动接收 Ubuntu 内核安全更新。

## 开发与维护

正式内核在本地 Linux / WSL 编译，并在隔离 QEMU 来宾完成安装、启动、SSH/HTTPS、headers 和回退验收，随后上传 GitHub Release。GitHub Actions 仅保留代码与脚本回归检查，不编译内核、不自动发版。服务器菜单 1 → 1 下载已验收的预编译包，菜单 1 → 2 保留自行编译入口。维护流程见 [构建说明](docs/recovery-build.md)。

- [维护源、同步与回归入口](tools/README.md)
- [Guard 构建、包检查与验收边界](docs/recovery-build.md)
- [DD 验证链、写盘及失败处理](docs/dd-hardening.md)
- [上游来源与许可证](THIRD_PARTY.md)

`tools/` 是单文件脚本的维护源和构建工具，`tests/` 是现用回归。已结束实验的临时脚本和旧版本 Shell 副本已归档并移除散落文件；日志、原始包、验收证据及当前 Release 资产快照保留在 `.cache/`，不随仓库发布。`docs/` 保留当前安装、构建和恢复说明，历史报告通过固定 Git 提交链接查阅。历史发版说明见 [GitHub Releases](https://github.com/lookfeeb/ubuntu-bbr-dd/releases)。
