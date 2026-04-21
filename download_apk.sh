#!/bin/bash
# 监控 GitHub Actions 构建并下载 APK
# 用法: ./download_apk.sh [GITHUB_TOKEN]
#        GITHUB_TOKEN=xxx ./download_apk.sh

set -e

TOKEN="${GITHUB_TOKEN:-$1}"
OWNER="muziyi-gg"
REPO="tinggutonng"
WORKFLOW_NAME="Build Android APK"
ARTIFACT_NAME="tingutong-release-apk"
OUTPUT_DIR="/workspace"

if [ -z "$TOKEN" ]; then
    echo "错误: 请提供 GitHub Token"
    echo "用法: GITHUB_TOKEN=xxx $0"
    exit 1
fi

AUTH_HEADER="Authorization: Bearer $TOKEN"
API_BASE="https://api.github.com"

echo "开始监控构建状态..."

while true; do
    # 获取最新构建
    RUN_ID=$(curl -s -H "$AUTH_HEADER" \
        "$API_BASE/repos/$OWNER/$REPO/actions/workflows/build.yml/runs?per_page=1&branch=main" \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['workflow_runs'][0]['id'] if d['workflow_runs'] else '')" 2>/dev/null)

    if [ -z "$RUN_ID" ]; then
        echo "[$(date '+%H:%M:%S')] 未找到构建记录，等待 30s..."
        sleep 30
        continue
    fi

    # 获取构建状态
    STATUS=$(curl -s -H "$AUTH_HEADER" \
        "$API_BASE/repos/$OWNER/$REPO/actions/runs/$RUN_ID" \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['status'], d['conclusion'])" 2>/dev/null)

    STATUS_LINE=$(echo "$STATUS" | cut -d' ' -f1)
    CONCLUSION=$(echo "$STATUS" | cut -d' ' -f2)

    echo "[$(date '+%H:%M:%S')] 构建状态: $STATUS_LINE | 结果: $CONCLUSION"

    if [ "$STATUS_LINE" == "completed" ]; then
        if [ "$CONCLUSION" == "success" ]; then
            echo "构建成功！开始下载 APK..."

            # 获取 artifact download url
            DOWNLOAD_URL=$(curl -s -H "$AUTH_HEADER" \
                "$API_BASE/repos/$OWNER/$REPO/actions/runs/$RUN_ID/artifacts" \
                | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['artifacts'][0]['archive_download_url'])" 2>/dev/null)

            if [ -z "$DOWNLOAD_URL" ]; then
                echo "未找到 artifact"
                exit 1
            fi

            # 清理旧包（保留最新1个版本）
            echo "清理旧 APK..."
            rm -f $OUTPUT_DIR/app-arm64-v8a-release.apk
            rm -f $OUTPUT_DIR/app-armeabi-v7a-release.apk
            rm -f $OUTPUT_DIR/app-x86_64-release.apk
            rm -f $OUTPUT_DIR/apk_part_*.bin
            rm -rf $OUTPUT_DIR/apk_download
            mkdir -p $OUTPUT_DIR/apk_download

            # 下载并解压
            cd $OUTPUT_DIR/apk_download
            curl -L -o artifact.zip -H "$AUTH_HEADER" "$DOWNLOAD_URL"
            unzip -q artifact.zip
            rm -f artifact.zip

            # 移动 APK 到 workspace 根目录
            mv flutter-apk/*.apk $OUTPUT_DIR/ 2>/dev/null || mv *.apk $OUTPUT_DIR/ 2>/dev/null
            rm -rf flutter-apk apk_download

            echo ""
            echo "下载完成！APK 保存在 /workspace/:"
            ls -lh $OUTPUT_DIR/*.apk 2>/dev/null
            echo ""
            echo "下载链接:"
            for f in $OUTPUT_DIR/*.apk; do
                [ -f "$f" ] && echo "  http://$(curl -s ifconfig.me 2>/dev/null)/$(basename $f)"
            done
        else
            echo "构建失败: $CONCLUSION"
            exit 1
        fi
        break
    fi

    sleep 30
done
