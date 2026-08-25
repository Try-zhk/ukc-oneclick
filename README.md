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

## 注意事项

- 实例默认**常驻运行**（不休眠归零）：休眠唤醒会重新初始化，不稳定。多地区×大内存注意配额
- Unikraft Cloud 不是普通容器平台：只支持上述打包方式，不支持任意 Docker 镜像 / Dockerfile
- Python 的自定义首页前置层不透传 WebSocket；需要 WS 的 Python 应用别放 `index.html`
- token 走 GitHub Secrets，不会出现在日志和代码里；公开仓库也安全，但仍建议私有
