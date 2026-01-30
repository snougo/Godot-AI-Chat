# UI 布局指南 (UI Layout Guide)

Godot 的 UI 系统基于 `Control` 节点。掌握 Anchors（锚点）、Containers（容器）和 Size Flags（尺寸标记）是创建响应式 UI 的关键。

## 1. 锚点 (Anchors) 与 偏移 (Offsets)

*   **Anchors (锚点)**: 定义了子节点相对于父节点矩形边框的**相对位置**（0.0 到 1.0）。
    *   `Top-Left`: (0, 0, 0, 0) - 固定在左上角。
    *   `Full Rect`: (0, 0, 1, 1) - 铺满父节点。
    *   `Center`: (0.5, 0.5, 0.5, 0.5) - 锚定在中心。
*   **Offsets (偏移)**: 定义了子节点边缘距离锚点的**像素距离**。
    *   如果使用 `Full Rect` 锚点且偏移全为 0，子节点将完全填充父节点。

**AI 操作建议**:
在代码中设置布局时，优先使用 `set_anchors_preset()` 方法，它封装了常见的锚点配置。

```gdscript
# 铺满父节点
control_node.set_anchors_preset(Control.PRESET_FULL_RECT)

# 居中
control_node.set_anchors_preset(Control.PRESET_CENTER)

# 顶部宽条
control_node.set_anchors_preset(Control.PRESET_TOP_WIDE)
```

## 2. 容器 (Containers)

容器会自动管理子节点的位置和大小。**在容器内部，手动设置子节点的 Position 和 Size 是无效的。**

*   **BoxContainer (HBox / VBox)**: 水平或垂直排列子节点。
*   **GridContainer**: 网格排列。
*   **MarginContainer**: 为子节点添加内边距（通过 `theme_override_constants` 设置）。
*   **CenterContainer**: 将子节点居中显示（子节点保持其最小尺寸）。
*   **ScrollContainer**: 当内容超出范围时提供滚动条。

## 3. 尺寸标记 (Size Flags)

当节点位于容器中时，`size_flags` 决定了它如何分配空间。

*   **Fill (填充)**: 节点会尝试占据分配给它的所有空间。
*   **Expand (扩展)**: 节点会尝试占用容器中剩余的空白空间。
*   **Shrink (收缩)**: 默认行为，节点只占用其最小尺寸 (`custom_minimum_size`)。

**常见组合**:
*   **水平铺满**: `H_SIZE_FLAG_EXPAND | H_SIZE_FLAG_FILL`
*   **垂直铺满**: `V_SIZE_FLAG_EXPAND | V_SIZE_FLAG_FILL`

```gdscript
# 代码设置示例
node.size_flags_horizontal = Control.SIZE_EXPAND_FILL
node.size_flags_vertical = Control.SIZE_FILL
```

## 4. 最小尺寸 (Custom Minimum Size)

如果希望容器中的某个元素（如按钮）保持一定的大小而不被压缩，请设置 `custom_minimum_size`。

```gdscript
button.custom_minimum_size = Vector2(100, 40)
```

## 5. 常见布局层级

**标准面板**:
```text
PanelContainer (提供背景)
 └── MarginContainer (提供内边距)
      └── VBoxContainer (内容垂直排列)
           ├── Label (标题)
           ├── HSeparator (分割线)
           └── RichTextLabel (正文, Size Flags = Expand + Fill)
```
