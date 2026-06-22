# Godot 4 PBR 贴图与材质指南

## 材质体系

| 材质类 | 说明 |
|--------|------|
| `StandardMaterial3D` | 标准 PBR 材质，AO/Roughness/Metallic 使用 **独立贴图** |

## 贴图槽位（TextureParam）

| 参数常量 | 值 | 对应属性 | 说明 |
|----------|----|----------|------|
| `TEXTURE_ALBEDO` | `0` | `albedo_texture` | 基底色（漫反射）贴图 |
| `TEXTURE_METALLIC` | `1` | `metallic_texture` | 金属度贴图 |
| `TEXTURE_ROUGHNESS` | `2` | `roughness_texture` | 粗糙度贴图 |
| `TEXTURE_EMISSION` | `3` | `emission_texture` | 自发光贴图 |
| `TEXTURE_NORMAL` | `4` | `normal_texture` | 法线贴图 |
| `TEXTURE_RIM` | `5` | `rim_texture` | 边缘光贴图 |
| `TEXTURE_CLEARCOAT` | `6` | `clearcoat_texture` | 清漆贴图 |
| `TEXTURE_FLOWMAP` | `7` | `anisotropy_flowmap` | 各向异性流向贴图 |
| `TEXTURE_AMBIENT_OCCLUSION` | `8` | `ao_texture` | 环境光遮蔽贴图 |
| `TEXTURE_HEIGHTMAP` | `9` | `heightmap_texture` | 高度贴图（视差映射） |
| `TEXTURE_SUBSURFACE_SCATTERING` | `10` | `subsurf_scatter_texture` | 次表面散射贴图 |

## 贴图文件命名建议

> Godot **不会**根据文件名自动关联贴图到材质槽位，贴图需要手动或通过代码设置到对应槽位。
> 但良好的命名规范有助于团队协作和资产管线的自动化处理。

### 命名规范（用于工具自动识别）

```
xxx_albedo       # 基底色（sRGB 颜色空间）
xxx_normal       # 法线贴图（Linear 颜色空间）
xxx_metallic     # 金属度（Linear，单通道）
xxx_roughness    # 粗糙度（Linear，单通道）
xxx_ao           # 环境光遮蔽（Linear，单通道）
xxx_emission     # 自发光（sRGB，可选 HDR）
xxx_height       # 高度图（Linear）
xxx_subsurface   # 次表面散射（Linear）
xxx_1k/2k/4k     # 贴图分辨率
```
