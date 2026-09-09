cat > /app/yak/server/uploadPath/upload/yak/build_file.sh << 'EOF'
#!/bin/bash

WATCH_DIR="/app/yak/server/uploadPath/upload/yak"

PEDIGREE_DIR="pedigree"
IMPUTATION_DIR="imputation"
BREEDING_DIR="breeding"
BODY_DIR="body"

for dir in "$WATCH_DIR"/*/; do
    [ -d "$dir" ] || continue

    if [ ! -d "${dir}${PEDIGREE_DIR}" ]; then
        echo "$(date): 检测到新文件夹: $dir"

        mkdir -p "${dir}${PEDIGREE_DIR}"
        mkdir -p "${dir}${IMPUTATION_DIR}"
        mkdir -p "${dir}${BREEDING_DIR}"
        mkdir -p "${dir}${BODY_DIR}"

     
        echo "$(date): 已初始化结构: $dir"
    fi
done
EOF