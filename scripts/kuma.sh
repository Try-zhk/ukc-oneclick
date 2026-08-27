#!/usr/bin/env bash
# 从源码构建 Uptime Kuma 镜像并推送（CI 内使用，先装好 unikraft CLI）
# 用法: kuma.sh [版本号，默认 1.23.16]
set -euo pipefail

VER="${1:-1.23.16}"
TOKEN="${UNIKRAFT_API_TOKEN:?缺少 UNIKRAFT_API_TOKEN}"
ORG=$(printf '%s' "$TOKEN" | base64 -d | cut -d: -f1 | sed -e 's/^robot\$//' -e 's/\.users\.kraftcloud$//')
[ -n "$ORG" ] || { echo "无法从 token 解析组织名"; exit 1; }

# 1) 拉源码
git clone --depth 1 --branch "$VER" https://github.com/louislam/uptime-kuma _kuma/src

# 2) 构建前端 + 裁剪依赖
# ⚠️ 构建必须 NODE_ENV=production：kuma 前端会把 NODE_ENV 烤进 bundle，
#    若是 development，前端会硬编码连接 域名:3001（反代环境没有此端口），
#    浏览器报 "xhr poll error"。devDeps 用 --include=dev 安装，不靠 NODE_ENV。
#    原生模块(sqlite3)按 CI 的 glibc 编译/下载，所以基础镜像必须用
#    glibc 的 node:20-slim，不能用 alpine。
cd _kuma/src
npm install --no-audit --no-fund --include=dev
NODE_ENV=production npm run build
npm prune --omit=dev
cd ..

# 3) 组装 rootfs（Docker Hub 限流时走 mirror.gcr.io）
python3 ../scripts/pull-base.py library/node 20-slim rootfs || \
python3 ../scripts/pull-base.py library/node 20-slim rootfs https://mirror.gcr.io
mkdir -p rootfs/app
cp -a src/server src/dist src/db src/node_modules src/package.json rootfs/app/
printf '#!/bin/sh\nmkdir -p /app/data\ncd /app\nexport UPTIME_KUMA_PORT="${UPTIME_KUMA_PORT:-${PORT:-3001}}"\nexec node server/server.js\n' > rootfs/app/start.sh
chmod 755 rootfs/app/start.sh
cat > Kraftfile <<EOF
spec: v0.7
runtime: base-compat:latest
rootfs:
  source: ./rootfs
  format: erofs
cmd: ["/bin/sh", "/app/start.sh"]
EOF

# 4) 构建推送
unikraft build . --output "$ORG/kuma:latest"
echo "镜像: $ORG/kuma:latest"
