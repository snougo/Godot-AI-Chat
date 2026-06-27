# Godot 4 世界环境设置指南

> 基于本地 API 文档（WorldEnvironment, Environment）

## 一、基础概念

### 1.1 WorldEnvironment 节点

`WorldEnvironment` 是场景中的**环境配置节点**，负责定义：
- **背景**（天空/纯色/画布等）
- **环境光**（Ambient Light）
- **后处理特效**（SSAO、SSR、Glow、DOF 等）
- **色调映射**（Tonemapping）
- **雾效**（Fog / Volumetric Fog）
- **全局光照**（SDFGI）
- **色彩校正**（Brightness/Contrast/Saturation）

> 一个场景只能有一个 `WorldEnvironment`，且可被 `Camera3D` 上设置的 `Environment` 覆盖。

### 1.2 基本设置步骤

```
创建 WorldEnvironment 节点 →
  创建 Environment 资源（或使用已有）→
	设置背景（Sky / Color / Canvas）→
	设置环境光 →
	按需开启后处理效果 →
	调整色调映射
```

### 1.3 渲染管线顺序

```
Depth of Field → Auto Exposure → Glow → Tonemap → Adjustments
```

---

## 二、背景模式（Background Mode）

| 模式 | 枚举值 | 说明 |
|------|--------|------|
| `BG_CLEAR_COLOR` | `0` | 使用项目设置中的默认清除颜色 |
| `BG_COLOR` | `1` | 使用自定义纯色背景 |
| `BG_SKY` | `2` | 显示 Sky 资源定义的天空（**最常用**） |
| `BG_CANVAS` | `3` | 显示 CanvasLayer 作为背景 |
| `BG_KEEP` | `4` | 保留屏幕已有像素（最快，仅适用于纯室内场景） |
| `BG_CAMERA_FEED` | `5` | 显示摄像头画面 |

### Sky 资源

使用 `BG_SKY` 模式时需要设置 `sky` 属性：

- 创建 **Sky** 资源，设置 `sky_material` 为：
  - `ProceduralSkyMaterial` — 程序化生成天空（渐变 + 太阳）
  - `PanoramaSkyMaterial` — 使用全景 HDR 贴图
  - `PhysicalSkyMaterial` — 物理天空（更真实的散射效果）
- 可通过 `sky_rotation` 旋转天空
- 可通过 `sky_custom_fov` 覆盖天空渲染的 FOV

---

## 三、环境光（Ambient Light）

| 属性 | 默认值 | 说明 |
|------|--------|------|
| `ambient_light_source` | `AMBIENT_SOURCE_BG` (`0`) | 环境光来源 |
| `ambient_light_color` | `Color(0,0,0,1)` | 环境光颜色 |
| `ambient_light_energy` | `1.0` | 环境光强度 |
| `ambient_light_sky_contribution` | `1.0` | 天空对场景照明的贡献度 |

### AmbientSource 枚举

| 枚举值 | 说明 |
|--------|------|
| `AMBIENT_SOURCE_BG` | 从背景来源获取环境光 |
| `AMBIENT_SOURCE_DISABLED` | 禁用环境光（略微提升性能） |
| `AMBIENT_SOURCE_COLOR` | 使用指定的纯色环境光（略微提升性能） |
| `AMBIENT_SOURCE_SKY` | 从 Sky 获取环境光（不论背景模式） |

> **提示**：`ambient_light_sky_contribution = 0` 时完全使用 `ambient_light_color`；
> `= 1` 时完全使用天空光照。可用于调整室内场景的亮度平衡。

---

## 四、色调映射（Tonemapping）

色调映射将 HDR 值转换为适合显示器的 LDR 值。

### ToneMapper 枚举

| 映射器 | 枚举值 | 说明 | 性能 |
|--------|--------|------|------|
| `TONE_MAPPER_LINEAR` | `0` | 线性映射，高亮区域易过曝 | 最快 |
| `TONE_MAPPER_REINHARDT` | `1` | 简单柔和高光，可能偏暗/低对比 | 较快 |
| `TONE_MAPPER_FILMIC` | `2` | 胶片风格映射，良好对比度 | 适中 |
| `TONE_MAPPER_ACES` | `3` | 高对比度，高光去饱和，真实感强 | 适中 |
| `TONE_MAPPER_AGX` | `4` | 可调胶片风格，色彩保真度最好 | 最慢 |

### 关键参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `tonemap_exposure` | `1.0` | 曝光度（映射前调整亮度） |
| `tonemap_white` | `1.0` | 白点参考值（写实场景建议 ≥ `6.0`） |
| `tonemap_agx_contrast` | `1.25` | AGX 对比度 |
| `tonemap_agx_white` | `16.29` | AGX 白点参考值 |

> **建议**：多数游戏使用 **ACES** 或 **Filmic** 可获得较好的视觉效果。
> 写实场景建议提高 `tonemap_white` 到 `6.0~16.0` 避免高光过曝。

---

## 五、雾效（Fog）

### 5.1 基础雾

| 属性 | 默认值 | 说明 |
|------|--------|------|
| `fog_enabled` | `false` | 启用雾效 |
| `fog_mode` | `FOG_MODE_EXPONENTIAL` (`0`) | 雾模式 |
| `fog_density` | `0.01` | 雾密度 |
| `fog_light_color` | `Color(0.518,0.553,0.608,1)` | 雾的颜色 |
| `fog_light_energy` | `1.0` | 雾的亮度 |
| `fog_sun_scatter` | `0.0` | 太阳光穿过雾的散射效果 |
| `fog_sky_affect` | `1.0` | 雾对天空的影响程度 |

### 5.2 Depth 雾模式（`FOG_MODE_DEPTH`）

适用于需要**艺术化控制**的场景：

| 属性 | 默认值 | 说明 |
|------|--------|------|
| `fog_depth_begin` | `10.0` | 雾开始距离 |
| `fog_depth_end` | `100.0` | 雾结束距离（`0` = 等于相机 far 值） |
| `fog_depth_curve` | `1.0` | 雾强度曲线 |

### 5.3 高度雾

| 属性 | 默认值 | 说明 |
|------|--------|------|
| `fog_height` | `0.0` | 高度雾基准高度 |
| `fog_height_density` | `0.0` | 高度雾密度（负值=高度越高雾越浓） |

### 5.4 体积雾（Volumetric Fog）

> **仅在 Forward+ 渲染模式下可用**

| 属性 | 默认值 | 说明 |
|------|--------|------|
| `volumetric_fog_enabled` | `false` | 启用体积雾 |
| `volumetric_fog_density` | `0.05` | 基础密度（`0` = 禁用全局但保留 FogVolume） |
| `volumetric_fog_albedo` | `Color(1,1,1,1)` | 体积雾反照率 |
| `volumetric_fog_emission` | `Color(0,0,0,1)` | 体积雾自发光 |
| `volumetric_fog_emission_energy` | `1.0` | 自发光强度 |
| `volumetric_fog_length` | `64.0` | 体积雾计算距离 |
| `volumetric_fog_anisotropy` | `0.2` | 散射方向（`1`=全前向, `0`=均匀, `-1`=全后向） |
| `volumetric_fog_sky_affect` | `1.0` | 对天空的影响 |
| `volumetric_fog_temporal_reprojection_enabled` | `true` | 时域重投影（平滑但可能有拖影） |

---

## 六、屏幕空间效果

### 6.1 SSAO（屏幕空间环境光遮蔽）

| 属性 | 默认值 | 说明 |
|------|--------|------|
| `ssao_enabled` | `false` | 启用 SSAO |
| `ssao_intensity` | `2.0` | 强度 |
| `ssao_radius` | `1.0` | 采样半径 |
| `ssao_power` | `1.5` | 分布曲线 |
| `ssao_detail` | `0.5` | 细节强度 |
| `ssao_horizon` | `0.06` | 水平遮挡阈值 |
| `ssao_sharpness` | `0.98` | 边缘锐度 |
| `ssao_light_affect` | `0.0` | 直射光中的 SSAO 强度（>0 会使直射光区域也受 AO 影响） |
| `ssao_ao_channel_affect` | `0.0` | 对材质 AO 贴图的影响程度 |

> **可用渲染模式**：Forward+ 和 Compatibility

### 6.2 SSR（屏幕空间反射）

| 属性 | 默认值 | 说明 |
|------|--------|------|
| `ssr_enabled` | `false` | 启用 SSR |
| `ssr_max_steps` | `64` | 最大步进次数 |
| `ssr_fade_in` | `0.15` | 淡入距离 |
| `ssr_fade_out` | `2.0` | 淡出距离 |
| `ssr_depth_tolerance` | `0.5` | 深度容差 |

> **可用渲染模式**：仅 Forward+

### 6.3 SSIL（屏幕空间间接光照）

| 属性 | 默认值 | 说明 |
|------|--------|------|
| `ssil_enabled` | `false` | 启用 SSIL |
| `ssil_intensity` | `1.0` | 亮度 |
| `ssil_radius` | `5.0` | 光照反弹距离 |
| `ssil_sharpness` | `0.98` | 边缘锐度 |
| `ssil_normal_rejection` | `1.0` | 法线剔除（防漏光） |

> **可用渲染模式**：仅 Forward+

---

## 七、全局光照 — SDFGI

有符号距离场全局光照，实时 GI 方案。

| 属性 | 默认值 | 说明 |
|------|--------|------|
| `sdfgi_enabled` | `false` | 启用 SDFGI |
| `sdfgi_energy` | `1.0` | GI 能量倍率 |
| `sdfgi_bounce_feedback` | `0.5` | 光线反弹能量（>0.5 可能无限反馈） |
| `sdfgi_cascades` | `4` | 级联数（1~8） |
| `sdfgi_cascade0_distance` | `12.8` | 第一级级联距离 |
| `sdfgi_min_cell_size` | `0.2` | 最小单元格大小 |
| `sdfgi_max_distance` | `204.8` | 最大 GI 距离 |
| `sdfgi_y_scale` | `SDFGI_Y_SCALE_75_PERCENT` | Y轴缩放（薄楼板场景建议 50%） |
| `sdfgi_use_occlusion` | `false` | 使用遮挡减少漏光（有性能开销） |
| `sdfgi_read_sky_light` | `true` | 室内场景建议设为 `false` |
| `sdfgi_probe_bias` | `1.1` | 探针偏移（减少条纹 artifact） |
| `sdfgi_normal_bias` | `1.1` | 法线偏移 |

> **注意**：仅 Forward+ 渲染模式可用。
> 建议在室内场景关闭 `sdfgi_read_sky_light`，启用 `sdfgi_use_occlusion`。

---

## 八、Glow 辉光效果

| 属性 | 默认值 | 说明 |
|------|--------|------|
| `glow_enabled` | `false` | 启用辉光 |
| `glow_intensity` | `0.3` | 辉光整体亮度 |
| `glow_strength` | `1.0` | 模糊扩散强度 |
| `glow_bloom` | `0.0` | Bloom 强度（让暗区也发光） |
| `glow_blend_mode` | `GLOW_BLEND_MODE_SCREEN` (`1`) | 混合模式 |
| `glow_hdr_threshold` | `1.0` | HDR 阈值（高于此值才产生辉光） |
| `glow_hdr_scale` | `2.0` | HDR 过渡平滑 |
| `glow_hdr_luminance_cap` | `12.0` | HDR 亮度上限 |
| `glow_levels/1~7` | 见下 | 7 级模糊层级强度 |

### Glow 层级说明

| 层级 | 默认值 | 说明 |
|------|--------|------|
| Level 1 | `0.0` | 最局部（最不模糊） |
| Level 2 | `0.8` | 常用层级 |
| Level 3 | `0.4` | 常用层级 |
| Level 4 | `0.1` | — |
| Level 5~7 | `0.0` | 最全局（最模糊） |

### GlowBlendMode 枚举

| 模式 | 说明 |
|------|------|
| `GLOW_BLEND_MODE_ADDITIVE` | 叠加到场景 |
| `GLOW_BLEND_MODE_SCREEN` | 屏幕模式（暗区影响大，默认推荐） |
| `GLOW_BLEND_MODE_SOFTLIGHT` | 柔光模式（仅影响中间调） |
| `GLOW_BLEND_MODE_REPLACE` | 替换（全屏模糊预览用） |
| `GLOW_BLEND_MODE_MIX` | 混合（配合 bloom 使用） |

---

## 九、色彩校正（Adjustments）

| 属性 | 默认值 | 说明 |
|------|--------|------|
| `adjustment_enabled` | `false` | 启用色彩校正 |
| `adjustment_brightness` | `1.0` | 亮度 |
| `adjustment_contrast` | `1.0` | 对比度 |
| `adjustment_saturation` | `1.0` | 饱和度（`0`=完全灰度） |
| `adjustment_color_correction` | — | LUT 查色表（`Texture2D` 或 `Texture3D`） |

> **提示**：`adjustment_brightness` 是在色调映射**之后**调整的。
> 场景亮度应优先使用 `tonemap_exposure`（在映射之前调整，效果更自然）。

---

## 十、氛围速查表

| 场景氛围 | 背景 | 雾效 | Tonemap | Glow | SSAO | 其他 |
|----------|------|------|---------|------|------|------|
| **明亮户外** | Sky（程序化） | 轻雾 `density=0.005` | ACES | 关闭 | 低强度 | — |
| **阴暗室内** | Color 暗色 / Sky | Depth 雾 `begin=5, end=30` | ACES/Filmic | 可选 | 中强度 | SDFGI 室内模式 |
| **恐怖氛围** | Color 黑灰 | 浓雾 `density=0.05`，`fog_sun_scatter>0` | Filmic | 低强度 | 高强度 | — |
| **赛博朋克** | Sky（夜景） | 薄雾 | ACES | 高强度，bloom 开启 | 中强度 | 色彩校正偏冷 |
| **梦幻/魔法** | Sky 彩色 | 薄雾 | Filmic/AGX | 高强度，`blend_mode=ADDITIVE` | 低强度 | Glow 层级 2+3 为主 |
| **废土/荒漠** | Sky（暖色） | 高度雾 `height_density=0.02` | ACES | 关闭 | 中强度 | `tonemap_exposure` 偏高 |
| **水下** | Color 深蓝绿 | 体积雾，颜色偏蓝绿 | Filmic | bloom 开启 | 低强度 | 色彩校正偏蓝 |

---

## 十一、性能注意事项

| 特性 | 性能影响 | 建议 |
|------|----------|------|
| Sky（程序化/全景） | 低~中 | 推荐使用 |
| SSAO | 中 | 移动端谨慎使用 |
| SSR | 高 | 仅在 Forward+ 下可用，酌情使用 |
| SSIL | 高 | 仅在 Forward+ 下可用 |
| SDFGI | 高 | 仅在 Forward+ 下可用，可启用半分辨率 |
| Glow | 低~中 | 层级越多越慢，建议只开 2~3 级 |
| 体积雾 | 高 | 仅在 Forward+ 下可用，性能开销大 |
| 色调映射 | 极低 | AGX 略慢但质量最好 |
