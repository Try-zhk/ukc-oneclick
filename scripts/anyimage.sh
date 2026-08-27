#!/usr/bin/env bash
# 通用 OCI/Docker 镜像导入器：把 ghcr.io / Docker Hub 的公开镜像转成 UKC 实例
# 用法: anyimage.sh <镜像ref> [实例名]
# 例:   anyimage.sh ghcr.io/atryhk/railway.temp:lastly
#       anyimage.sh library/redis:7 redis
set -euo pipefail
cd "$(dirname "$0")/.."   # 仓库根目录

REF="${1:?用法: anyimage.sh <镜像ref> [实例名]}"
TOKEN="${UNIKRAFT_API_TOKEN:?缺少 UNIKRAFT_API_TOKEN}"
ORG=$(printf '%s' "$TOKEN" | base64 -d | cut -d: -f1 | sed -e 's/^robot\$//' -e 's/\.users\.kraftcloud$//')

# 解析 registry / repo / tag
case "$REF" in
  ghcr.io/*)   REG="https://ghcr.io";              REPO="${REF#ghcr.io/}" ;;
  docker.io/*) REG="https://registry-1.docker.io"; REPO="${REF#docker.io/}" ;;
  *)           REG="https://registry-1.docker.io"; REPO="$REF" ;;
esac
case "$REPO" in
  */*) ;;                       # owner/name 保持
  *)   REPO="library/$REPO" ;;  # docker hub 官方镜像补 library/
esac
if [[ "$REPO" == *:* ]]; then TAG="${REPO##*:}"; REPO="${REPO%:*}"; else TAG="latest"; fi
NAME="${2:-$(printf '%s' "$REPO" | tr '/.' '--' | tr '[:upper:]' '[:lower:]')}"
echo "镜像: $REG/v2/$REPO:$TAG → 实例名: $NAME"

# 1) 拉 rootfs + 读启动配置
mkdir -p _img
OUT=$(python3 scripts/pull-base.py "$REPO" "$TAG" _img/rootfs "$REG")
echo "$OUT" | tail -1
CFG_LINE=$(echo "$OUT" | grep '^IMAGE_CONFIG=' || true)
[ -n "$CFG_LINE" ] || { echo "镜像没有 config（无法确定启动命令）"; exit 1; }
CFG="${CFG_LINE#IMAGE_CONFIG=}"

# 2) 生成 /start.sh：还原镜像的 ENV / WORKDIR / ENTRYPOINT / CMD
python3 - "$CFG" > _img/rootfs/start.sh <<'PY'
import json, shlex, sys
c = json.loads(sys.argv[1])
print("#!/bin/sh")
for e in c["env"]:
    if "=" in e:
        k, _, v = e.partition("=")
        print("export %s=%s" % (k, shlex.quote(v)))
if not any(e.startswith("PATH=") for e in c["env"]):
    print('export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"')
wd = c["working_dir"]
print('cd %s 2>/dev/null || cd /' % shlex.quote(wd))
argv = c["entrypoint"] + c["cmd"]
if not argv:
    sys.exit("镜像没有 ENTRYPOINT/CMD")
print("exec " + " ".join(shlex.quote(a) for a in argv))
PY
chmod 755 _img/rootfs/start.sh
echo "--- start.sh ---"; cat _img/rootfs/start.sh

# 3) Kraftfile（cmd 走 start.sh，规避部分地区对复杂 cmd 的兼容问题）
cat > _img/Kraftfile <<EOF
spec: v0.7
runtime: base-compat:latest
rootfs:
  source: ./rootfs
  format: erofs
cmd: ["/bin/sh", "/start.sh"]
EOF

# 4) 构建推送（Docker Hub 限流时 pull-base 已内置 mirror 兜底，这里无需处理）
unikraft build _img --output "$ORG/$NAME:latest"
echo "完成: $ORG/$NAME:latest"
echo "部署: PROJECT_NAME=$NAME APP_PORT=<应用端口> REGIONS=sin bash scripts/deploy.sh deploy"
