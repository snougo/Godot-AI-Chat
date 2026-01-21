---
name: material-generator
description: 根据指定贴图文件夹自动批量创建 StandardMaterial3D 或 ShaderMaterial 资源
---

# Material Generator

## 概览
本技能旨在简化 Godot 中的材质创建流程。它能扫描指定的文件夹，识别其中的纹理贴图（如 Albedo, Normal, Roughness, Metallic 等），并自动配置并保存对应的 `StandardMaterial3D` 或 `ShaderMaterial` 资源。

## 触发条件
当用户请求“创建材质”、“生成材质”、“批量处理贴图”，或提供包含纹理的文件夹路径并暗示需要材质时。

## 指令
1. **分析路径**：确认用户提供的文件夹路径是否有效。
3. **创建材质**：使用 `generate_material` 工具创建材质
6. **反馈结果**：报告成功创建的材质数量及保存路径。

## 示例

**输入：** “帮我为 res://assets/textures/wood_floor/ 下的贴图创建材质”
**输出：** “已扫描到贴图。开始创建材质。”
