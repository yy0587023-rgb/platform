set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

WORK_DIR=""
if [[ $# -ge 1 ]]; then
  WORK_DIR="$1"
else
  
  LATEST_DIR=$(ls -td /app/yak/server/uploadPath/upload/*/breeding/* 2>/dev/null | head -n 1 || true)
  if [[ -z "$LATEST_DIR" ]]; then
    echo "错误：未指定工作目录，且自动扫描未找到任何 breeding 目录。"
    exit 1
  fi
  WORK_DIR="$LATEST_DIR"
fi

WORK_DIR="${WORK_DIR%/}"
echo "=================================================="
echo "工作目录: $WORK_DIR"
echo "=================================================="

shopt -s nullglob nocaseglob
ARCHIVES=("$WORK_DIR"/*.zip "$WORK_DIR"/*.tar.gz "$WORK_DIR"/*.tgz "$WORK_DIR"/*.tar.bz2 "$WORK_DIR"/*.tar "$WORK_DIR"/*.rar "$WORK_DIR"/*.7z)
shopt -u nullglob nocaseglob

if [[ ${#ARCHIVES[@]} -gt 0 ]]; then
  echo "[解压阶段] 发现压缩包，准备解压..."
  for arc in "${ARCHIVES[@]}"; do
    marker="${arc}.extracted"
    if [[ -f "$marker" ]]; then
      echo "  -> [跳过] $(basename "$arc") 已解压过"
      continue
    fi
    
    echo "  -> [解压] $(basename "$arc") ..."
    case "$arc" in
      *.zip)     unzip -q -o "$arc" -d "$WORK_DIR" || echo "警告: 解压出错" ;;
      *.tar.gz|*.tgz|*.tar.bz2|*.tar) 
                 tar -xf "$arc" -C "$WORK_DIR" || echo "警告: 解压出错" ;;
      *.rar)     unrar x -y "$arc" "$WORK_DIR/" >/dev/null || echo "警告: 解压出错" ;;
      *.7z)      7z x -y "$arc" -o"$WORK_DIR" >/dev/null || echo "警告: 解压出错" ;;
    esac
    # 标记为已解压
    touch "$marker"
  done
else
  echo "[解压阶段] 未发现新压缩包，直接进入分析..."
fi

echo ""
echo "[分析阶段] 启动 R 脚本..."

Rscript "$SCRIPT_DIR/gebvs.r" "$WORK_DIR"
