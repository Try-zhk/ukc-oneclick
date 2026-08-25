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
    auth = ("https://auth.docker.io/token?service=registry.docker.io"
            "&scope=repository:%s:pull" % repo)
    token = fetch_json(auth)["token"]
    reg = "https://registry-1.docker.io/v2/%s/manifests/%s" % (repo, tag)

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
        man = fetch_json("https://registry-1.docker.io/v2/%s/manifests/%s" % (repo, digest), token)
    else:
        man = idx

    os.makedirs(dest, exist_ok=True)
    layers = man.get("layers", [])
    for i, layer in enumerate(layers):
        url = "https://registry-1.docker.io/v2/%s/blobs/%s" % (repo, layer["digest"])
        req = urllib.request.Request(url, headers={"Authorization": "Bearer " + token})
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


if __name__ == "__main__":
    main()
