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

  # 2) 拉基础镜像层作为 rootfs（Docker Hub 限流时走 mirror.gcr.io）
  if [ "$KIND" = node ]; then
    python3 scripts/pull-base.py library/node 20-alpine _build/rootfs || \
    python3 scripts/pull-base.py library/node 20-alpine _build/rootfs https://mirror.gcr.io
  else
    python3 scripts/pull-base.py library/python 3.12-alpine _build/rootfs || \
    python3 scripts/pull-base.py library/python 3.12-alpine _build/rootfs https://mirror.gcr.io
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
  # 修复: 部分地区(dal等)的运行时处理不了 cmd 里带 && / 空格的 sh -c，会秒退 exit 0
  #       → 一律改用 start.sh 脚本启动，cmd 只留两个干净参数
  if [ -f index.html ]; then
    cp index.html _build/rootfs/app/index.html
    if [ "$KIND" = node ]; then
      cp scripts/front-proxy.js _build/rootfs/app/front.js
      printf '#!/bin/sh\ncd /app\nexec node front.js\n' > _build/rootfs/app/start.sh
    else
      cp scripts/front-proxy.py _build/rootfs/app/front.py
      printf '#!/bin/sh\ncd /app\nexec python3 -u front.py\n' > _build/rootfs/app/start.sh
    fi
    echo "检测到 index.html → 已启用自定义首页"
  else
    if [ "$KIND" = node ]; then
      printf '#!/bin/sh\ncd /app\nexec node index.js\n' > _build/rootfs/app/start.sh
    else
      printf '#!/bin/sh\ncd /app\nexec python3 -u %s\n' "$PY_ENTRY" > _build/rootfs/app/start.sh
    fi
  fi
  chmod 755 _build/rootfs/app/start.sh

  cat > _build/Kraftfile <<EOF
spec: v0.7
runtime: base-compat:latest
rootfs:
  source: ./rootfs
  format: erofs
cmd: ["/bin/sh", "/app/start.sh"]
EOF
  echo "Kraftfile 就绪"
  ;;

build)
  login
  "$CLI" build _build --output "$ORG/$NAME:latest"
  # 修复: 不再捕获 digest —— images list 有最终一致性延迟，CI 拿到旧 digest
  # 会导致 deploy 报 "No image with name"。改用 :latest 标签部署，注册表自己解析。
  echo "镜像: $ORG/$NAME:latest"
  ;;

deploy)
  login
  # 按名字删旧实例，实现“同名即更新”。
  # 注意: CLI 的 instances delete 不支持 --metro 且名字按地区隔离，
  # 必须按 uuid 逐个删才能清掉所有地区的同名实例
  for ID in $("$CLI" instances list -o json 2>/dev/null | jq -r --arg n "$NAME" '.[]|select(.name==$n)|.uuid'); do
    "$CLI" instances delete "$ID" --force >/dev/null 2>&1 || true
  done
  sleep 2
  for R in $REGIONS; do
    R=$(printf '%s' "$R" | xargs)
    [ -n "$R" ] || continue
    echo "== 地区 $R =="
    # "already exists" 类错误视为成功；其余（权限/配额等）直接终止，不能静默吞掉
    if ! OUT=$("$CLI" services create --name "$NAME-$R" --metro "$R" \
        --services "443:$APP_PORT/tls+http" --services "80:443/http+redirect" 2>&1); then
      echo "$OUT" | grep -qi "already exists\|in use\|conflict" || \
        { echo "✗ service 创建失败($R):"; echo "$OUT" | tail -3; exit 1; }
    fi
    EXTRA_ENV=(-e "PORT=$APP_PORT")
    [ -n "${TRACE_KEY:-}" ] && EXTRA_ENV+=(-e "TRACE_KEY=$TRACE_KEY")
    # deploy 阶段是独立进程，KIND/PY_ENTRY 不存在，重新探测（与 prepare 的优先级一致）
    for F in main.py app.py index.py; do
      if [ -f "app/$F" ]; then EXTRA_ENV+=(-e "PY_ENTRY=$F"); break; fi
    done
    if [ -f app/requirements.txt ]; then
      EXTRA_ENV+=(-e "PYTHONPATH=/app/pylibs:/app")
    fi
    # 可选持久卷（如 kuma 的 DATA_VOLUME=kuma-data），卷按地区各建一个
    VOLARG=()
    if [ -n "${DATA_VOLUME:-}" ]; then
      VOL="$DATA_VOLUME-$R"
      if ! OUT=$("$CLI" volumes create --name "$VOL" --metro "$R" --size "${VOLUME_MB:-1024}" 2>&1); then
        echo "$OUT" | grep -qi "already exists\|in use\|conflict" || \
          { echo "✗ volume 创建失败($R):"; echo "$OUT" | tail -3; exit 1; }
      fi
      VOLARG=(-v "$VOL:/app/data")
    fi
    # 大镜像推送后各地区同步有延迟，"No image" 时等待重试
    OK=0
    for A in 1 2 3 4 5; do
      OUT=$("$CLI" run --metro "$R" --name "$NAME" -m "${MEMORY_MB}M" \
          --service "$NAME-$R" --scale-to-zero policy=off \
          "${EXTRA_ENV[@]}" "${VOLARG[@]}" --image "$ORG/$NAME:latest" 2>&1) && \
          { echo "$OUT" | grep -m1 state || true; OK=1; break; }
      if echo "$OUT" | grep -q "No image"; then
        echo "  镜像同步中,20s后重试($A/5)"; sleep 20
      else
        break
      fi
    done
    # 真失败必须让 CI 变红（配额超限这类错误文本里没有 "error" 字样，不能 grep）
    [ "$OK" = 1 ] || { echo "✗ 地区 $R 实例启动失败:"; echo "$OUT" | tail -5; exit 1; }
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
