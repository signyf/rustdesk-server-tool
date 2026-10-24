# RustDesk Server 一键管理脚本

在 Linux 服务器上一键部署官方开源版 **RustDesk Server**（`hbbs` ID/信令服务 + `hbbr` 中继服务），以 systemd 方式运行。脚本提供交互菜单，也支持子命令直接执行。

实现依据 [RustDesk 官方自托管文档](https://rustdesk.com/docs/en/self-host/rustdesk-server-oss/)：服务组成、端口、密钥生成方式均与官方说明一致；菜单式交互参考了 [sshpc/rustdesktool](https://github.com/sshpc/rustdesktool)。

## 功能

- **安装 / 卸载**：卸载前可把密钥与数据库备份到 `/root/rustdesk-backup-*`
- **状态 / 查看 Key / 启动 / 停止 / 重启**
- **升级服务端**：自动查询官方最新版，只换二进制，密钥与数据库原样保留
- **更新脚本**：脚本可自更新到本仓库最新版
- **架构自适应**：x86_64(amd64)、ARM64、ARMv7、i386 自动识别
- **版本自动检测**：安装时从 GitHub API 取最新版（当前兜底 1.1.16），不再写死旧版本
- **下载兜底**：直连 GitHub 失败时自动切换加速镜像，并校验压缩包完整性

## 一键安装

> 需要 root 用户，且系统使用 systemd（Ubuntu / Debian / CentOS / RHEL 等均可）。

```sh
wget -N https://raw.githubusercontent.com/signyf/rustdesk-server-tool/main/rustdesk-server-tool.sh && chmod +x rustdesk-server-tool.sh && ./rustdesk-server-tool.sh
```

下载慢时可走镜像：

```sh
wget -N https://gh-proxy.com/https://raw.githubusercontent.com/signyf/rustdesk-server-tool/main/rustdesk-server-tool.sh && chmod +x rustdesk-server-tool.sh && ./rustdesk-server-tool.sh
```

再次执行 `./rustdesk-server-tool.sh` 即回到管理菜单。

## 子命令用法

不想进菜单时可直接传参，适合远程/自动化执行：

```sh
./rustdesk-server-tool.sh install      # 安装
./rustdesk-server-tool.sh status       # 查看服务状态与端口监听
./rustdesk-server-tool.sh key          # 查看服务器公钥
./rustdesk-server-tool.sh restart      # 重启服务
./rustdesk-server-tool.sh upgrade      # 升级服务端到最新版
./rustdesk-server-tool.sh uninstall    # 卸载
```

## 安装后：客户端配置

客户端在 [RustDesk 官网](https://rustdesk.com/download) 下载。默认连的是官方公共服务器，需改为自己的：

设置 → 网络：

- **ID 服务器**：你的服务器 IP 或域名
- **中继服务器**：同上
- **API 服务器**：留空
- **密钥 (Key)**：安装完成后脚本打印的公钥，也可用菜单 `4` 或子命令 `key` 随时查看

## 端口

云厂商安全组 / 防火墙需放行（官方文档口径）：

| 端口 | 协议 | 服务 | 用途 |
| --- | --- | --- | --- |
| 21115 | TCP | hbbs | NAT 类型测试 |
| 21116 | TCP/UDP | hbbs | UDP 做 ID 注册与心跳，TCP 做打洞与连接 |
| 21117 | TCP | hbbr | 中继服务 |
| 21118 | TCP | hbbs | 网页客户端 |
| 21119 | TCP | hbbr | 网页客户端 |

```sh
# ufw 示例
ufw allow 21115:21119/tcp && ufw allow 21116/udp
# firewalld 示例
firewall-cmd --permanent --add-port=21115-21119/tcp --add-port=21116/udp && firewall-cmd --reload
```

## 目录与文件

- 安装目录：`/usr/local/rustdesk-server`（二进制、密钥 `id_ed25519(.pub)`、数据库 `db.sqlite3` 都在这里）
- systemd 单元：`/etc/systemd/system/rustdesk-hbbs.service`、`rustdesk-hbbr.service`
- 公钥位置：`/usr/local/rustdesk-server/id_ed25519.pub`（hbbs 首次启动时自动生成）
- 自定义密钥：停服后替换安装目录下的 `id_ed25519.pub` 与 `id_ed25519` 再启动即可

## 参考

- 官方文档：https://rustdesk.com/docs/en/self-host/rustdesk-server-oss/
- 官方服务端仓库：https://github.com/rustdesk/rustdesk-server
- 交互思路参考：https://github.com/sshpc/rustdesktool

## License

MIT
