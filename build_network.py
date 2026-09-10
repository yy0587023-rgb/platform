# ==============================================================================
# build_network.py - 自动化驱动 Cytoscape REST API 渲染 SVG
# ==============================================================================

import json
import time
import urllib.request

BASE_URL = "http://localhost:12345/v1"

def api_request(endpoint, method="GET", data=None):
    url = f"{BASE_URL}{endpoint}"
    body = json.dumps(data).encode('utf-8') if data is not None else None
    headers = {"Content-Type": "application/json"} if body else {}
    req = urllib.request.Request(url, data=body, headers=headers, method=method)
    with urllib.request.urlopen(req) as res:
        content = res.read().decode('utf-8')
        return json.loads(content) if content else None

def get_valid_view_id(net_id):
    try:
        views = api_request(f"/networks/{net_id}/views", method="GET")
        if isinstance(views, list) and len(views) > 0:
            return views[0]
    except Exception:
        pass

    res = api_request(f"/networks/{net_id}/views", method="POST")
    if isinstance(res, list) and len(res) > 0:
        return res[0]
    elif isinstance(res, dict):
        return res.get("viewSUID") or res.get("networkSUID")
    return None

def apply_blue_style(net_id):
    """应用 3.75:1 扁平圆角矩形样式 (75x20)"""
    style_name = "BlueRectangleStyle"
    
    style_data = {
        "title": style_name,
        "defaults": [
            {"visualProperty": "NODE_SHAPE", "value": "ROUND_RECTANGLE"},     # 圆角矩形
            {"visualProperty": "NODE_FILL_COLOR", "value": "#7EC8F5"},        # 天蓝色
            {"visualProperty": "NODE_WIDTH", "value": 75},                     # 宽 75px
            {"visualProperty": "NODE_HEIGHT", "value": 20},                    # 高 20px (比例 3.75 : 1)
            {"visualProperty": "NODE_BORDER_WIDTH", "value": 1},               # 细边框
            {"visualProperty": "NODE_BORDER_PAINT", "value": "#4A90E2"},       # 边框蓝
            {"visualProperty": "NODE_LABEL_COLOR", "value": "#111111"},        # 黑色文字
            {"visualProperty": "NODE_LABEL_FONT_SIZE", "value": 9},            # 9pt 小字体
            {"visualProperty": "EDGE_WIDTH", "value": 1},                      # 1px 细线条
            {"visualProperty": "EDGE_STROKE_UNSELECTED_PAINT", "value": "#888888"} # 灰色边
        ],
        "mappings": [
            {
                "mappingType": "passthrough",
                "mappingColumn": "label",
                "mappingColumnType": "String",
                "visualProperty": "NODE_LABEL"
            }
        ]
    }
    
    try:
        api_request(f"/styles/{style_name}", method="DELETE")
    except Exception:
        pass

    # 1. 创建样式
    api_request("/styles", method="POST", data=style_data)
    
    # 2. 解锁 Cytoscape 的 nodeSizeLocked (锁定节点宽高)
    dep_data = [{"visualPropertyDependency": "nodeSizeLocked", "enabled": False}]
    try:
        api_request(f"/styles/{style_name}/dependencies", method="PUT", data=dep_data)
    except Exception as e:
        print(f"提示: 设置 dependencies 状态: {e}")

    # 3. 应用样式
    api_request(f"/apply/styles/{style_name}/{net_id}")

def fit_view(net_id, view_id):
    """全局镜头居中"""
    try:
        api_request(f"/apply/fit/{net_id}")
    except Exception:
        pass

    url = f"{BASE_URL}/networks/{net_id}/views/{view_id}/fitContent"
    req = urllib.request.Request(
        url, data=b"{}", headers={"Content-Type": "application/json"}, method="PUT"
    )
    try:
        with urllib.request.urlopen(req):
            pass
    except Exception:
        pass

def main():
    # 1. 清理工作区
    try:
        api_request("/networks", method="DELETE")
    except Exception:
        pass

    # 2. 上传网络数据
    print("--> 1. 读取 R 语言生成的 network_final.json 并上传至 Cytoscape...")
    with open("network_final.json", "rb") as f:
        json_bytes = f.read()

    req = urllib.request.Request(
        f"{BASE_URL}/networks", data=json_bytes,
        headers={"Content-Type": "application/json"}, method="POST"
    )
    with urllib.request.urlopen(req) as res:
        net_res = json.loads(res.read().decode())
    
    net_id = net_res.get("networkSUID") if isinstance(net_res, dict) else net_res[0]

    # 3. 应用 3.75:1 扁平矩形样式
    print("--> 2. 应用解锁后的 3.75:1 扁平矩形样式...")
    view_id = get_valid_view_id(net_id)
    apply_blue_style(net_id)

    # 4. 全图适应镜头
    print("--> 3. 调整镜头视角居中...")
    fit_view(net_id, view_id)
    time.sleep(1.5)

    # 5. 导出 SVG
    print("--> 4. 正在导出 SVG 图像...")
    req = urllib.request.Request(f"{BASE_URL}/networks/{net_id}/views/{view_id}.svg")
    with urllib.request.urlopen(req) as res:
        svg_bytes = res.read()

    output_file = "/app/yak/GPEID_pedigree.svg"
    with open(output_file, "wb") as f:
        f.write(svg_bytes)

    print(f"\n🎉 渲染完成！长扁矩形系谱图已保存至: {output_file}")

if __name__ == "__main__":
    main()