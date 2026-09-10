#!/bin/bash

# ==============================================================================
# 1. 基础配置与环境变量设置
# ==============================================================================
export JAVA_HOME=/app/yak/server/uploadPath/upload/GPEID/jdk-17.0.12
export INSTALL4J_JAVA_HOME=/app/yak/server/uploadPath/upload/GPEID/jdk-17.0.12
export PATH=$JAVA_HOME/bin:$PATH
export DISPLAY=:99

UPLOAD_BASE_DIR="/app/yak/server/uploadPath/upload"
TOOLS_DIR="/app/yak/server/uploadPath/upload/GPEID"
SCAN_INTERVAL=10

R_SCRIPT_NAME="run_gpedi_pipeline.R"
if [ ! -f "$TOOLS_DIR/$R_SCRIPT_NAME" ] && [ -f "$TOOLS_DIR/GPEDI.r" ]; then
    R_SCRIPT_NAME="GPEDI.r"
fi

# ==============================================================================
# 2. 全局服务初始化 (Xvfb & Cytoscape REST)
# ==============================================================================
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

# ==============================================================================
# 3. 核心处理函数 (解压平铺、智能找表、调用 R/Python)
# ==============================================================================
process_task_dir() {
    local task_dir="$1"
    
    local status_processing="$task_dir/.processing"
    local status_done="$task_dir/.done"
    local status_error="$task_dir/.error"

    # 如果已经处理成功、正在处理或已标记失败，则跳过
    if [ -f "$status_done" ] || [ -f "$status_processing" ] || [ -f "$status_error" ]; then
        return 0
    fi

    echo "--------------------------------------------------"
    echo "发现新任务目录: $task_dir"
    echo "--> 标记处理状态为 [.processing]..."
    touch "$status_processing"

    # --- Step A: 自动解压并将嵌套文件移动到批次根目录 ---
    for archive in "$task_dir"/*.zip "$task_dir"/*.tar.gz "$task_dir"/*.tgz "$task_dir"/*.gz; do
        if [ -f "$archive" ]; then
            echo "--> 检测到压缩包: $(basename "$archive")，正在解压..."
            case "$archive" in
                *.zip)
                    unzip -o -q "$archive" -d "$task_dir" || echo "⚠️ unzip 命令解压提示异常！"
                    ;;
                *.tar.gz|*.tgz)
                    tar -xzf "$archive" -C "$task_dir"
                    ;;
                *.gz)
                    gunzip -f -k "$archive"
                    ;;
            esac

            find "$task_dir" -mindepth 2 -type f -exec mv -f {} "$task_dir/" \; 2>/dev/null || true

            find "$task_dir" -mindepth 1 -type d -exec rm -rf {} + 2>/dev/null || true
        fi
    done

    # --- Step B: 智能识别输入文件 ---
    local input_file=""
    if [ -f "$task_dir/mdp_numeric.txt" ]; then
        input_file="mdp_numeric.txt"
    else
        local found_path
        found_path=$(find "$task_dir" -maxdepth 1 -type f \( -name "*.txt" -o -name "*.TXT" \) ! -name ".*" | head -n 1)
        if [ -n "$found_path" ]; then
            input_file=$(basename "$found_path")
        fi
    fi

    if [ -z "$input_file" ]; then
        echo "❌ 错误：在 $task_dir 中未找到可用于分析的 .txt 输入文件！"
        rm -f "$status_processing"
        touch "$status_error"
        return 1
    fi

    local prefix="${input_file%.*}"
    echo "--> 确定输入文件: $input_file (Prefix: $prefix)"

    # --- Step C: 进入任务目录执行计算 ---
    cd "$task_dir"

    # 1. 执行 R 脚本进行系谱计算
    echo "--> [1/2] 执行 R 计算: Rscript $TOOLS_DIR/$R_SCRIPT_NAME \"$input_file\" \"$prefix\""
    if ! Rscript "$TOOLS_DIR/$R_SCRIPT_NAME" "$input_file" "$prefix"; then
        echo "❌ R 脚本执行失败！"
        rm -f "$status_processing"
        touch "$status_error"
        return 1
    fi

    # 2. 执行 Python 脚本生成 Cytoscape 网络图
    echo "--> [2/2] 执行 Python 网络构建: python3 $TOOLS_DIR/build_network.py"
    if ! python3 "$TOOLS_DIR/build_network.py"; then
        echo "❌ Python 脚本执行失败！"
        rm -f "$status_processing"
        touch "$status_error"
        return 1
    fi

    if [ -f "/app/yak/GPEID_pedigree.svg" ]; then
        mv "/app/yak/GPEID_pedigree.svg" "$task_dir/GPEID_pedigree.svg"
    fi

    echo "--> ✅ 该批次任务执行成功！"
    rm -f "$status_processing"
    touch "$status_done"
}

# ==============================================================================
# 4. 主轮询扫描循环 (Daemon 入口)
# ==============================================================================
echo "=== 3. 开启轮询扫描服务 (每 $SCAN_INTERVAL 秒扫描一次) ==="
echo "扫描基准路径: $UPLOAD_BASE_DIR/{user_id}/pedigree/{upload_batch_id}"

while true; do
    find "$UPLOAD_BASE_DIR" -mindepth 3 -maxdepth 3 -type d -path "*/pedigree/*" 2>/dev/null | while read -r task_dir; do
        if [ -d "$task_dir" ]; then
            process_task_dir "$task_dir" || true
        fi
    done

    sleep "$SCAN_INTERVAL"
done