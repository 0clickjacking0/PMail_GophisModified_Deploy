# PMail + Gophish 一键部署 —— 填写说明

本说明配合 `deploy.sh`（公网版）和 `deploy-intranet.sh`（内网版）使用。

---

## 一、部署前准备

| 项目 | 要求 |
|---|---|
| 系统 | Ubuntu 20.04 / 22.04（脚本只支持 apt） |
| 权限 | root（用 `sudo bash` 运行） |
| 网络 | 公网版需能访问 GitHub、Docker Hub、`download.docker.com` |
| 端口 | 25/80/110/443/465/587/993/995（PMail）、62758/8081（Gophish）需未被占用 |
| 磁盘 | 建议 ≥ 10GB（镜像 + 数据库） |

> 服务器防火墙 / 云安全组需放行上述端口，否则外部无法访问。

---

## 二、运行方式

### 方式 A：交互式（推荐，会逐步提问）

```bash
sudo bash deploy.sh
```

脚本会依次提问，按下面的表填写。

### 方式 B：非交互式（一条命令，适合自动化）

```bash
sudo SPACESHIP_API_KEY="你的Key" \
     SPACESHIP_API_SECRET="你的Secret" \
     DOMAIN="example.com" \
     bash deploy.sh
```

不配置 DNS 时，直接留空或不传这些变量即可：

```bash
sudo bash deploy.sh     # 遇到 Spaceship 提问时直接回车跳过
```

---

## 三、交互式各字段怎么填

脚本开头会出现 3 个提问（都属于 Spaceship DNS 自动配置，**可选**）：

```
Spaceship DNS 自动配置 (可选)
  Spaceship API Key:    ← ①
  Spaceship API Secret: ← ②
  邮件域名 (如 example.com): ← ③
```

| # | 提问 | 填什么 | 从哪获取 | 可否跳过 |
|---|---|---|---|---|
| ① | Spaceship API Key | 一串 Key 字符串 | Spaceship 控制台 → Account → API/Developer → 创建 API Key | 可（回车留空） |
| ② | Spaceship API Secret | 与 Key 成对的 Secret | 同上，创建时一并显示（通常只显示一次） | 填了①就必须填② |
| ③ | 邮件域名 | 主域名，如 `example.com`（**不带** `smtp.` 前缀） | 你要用于收发的域名 | 填了①②就必须填③ |

**规则**：
- 三个全留空 → 跳过 DNS 配置，正常部署，之后手动去 Spaceship 控制台加解析。
- 只填①不填②/③ → 视为信息不完整，自动跳过并提示。
- 三个都填 → 脚本自动写入 A / MX / SPF / DMARC / DKIM 全套记录。

> ⚠️ Spaceship 是**两段式认证**：API Key 和 API Secret 是两个不同的值，都要填。
> 域名只填**主域名**。脚本会自动派生 `@`、`smtp`、`imap`、`pop`、`mail` 等子记录。

---

## 四、部署后访问地址

脚本结束会打印，格式如下（`<IP>` 为服务器公网/内网 IP）：

| 服务 | 地址 | 说明 |
|---|---|---|
| PMail 初始化向导 | `http://<IP>` | **首次访问**完成域名/账号设置 |
| PMail SMTP | `<IP>:25` | 发信 |
| PMail IMAP | `<IP>:993` | 收信（SSL） |
| Gophish 管理后台 | `https://<IP>:62758` | 自签名证书，浏览器需信任 |
| Gophish 钓鱼页面 | 配置域名后经 Nginx SNI 转发 | 投放页 |
| Gophish 账号 | `admin` / 初始密码 | 初始密码在脚本输出中，首次登录强制改密 |

---

## 五、关键目录与命令

| 内容 | 路径 / 命令 |
|---|---|
| 部署根目录 | `/opt/mail-deploy` |
| PMail 配置/数据库 | `/opt/mail-deploy/pmail-config`（`pmail.db`、`dkim/`、`config.json`） |
| Gophish 数据 | `/opt/mail-deploy/gophish-data`（`gophish.db`） |
| PMail 日志 | `docker logs -f pmail` |
| Gophish 日志 | `docker logs -f gophish-modified` |
| Gophish 初始密码 | `docker logs gophish-modified \| grep password` |

---

## 六、常见问题

**Q1: Gophish 初始密码没打印出来？**
等容器完全启动（约 10–30 秒）后手动查：
```bash
docker logs gophish-modified | grep -i password
```

**Q2: 端口 25 被占用或发信被拒？**
很多云厂商默认封 25 端口出站，需提工单解封；或确认本机 25 无其他进程占用：
```bash
ss -tlnp | grep :25
```

**Q3: DNS 配置后邮件仍收不到？**
DNS 生效需几分钟到几小时，用以下命令确认已生效：
```bash
dig MX example.com
dig TXT example.com
dig TXT default._domainkey.example.com
```

**Q4: 重复运行脚本会怎样？**
脚本幂等：源码会更新到最新、容器会重建（数据目录保留，`pmail.db`/`gophish.db` 不丢）。

**Q5: 想改 Gophish 端口？**
改 `run_containers` 里的 `-p 0.0.0.0:62758:3333` 和 `-p 0.0.0.0:8081:80`。

