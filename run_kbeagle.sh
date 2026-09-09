#!/bin/bash

BASE_DIR="/app/yak/server/uploadPath/upload/yak"
KBEAGLE_DIR="/app/yak/server/uploadPath/upload/Kbeagle"
RSCRIPT="/usr/bin/Rscript"
KBEAGLE_SCRIPT="${KBEAGLE_DIR}/KBeagle.R"
PROCESSED_LIST="/tmp/kbeagle_processed_folders.txt"
LOG_FILE="/app/yak/server/uploadPath/upload/yak/kbeagle_auto.log"
R_LIBS_USER="/root/R_libs"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

process_folder() {
    local folder="$1"
    local imputation_dir="$folder/imputation"
    local folder_name=$(basename "$folder")

    if [ ! -d "$imputation_dir" ]; then
        log "跳过 $folder_name：没有 imputation 子目录"
        return 1
    fi

    local data_file=""
    for ext in txt; do
        files=($(find "$imputation_dir" -maxdepth 1 -type f -iname "*.${ext}" 2>/dev/null))
        if [ ${#files[@]} -gt 0 ]; then
            data_file="${files[0]}"
            break
        fi
    done

    if [ -z "$data_file" ]; then
        log "跳过 $folder_name：imputation 目录下没有 .txt 文件"
        return 1
    fi

    local lock_file="$folder/.kbeagle_processing.lock"
    if [ -f "$lock_file" ]; then
        log "跳过 $folder_name：已有处理锁文件"
        return 1
    fi

    touch "$lock_file"
    log "开始处理 $folder_name，数据文件：$data_file"

    cd "$KBEAGLE_DIR"

    $RSCRIPT -e ".libPaths('$R_LIBS_USER'); source('$KBEAGLE_SCRIPT'); input_file <- '$data_file'; result <- KBeagle(data_NA = input_file); print(result)" >> "$LOG_FILE" 2>&1
    local exit_code=$?

    if [ $exit_code -eq 0 ]; then
        local result_file="${KBEAGLE_DIR}/KBeagle_wc/KBeagle_finshed.txt"
        if [ -f "$result_file" ]; then
            mv "$result_file" "$folder/"
            log "成功处理 $folder_name，结果保存在 $folder/KBeagle_finshed.txt"
            echo "$folder" >> "$PROCESSED_LIST"
        else
            log "处理完成但未找到结果文件 $result_file"
        fi
    else
        log "处理 $folder_name 失败，R 脚本返回码 $exit_code"
    fi

    rm -f "$lock_file"
}

main() {
    touch "$PROCESSED_LIST"
    log "KBeagle 自动分析任务开始，扫描目录：$BASE_DIR"

    for sub_dir in "$BASE_DIR"/*/ ; do
        [ -d "$sub_dir" ] || continue
        sub_dir="${sub_dir%/}"

        if grep -qxF "$sub_dir" "$PROCESSED_LIST" 2>/dev/null; then
            continue
        fi

        process_folder "$sub_dir"
    done

    log "KBeagle 自动分析任务结束"
}

main
