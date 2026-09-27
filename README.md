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
│   └── Dockerfile.image         产物镜像（OpenWrt rootfs，FROM scratch）
├── docker-compose.yml           部署 OpenWrt 容器
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
