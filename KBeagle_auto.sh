#!/bin/bash

# ==============================================================================
# KBeagle 基因组填充自动化守护脚本 (KBeagle_auto.sh)
# 功能：自动扫描任务目录、预处理数据框输入、运行 R 分析并归档结果
# ==============================================================================

# 1. 基础环境与路径配置
UPLOAD_BASE="/app/yak/server/uploadPath/upload"
KBEAGLE_DIR="/app/yak/server/uploadPath/upload/Kbeagle"
KBEAGLE_SCRIPT="${KBEAGLE_DIR}/KBeagle.r"
LOG_FILE="${KBEAGLE_DIR}/kbeagle_auto.log"

# R 运行环境配置
RSCRIPT="/usr/bin/Rscript"
R_LIBS_USER="/root/R_libs"

# 日志记录辅助函数
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# 2. 单个任务目录的处理函数
process_task_dir() {
    local task_dir="$1"
    local status_processing="${task_dir}/.processing"
    local status_done="${task_dir}/.done"
    local status_error="${task_dir}/.error"

    # 如果任务已完成、失败或正在处理中，则直接跳过
    if [ -f "$status_done" ] || [ -f "$status_error" ] || [ -f "$status_processing" ]; then
        return 0
    fi

    log "--------------------------------------------------"
    log "发现新 KBeagle 填充任务: $task_dir"
    touch "$status_processing"

    # 智能识别输入数据文件（排除隐藏文件和之前的结果文件）
    local data_file
    data_file=$(find "$task_dir" -maxdepth 1 -type f \( -name "*.txt" -o -name "*.TXT" \) ! -name ".*" ! -name "KBeagle_finshed_result.txt" | head -n 1)

    if [ -z "$data_file" ]; then
        log "❌ 错误：在 $task_dir 中未找到可用于填充的 .txt 输入文件！"
        rm -f "$status_processing"
        touch "$status_error"
        return 1
    fi

    log "--> 确定输入文件: $data_file"

    # 切换至 KBeagle 工作目录，确保依赖文件与中间输出正常定位
    cd "$KBEAGLE_DIR" || exit 1
    mkdir -p "${KBEAGLE_DIR}/KBeagle_wc"

    log "--> 正在通过 R 读取数据为 data.frame 并执行 KBeagle 分析..."

    # 核心修复：在 R 内存中先用 read.table 读取为数据框 df，再传给 KBeagle(data_NA = df)
    $RSCRIPT -e "
    .libPaths('$R_LIBS_USER');
    setwd('$KBEAGLE_DIR');
    source('$KBEAGLE_SCRIPT');
    df <- read.table('$data_file', header = TRUE, sep = '', check.names = FALSE);
    result <- KBeagle(data_NA = df);
    print(result);
    " >> "$LOG_FILE" 2>&1

    local exit_code=$?
    local result_file="${KBEAGLE_DIR}/KBeagle_wc/KBeagle_finshed_result.txt"

    # 检查运行状态与结果文件
    if [ $exit_code -eq 0 ] && [ -f "$result_file" ]; then
        mv -f "$result_file" "${task_dir}/KBeagle_finshed_result.txt"
        log "✅ 成功处理任务，填充结果已提取至: ${task_dir}/KBeagle_finshed_result.txt"
        rm -f "$status_processing"
        touch "$status_done"
    else
        log "❌ 错误：处理任务失败（R 返回码 $exit_code 或结果文件未成功生成）"
        rm -f "$status_processing"
        touch "$status_error"
        return 1
    fi
}

# 3. 主扫描循环
main() {
    log "=== KBeagle 自动填充分析守护服务已启动 ==="
    log "扫描基准路径: ${UPLOAD_BASE}/{user_id}/imputation/{upload_batch_id}"

    # 遍历所有形如 /upload/{user_id}/imputation/{upload_batch_id} 的子目录
    find "$UPLOAD_BASE" -mindepth 3 -maxdepth 3 -type d -path "*/imputation/*" | while read -r task_dir; do
        process_task_dir "$task_dir"
    done
}

main