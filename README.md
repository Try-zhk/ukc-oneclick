# Unikraft Cloud 一键部署

把 `app/` 里的代码推上 GitHub，然后**手动**在 Actions 页面点部署，发布到 Unikraft Cloud（全球多地区）。push 不会自动部署，什么时候发布由你决定。

## 首次配置（3 分钟）

1. **建仓库**：把这个项目上传/推到你的 GitHub 仓库（建议 Private）
2. **加 Secret**：仓库 Settings → Secrets and variables → Actions → New repository secret
   - Name: `UNIKRAFT_API_TOKEN`
   - Value: 你的 Unikraft Cloud API token（控制台 Settings → API Keys 里拿）
3. **可选变量**（同页面的 Variables 标签，不设就用默认值）：

   | 变量名 | 默认值 | 说明 |
   |---|---|---|
   | `DEPLOY_REGIONS` | `fra,sin` | 地区，逗号分隔 |
   | `PROJECT_NAME` | 仓库名 | 项目名（实例/服务/镜像都用它，同名=更新） |
   | `MEMORY_MB` | `1024` | 每实例内存 |
   | `APP_PORT` | `3000` | 应用监听端口 |

## 可用地区

| 代码 | 地区 |
|---|---|
| `fra` | 🇩🇪 法兰克福 |
| `sin` | 🇸🇬 新加坡 |
| `dal` | 🇺🇸 达拉斯 |
| `sfo` | 🇺🇸 旧金山 |
| `was` | 🇺🇸 华盛顿 |

## 怎么用

### 部署（手动触发）
把代码放进 `app/`，push 到 `main` 分支（只是保存代码，不会部署）。
然后：Actions → **Deploy to Unikraft Cloud** → Run workflow → 表单里填项目名、勾选地区、内存、端口 → 运行。

### 更新
改完代码 push，再跑一次 workflow。**同名即更新**：实例会先删后建（中断约几十秒）。

### 删除资源
Actions → **Destroy** → Run workflow：
- `target` 填 `all` → 清空账号下**全部**实例/服务/镜像
- `target` 填项目名（如 `woserwe`）→ 只删该项目的实例（含所有地区）、服务和镜像

两种方式都要再填 `DELETE` 确认，不可恢复。

## 放什么文件

```
├── app/                  ← 你的应用代码放这里（放之前清空示例文件）
│   ├── index.js          Node 应用入口
│   ├── package.json      npm 依赖（有就自动 npm install）
│   └── main.py           Python 入口（main.py / app.py / index.py 任选其一）
├── index.html            ← 可选！放了它，访问 / 就是这个页面，
│                            其余路径照常到你的应用
└── .github/workflows/    ← 部署流水线（不用动）
```

- **Node.js**：有 `app/index.js` 或 `app/package.json` 就识别为 Node（Node 20），入口固定 `index.js`
- **Python**：有 `main.py` / `app.py` / `index.py` 或 `requirements.txt` 就识别为 Python（3.12），入口按这个顺序探测；依赖写进 `requirements.txt`
- 两种语言的标志文件别混放，脚本会报错提醒
- 应用必须监听环境变量 `PORT` 给的端口（示例代码就是这么写的）

## 跑现成的 Docker / ghcr 镜像

公开镜像可以直接导入（本地或 Codespaces 跑，CI 里也能跑）：

```bash
export UNIKRAFT_API_TOKEN=<你的token>
bash scripts/anyimage.sh ghcr.io/atryhk/railway.temp:lastly   # [实例名] 可选第二个参数
# 构建完按提示部署：
PROJECT_NAME=atryhk-railway-temp APP_PORT=3000 REGIONS=sin bash scripts/deploy.sh deploy
```

脚本自动：拉取镜像层做 rootfs → 读出 ENTRYPOINT/CMD/ENV/WORKDIR → 生成 `/start.sh` → 构建推送。
私有镜像暂不支持（需要带凭据拉取）；镜像内应用监听的端口自己填 `APP_PORT`。

### 已知坑：应用启动卡死、接口 404、CPU 0%

症状：容器活着但某路由一直 404、CPU 为 0 —— 多半是应用启动时要下载外部二进制（如
argo 用 `*.ssss.nyc.mn` 中转源），而这类免费中转源的权威 DNS 时好时坏，UKC 内解析失败就永远卡住。
排查方法：部署调试实例用 `node -e 'require("dns").promises.lookup(...)'` 测域名；
修法：往打包好的 rootfs 的 `/etc/hosts` 里钉一行该域名的 Cloudflare IP（CF anycast 大段都通），重新 build 部署即可。
另外注意 registry 配额只有 1GiB：同名镜像反复 push 会累积旧层，403 "exceed upper limit" 就是爆了，
删掉没实例引用的镜像再推。

## 预置应用

| Workflow | 说明 |
|---|---|
| `deploy.yml` | 部署你自己的项目（`app/` 目录，Node/Python） |
| `komari.yml` | Komari 监控面板（官方 ghcr 镜像直装，25774 端口，512M+1G 卷） |
| `kuma.yml` | Uptime Kuma（源码构建，3001 端口，1G 卷） |
| `destroy.yml` | 清理资源 |

## 换自定义域名

两种方式，选一个：

**方式 A：UKC 原生绑定（最简单）**
1. 在你的 DNS 加 CNAME：`monitor.你的域名 → komari-sin-xxxx.sin.unikraft.app`（实例的 FQDN，控制台能看）
2. 绑定到 service 并自动签证书：
   ```bash
   unikraft services edit komari-sin \
     --domains komari-sin-xxxx.sin.unikraft.app \
     --domains monitor.你的域名
   ```
   之后 `https://monitor.你的域名` 直接可用。

**方式 B：Cloudflare Worker 反代（域名托管在 CF 时推荐）**
不改 UKC 任何配置，Worker 全量转发（含 WebSocket，komari 实时数据正常）：

```js
export default {
  async fetch(req) {
    const url = new URL(req.url);
    url.hostname = "komari-sin-dm44lj4d.sin.unikraft.app"; // 换成你的实例 FQDN
    return fetch(new Request(url, req));
  },
};
```

Worker 绑定自定义域（Workers 路由 → 你的域名）后即可访问。优点：换后端只改一行、
可叠加 CF 的 WAF/缓存；注意 CF 代理下 UKC 侧看到的是 CF 的 IP。

## 注意事项

- 带自定义首页的部署里有个诊断端点 `/__trace`（记录应用出站请求/子进程命令）。**默认 404 关闭**；
  仓库 Variables 里设 `TRACE_KEY` 后，用 `/__trace?key=<TRACE_KEY>` 访问
- 实例默认**常驻运行**（不休眠归零）：休眠唤醒会重新初始化，不稳定。多地区×大内存注意配额
- Unikraft Cloud 不是 VPS：没有 systemd/apt/iptables/Docker-in-Docker，装服务型一键脚本的玩法不行；但"一个程序 + 监听端口"的镜像用 anyimage.sh 导入即可
- Python 的自定义首页前置层不透传 WebSocket；需要 WS 的 Python 应用别放 `index.html`
- token 走 GitHub Secrets，不会出现在日志和代码里；公开仓库也安全，但仍建议私有
