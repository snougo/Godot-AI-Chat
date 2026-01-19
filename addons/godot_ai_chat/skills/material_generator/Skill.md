---
name: material-generator
description: 根据指定贴图文件夹自动批量创建 StandardMaterial3D 或 ShaderMaterial 资源
category: Game Material
---

# 材质自动生成器 (Material Generator)

## 概览 (Overview)
本技能旨在简化 Godot 中的材质创建流程。它能扫描指定的文件夹，识别其中的纹理贴图（如 Albedo, Normal, Roughness, Metallic 等），并自动配置并保存对应的 `StandardMaterial3D` 或 `ShaderMaterial` 资源。

## 触发条件 (Activation)
当用户请求“创建材质”、“生成材质”、“批量处理贴图”，或提供包含纹理的文件夹路径并暗示需要材质时。

## 指令 (Instructions)
1. **分析路径**：确认用户提供的文件夹路径是否有效，并扫描其中的图片文件（.png, .jpg, .tga, .webp 等）。
2. **识别纹理映射**：根据文件名后缀智能匹配纹理槽位。
   - Albedo: `_albedo`, `_color`, `_diffuse`, `_basecolor`
   - Normal: `_normal`, `_n`, `_norm`
   - Roughness: `_roughness`, `_rough`, `_r`
   - Metallic: `_metallic`, `_metal`, `_m`
   - Ambient Occlusion: `_ao`, `_ambient`, `_o`
   - Emission: `_emission`, `_emissive`, `_emit`
3. **创建材质**：
	- 默认创建 `StandardMaterial3D`。
	- 开启必要的特性（例如：如果有 Normal map 则开启 Normal enabled）。
4. **配置参数**：将识别到的纹理分配给材质的相应属性。
5. **保存资源**：将生成的材质文件（.tres）保存在同级目录中，命名应基于纹理的基础名称（例如 `Wood_Floor_Albedo.png` -> `Wood_Floor.tres`）。
6. **反馈结果**：报告成功创建的材质数量及保存路径。

## 示例 (Examples)

**输入：** “帮我为 res://assets/textures/wood_floor/ 下的贴图创建材质”
**输出：** “已扫描到 albedo, normal, roughness 贴图。正在创建 'wood_floor.tres' ... 完成。”

**输入：** “把 res://textures/metal/ 里的所有贴图都转成材质”
**输出：** “检测到 3 组纹理。正在批量生成 Material...”
