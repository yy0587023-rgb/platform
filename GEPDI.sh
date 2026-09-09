#!/bin/bash
set -e

# 核心系统代码所在目录
GPEID_DIR="/app/yak/server/uploadPath/upload/GPEID"

# ==============================================================================
# 1. 配置 Java 与显示环境变量
# ==============================================================================
export JAVA_HOME=$GPEID_DIR/jdk-17.0.12
export INSTALL4J_JAVA_HOME=$GPEID_DIR/jdk-17.0.12
export PATH=$JAVA_HOME/bin:$PATH
export DISPLAY=:99

TARGET_PATH="$1"

if [ -z "$TARGET_PATH" ]; then
    echo "❌ 错误：未传入分析文件或目录！用法: $0 <文件或文件夹路径>"
    exit 1
fi

# 判断传入的是文件夹还是文件，自动锁定 WORK_DIR 与 INPUT_FILE
if [ -d "$TARGET_PATH" ]; then
    WORK_DIR="$TARGET_PATH"
    INPUT_FILE=$(ls -t "$WORK_DIR"/*.txt 2>/dev/null | head -n 1)
else
    WORK_DIR=$(dirname "$TARGET_PATH")
    INPUT_FILE="$TARGET_PATH"
fi

FILENAME=$(basename "$INPUT_FILE")
PREFIX="${FILENAME%.*}"

echo "=== 1. 检查并启动 Xvfb 虚拟显示服务 ==="
if ! ps -ef | grep -v grep | grep -q "Xvfb :99"; then
    echo "--> 正在启动 Xvfb :99..."
    Xvfb :99 -screen 0 1920x1080x24 > /dev/null 2>&1 &
    sleep 2
else
    echo "--> ✅ Xvfb :99 已在运行中。"
fi

echo "=== 2. 检查并启动 Cytoscape REST 服务 ==="
if ! curl -s http://localhost:12345/v1/version > /dev/null 2>&1; then
    echo "--> Cytoscape 未启动，正在后台拉起服务 (日志存至 /app/yak/cytoscape.log)..."
    cd /app/yak/Cytoscape
    nohup ./cytoscape.sh -R 12345 > /app/yak/cytoscape.log 2>&1 &
    
    echo "--> 正在等待 Cytoscape REST API 连通 (最多等待 45 秒)..."
    RETRY=0
    MAX_RETRY=45
    until curl -s http://localhost:12345/v1/version > /dev/null 2>&1; do
        sleep 1
        RETRY=$((RETRY+1))
        echo -n "."
        if [ $RETRY -ge $MAX_RETRY ]; then
            echo ""
            echo "❌ 错误：Cytoscape 服务启动超时！"
            exit 1
        fi
    done
    echo ""
    echo "--> ✅ Cytoscape REST API 服务连接成功！"
else
    echo "--> ✅ Cytoscape REST API 服务已在运行中。"
fi

# 切换到用户的 pedigree 目录，确保 R 和 Python 算出的结果直接落盘到此处
cd "$WORK_DIR"

echo "=== 3. 运行 R 脚本进行系谱计算 ==="
R_SCRIPT="$GPEID_DIR/GPEDI.r"
[ ! -f "$R_SCRIPT" ] && R_SCRIPT="$GPEID_DIR/run_gpedi_pipeline.R"

echo "--> 执行: Rscript $R_SCRIPT $INPUT_FILE $PREFIX"
Rscript "$R_SCRIPT" "$INPUT_FILE" "$PREFIX"

echo "=== 4. 运行 Python 脚本生成 Cytoscape 系谱图 ==="
echo "--> 执行: python3 $GPEID_DIR/build_network.py $WORK_DIR"
python3 "$GPEID_DIR/build_network.py" "$WORK_DIR"

echo "=================================================="
echo "🎉 所有任务自动化执行完成！"
echo "结果导出路径 (与输入文件在同一目录):"
echo " 1. 高清矢量系谱图: $WORK_DIR/GPEID_pedigree_reslult.svg"
echo " 2. 结果数据目录:   $WORK_DIR/"
echo "=================================================="