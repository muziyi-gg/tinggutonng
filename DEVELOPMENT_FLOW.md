# 听股通 App 开发流程

## 1. 工作流总览

```
本地沙盒修改代码 → 推送 GitHub → GitHub Actions 自动构建 → 下载 APK 到 workspace/app_debug/
```

## 2. 详细流程

### 2.1 本地修改代码
在沙盒 `/workspace/android/` 目录下修改 Flutter/Kotlin 代码。

### 2.2 推送 GitHub
```bash
cd /workspace
git add -A
git commit -m "描述改动"
git push
```
> ⚠️ `.github/workflows/build.yml` 的修改**不触发构建**（paths-ignore），需配合代码改动一起推送。

### 2.3 等待 GitHub Actions 构建
- 每 45 秒轮询一次状态
- 最多等待 10 分钟（约 13 轮）
- 构建成功 → 下载 APK
- 构建失败 → 分析原因 → 修复 → 重新推送

### 2.4 下载 APK 到 workspace
构建成功后，从 GitHub Release 下载 APK 并保存到 `workspace/app_debug/`。

清理规则：每次构建新包后，删除 workspace 下前 2 个版本之前的 APK 包，只保留最新 1 个。

### 2.5 验证
下载完成后验证 APK 是否存在且大小正常。

## 3. 当前已知问题

### APK 下载失败
- GitHub Actions 的 artifact（`actions/upload-artifact`）需要认证才能下载，匿名 API 返回 401
- 解决方案：使用 `softprops/action-gh-release` 发布到 GitHub Release，这是永久公开链接，无需认证

### Build 失败（持续排查中）
- Run #147 是最近一次成功构建（2026-04-24 23:46）
- 之后 7 次构建全部失败，失败步骤：`Build release APK`
- 原因未明：沙盒中 build 成功，GitHub Actions 环境失败
- 可能原因：环境缓存问题、Flutter SDK 状态不一致
- **诊断方法**：在 workflow 中将 build log 发布到可公开访问的位置

## 4. Workflow 配置（当前）

文件：`.github/workflows/build.yml`

关键配置：
- Flutter 版本：`3.19.0`
- 构建命令：`flutter build apk --release`
- 成功时：发布 APK 到 GitHub Release（永久链接）
- 总是上传 build log（retention 3 天）
- 触发条件：`paths-ignore: .github/workflows/**`（workflow 自身修改不触发）
- 构建失败时：自动重试一次

## 5. 常用命令

```bash
# 查看本地文件
ls -lh /workspace/app_debug/

# 查看最近提交
git log --oneline -5

# 查看 GitHub Actions 状态
curl -s https://api.github.com/repos/muziyi-gg/tinggutonng/actions/runs?per_page=1 | python3 -c "import sys,json; r=json.load(sys.stdin)['workflow_runs'][0]; print(f'#{r[\"run_number\"]} | {r[\"status\"]} | {r.get(\"conclusion\",\"?\")}')"

# 手动触发 workflow_dispatch（需要 GitHub token，当前无权限）
curl -X POST -H "Authorization: token TOKEN" https://api.github.com/repos/muziyi-gg/tinggutonng/actions/workflows/build.yml/dispatches -d '{"ref":"main"}'
```

## 6. APK 版本信息

| 版本 | 文件名 | 大小 | 时间 |
|------|--------|------|------|
| v1.4.9 (最新有效) | tinggutong-v1.4.9-arm64-v8a.apk | 16M | 2026-04-23 |
| v1.4.9 | tinggutong-v1.4.9-armeabi-v7a.apk | 14M | 2026-04-23 |
| v1.4.9 | tinggutong-v1.4.9-x86_64.apk | 17M | 2026-04-23 |

> ⚠️ GitHub Actions 构建的 APK 尚未成功下载到本地（Build #147 成功但下载 artifact 失败）

## 7. GitHub Releases

当前只有一个手动创建的 release（tinggutong），APK 在本地沙盒中，不在 GitHub 上。

## 8. 关键文件路径

- 代码目录：`/workspace/android/`
- APK 输出：`/workspace/app_debug/`
- Workflow：`.github/workflows/build.yml`
- Flutter pubspec：`/workspace/android/pubspec.yaml`
- 流程文档：`/workspace/DEVELOPMENT_FLOW.md`（本文件）