# 卫戍协议自建部署

把上游 [Stronghold-Protocol v0.4.0](https://github.com/sganggs/Stronghold-Protocol/releases/tag/v0.4.0) 装到一台已经有网站的 Linux 服务器上。游戏只监听 `127.0.0.1:3000`，对外用 `https://play.qimiyo.online/`。安装脚本不修改 `www.qimiyo.online` 的站点配置。

这是非官方同人作品。代码许可是上游的 GPL-3.0-or-later；游戏美术和音频版权归原权利人，只供个人和非商业使用。本仓库不含游戏源码和素材。素材约 720 MB，在服务器第一次安装时下载。

## 服务器上安装

需要 root、git、curl，以及至少 3 GB 可用磁盘。Node.js 22 会装到 `/opt/node-v22`，不替换系统里已有的 Node。

```bash
git clone https://github.com/Light-milk-tea/stronghold-selfhost.git
cd stronghold-selfhost
sudo bash deploy/install.sh
```

脚本可以再次执行。它会续传没下完的素材。再次执行会重启游戏进程，正在进行的对局会结束。

腾讯云安全组保持 22、80、443 即可，不要对公网开放 3000。`play` 的 A 记录指向这台服务器。

## 装完怎么确认

- `curl -I http://127.0.0.1:3000/` 有响应，说明游戏进程在。
- `https://www.qimiyo.online/` 仍是原来的封面站。
- `https://play.qimiyo.online/` 打开的是卫戍协议。证书还没申请时，先看 `http://play.qimiyo.online/`。

日志：`journalctl -u stronghold -f`

## 反向代理

普通 Nginx：脚本把 [deploy/nginx-play.qimiyo.online.conf](deploy/nginx-play.qimiyo.online.conf) 写到 `/etc/nginx/conf.d/play.qimiyo.online.conf`，先 `nginx -t` 再 reload。机器上有 certbot 且当前是交互终端时，只为 `play.qimiyo.online` 申请证书。已有 `ssl_certificate` 的配置不会被覆盖。

宝塔：脚本不改面板。游戏起来之后，在面板里新建站点 `play.qimiyo.online`，反代到 `http://127.0.0.1:3000` 并开启 WebSocket，SSL 只勾选这个新域名。

只有 Caddy 时，把 [deploy/Caddyfile.snippet](deploy/Caddyfile.snippet) 合并进现有 Caddyfile 再 reload。

## 这次安装不做的事

- 不从本机明日方舟客户端提取 3D 棋盘和战场场景。没有这些文件时，棋盘用程序里的替代样式，对局可以正常进行。
- 没有账号。把 `https://play.qimiyo.online/` 只发给要一起玩的人。
