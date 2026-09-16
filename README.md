# Active Converter

Godot 4 编辑器插件：把 Clickteam Fusion 跑路导出的 **active 位置数据**，按坐标实例化成你自己的场景（对象名 → `.tscn`）。

> **只搬位置**：行为逻辑请自行复刻。

本仓库：<https://github.com/GreenSweet233/ctf-to-godot-active-converter>

## 支持的数据

| 来源               | 入口                                | 说明                                                                       |
| ---------------- | --------------------------------- | ------------------------------------------------------------------------ |
| CTF 侧加组导出 / 手写清单 | `1a. Open TXT file (tiles)`       | Tile 行文本；**裸列表、UTF-8 / UTF-16 也能读**，遇到 `parentType` 假实例可按需过滤             |
| 魔改版 Nebula 的 IR  | `1b. Open objects.json (actives)` | 只取 `type == 2` 的 Active 实例，按**对象名**映射；假实例（`parentType != 0`，坐标恒 0,0）默认跳过 |

## 用法

1. 场景树里选中一个节点作为父节点
2. 打开 txt / objects.json
3. `3. Add scenes to pool (.tscn)` 把要实例化的场景加进场景池
4. `4. Map & Generate`：左栏选对象名 / image id → 右栏点场景 → 需要时微调该条映射的 **offset** → **Generate Scene Instances**

规则：落点 = 数据坐标 + 该映射的 offset；目标节点直接子节点 **16px 内已有物品则跳过**；整批可 Ctrl+Z；产物带 `active_converter_object` / `active_converter_image` 标记，可用「Remove generated instances」一键清除。

## 相关

- 数据从哪来：**魔改版 Nebula** <https://github.com/GreenSweet233/NebulaFD>（`objects.json` 带坐标与动画素材），
  或 CTF 侧「给待跑路物品加组 + 特制事件」运行时导出
- 配套插件（backdrop 图块导入）：<https://github.com/GreenSweet233/ctf-to-godot-tile-converter>

## 许可

MIT——本插件由 **DeepSeek V4 Pro / DeepSeek V4.1-Flash** 辅助开发。
