# edit_resource 工具使用指南

## 概述
编辑已存在的 `.tres` / `.res` 资源文件的属性。加载 → 修改 → 保存，支持自动类型转换。

## 参数

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `path` | String | ✅ | 目标文件路径，如 `res://materials/stone.tres` |
| `properties` | Dictionary | ✅ | 要修改的属性键值对 |

## 属性值格式速查

### 基础类型

| Godot 类型 | 传入格式 | 示例 |
|-----------|---------|------|
| **bool** | `true` / `false` | `"visible": true` |
| **int** | 直接数字 | `"render_priority": 2` |
| **float** | 带小数数字 | `"roughness": 0.5` |
| **String** | 字符串 | `"resource_name": "MyMaterial"` |

### 复合类型

| Godot 类型 | 传入格式 | 示例 |
|-----------|---------|------|
| **Color** | `"Color(r, g, b, a)"` 或十六进制 | `"albedo_color": "Color(0.8, 0.2, 0.2, 1)"` |
| **Vector2** | `"[x, y]"` | `"uv1_offset": "[0.5, 0.0]"` |
| **Vector3** | `"[x, y, z]"` | `"uv1_scale": "[2.0, 2.0, 1.0]"` |

### 资源引用

| 场景 | 传入格式 | 示例 |
|------|---------|------|
| 绑定贴图/材质 | `res://` 路径 | `"albedo_texture": "res://textures/stone_albedo.png"` |
| 清空引用 | `"null"` | `"albedo_texture": "null"` |

## 常见操作示例

### 修改材质颜色和粗糙度
```json
{
  "path": "res://materials/stone.tres",
  "properties": {
	"albedo_color": "Color(0.6, 0.4, 0.2, 1)",
	"roughness": 0.8,
	"metallic": 0.0
  }
}
```
