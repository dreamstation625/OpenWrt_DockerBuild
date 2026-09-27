# OpenWrt_DockerBuild

在 Docker 容器里编译 OpenWrt x86_64，产出**可直接 `docker compose` 部署的 OpenWrt 系统镜像**，
同时保留原有的刷机固件（`.img.gz`）。

- 编译环境、编译过程、部署形态全部容器化
- 保留原 `build-openwrt.sh` 的全部功能：插件清单、LuCI 中文、Argon 主题、
  AdGuardHome / MosDNS / OpenClash / Dockerman、LAN 地址 `192.168.31.254`、
  nftables 自定义规则页等
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
│   └── entrypoint.sh            容器内把环境变量刷进 UCI，再 exec /sbin/init
├── docker-compose.yml           部署 OpenWrt 容器（含 environment 与持久化卷）
├── .env.example                 部署参数模板
└── .github/workflows/
    └── build-openwrt.yml        自动构建工作流
```

编译过程中会产生两个目录，已在 `.gitignore` 中排除：

| 目录 | 内容 |
| --- | --- |
| `work/` | OpenWrt 源码、feeds、`dl/` 源码包、ccache（复用后重新编译很快） |
| `output/` | 固件产物（`.img.gz`、`rootfs.tar.gz` 等） |

---

## 快速开始

### 1. 自动构建（推荐）

改 `VERSION` 里的版本号 → 推送 → 手动触发 workflow（或打个 `v1.0.1` 的 tag）。

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

编译线程模式作为第一个参数：

```bash
./build-openwrt-docker.sh 0    # 自动，用满 CPU（默认）
./build-openwrt-docker.sh 1    # 2/3 线程
./build-openwrt-docker.sh 2    # 一半线程
./build-openwrt-docker.sh 3    # 单线程（排查编译错误用）
```

`./build-openwrt-docker.sh --help` 查看全部参数。

### 3. 部署到 Docker

```bash
cp .env.example .env
vi .env          # 填 LAN_PARENT_IFACE（宿主机真实网卡名）和镜像 tag
docker compose up -d
```

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
  dreamstation625/openwrt:1.0.0
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
| `DOCKER_DATA_ROOT` | `/opt/docker` | 容器内 Docker 数据目录 |

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

插件配置全靠这些卷，**不挂的话容器一重建就全没了**：

| 卷 | 容器路径 | 内容 |
| --- | --- | --- |
| `openwrt-config` | `/etc/config` | ★ 核心。网络、防火墙、DHCP、MosDNS、AdGuardHome、OpenClash、Dockerman 等几乎所有 UCI 配置 |
| `openwrt-openclash` | `/etc/openclash` | OpenClash 配置、订阅、规则集（体积大，不持久化每次都要重新下载） |
| `openwrt-nftables` | `/usr/share/nftables.d` | LuCI 防火墙自定义规则页写的 nftables 片段 |
| `openwrt-docker` | `/opt/docker` | 容器内 Docker 的数据目录 |
| `openwrt-log` | `/var/log` | 日志 |
| `openwrt-root` | `/root` | root 家目录（部分插件会往里写东西） |

### 为什么用命名卷而不是 `./data:/etc/config`

**命名卷首次创建时，Docker 会把镜像里该目录的初始内容复制进去**，所以是安全的。

**bind mount 到宿主机的空目录会直接把容器内目录"盖"成空的** ——
`/etc/config` 变空会导致 OpenWrt 启动异常。想用 bind mount 方便备份的话，
先把容器里的文件拷出来：

```bash
docker cp openwrt:/etc/config ./data/config
# 然后改成 - ./data/config:/etc/config
```

### 追加其他插件目录

如果发现某个插件的配置还是丢了，往 `volumes` 里加一行，并在文件末尾的
`volumes:` 段声明即可（compose 里已留好注释）：

```yaml
      - openwrt-adguardhome:/etc/AdGuardHome
      - openwrt-mosdns:/etc/mosdns
```

### 升级镜像时

配置卷会保留旧配置，**新镜像里的默认配置不会自动覆盖进来**。
如果升级后行为异常，`docker compose down` 后删掉对应卷重建即可（会丢配置，先备份）：

```bash
docker run --rm -v openwrt-config:/src -v "$PWD":/dst alpine \
  tar czf /dst/openwrt-config-backup.tar.gz -C /src .
```

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
| `DOCKER_DATA_ROOT` | `/opt/docker` | 固件内 Docker 数据目录 |
| `BRANCH` | `openwrt-25.12` | OpenWrt 分支 |
| `BUILD_MODE` | `0` | 编译线程模式（CI 里设为 `2`） |
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

CI 里 `BUILD_MODE` 设为 `2`（一半线程）。runner 是 4 vCPU / 16G，mosdns、adguardhome
这类 Go 包并行跑满 4 线程有 OOM 风险。

---

## 常见问题

**Q：镜像怎么这么大？**
编译环境镜像（`Dockerfile.build`）装了 clang / ocaml / java 等一整套交叉编译依赖，
约 2GB。它不进 Docker Hub，只在本地和 CI 缓存里。推送到 Docker Hub 的是体积小得多的
OpenWrt 系统镜像。

**Q：为什么容器里还装了 Docker / Dockerman？**
原脚本的插件清单里有 `docker` + `dockerd` + `luci-app-dockerman`，属于「现有功能保留」。
但容器里再跑 Docker（DinD）需要额外挂 cgroup 并开 privileged，默认不可用，
这两个插件在容器部署场景下基本是用来看的；刷机到物理机上才正常。

**Q：容器模式下的网络配置会打架吗？**
固件默认是 `br-lan` 桥接 `eth0`。容器里 `eth0` 已经是 macvlan 接口，再套一层 bridge
会不通，所以 `files/etc/uci-defaults/99-default-settings` 里加了判断：
检测到 `/.dockerenv` 时自动把 LAN 直连 `eth0`，IP 仍然是 `192.168.31.254`。
刷到物理机上则保持原来的 `br-lan` 配置。

**Q：重新构建真的很慢怎么办？**
正常情况只需要复用 Docker Hub 上已有的镜像，不触发编译。
确实需要重编时，`work/` 目录（源码 + `dl/` + ccache）会保留，第二次编译比第一次快很多。
CI 上 `dl/` 和 ccache 走 actions/cache，注意仓库缓存总量上限 10GB。
