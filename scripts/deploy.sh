#!/usr/bin/env bash
# Unikraft Cloud 一键部署脚本（CI 内使用）
# 用法: deploy.sh <prepare|build|deploy>
set -euo pipefail

CLI=unikraft
PHASE="${1:?用法: deploy.sh <prepare|build|deploy>}"

NAME=$(printf '%s' "${PROJECT_NAME:-}" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9-]/-/g' -e 's/^-*//' -e 's/-*$//')
[ -n "$NAME" ] || NAME=$(printf '%s' "${GITHUB_REPOSITORY##*/}" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9-]/-/g')
REGIONS=$(printf '%s' "${REGIONS:-fra,sin}" | tr ',' ' ' | sed 's/ - .*//')  # 兼容 "sin - 新加坡" 下拉格式与 "fra,sin" 旧格式
MEMORY_MB="${MEMORY_MB:-1024}"
APP_PORT="${APP_PORT:-3000}"

login() {
  TOKEN="${UNIKRAFT_API_TOKEN:?缺少 UNIKRAFT_API_TOKEN}"
  ORG=$(printf '%s' "$TOKEN" | base64 -d | cut -d: -f1 | sed -e 's/^robot\$//' -e 's/\.users\.kraftcloud$//')
  [ -n "$ORG" ] || { echo "无法从 token 解析组织名"; exit 1; }
  printf '%s' "$TOKEN" | "$CLI" login --token=- --organization "$ORG" >/dev/null
  echo "已登录 org=$ORG"
}

case "$PHASE" in
prepare)
  # 1) 检测语言
  IS_NODE=0; IS_PY=0
  if [ -f app/package.json ] || [ -f app/index.js ]; then IS_NODE=1; fi
  if [ -f app/main.py ] || [ -f app/app.py ] || [ -f app/index.py ] || [ -f app/requirements.txt ]; then IS_PY=1; fi
  if [ "$IS_NODE" = 1 ] && [ "$IS_PY" = 1 ]; then
    echo "✗ app/ 里同时有 Node 和 Python 的标志文件，请只保留一种语言的代码"; exit 1
  fi
  KIND=""; [ "$IS_NODE" = 1 ] && KIND=node || KIND=python
  [ -n "$KIND" ] || { echo "app/ 里没找到代码：Node 放 index.js(+package.json)，Python 放 main.py/app.py/index.py(+可选 requirements.txt)"; exit 1; }
  PY_ENTRY=main.py
  if [ -f app/app.py ]; then PY_ENTRY=app.py; fi
  if [ -f app/index.py ]; then PY_ENTRY=index.py; fi
  echo "语言: $KIND (入口: $([ "$KIND" = node ] && echo index.js || echo "$PY_ENTRY"))"

  # 2) 拉基础镜像层作为 rootfs
  if [ "$KIND" = node ]; then
    python3 scripts/pull-base.py library/node 20-alpine _build/rootfs
  else
    python3 scripts/pull-base.py library/python 3.12-alpine _build/rootfs
  fi

  # 3) 安装依赖
  if [ "$KIND" = node ] && [ -f app/package.json ]; then
    (cd app && npm install --omit=dev --no-audit --no-fund)
  fi
  if [ "$KIND" = python ] && [ -f app/requirements.txt ]; then
    pip3 install -q -r app/requirements.txt --target app/pylibs
  fi

  # 4) 拷贝代码进 rootfs
  mkdir -p _build/rootfs/app
  cp -a app/. _build/rootfs/app/

  # 5) 决定入口（index.html 存在 → 加首页前置层）
  ENTRY=""
  if [ -f index.html ]; then
    cp index.html _build/rootfs/app/index.html
    if [ "$KIND" = node ]; then
      cp scripts/front-proxy.js _build/rootfs/app/front.js
      ENTRY='/bin/sh|-c|cd /app && exec node front.js'
    else
      cp scripts/front-proxy.py _build/rootfs/app/front.py
      ENTRY='/bin/sh|-c|cd /app && exec python3 -u front.py'
    fi
    echo "检测到 index.html → 已启用自定义首页"
  else
    if [ "$KIND" = node ]; then
      ENTRY='/bin/sh|-c|cd /app && exec node index.js'
    else
      ENTRY="/bin/sh|-c|cd /app && exec python3 -u $PY_ENTRY"
    fi
  fi

  CMD_JSON=$(printf '%s' "$ENTRY" | python3 -c "import json,sys;print(json.dumps(sys.stdin.read().split('|')))")
  cat > _build/Kraftfile <<EOF
spec: v0.7
runtime: base-compat:latest
rootfs:
  source: ./rootfs
  format: erofs
cmd: $CMD_JSON
EOF
  echo "Kraftfile 就绪"
  ;;

build)
  login
  "$CLI" build _build --output "$ORG/$NAME:latest"
  DIGEST=$("$CLI" images list -o json 2>/dev/null | jq -r --arg r "$ORG/$NAME" '.[]|select(.ref==$r)|.digest' | head -1)
  [ -n "$DIGEST" ] || { echo "推送后找不到镜像 digest"; exit 1; }
  echo "镜像: $ORG/$NAME@$DIGEST"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "digest=$DIGEST" >> "$GITHUB_OUTPUT"
  fi
  ;;

deploy)
  login
  # 按名字删旧实例（所有地区），实现“同名即更新”
  "$CLI" instances delete "$NAME" --force >/dev/null 2>&1 || true
  sleep 2
  for R in $REGIONS; do
    R=$(printf '%s' "$R" | xargs)
    [ -n "$R" ] || continue
    echo "== 地区 $R =="
    "$CLI" services create --name "$NAME-$R" --metro "$R" \
        --services "443:$APP_PORT/tls+http" --services "80:443/http+redirect" >/dev/null 2>&1 || true
    EXTRA_ENV=(-e "PORT=$APP_PORT")
    # deploy 阶段是独立进程，KIND/PY_ENTRY 不存在，重新探测（与 prepare 的优先级一致）
    for F in main.py app.py index.py; do
      if [ -f "app/$F" ]; then EXTRA_ENV+=(-e "PY_ENTRY=$F"); break; fi
    done
    if [ -f app/requirements.txt ]; then
      EXTRA_ENV+=(-e "PYTHONPATH=/app/pylibs:/app")
    fi
    "$CLI" run --metro "$R" --name "$NAME" -m "${MEMORY_MB}M" \
        --service "$NAME-$R" --scale-to-zero policy=off \
        "${EXTRA_ENV[@]}" --image "$ORG/$NAME@${DIGEST:?缺 digest}"
  done
  sleep 6
  echo ""
  echo "===== 部署完成 ====="
  "$CLI" instances list -o json 2>/dev/null | jq -r --arg n "$NAME" \
      '.[]|select(.name==$n)|"\(.metro)\t\(.state)\thttps://\(.domains[0].fqdn // .fqdn // "?")"' |
      while IFS=$'\t' read -r m s u; do printf '%-4s %-8s %s\n' "$m" "$s" "$u"; done
  ;;

*)
  echo "未知阶段: $PHASE"; exit 1;;
esac
