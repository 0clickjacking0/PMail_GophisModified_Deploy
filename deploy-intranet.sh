#!/bin/bash
#====================================================================
# PMail + Gophish 一键部署脚本 —— 内网版 (Ubuntu)
#
# 与公网版 (deploy.sh) 的区别:
#   1. DNS 上游使用内网 DNS (可配置, 默认读 /etc/resolv.conf)
#   2. 使用内网 IP (不走 ifconfig.me)
#   3. 支持离线模式: 从预先保存的镜像 tar 包加载,
#      适配无法访问 GitHub / Docker Hub 的隔离环境
#
# 用法:
#   sudo bash deploy-intranet.sh                       # 在线模式 (需能访问 GitHub/Docker Hub)
#   sudo OFFLINE=1 bash deploy-intranet.sh             # 离线模式 (需先准备镜像包)
#   sudo INTERNAL_DNS=10.0.0.53 bash deploy-intranet.sh  # 指定内网 DNS
#
# 离线模式准备 (在一台能联网的机器上执行):
#   # 公网版 deploy.sh 会生成部署镜像名 pmail:inline-cid 与
#   # gophish-modified:inline-qr；内网离线模式沿用这两个镜像名。
#   docker save pmail:inline-cid -o pmail.tar
#   docker save gophish-modified:inline-qr -o gophish.tar
#   # 把 pmail.tar / gophish.tar 拷到内网服务器 /opt/mail-deploy/images/ 下
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
IMAGE_DIR="$WORK_DIR/images"

PMAIL_IMAGE="pmail:inline-cid"
GOPHISH_IMAGE="gophish-modified:inline-qr"
PMAIL_CONTAINER="pmail"
GOPHISH_CONTAINER="gophish-modified"

OFFLINE="${OFFLINE:-0}"

# 内网 IP (不走公网探测)
PUBLIC_IP=$(hostname -I | awk '{print $1}')

# 内网 DNS 上游 (默认取系统第一个 nameserver; 没有则退回 8.8.8.8)
if [ -z "${INTERNAL_DNS:-}" ]; then
    INTERNAL_DNS=$(grep -m1 '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}')
fi
[ -z "$INTERNAL_DNS" ] && INTERNAL_DNS="8.8.8.8"

info "部署目录 : $WORK_DIR"
info "内网 IP  : $PUBLIC_IP"
info "内网 DNS : $INTERNAL_DNS"
info "模式     : $([ "$OFFLINE" = "1" ] && echo 离线 || echo 在线)"
mkdir -p "$WORK_DIR" "$IMAGE_DIR"

#====================================================================
# 1. 安装 Docker
#====================================================================
install_docker() {
    if command -v docker >/dev/null 2>&1; then
        info "Docker 已安装: $(docker --version)"
        return
    fi
    if [ "$OFFLINE" = "1" ]; then
        error "离线模式下未检测到 Docker, 请先手动安装 Docker 或提供离线安装包"
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
# 2. 安装 / 配置 dnsmasq (上游指向内网 DNS)
#====================================================================
install_dnsmasq() {
    if command -v dnsmasq >/dev/null 2>&1; then
        info "dnsmasq 已安装"
    else
        if [ "$OFFLINE" = "1" ]; then
            warn "离线模式下无法安装 dnsmasq, 跳过 (容器将直接使用内网 DNS)"
            return
        fi
        info "正在安装 dnsmasq ..."
        apt-get install -y -qq dnsmasq >/dev/null
    fi

    cat > /etc/dnsmasq.d/pmail-cache.conf <<EOF
# PMail 邮件演练 DNS 缓存 (内网版, 上游为内网 DNS)
listen-address=127.0.0.1,172.17.0.1
bind-interfaces
server=$INTERNAL_DNS
cache-size=10000
EOF

    systemctl restart dnsmasq 2>/dev/null || true
    systemctl enable dnsmasq >/dev/null 2>&1 || true
    info "dnsmasq 已配置并启动 (上游: $INTERNAL_DNS)"
}
install_dnsmasq

#====================================================================
# 3. 获取镜像 (离线加载 或 在线克隆构建)
#====================================================================
load_or_build() {
    if [ "$OFFLINE" = "1" ]; then
        info "离线模式: 从 $IMAGE_DIR 加载镜像 ..."
        local loaded=0
        for tar in "$IMAGE_DIR"/*.tar "$IMAGE_DIR"/*.tar.gz; do
            [ -f "$tar" ] || continue
            info "加载: $tar"
            docker load -i "$tar"
            loaded=1
        done
        [ "$loaded" = "0" ] && error "离线模式下 $IMAGE_DIR 中没有找到镜像包 (*.tar / *.tar.gz)"
        docker image inspect "$PMAIL_IMAGE"   >/dev/null 2>&1 || error "镜像包中缺少 $PMAIL_IMAGE"
        docker image inspect "$GOPHISH_IMAGE" >/dev/null 2>&1 || error "镜像包中缺少 $GOPHISH_IMAGE"
        info "镜像加载完成"
        return
    fi

    # ---- 在线: 克隆源码并构建 ----
    command -v git >/dev/null || { info "安装 git ..."; apt-get install -y -qq git >/dev/null; }

    clone_repo() {
        local url="$1" branch="$2" dir="$3" name="$4"
        if [ -d "$dir/.git" ]; then
            info "$name 源码已存在, 更新到最新 ..."
            cd "$dir"
            git fetch origin
            git config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"
            git fetch origin "$branch:refs/remotes/origin/$branch"
            git checkout -B "$branch" "origin/$branch"
            git reset --hard "origin/$branch"
        else
            info "克隆 $name ($branch) ..."
            git clone --branch "$branch" --single-branch "$url" "$dir"
        fi
    }
    clone_repo "$PMAIL_GIT"   "$PMAIL_BRANCH"   "$PMAIL_SRC"   "PMail"
    clone_repo "$GOPHISH_GIT" "$GOPHISH_BRANCH" "$GOPHISH_SRC" "Gophish"

    info "构建 PMail 镜像 ... (首次约 5-10 分钟)"
    cd "$PMAIL_SRC"
    docker build -f Dockerfile -t "$PMAIL_IMAGE" .
    info "PMail 镜像构建完成"

    info "构建 Gophish 镜像 ... (首次约 5-10 分钟)"
    cd "$GOPHISH_SRC"
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
load_or_build

#====================================================================
# 4. 准备数据目录
#====================================================================
prepare_dirs() {
    info "准备数据目录 ..."

    # --- PMail ---
    mkdir -p "$PMAIL_DATA/dkim" "$PMAIL_DATA/ssl"
    if [ ! -f "$PMAIL_DATA/dkim/dkim.priv" ]; then
        openssl genrsa -out "$PMAIL_DATA/dkim/dkim.priv" 2048 2>/dev/null
        info "已生成 DKIM 私钥"
    fi
    if [ ! -f "$PMAIL_DATA/dkim/dkim.public" ]; then
        DKIM_PUB_B64=$(openssl rsa -in "$PMAIL_DATA/dkim/dkim.priv" -pubout -outform DER 2>/dev/null | base64 | tr -d '\n')
        printf 'v=DKIM1; k=rsa; p=%s' "$DKIM_PUB_B64" > "$PMAIL_DATA/dkim/dkim.public"
        info "已生成 DKIM 公钥"
    fi
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
    chown -R 1000:1000 "$GOPHISH_DATA"
    info "数据目录准备完成"
}
prepare_dirs

#====================================================================
# 5. 运行容器 (DNS 指向本机 dnsmasq, 回退内网 DNS)
#====================================================================
run_containers() {
    info "启动容器 ..."

    docker rm -f "$PMAIL_CONTAINER" 2>/dev/null || true
    docker rm -f "$GOPHISH_CONTAINER" 2>/dev/null || true

    docker run -d --name "$PMAIL_CONTAINER" --restart always \
        --dns 172.17.0.1 --dns "$INTERNAL_DNS" \
        -v "$PMAIL_DATA":/work/config \
        -p 25:25 -p 80:80 -p 110:110 -p 443:443 \
        -p 465:465 -p 587:587 -p 993:993 -p 995:995 \
        "$PMAIL_IMAGE"
    info "PMail 容器已启动"

    docker run -d --name "$GOPHISH_CONTAINER" --restart unless-stopped --init \
        -p 0.0.0.0:8081:80 -p 0.0.0.0:62758:3333 \
        -e ADMIN_LISTEN_URL="0.0.0.0:3333" \
        -e ADMIN_USE_TLS="true" \
        -e ADMIN_CERT_PATH="/data/gophish_admin.crt" \
        -e ADMIN_KEY_PATH="/data/gophish_admin.key" \
        -e PHISH_LISTEN_URL="0.0.0.0:80" \
        -e PHISH_USE_TLS="false" \
        -e DB_FILE_PATH="/data/gophish.db" \
        -v "$GOPHISH_DATA":/data \
        "$GOPHISH_IMAGE"
    info "Gophish 容器已启动"
}
run_containers

#====================================================================
# 6. 等待 Gophish 初始化并提取初始密码
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
# 7. 输出结果
#====================================================================
echo ""
echo "============================================================"
echo -e "${GREEN}  内网部署完成!${NC}"
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
echo "  钓鱼页面   : http://$PUBLIC_IP:8081"
echo "  用户名     : admin"
echo "  初始密码   : $GOPHISH_PWD"
echo "  (首次登录会要求修改密码)"
echo ""
echo "============================================================"
echo "  内网 DNS : $INTERNAL_DNS"
echo "  模式     : $([ "$OFFLINE" = "1" ] && echo 离线 || echo 在线)"
echo ""
echo "  数据目录:"
echo "    PMail 配置   : $PMAIL_DATA"
echo "    Gophish 数据 : $GOPHISH_DATA"
echo ""
echo "  常用命令:"
echo "    docker logs -f $PMAIL_CONTAINER"
echo "    docker logs -f $GOPHISH_CONTAINER"
echo "============================================================"
