# Prompt 编写指南

## 通用原则
- **具体明确**：越详细越好，不要吝啬形容词
- **先主体，后环境，再风格**：`主体描述, 环境/背景, 光照/色调, 风格/质量词`
- **用英文编写**：Draw Things 的模型对英文 prompt 理解最佳

---

## 概念图 / 参考图

### 结构模板
```
[主体], [环境/场景], [光照/氛围], [构图], [风格], [质量词]
```

### 关键词库

| 类别 | 推荐关键词 |
|------|-----------|
| **风格** | `concept art`, `matte painting`, `digital painting`, `illustration`, `artstation`, `cinematic` |
| **光照** | `golden hour`, `volumetric lighting`, `soft lighting`, `dramatic lighting`, `rim light` |
| **色调** | `warm tone`, `cool tone`, `monochrome`, `vibrant colors`, `muted colors` |
| **质量** | `highly detailed`, `intricate details`, `8k`, `sharp focus`, `masterpiece` |

### 示例
```
fantasy forest temple entrance, overgrown with vines and moss, golden hour sunlight piercing through canopy, volumetric fog, cinematic composition, concept art, highly detailed, 8k
```

---

## 无缝贴图

### 结构模板
```
seamless/tiling [材质类型] texture, [颜色/质感], [风格], [纹理特征]
```

### 关键词库

| 类别 | 推荐关键词 |
|------|-----------|
| **类型** | `seamless texture`, `tiling texture`, `seamless tileable`, `repeatable pattern` |
| **风格** | `realistic`, `stylized`, `hand-painted`, `pbr`, `photorealistic` |
| **特征** | `rough`, `smooth`, `weathered`, `cracked`, `mossy`, `worn` |

### 示例
```
seamless stone brick texture, grey granite, moss growing in crevices, realistic, pbr, tileable, 4k, highly detailed
```

---

## 负面提示词 (Negative Prompt)

### 通用排除项
```
blurry, low quality, low resolution, deformed, distorted, ugly, bad anatomy, watermark, text, signature, worst quality, normal quality, jpeg artifacts
```

### 概念图专用
```
amateur, sketchy, draft, flat lighting, oversaturated
```

### 无缝贴图专用
```
border, edge, frame, pattern interruption, non-repeating, asymmetrical
```

---

## 参数建议速查表

| 用途 | 尺寸 | seed | 说明 |
|------|------|------|------|
| 🎨 概念图/参考图 | 1024×1024 | -1（随机） | 高质量详细描述 |
| 🧪 测试贴图 | 512×512 | 固定值（可复现） | 含 `seamless` 关键词 |
| ⚡ 快速草图 | 512×512 | -1（随机） | 快速迭代想法 |
