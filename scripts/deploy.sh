#!/usr/bin/env bash
# Unikraft Cloud 一键部署脚本（CI 内使用）
# 用法: deploy.sh <prepare|build|deploy>
set -euo pipefail

CLI=unikraft
PHASE="${1:?用法: deploy.sh <prepare|build|deploy>}"

NAME=$(printf '%s' "${PROJECT_NAME:-}" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9-]/-/g' -e 's/^-*//' -e 's/-*$//')
[ -n "$NAME" ] || NAME=$(printf '%s' "${GITHUB_REPOSITORY##*/}" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9-]/-/g')
RAW_REGIONS="${REGIONS:-fra,sin}"
# 下拉选了 "all - 全部地区" 时展开成全部地区；其余情况按逗号拆分，
# 并去掉下拉自带的 " - 中文说明" 后缀，兼容 "sin - 新加坡" 与 "fra,sin" 两种输入。
if printf '%s' "$RAW_REGIONS" | sed -e 's/ - .*//' -e 's/^ *//' -e 's/ *$//' | grep -qx 'all'; then
  RAW_REGIONS="sin,dal,fra,sfo,was"
fi
REGIONS=$(printf '%s' "$RAW_REGIONS" | tr ',' '\n' | sed -e 's/ - .*//' -e 's/^ *//' -e 's/ *$//' | tr '\n' ' ')
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
  KIND=""
  if [ -f app/package.json ] || [ -f app/index.js ]; then KIND=node; fi
  if [ -f app/main.py ] || [ -f app/requirements.txt ]; then KIND=python; fi
  [ -n "$KIND" ] || { echo "app/ 里没找到 index.js(Node) 或 main.py(Python)"; exit 1; }
  echo "语言: $KIND"

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
      ENTRY='/bin/sh|-c|cd /app && exec python3 -u main.py'
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
  FAILED=()
  OK=()
  for R in $REGIONS; do
    R=$(printf '%s' "$R" | xargs)
    [ -n "$R" ] || continue
    echo "== 地区 $R =="
    INAME="$NAME-$R"

    # 按地区清理旧实例/旧服务（必须显式带 --metro，否则只会作用于 CLI 默认地区，
    # 导致别的地区残留旧资源、新建时因同名/配额冲突而失败）
    "$CLI" instances delete "$INAME" --metro "$R" --force >/dev/null 2>&1 || true
    "$CLI" services delete "$INAME" --metro "$R" >/dev/null 2>&1 || true
    sleep 2

    if ! SVC_ERR=$("$CLI" services create --name "$INAME" --metro "$R" \
        --services "443:$APP_PORT/tls+http" --services "80:443/http+redirect" 2>&1); then
      if printf '%s' "$SVC_ERR" | grep -qi "already exists"; then
        echo "  [$R] service 已存在，复用（同名即更新）"
      else
        echo "  [$R] 创建 service 失败:"
        echo "$SVC_ERR" | sed 's/^/    /'
        FAILED+=("$R")
        continue
      fi
    fi

    EXTRA_ENV=(-e "PORT=$APP_PORT")
    if [ -f app/requirements.txt ]; then
      EXTRA_ENV+=(-e "PYTHONPATH=/app/pylibs:/app")
    fi
    if ! RUN_ERR=$("$CLI" run --metro "$R" --name "$INAME" -m "${MEMORY_MB}M" \
        --service "$INAME" --scale-to-zero policy=off \
        "${EXTRA_ENV[@]}" --image "$ORG/$NAME@${DIGEST:?缺 digest}" 2>&1); then
      echo "  [$R] 创建实例失败:"
      echo "$RUN_ERR" | sed 's/^/    /'
      FAILED+=("$R")
      continue
    fi
    echo "  [$R] OK"
    OK+=("$R")
  done

  sleep 6
  echo ""
  echo "===== 部署结果 ====="
  for R in "${OK[@]:-}"; do
    [ -n "$R" ] || continue
    if LIST_JSON=$("$CLI" instances list --metro "$R" -o json 2>/dev/null); then
      LIST_RC=0
    else
      LIST_RC=$?
    fi
    if [ "$LIST_RC" -ne 0 ] || [ -z "$LIST_JSON" ]; then
      echo "  [$R] 部署已成功，但查询状态暂时失败（接口响应慢或状态还没同步），稍后可到 Unikraft 控制台/CLI 自行查看"
      continue
    fi
    printf '%s' "$LIST_JSON" | jq -r --arg n "$NAME-$R" \
        '.[]|select(.name==$n)|"\(.metro)\t\(.state)\thttps://\(.domains[0].fqdn // .fqdn // "?")"' 2>/dev/null |
        while IFS=$'\t' read -r m s u; do printf '%-4s %-8s %s\n' "$m" "$s" "$u"; done || true
  done
  if [ "${#FAILED[@]}" -gt 0 ]; then
    echo ""
    echo "以下地区部署失败: ${FAILED[*]}（原因见上方日志，常见于该地区在当前账号/套餐下不可用或配额不足）"
    exit 1
  fi
  ;;

*)
  echo "未知阶段: $PHASE"; exit 1;;
esac
