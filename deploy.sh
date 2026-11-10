#!/bin/bash
#====================================================================
# PMail + Gophish 一键部署脚本 (Ubuntu)
#
# 功能:
#   1. 安装 Docker (如未安装)
#   2. 安装/配置 dnsmasq (DNS 缓存, 减少出站 DNS 超时)
#   3. 从 GitHub 拉取源码并构建:
#        PMail   (0clickjacking0/PMail @ mine)
#        Gophish (0clickjacking0/GophisModified @ mine)
#   4. 运行两个容器 (端口与生产一致)
#   5. 提取 Gophish 初始随机密码并展示
#   6. [可选] 通过 Spaceship API 自动配置域名 DNS 解析 (A/MX/SPF/DKIM/DMARC)
#
# 说明:
#   - PMail 端口: 25/80/110/465/587/993/995 (首次访问走初始化向导)
#   - Gophish 端口: 管理后台 62758, 钓鱼页面 443 (HTTPS)
#   - Spaceship DNS 配置读取脚本同级的 mail_env (可选)
#
# 用法:
#   1. 首次填写脚本同级 mail_env:
#        nano /root/mail_env
#        SPACESHIP_API_KEY=xxx
#        SPACESHIP_API_SECRET=yyy
#        DOMAIN=example.com
#        PHISH_DOMAIN=www.example.com
#   2. sudo bash /root/deploy.sh
#   也可用进程环境变量临时覆盖 mail_env。
# 快速操作:
#   仅同步 DNS, 不构建、不重启容器:
#     sudo SKIP_BUILD=1 SKIP_RESTART=1 bash /root/deploy.sh
#   已有镜像重建容器, 但不重新构建:
#     sudo SKIP_BUILD=1 bash /root/deploy.sh
#====================================================================
set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ---------- 0. 前置检查 ----------
[ "$(id -u)" -eq 0 ] || error "请以 root 运行: sudo bash $0"
command -v apt-get >/dev/null || error "此脚本仅支持 Ubuntu (apt)"

PMAIL_GIT="https://github.com/0clickjacking0/PMail.git"
PMAIL_BRANCH="mine"
GOPHISH_GIT="https://github.com/0clickjacking0/GophisModified.git"
GOPHISH_BRANCH="mine"

WORK_DIR="/opt/mail-deploy"
PMAIL_SRC="$WORK_DIR/pmail-src"
GOPHISH_SRC="$WORK_DIR/gophish-src"
PMAIL_DATA="$WORK_DIR/pmail-config"
GOPHISH_DATA="$WORK_DIR/gophish-data"

PMAIL_IMAGE="pmail:inline-cid"
GOPHISH_IMAGE="gophish-modified:inline-qr"
PMAIL_CONTAINER="pmail"
GOPHISH_CONTAINER="gophish-modified"
LETSENCRYPT_DATA="$WORK_DIR/letsencrypt"
NGINX_SNI_CONF="/etc/nginx/sites-available/mail-sni"
DEPLOY_ENV_FILE="${DEPLOY_ENV_FILE:-$(cd "$(dirname "$0")" && pwd)/mail_env}"

PUBLIC_IP=$(curl -4 -s --max-time 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')

info "部署目录: $WORK_DIR"
info "公网 IP : $PUBLIC_IP"
mkdir -p "$WORK_DIR"

#====================================================================
# 0.1 读取 .env (root:600; 已存在的进程环境变量优先)
#====================================================================
load_deploy_env() {
    if [ ! -f "$DEPLOY_ENV_FILE" ]; then
        return
    fi

    info "读取部署配置: $DEPLOY_ENV_FILE"
    local line key value
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        # 去掉行首空白
        line="${line#"${line%%[![:space:]]*}"}"
        case "$line" in
            ''|'#'*) continue ;;
            *=*) ;;
            *) continue ;;
        esac

        key="${line%%=*}"
        value="${line#*=}"
        case "$value" in
            \"*\") value="${value#\"}"; value="${value%\"}" ;;
            \'*\') value="${value#\'}"; value="${value%\'}" ;;
        esac

        case "$key" in
            SPACESHIP_API_KEY)    [ -z "${SPACESHIP_API_KEY:-}" ]    && SPACESHIP_API_KEY="$value" ;;
            SPACESHIP_API_SECRET) [ -z "${SPACESHIP_API_SECRET:-}" ] && SPACESHIP_API_SECRET="$value" ;;
            DOMAIN)               [ -z "${DOMAIN:-}" ]               && DOMAIN="$value" ;;
            PHISH_CERT_CN)        [ -z "${PHISH_CERT_CN:-}" ]        && PHISH_CERT_CN="$value" ;;
            PHISH_DOMAIN)         [ -z "${PHISH_DOMAIN:-}" ]         && PHISH_DOMAIN="$value" ;;
        esac
    done < "$DEPLOY_ENV_FILE"
}
load_deploy_env

#====================================================================
# 0.5 Spaceship DNS 配置来源检查 (可选)
#====================================================================
SPACESHIP_API_KEY="${SPACESHIP_API_KEY:-}"
SPACESHIP_API_SECRET="${SPACESHIP_API_SECRET:-}"
DOMAIN="${DOMAIN:-}"

if [ -z "$SPACESHIP_API_KEY" ]; then
    warn "未配置 SPACESHIP_API_KEY, 跳过 Spaceship DNS 自动配置"
    warn "如需启用, 请编辑 $DEPLOY_ENV_FILE 后重新运行本脚本"
fi

if [ -n "$SPACESHIP_API_KEY" ]; then
    if [ -z "$DOMAIN" ]; then
        warn "未配置 DOMAIN, 跳过 Spaceship DNS 自动配置"
        warn "如需启用, 请编辑 $DEPLOY_ENV_FILE 后重新运行本脚本"
    fi
    if [ -z "$DOMAIN" ] || [ -z "$SPACESHIP_API_SECRET" ]; then
        warn "Spaceship 配置不完整, 跳过 DNS 自动配置"
        SPACESHIP_API_KEY=""
    fi
fi

#====================================================================
# 1. 安装 Docker
#====================================================================
install_docker() {
    if command -v docker >/dev/null 2>&1; then
        info "Docker 已安装: $(docker --version)"
        return
    fi
    info "正在安装 Docker ..."
    apt-get update -qq
    apt-get install -y -qq ca-certificates curl gnupg lsb-release >/dev/null
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
        > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin >/dev/null
    systemctl enable docker >/dev/null 2>&1
    systemctl start docker
    info "Docker 安装完成: $(docker --version)"
}
install_docker

#====================================================================
# 2. 安装 / 配置 dnsmasq
#====================================================================
install_dnsmasq() {
    if command -v dnsmasq >/dev/null 2>&1; then
        info "dnsmasq 已安装"
    else
        info "正在安装 dnsmasq ..."
        apt-get install -y -qq dnsmasq >/dev/null
    fi

    cat > /etc/dnsmasq.d/pmail-cache.conf <<EOF
# PMail 邮件演练 DNS 缓存
listen-address=127.0.0.1,172.17.0.1
bind-interfaces
server=8.8.8.8
server=8.8.4.4
cache-size=10000
EOF

    systemctl restart dnsmasq
    systemctl enable dnsmasq >/dev/null 2>&1
    info "dnsmasq 已配置并启动"
}
install_dnsmasq

#====================================================================
# 3. 安装 git (如缺失)
#====================================================================
command -v git >/dev/null || { info "安装 git ..."; apt-get install -y -qq git >/dev/null; }

#====================================================================
# 4. 克隆源码
#====================================================================
clone_repo() {
    local url="$1" branch="$2" dir="$3" name="$4"
    if [ -d "$dir/.git" ]; then
        info "$name 源码已存在, 更新到最新 ..."
        cd "$dir"
        git fetch origin
        git checkout "$branch" 2>/dev/null || git checkout -b "$branch" "origin/$branch"
        git reset --hard "origin/$branch"
    else
        info "克隆 $name ($branch) ..."
        git clone --branch "$branch" --single-branch "$url" "$dir"
    fi
}
clone_repo "$PMAIL_GIT"   "$PMAIL_BRANCH"   "$PMAIL_SRC"   "PMail"
clone_repo "$GOPHISH_GIT" "$GOPHISH_BRANCH" "$GOPHISH_SRC" "Gophish"

#====================================================================
# 5. 构建 PMail 镜像 (仓库自带 Dockerfile)
#====================================================================
SKIP_BUILD="${SKIP_BUILD:-}"

build_pmail() {
    if [ -n "$SKIP_BUILD" ]; then
        info "SKIP_BUILD 已设置, 跳过 PMail 镜像构建"
        return
    fi
    info "构建 PMail 镜像 ... (首次约 5-10 分钟)"
    cd "$PMAIL_SRC"
    # 上游 Dockerfile 中的 node:lts-alpine 已不内置 yarn, 且仓库缺少 fe/ 子模块内容时构建会失败。
    # 使用本地验证过的 Dockerfile.codex: 固定 Node 22 + yarn.lock, 仅构建 server/ 与 fe/。
    cat > Dockerfile.codex <<'PMAILEOF'
FROM node:22-alpine AS frontend

WORKDIR /work
COPY fe/package.json fe/yarn.lock ./
RUN corepack enable && yarn install --frozen-lockfile
COPY fe/ ./
RUN yarn build

FROM golang:1.24-alpine AS server

ARG VERSION=deploy-local
WORKDIR /work
RUN apk add --no-cache git
COPY server/ ./
COPY --from=frontend /work/dist ./listen/http_server/dist
RUN go build -trimpath -ldflags "-s -w -X 'main.version=${VERSION}'" -o /out/pmail main.go \
    && cd hooks/wechat_push \
    && go build -trimpath -ldflags '-s -w' -o /out/wechat_push wechat_push.go \
    && cd ../spam_block \
    && go build -trimpath -ldflags '-s -w' -o /out/spam_block spam_block.go

FROM alpine:3.22

WORKDIR /work
RUN apk add --no-cache ca-certificates tzdata \
    && ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime \
    && echo 'Asia/Shanghai' > /etc/timezone
COPY --from=server /out/pmail ./pmail
COPY --from=server /out/wechat_push ./plugins/wechat_push
COPY --from=server /out/spam_block ./plugins/spam_block

EXPOSE 25 80 110 443 465 587 993 995
CMD ["/work/pmail"]
PMAILEOF
    docker build -f Dockerfile.codex -t "$PMAIL_IMAGE" .
    info "PMail 镜像构建完成"
}
build_pmail

#====================================================================
# 6. 构建 Gophish 镜像
#====================================================================
build_gophish() {
    if [ -n "$SKIP_BUILD" ]; then
        info "SKIP_BUILD 已设置, 跳过 Gophish 镜像构建"
        return
    fi
    info "构建 Gophish 镜像 ... (首次约 5-10 分钟)"
    cd "$GOPHISH_SRC"

    # 生成与新版 Go 兼容的 Dockerfile
    cat > Dockerfile.codex <<'GOEOF'
FROM golang:1.24-bookworm AS build

WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=1 go build -trimpath -ldflags='-s -w' -o /out/gophish .

FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates jq libcap2-bin \
    && rm -rf /var/lib/apt/lists/* \
    && useradd -m -d /opt/gophish -s /usr/sbin/nologin app \
    && mkdir /data \
    && chown app:app /data

WORKDIR /opt/gophish
COPY --from=build /out/gophish ./gophish
COPY VERSION config.json ./
COPY static ./static
COPY templates ./templates
COPY db ./db
COPY docker/run.sh ./docker/run.sh
RUN chmod 0755 gophish docker/run.sh \
    && chown app:app config.json \
    && setcap 'cap_net_bind_service=+ep' gophish

USER app
EXPOSE 80 3333
CMD ["/bin/bash", "./docker/run.sh"]
GOEOF

    docker build -f Dockerfile.codex -t "$GOPHISH_IMAGE" .
    info "Gophish 镜像构建完成"
}
build_gophish

#====================================================================
# 7. 准备数据目录
#====================================================================
prepare_dirs() {
    info "准备数据目录 ..."

    # --- PMail ---
    mkdir -p "$PMAIL_DATA/dkim" "$PMAIL_DATA/ssl"
    if [ ! -f "$PMAIL_DATA/dkim/dkim.priv" ]; then
        openssl genrsa -out "$PMAIL_DATA/dkim/dkim.priv" 2048 2>/dev/null
        info "已生成 DKIM 私钥"
    fi

    # 生成 DKIM 公钥 TXT 值 (SubjectPublicKeyInfo/PKIX 格式, 与 PMail DkimGen 一致)
    if [ ! -f "$PMAIL_DATA/dkim/dkim.public" ]; then
        DKIM_PUB_B64=$(openssl rsa -in "$PMAIL_DATA/dkim/dkim.priv" -pubout -outform DER 2>/dev/null | base64 | tr -d '\n')
        printf 'v=DKIM1; k=rsa; p=%s' "$DKIM_PUB_B64" > "$PMAIL_DATA/dkim/dkim.public"
        info "已生成 DKIM 公钥 (DNS TXT 记录值)"
    fi
    # 初始 config.json: isInit=false => 首次访问 80 端口进入初始化向导
    cat > "$PMAIL_DATA/config.json" <<'EOF'
{
  "logLevel": "",
  "domain": "",
  "domains": [],
  "webDomain": "",
  "dkimPrivateKeyPath": "/work/config/dkim/dkim.priv",
  "sslType": "0",
  "SSLPrivateKeyPath": "/work/config/ssl/private.key",
  "SSLPublicKeyPath": "/work/config/ssl/public.crt",
  "dbDSN": "/work/./config/pmail.db",
  "dbType": "sqlite",
  "httpsEnabled": 0,
  "spamFilterLevel": 0,
  "httpPort": 0,
  "httpsPort": 0,
  "isInit": false
}
EOF

    # --- Gophish ---
    mkdir -p "$GOPHISH_DATA"
    if [ ! -f "$GOPHISH_DATA/gophish_admin.key" ]; then
        openssl req -x509 -newkey rsa:2048 \
            -keyout "$GOPHISH_DATA/gophish_admin.key" \
            -out  "$GOPHISH_DATA/gophish_admin.crt" \
            -days 365 -nodes -subj "/CN=gophish" 2>/dev/null
        chmod 640 "$GOPHISH_DATA/gophish_admin.key"
        info "已生成 Gophish admin 自签名证书"
    fi

    PHISH_DOMAIN="${PHISH_DOMAIN:-${PHISH_CERT_CN:-}}"
    if [ -n "$PHISH_DOMAIN" ]; then
        info "钓鱼页面域名: $PHISH_DOMAIN"
    fi

    # 钓鱼页面 HTTPS 证书 (先自签名; 若配置 PHISH_DOMAIN 则后续尝试 Let's Encrypt)
    if [ ! -f "$GOPHISH_DATA/gophish_phish.key" ]; then
        PHISH_CERT_CN="${PHISH_CERT_CN:-${DOMAIN:-$PUBLIC_IP}}"
        PHISH_SAN="DNS:localhost,IP:127.0.0.1"
        if [ -n "$PHISH_CERT_CN" ] && [ "$PHISH_CERT_CN" != "$PHISH_SAN" ]; then
            PHISH_SAN="$PHISH_SAN,DNS:$PHISH_CERT_CN"
        fi
        if [[ "$PHISH_CERT_CN" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            PHISH_SAN="$PHISH_SAN,IP:$PHISH_CERT_CN"
        else
            PHISH_SAN="$PHISH_SAN,DNS:$PHISH_CERT_CN"
        fi
        openssl req -x509 -newkey rsa:2048 \
            -keyout "$GOPHISH_DATA/gophish_phish.key" \
            -out  "$GOPHISH_DATA/gophish_phish.crt" \
            -days 365 -nodes -subj "/CN=$PHISH_CERT_CN" \
            -addext "subjectAltName=$PHISH_SAN" 2>/dev/null
        chmod 640 "$GOPHISH_DATA/gophish_phish.key"
        info "已生成 Gophish 钓鱼页面自签名证书 (CN: $PHISH_CERT_CN)"
    fi
    chown -R 1000:1000 "$GOPHISH_DATA"
    info "数据目录准备完成"
}
prepare_dirs

#====================================================================
# 7.5 通过 Spaceship API 自动配置域名 DNS 解析
#====================================================================
configure_spaceship_dns() {
    if [ -z "$SPACESHIP_API_KEY" ] || [ -z "$DOMAIN" ]; then
        info "未提供 Spaceship API Key / 域名, 跳过 DNS 自动配置"
        return
    fi

    info "通过 Spaceship API 配置 $DOMAIN 的 DNS 解析 ..."

    # Spaceship API 实际可用地址是 https://spaceship.dev/api/v1
    # (api.spaceship.dev 当前无 DNS 记录, 不能使用)
    local api="https://spaceship.dev/api/v1"
    local auth_key="X-Api-Key: $SPACESHIP_API_KEY"
    local auth_secret="X-Api-Secret: $SPACESHIP_API_SECRET"

    # 读取 DKIM TXT 值
    local dkim_value=""
    if [ -f "$PMAIL_DATA/dkim/dkim.public" ]; then
        dkim_value=$(cat "$PMAIL_DATA/dkim/dkim.public")
    fi

    # Spaceship DNS API 使用 PUT /dns/records/{domain} 批量 upsert 记录。
    # 字段名与常见 DNS API 不同:
    #   A   -> address
    #   MX  -> exchange + preference
    #   TXT -> value
    local body
    body=$(jq -n \
        --arg domain "$DOMAIN" \
        --arg ip "$PUBLIC_IP" \
        --arg dkim "$dkim_value" \
        '{
            force: true,
            items: [
                {type:"A", name:"@", address:$ip},
                {type:"A", name:"www", address:$ip},
                {type:"A", name:"smtp", address:$ip},
                {type:"A", name:"imap", address:$ip},
                {type:"A", name:"pop", address:$ip},
                {type:"A", name:"pmail", address:$ip},
                {type:"MX", name:"@", exchange:("smtp." + $domain), preference:10},
                {type:"TXT", name:"@", value:("v=spf1 a mx ip4:" + $ip + " ~all")},
                {type:"TXT", name:"_dmarc", value:("v=DMARC1; p=none; rua=mailto:admin@" + $domain)},
                {type:"TXT", name:"default._domainkey", value:$dkim}
            ]
        }')

    local http_code resp
    resp=$(curl -4 -sS -X PUT "$api/dns/records/$DOMAIN" \
        -H "$auth_key" -H "$auth_secret" -H "Content-Type: application/json" \
        -d "$body" -w "\n%{http_code}" 2>/dev/null || echo -e "\n000")
    http_code=$(tail -n 1 <<< "$resp")
    resp=$(sed '$d' <<< "$resp")

    if [ "$http_code" = "204" ]; then
        info "Spaceship DNS 批量配置成功: 9 条记录"
    else
        warn "Spaceship DNS 配置失败 (HTTP $http_code): $resp"
    fi
}
configure_spaceship_dns

#====================================================================
# 8. 运行容器
#====================================================================
issue_phish_certificate() {
    if [ -z "$PHISH_DOMAIN" ]; then
        info "未配置 PHISH_DOMAIN, 钓鱼页面继续使用自签名证书"
        return
    fi

    mkdir -p "$LETSENCRYPT_DATA/etc" "$LETSENCRYPT_DATA/www"

    # 优先复用已有证书; 强制更新用 FORCE_PHISH_CERT=1
    if [ -f "$LETSENCRYPT_DATA/etc/live/$PHISH_DOMAIN/fullchain.pem" ] \
        && [ -z "${FORCE_PHISH_CERT:-}" ]; then
        info "Let's Encrypt 证书已存在, 复用: $PHISH_DOMAIN"
    else
        info "正在为 $PHISH_DOMAIN 申请 Let's Encrypt 证书 ..."
        docker run --rm \
            -v "$LETSENCRYPT_DATA/etc":/etc/letsencrypt \
            -v "$LETSENCRYPT_DATA/www":/var/www/certbot \
            -p 127.0.0.1:8080:80 \
            certbot/certbot certonly --standalone \
            --non-interactive --agree-tos \
            --register-unsafely-without-email \
            -d "$PHISH_DOMAIN" \
            --http-01-address 0.0.0.0 --http-01-port 80
    fi

    if [ ! -f "$LETSENCRYPT_DATA/etc/live/$PHISH_DOMAIN/fullchain.pem" ]; then
        warn "未找到 Let's Encrypt 证书, 继续使用自签名证书"
        FAILED_PHISH_CERT=1
        return
    fi

    install -m 0644 "$LETSENCRYPT_DATA/etc/live/$PHISH_DOMAIN/fullchain.pem" \
        "$GOPHISH_DATA/gophish_phish.crt"
    install -m 0640 "$LETSENCRYPT_DATA/etc/live/$PHISH_DOMAIN/privkey.pem" \
        "$GOPHISH_DATA/gophish_phish.key"
    chown 1000:1000 "$GOPHISH_DATA/gophish_phish.crt" "$GOPHISH_DATA/gophish_phish.key"
    info "已安装钓鱼页面 Let's Encrypt 证书: $PHISH_DOMAIN"
}

# Certbot standalone 需要公网 80 端口。这里先临时处理 80 端口占用, 完成后恢复。
issue_phish_certificate_safely() {
    local port80_owner=""
    FAILED_PHISH_CERT=0

    # 如果 80 被占用, 优先临时停止 PMail 容器
    if ss -lnt '( sport = :80 )' | grep -q LISTEN; then
        if docker inspect "$PMAIL_CONTAINER" >/dev/null 2>&1; then
            info "临时停止 PMail 以释放 80 端口, 申请完成后自动恢复"
            docker stop "$PMAIL_CONTAINER" >/dev/null
            port80_owner="$PMAIL_CONTAINER"
        fi
    fi

    issue_phish_certificate

    if [ -n "$port80_owner" ]; then
        docker start "$port80_owner" >/dev/null
        info "PMail 已恢复启动"
    fi

    return "$FAILED_PHISH_CERT"
}
issue_phish_certificate_safely || warn "钓鱼页面证书申请失败, 将使用自签名证书"
issue_phish_certificate

run_containers() {
    info "启动容器 ..."

    if [ -n "$SKIP_RESTART" ]; then
        info "SKIP_RESTART 已设置, 跳过容器重建"
        return
    fi

    docker rm -f "$PMAIL_CONTAINER" 2>/dev/null || true
    docker rm -f "$GOPHISH_CONTAINER" 2>/dev/null || true

    # --- PMail (公网 80/443 由 Nginx SNI 分流) ---
    docker run -d --name "$PMAIL_CONTAINER" --restart always \
        --dns 172.17.0.1 --dns 8.8.8.8 \
        -v "$PMAIL_DATA":/work/config \
        -p 25:25 -p 127.0.0.1:18080:80 -p 110:110 -p 127.0.0.1:8443:443 \
        -p 465:465 -p 587:587 -p 993:993 -p 995:995 \
        "$PMAIL_IMAGE"
    info "PMail 容器已启动"

    # --- Gophish (管理后台 62758, 钓鱼页面 443 经 Nginx SNI 分流) ---
    docker run -d --name "$GOPHISH_CONTAINER" --restart unless-stopped --init \
        -p 127.0.0.1:9443:443 -p 0.0.0.0:62758:3333 \
        -e ADMIN_LISTEN_URL="0.0.0.0:3333" \
        -e ADMIN_USE_TLS="true" \
        -e ADMIN_CERT_PATH="/data/gophish_admin.crt" \
        -e ADMIN_KEY_PATH="/data/gophish_admin.key" \
        -e PHISH_LISTEN_URL="0.0.0.0:443" \
        -e PHISH_USE_TLS="true" \
        -e PHISH_CERT_PATH="/data/gophish_phish.crt" \
        -e PHISH_KEY_PATH="/data/gophish_phish.key" \
        -e DB_FILE_PATH="/data/gophish.db" \
        -v "$GOPHISH_DATA":/data \
        -v "$GOPHISH_DATA/page-assets":/opt/gophish/static/endpoint/page-assets \
        "$GOPHISH_IMAGE"
    info "Gophish 容器已启动"
}

configure_nginx_sni() {
    info "配置 Nginx 443 SNI 分流 ..."
    command -v nginx >/dev/null || {
        info "安装 Nginx ..."
        apt-get update -qq >/dev/null
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nginx >/dev/null
    }

    mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
    cat > "$NGINX_SNI_CONF" <<'NGINXEOF'
map $http_upgrade $connection_upgrade {
    default upgrade;
    "" close;
}

server {
    listen 80 default_server;
    server_name _;

    if ($host = __PHISH_DOMAIN__) {
        return 301 https://$host$request_uri;
    }

    location / {
        proxy_pass http://127.0.0.1:18080;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto http;
    }
}

server {
    listen 443 ssl http2;
    server_name pmail.__DOMAIN__;

    ssl_certificate     __PMAIL_CERT__;
    ssl_certificate_key __PMAIL_KEY__;

    location / {
        proxy_pass https://127.0.0.1:8443;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
    }
}

server {
    listen 443 ssl http2 default_server;
    server_name _;

    ssl_certificate     __PHISH_CERT__;
    ssl_certificate_key __PHISH_KEY__;

    location / {
        proxy_pass https://127.0.0.1:9443;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
    }
}
NGINXEOF

    sed -i "s/__DOMAIN__/${DOMAIN:-example.com}/g" "$NGINX_SNI_CONF"
    sed -i "s/__PHISH_DOMAIN__/${PHISH_DOMAIN:-www.$DOMAIN}/g" "$NGINX_SNI_CONF"
    sed -i "s#__PMAIL_CERT__#$PMAIL_DATA/ssl/public.crt#g" "$NGINX_SNI_CONF"
    sed -i "s#__PMAIL_KEY__#$PMAIL_DATA/ssl/private.key#g" "$NGINX_SNI_CONF"
    sed -i "s#__PHISH_CERT__#$LETSENCRYPT_DATA/etc/live/${PHISH_DOMAIN:-www.$DOMAIN}/fullchain.pem#g" "$NGINX_SNI_CONF"
    sed -i "s#__PHISH_KEY__#$LETSENCRYPT_DATA/etc/live/${PHISH_DOMAIN:-www.$DOMAIN}/privkey.pem#g" "$NGINX_SNI_CONF"

    ln -sf "$NGINX_SNI_CONF" /etc/nginx/sites-enabled/mail-sni
    rm -f /etc/nginx/sites-enabled/default
    nginx -t
    systemctl enable nginx >/dev/null 2>&1
    systemctl restart nginx
    info "Nginx SNI 分流已启用: pmail -> PMail, www -> Gophish"
}
configure_nginx_sni
run_containers

#====================================================================
# 9. 等待 Gophish 初始化并提取初始密码
#====================================================================
info "等待 Gophish 初始化 ..."
GOPHISH_PWD=""
for i in $(seq 1 60); do
    GOPHISH_PWD=$(docker logs "$GOPHISH_CONTAINER" 2>&1 \
        | grep -oP 'the password \K[a-zA-Z0-9]+' | tail -1)
    if [ -n "$GOPHISH_PWD" ]; then
        break
    fi
    sleep 2
done

if [ -z "$GOPHISH_PWD" ]; then
    warn "未能自动提取初始密码, 请手动执行: docker logs $GOPHISH_CONTAINER"
    GOPHISH_PWD="(请查看容器日志)"
fi

#====================================================================
# 10. 输出结果
#====================================================================
echo ""
echo "============================================================"
echo -e "${GREEN}  部署完成!${NC}"
echo "============================================================"
echo ""
echo -e "  ${YELLOW}PMail (邮件服务)${NC}"
echo "  --------------------------------------"
echo "  初始化向导 : http://$PUBLIC_IP   (首次访问完成设置)"
echo "  SMTP       : $PUBLIC_IP:25"
echo "  POP3       : $PUBLIC_IP:110"
echo "  IMAP(SSL)  : $PUBLIC_IP:993"
echo ""
echo -e "  ${YELLOW}Gophish (演练平台)${NC}"
echo "  --------------------------------------"
echo "  管理后台   : https://$PUBLIC_IP:62758"
echo "  钓鱼页面   : https://$PUBLIC_IP  (自签名证书, 浏览器会有安全提示)"
echo "  用户名     : admin"
echo "  初始密码   : $GOPHISH_PWD"
echo "  (首次登录会要求修改密码)"
echo ""
echo "============================================================"
echo "  数据目录:"
echo "    PMail 配置   : $PMAIL_DATA"
echo "    Gophish 数据 : $GOPHISH_DATA"
echo ""
echo "  常用命令:"
echo "    docker logs -f $PMAIL_CONTAINER"
echo "    docker logs -f $GOPHISH_CONTAINER"
echo "============================================================"

# DNS 配置结果提示
if [ -n "$SPACESHIP_API_KEY" ] && [ -n "$DOMAIN" ]; then
    echo ""
    echo -e "  ${YELLOW}域名解析 ($DOMAIN)${NC}"
    echo "  --------------------------------------"
    echo "  已通过 Spaceship API 自动配置以下记录:"
    echo "    A    @                        -> $PUBLIC_IP"
    echo "    A    smtp / imap / pop / mail -> $PUBLIC_IP"
    echo "    MX   @                        -> smtp.$DOMAIN (优先级 10)"
    echo "    TXT  @                        -> SPF"
    echo "    TXT  _dmarc                   -> DMARC"
    echo "    TXT  default._domainkey       -> DKIM 公钥"
    echo ""
    echo "  注意: DNS 生效需几分钟到几小时, 可用以下命令验证:"
    echo "    dig MX $DOMAIN"
    echo "    dig TXT $DOMAIN"
    echo "    dig TXT default._domainkey.$DOMAIN"
    echo "============================================================"
fi
