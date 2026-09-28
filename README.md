# OpenWrt_DockerBuild

在 Docker 容器里编译 OpenWrt x86_64，产出**可直接 `docker compose` 部署的 OpenWrt 系统镜像**，
同时保留原有的刷机固件（`.img.gz`）。

- 编译环境、编译过程、部署形态全部容器化
- 保留原 `build-openwrt.sh` 的全部功能：插件清单、LuCI 中文、Argon 主题、
  AdGuardHome / MosDNS / OpenClash、LAN 地址 `192.168.31.254`、
  nftables 自定义规则页等
- 固件内**不含** Docker（已移除 dockerd / Dockerman）：这台 OpenWrt 本身就跑在
  Docker 里，容器里再套一层 Docker 只会徒增故障点
- GitHub Actions 自动构建，**版本号没变就跳过**，变更时才重新编译并推送 Docker Hub

---

## 目录结构

```
.
├── VERSION                      版本号，改它才会触发重新构建
├── build-openwrt.sh             原脚本（保留，宿主机直接编译用）
├── build-openwrt-docker.sh      新脚本：Docker 编排 + 容器内编译
├── docker/
│   ├── Dockerfile.build         编译环境镜像（只装依赖）
│   ├── Dockerfile.image         产物镜像（OpenWrt rootfs，FROM scratch）
│   ├── entrypoint.sh            容器内把环境变量刷进 UCI，再 exec /sbin/init
│   └── init-volumes.sh          可选：起容器前预先导出默认配置到 ./data
├── docker-compose.yml           部署 OpenWrt 容器（含 environment 与持久化挂载）
├── .env.example                 部署参数模板
└── data/                        运行时生成，持久化数据（已 gitignore）
└── .github/workflows/
    └── build-openwrt.yml        自动构建工作流
```

编译过程中会产生两个目录，已在 `.gitignore` 中排除：

| 目录 | 内容 |
| --- | --- |
| `work/` | OpenWrt 源码、feeds、`dl/` 源码包、ccache（复用后重新编译很快） |
| `output/` | 固件产物（`.img.gz`、`rootfs.tar.gz` 等） |

> ccache 的实际落点是 `work/openwrt/.ccache`，不是 `work/.ccache`。
> 这是 OpenWrt `rules.mk` 里 `$(TOPDIR)/.ccache` 决定的（`TOPDIR` = 源码根目录），
> 脚本和 workflow 都按这个路径来，别改。

---

## 快速开始

### 1. 自动构建（推荐）

推送到 `main` 就会自动触发（`docker/`、脚本、`VERSION` 等改动都算）。
另外也支持打 tag（`git tag v1.0.1 && git push origin v1.0.1`）或
在 Actions 页面手动 Run workflow。

**想重新构建固件，改 `VERSION` 里的版本号再推送即可** —— 版本号没变的话
闸门会直接跳过（秒级结束，不烧 Actions 时长）。

工作流做的事：

1. 读版本号，查 Docker Hub 上有没有 `dreamstation625/openwrt:<版本号>`
   - **有** → 直接结束，不浪费 Actions 时长
   - **没有** → 继续
2. 构建编译环境镜像（依赖只装一次，之后走 GHA 层缓存，几秒钟）
3. 在容器内编译 OpenWrt（`dl/` 源码包 + ccache 走 actions/cache）
4. 打包成 OpenWrt 系统镜像，推送到 Docker Hub
5. 刷机固件上传到 Artifact，打 tag 时同时发布 GitHub Release

> 需要 `force_rebuild` 时，手动触发 workflow 并勾选该选项。

### 2. 本地构建

```bash
# 完整流程：编译 + 打包镜像
./build-openwrt-docker.sh --package-image

# 编译 + 打包 + 推送 Docker Hub（需先 docker login）
./build-openwrt-docker.sh --push

# 只想刷机固件，不用打包镜像
./build-openwrt-docker.sh

# 已经有产物了，只想重新打包镜像
./build-openwrt-docker.sh --package-only --push

# 完全不用 Docker，直接在 Linux 宿主机上编译（等价原脚本）
./build-openwrt-docker.sh --no-docker
```

编译线程数默认等于当前 CPU 核心数，脚本不做任何按比例的换算。需要手动指定时用环境变量：

```bash
./build-openwrt-docker.sh                      # 用满 CPU 核心数（默认）
BUILD_THREADS=2 ./build-openwrt-docker.sh      # 指定 2 线程
BUILD_THREADS=1 ./build-openwrt-docker.sh      # 单线程（排查编译错误用）
```

`./build-openwrt-docker.sh --help` 查看全部参数。

### 3. 部署到 Docker

```bash
cp .env.example .env
vi .env          # 填 LAN_PARENT_IFACE（宿主机真实网卡名）、镜像 tag、DATA_DIR

./docker/init-volumes.sh   # 可选：预先把默认配置导出到 ./data，方便查看和备份
docker compose up -d
```

持久化数据在 `./data`（`.env` 里 `DATA_DIR` 可改），备份就是整目录打包。

然后浏览器打开 `http://192.168.31.254`，默认账号 `root` / `root`。

---

## 网络方案：为什么推荐 macvlan

宿主机执行 `ip -br link` 查网卡名，填进 `.env` 的 `LAN_PARENT_IFACE`。

**推荐 macvlan**：容器在局域网里就是一台独立设备，固定拿到 `192.168.31.254`，
和固件里配的 LAN 地址一致，也不占用宿主机的 80 / 443 / 53 / 67 端口。

**不推荐 host 网络**：容器里的 `netifd` + `firewall4` 会直接接管宿主机网络栈 ——
会把 `192.168.31.254` 配到宿主机网卡上，还会抢占 80/53/67 端口，很可能直接把宿主机
网络搞挂。

几个注意事项：

- macvlan 需要有线网卡，**Wi-Fi 一般不支持**
- 宿主机默认**访问不到** macvlan 容器（这是 macvlan 的固有行为）。
  需要在宿主机上再建一个同网段的 macvlan 子接口：

  ```bash
  sudo ip link add mac0 link eth0 type macvlan mode bridge
  sudo ip addr add 192.168.31.253/24 dev mac0
  sudo ip link set mac0 up
  ```

- 需要容器重建后仍保留 LuCI 改动时，打开 `docker-compose.yml` 里注释掉的
  `volumes` 段。注意卷一旦创建，镜像里新的默认配置不会自动覆盖进去。

---

## 在 PVE 虚拟机里的 NAS 上部署（群晖 / 飞牛）

### 结论

**VM + VirtIO 网卡 → macvlan 可用。**

macvlan 的内核支持由**跑 Docker 的那台机器（NAS 自己）**提供，PVE 不需要为 macvlan
做任何配置 —— 对它来说，容器发出的只是源 MAC 不同的普通以太网帧。

PVE 侧只要别把这些帧当成 MAC 欺骗丢掉就行。

### PVE 检查清单

| 项 | 要求 | 不这么做会怎样 |
| --- | --- | --- |
| 网卡型号 | **VirtIO**（半虚拟化） | 用 SR-IOV 直通的 VF 上**建不了 macvlan**，直接报错 |
| VM 网卡防火墙 | **取消勾选** | PVE 防火墙的 MAC filter 拦截虚拟 MAC，表现为"容器起来了但 ping 不通网关" |
| 桥类型 | 默认 Linux bridge（`vmbr0`） | 用 OVS 时要另外确认未知 MAC 能泛洪 |

关防火墙：PVE → 选中 NAS 虚拟机 → Hardware → 网卡 → 去掉 **Firewall** 勾选。

### 群晖 DSM

**网卡名是第一个坑。** 群晖如果开了 Open vSwitch（多网卡聚合时常开），网卡名是
`ovs_eth0` 而不是 `eth0`。SSH 进群晖确认：

```bash
ip -br link
```

DSM 7 的 Container Manager（原 Docker 套件）图形界面不一定给 macvlan 的创建入口，
建议命令行建：

```bash
docker network create -d macvlan \
  --subnet=192.168.31.0/24 \
  --gateway=192.168.31.1 \
  -o parent=eth0 \
  openwrt-lan
```

然后把 `docker-compose.yml` 里 `networks.lan` 改成引用这个外部网络
（文件里已写好注释掉的 `external: true`）。或者不用 compose，直接跑：

```bash
docker run -d --name openwrt --restart unless-stopped \
  --network openwrt-lan --ip 192.168.31.254 \
  --cap-add NET_ADMIN --cap-add NET_RAW \
  --sysctl net.ipv4.ip_forward=1 \
  dreamstation625/openwrt:1.0.2
```

**群晖自己访问不了 `192.168.31.254`**（macvlan 固有行为），要加子接口：

```bash
ip link add mac0 link eth0 type macvlan mode bridge
ip addr add 192.168.31.253/24 dev mac0
ip link set mac0 up
```

群晖重启会丢，用「控制面板 → 任务计划 → 新增 → 触发的任务 → 开机」写进去。

### 飞牛 OS（FnOS）

基于 Debian，是原生 Docker，`ip -br link` 看网卡名（一般是 `eth0` 或 `ens18`），
填进 `.env` 后直接 `docker compose up -d` 就行，没有群晖那些坑。

### 先验证链路再部署

在 NAS 上跑一遍，通了再起容器：

```bash
lsmod | grep macvlan || modprobe macvlan
ip link add mv-test link eth0 type macvlan mode bridge
ip link set mv-test up
ip addr add 192.168.31.99/24 dev mv-test
ping -c 3 192.168.31.1      # 通 → 链路 OK
ip link del mv-test
```

不通就按上面的 PVE 检查清单逐项排查，90% 是 VM 网卡的 Firewall 没关。

### 备选：既然有 PVE，也可以不用 Docker

把 OpenWrt 直接跑成 PVE 里的独立 VM / LXC（VirtIO 网卡桥接 `vmbr0`）会省掉
macvlan 这一层，也不用跟 NAS 耦合（NAS 挂了旁路由不受影响）。产物里的
`rootfs.tar.gz` 可以直接给 LXC 导入，`*.img.gz` 可以转成磁盘给 VM 用。

---

## 容器部署参数（environment 覆写）

`docker-compose.yml` 里的 `environment` **不是 OpenWrt 自己读的** —— 镜像的 CMD 是
`/sbin/init`（procd），它不会去理会 Docker 注入的环境变量。

所以镜像里加了一层 `/usr/bin/openwrt-entrypoint.sh`：把环境变量刷进 UCI，
然后 `exec /sbin/init`。没有它，改 LAN IP 只能重新编译固件。

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `OPENWRT_APPLY_ENV` | `auto` | 生效时机，见下 |
| `OPENWRT_HOSTNAME` | `OpenWrt` | 主机名 |
| `OPENWRT_TIMEZONE` / `OPENWRT_ZONENAME` | `CST-8` / `Asia/Shanghai` | 时区 |
| `LUCI_THEME` / `LUCI_LANG` | `argon` / `zh-cn` | LuCI 主题与语言 |
| `LAN_IP` / `LAN_NETMASK` / `LAN_GATEWAY` | `192.168.31.254` 等 | LAN 地址 |
| `LAN_DNS` | `223.5.5.5 119.29.29.29` | 多个 DNS 用空格分隔 |
| `ROOT_PASSWORD` | `root` | root 密码 |
| `OPENWRT_SEED_AUTO` | `1` | 挂载目录为空时是否自动用镜像默认配置初始化，`0` 关闭 |
| `OPENWRT_SEED_DIRS` | 见 compose | 需要初始化的目录列表（空格分隔），一般用默认值 |

**生效时机**（`OPENWRT_APPLY_ENV`）：

| 值 | 行为 |
| --- | --- |
| `auto`（默认） | 只在首次启动应用一次，之后以 LuCI 里的改动为准 |
| `always` | 每次启动都应用，compose 里写什么就是什么 |
| `never` | 完全不应用，交给 LuCI |

> 注意 `auto` 的含义：改了 `.env` 里的 `LAN_IP` 再重启**不会生效**（配置卷里已经有值了）。
> 想让配置文件完全说了算，就设 `OPENWRT_APPLY_ENV=always`；
> 代价是 LuCI 里改这几项会被覆盖回去。
>
> **例外**：`ROOT_PASSWORD` 每次启动都设置。`/etc/shadow` 不在持久化卷里，
> 容器重建后会回到镜像默认值，不重设就用改过的密码登不进去。

---

## 数据持久化

插件配置全靠这些挂载，**不挂的话容器一重建就全没了**。

用的是 **bind mount**，全部落在当前目录下的 `data/`（可用 `.env` 的
`DATA_DIR` 改到别处，例如群晖的 `/volume1/docker/openwrt-data`）：

| 宿主机目录 | 容器路径 | 内容 |
| --- | --- | --- |
| `data/config` | `/etc/config` | ★ 核心。网络、防火墙、DHCP、MosDNS、AdGuardHome、OpenClash 等几乎所有 UCI 配置 |
| `data/openclash` | `/etc/openclash` | OpenClash 配置、订阅、规则集（体积大，不持久化每次都要重新下载） |
| `data/adguardhome` | `/etc/adguardhome` | AdGuard Home 配置文件 `adguardhome.yaml` |
| `data/adguardhome-data` | `/var/lib/adguardhome` | AdGuard Home 过滤规则、查询日志、统计数据库（**必须挂**，见下） |
| `data/mosdns` | `/etc/mosdns` | MosDNS 分流规则与自定义配置 |
| `data/nftables.d` | `/usr/share/nftables.d` | LuCI 防火墙自定义规则页写的 nftables 片段 |
| `data/root` | `/root` | root 家目录（部分插件会往里写状态、SSH key） |
| `data/log` | `/var/log` | 日志（注意见下方说明） |

> OpenWrt 里 `/var` 是指向 `/tmp` 的符号链接，而 `/tmp` 是 tmpfs，
> 系统日志默认仍在内存里、重启即丢。要真正落盘，在 LuCI
> 「系统 → 系统日志」里把输出路径改到持久化目录。
>
> 同理，AdGuard Home 的运行数据默认落在 `/var/lib/adguardhome`（官方
> `adguardhome` 包的位置），也在 tmpfs 里。不挂 `data/adguardhome-data`
> 的话，**每次容器重启过滤规则和统计数据都会重建**。

### bind mount 的空目录问题（已内置兜底）

bind mount 不像命名卷那样会自动把镜像里的初始内容带出来：
**宿主机目录为空时，挂上去会把容器内目录直接"盖"成空的**，
`/etc/config` 一空，UCI 读不到配置，OpenWrt 起不来也进不去 LuCI。

镜像已经处理了这件事：构建时把各目录的初始内容备份到
`/usr/share/openwrt-defaults`，容器启动的 entrypoint 检测到挂载目录为空
就自动恢复。**目录非空（说明你已经在用）则一律不动，绝不覆盖已有配置。**

所以直接 `docker compose up -d` 就行。想在起容器前先看到默认配置：

```bash
./docker/init-volumes.sh     # 幂等，已有内容不会覆盖
```

想关掉自动初始化（比如要自己 `docker cp` 进来）：设 `OPENWRT_SEED_AUTO=0`。

### 权限

容器内以 root 运行，宿主机上这些文件属主也是 root。
备份/编辑请用 root 或 sudo。

### 追加其他插件目录

如果发现某个插件的配置还是丢了，往 `docker-compose.yml` 的 `volumes` 里
照格式加一行即可（文件里已留好注释）：

```yaml
      - ${DATA_DIR:-./data}/ddns-go:/etc/ddns-go
      - ${DATA_DIR:-./data}/v2ray:/etc/v2ray
```

加完 `docker compose up -d` 重建容器生效（bind mount 变动需要重建）。

### 备份与恢复

备份就是整个目录打包拷走：

```bash
# 备份
docker compose down
tar czf openwrt-data-$(date +%F).tar.gz -C data .
docker compose up -d

# 恢复：停容器 → 解包覆盖 → 启动
docker compose down
tar xzf openwrt-data-2026-09-27.tar.gz -C data
docker compose up -d
```

### 升级镜像时

`data/` 会保留旧配置，**新镜像里的默认配置不会自动覆盖进来**（这是故意的）。
升级后若行为异常，备份后清空对应子目录重启，entrypoint 会重新用新镜像的
默认值初始化。

---

## 版本号机制

`VERSION` 文件是唯一的版本来源，它同时决定：

- Docker 镜像 tag：`dreamstation625/openwrt:<VERSION>`（同时打 `latest`）
- 固件里的 `DISTRIB_RELEASE`（`/etc/openwrt_release`）
- `/etc/openwrt-build-version` 文件内容

**改了 `VERSION` 才会重新构建镜像**；没改就复用 Docker Hub 上已有的镜像，工作流秒级结束。

想更新上游 OpenWrt 源码或调整插件清单，同样是改 `VERSION` 后触发构建。

---

## 仓库需要配置的环境变量

仓库 `Settings → Environments` 里建一个名为 **`DOCKERHUB`** 的环境
（工作流里写死的 `environment: DOCKERHUB`，改环境名就要同步改 `.github/workflows/build-openwrt.yml`）：

| 类型 | 名称 | 值 |
| --- | --- | --- |
| Variable | `DOCKERHUB_USERNAME` | `dreamstation625` |
| Secret | `DOCKERHUB_TOKEN` | Docker Hub Access Token（需 Read & Write 权限） |

> Token 在 Docker Hub `Account Settings → Personal Access Tokens` 生成，
> 权限勾 **Read & Write**（只读没法 push）。用户名是明文变量即可，不算敏感信息。
>
> 两个值缺任意一个，workflow 会在第一步「解析版本号并检查 Docker Hub」直接报错退出，
> 不会等到登录步骤才失败。

---

## 可用环境变量覆盖

脚本里所有固定值都可以用环境变量覆盖，不用改代码：

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `OPENWRT_VERSION` | `VERSION` 文件 | 版本号 |
| `LAN_IP` | `192.168.31.254` | 路由器 LAN 地址 |
| `LAN_NETMASK` | `255.255.255.0` | 子网掩码 |
| `LAN_GATEWAY` | `192.168.31.1` | 上游网关 |
| `LAN_DNS1` / `LAN_DNS2` | `223.5.5.5` / `119.29.29.29` | DNS |
| `ROOT_PASSWORD` | `root` | root 密码 |
| `BRANCH` | `openwrt-25.12` | OpenWrt 分支 |
| `BUILD_THREADS` | CPU 核心数 | 编译线程数，留空即自动取 `nproc` |
| `ROOTFS_PARTSIZE` | `2048` | 根分区大小（MiB），决定固件 rootfs 分区容量 |
| `IMAGE_NAMESPACE` / `IMAGE_NAME` | `dreamstation625` / `openwrt` | 镜像仓库 |
| `CCACHE_MAXSIZE` | `5G` | ccache 上限 |
| `LOG_TAIL_LINES` | CI `400` / 本地 `120` | 编译失败时回填的日志行数 |

改根分区大小不用动脚本：

```bash
ROOTFS_PARTSIZE=4096 ./build-openwrt-docker.sh
```

---

## GitHub Actions 适配说明

脚本检测到 `CI=true` 或 `GITHUB_ACTIONS=true` 会自动进入 CI 模式，行为和本地不同：

| 项 | 本地 | CI |
| --- | --- | --- |
| make 输出 | 实时 `tee` 到屏幕 | 写入 `work/openwrt/build-logs/*.log`，前台只打分钟级进度 |
| Actions 日志 | — | 各阶段用 `::group::` 折叠，失败时输出 `::error::` 注解 |
| 失败排查 | 屏幕直接看 | 日志尾部回填（400 行）+ 编译日志作为 Artifact 上传 |
| 产物摘要 | — | 生成 `output/build-summary.md`，workflow 追加到 Summary 页 |

这么做的原因：OpenWrt `V=s` 全量编译有几十万行输出，直接打到 Actions 日志会被限流
甚至截断，真正报错反而被冲掉。

**关键点**：真正跑 `make` 的是容器，所以 `CI` 标识会通过 `docker run -e` 透传进容器，
否则容器里不会走静默逻辑。

CI 里不写死编译线程数：脚本直接取 runner 的 CPU 核心数，runner 给几核就用几核。
需要调整时在 workflow 的编译步骤里加 `BUILD_THREADS` 环境变量即可。

---

## 常见问题

**Q：镜像怎么这么大？**
编译环境镜像（`Dockerfile.build`）装了 clang / ocaml / java 等一整套交叉编译依赖，
约 2GB。它不进 Docker Hub，只在本地和 CI 缓存里。推送到 Docker Hub 的是体积小得多的
OpenWrt 系统镜像。

**Q：为什么镜像里没有 Docker / Dockerman？**
原脚本的插件清单里有 `docker` + `dockerd` + `luci-app-dockerman`，本 Docker 版已将其移除。
原因：这台 OpenWrt 本身就跑在 Docker 里，容器里再跑 Docker（DinD）需要额外挂 cgroup
并开 privileged，默认不可用，而且会给防火墙/网络栈带来一堆干扰。
如果你需要在 OpenWrt 里跑容器，请改回 `build-openwrt.sh`（宿主机直编版，仍保留这些插件）
并刷到物理机上。

**Q：容器模式下的网络配置会打架吗？**
固件默认是 `br-lan` 桥接 `eth0`。容器里 `eth0` 已经是 macvlan 接口，再套一层 bridge
会不通，所以网络适配放在 `/usr/bin/openwrt-entrypoint.sh` 里：
它在 `/sbin/init` **之前**跑，检测到 `/.dockerenv` 时把 LAN 直连 `eth0` 并删除
`br-lan` 设备段，IP 仍然是 `192.168.31.254`。刷到物理机上则保持原来的 `br-lan` 配置。

**Q：重新构建真的很慢怎么办？**
正常情况只需要复用 Docker Hub 上已有的镜像，不触发编译。
确实需要重编时，`work/` 目录（源码 + `dl/` + ccache）会保留，第二次编译比第一次快很多。
CI 上 `dl/` 和 ccache 走 actions/cache，注意仓库缓存总量上限 10GB
（`dl` 用固定 key 写一次就够，`ccache` 每次构建都会产生一个新条目，
超限时 GitHub 按 LRU 淘汰最旧的那份，所以缓存池里始终保留着最新的几轮 ccache）。

**Q：CI 编译超时了，为什么会连缓存和日志一起丢？**
因为 job 级的 `timeout-minutes` 触发后 GitHub 会取消**整个作业**，后续步骤一个都不执行，
`actions/cache` 的保存和日志上传自然都跑不到，于是下次还是纯冷编译 —— 死循环。
现在编译步骤单独带了 `timeout-minutes: 270`（小于 job 的 350），超时时只是这一步失败，
作业继续往下走，`always()` 的保存缓存步骤就能把已经攒下的 `dl + ccache` 存住，
日志也会照常作为 Artifact 上传。
