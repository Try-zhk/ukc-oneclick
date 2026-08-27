#!/usr/bin/env python3
"""从 Docker Hub 匿名拉取官方基础镜像的 linux/amd64 层，解包为 rootfs 目录。
用法: pull-base.py <repo> <tag> <dest>
例:   pull-base.py library/node 20-alpine _build/rootfs
"""
import json
import os
import subprocess
import sys
import urllib.request

ACCEPT = ",".join([
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.v2+json",
])


def fetch_json(url, token=None):
    req = urllib.request.Request(url)
    if token:
        req.add_header("Authorization", "Bearer " + token)
    req.add_header("Accept", ACCEPT)
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read())


def main():
    repo, tag, dest = sys.argv[1], sys.argv[2], sys.argv[3]
    # 可选第4参数: registry 基地址（Docker Hub 被限流时可用 https://mirror.gcr.io，
    # ghcr.io 镜像用 https://ghcr.io）
    reg_base = sys.argv[4] if len(sys.argv) > 4 else "https://registry-1.docker.io"
    if "ghcr.io" in reg_base:
        # ghcr 公共镜像也要匿名 bearer token
        token = fetch_json("https://ghcr.io/token?scope=repository:%s:pull" % repo)["token"]
    elif "registry-1.docker.io" in reg_base:
        auth = ("https://auth.docker.io/token?service=registry.docker.io"
                "&scope=repository:%s:pull" % repo)
        token = fetch_json(auth)["token"]
    else:
        token = None  # mirror.gcr.io 匿名即可
    reg = "%s/v2/%s/manifests/%s" % (reg_base, repo, tag)

    idx = fetch_json(reg, token)
    if "manifests" in idx:  # 多架构索引 → 选 linux/amd64（跳过 attestation）
        digest = None
        for m in idx["manifests"]:
            p = m.get("platform") or {}
            ann = m.get("annotations") or {}
            if (p.get("os") == "linux" and p.get("architecture") == "amd64"
                    and ann.get("vnd.docker.reference.type") != "attestation-manifest"):
                digest = m["digest"]
                break
        if not digest:
            sys.exit("%s:%s 没有 linux/amd64 版本" % (repo, tag))
        man = fetch_json("%s/v2/%s/manifests/%s" % (reg_base, repo, digest), token)
    else:
        man = idx

    os.makedirs(dest, exist_ok=True)
    layers = man.get("layers", [])
    for i, layer in enumerate(layers):
        url = "%s/v2/%s/blobs/%s" % (reg_base, repo, layer["digest"])
        headers = {"Authorization": "Bearer " + token} if token else {}
        req = urllib.request.Request(url, headers=headers)
        tmp = "/tmp/_ukc_layer_%d.bin" % i
        with urllib.request.urlopen(req, timeout=600) as r, open(tmp, "wb") as f:
            while True:
                chunk = r.read(1 << 20)
                if not chunk:
                    break
                f.write(chunk)
        subprocess.run(["tar", "xzf", tmp, "-C", dest], check=False)
        os.remove(tmp)
        print("  layer %d/%d ok (%d B)" % (i + 1, len(layers), layer.get("size", 0)))
    print("rootfs 就绪: %s" % dest)

    # 输出镜像的启动配置（供 anyimage.sh 生成 start.sh）
    cfg_ref = (man.get("config") or {}).get("digest")
    if cfg_ref:
        url = "%s/v2/%s/blobs/%s" % (reg_base, repo, cfg_ref)
        headers = {"Authorization": "Bearer " + token} if token else {}
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req, timeout=120) as r:
            cfg = json.loads(r.read())
        c = cfg.get("config") or {}
        print("IMAGE_CONFIG=" + json.dumps({
            "entrypoint": c.get("Entrypoint") or [],
            "cmd": c.get("Cmd") or [],
            "working_dir": c.get("WorkingDir") or "/",
            "env": c.get("Env") or [],
        }, ensure_ascii=False))


if __name__ == "__main__":
    main()
