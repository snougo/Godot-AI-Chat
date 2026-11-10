# macOS 原生窗口与弹窗

> 结论来自 Godot 4.8 beta2 + macOS 的实测与引擎源码排查（2026-10-30）。

## 核心：`transient` 决定窗口行为

`Window.popup()` / `popup_centered()` 会把窗口设为 **transient**；而 `AcceptDialog`（含 `FileDialog`）的构造函数**本身就是** `set_transient(true)` + `set_exclusive(true)`。
macOS 后端把 transient 窗口实现为 AppKit 的**附加子窗口**，并按「是否同一显示器」动态挂接/脱开（`DisplayServerMacOS::reparent_check()`）：

| 两个窗口的位置 | 引擎行为 | 后果 |
|---|---|---|
| 同一显示器 | `addChildWindow()` 附加到父窗口 | 拖动明显卡顿；系统截图工具无法单独捕获（会截到整个父窗口） |
| 不同显示器 | `removeChildWindow()` | 退化为普通独立窗口，两个症状同时消失 |

## 硬规则

1. **需要独立原生窗口**：`force_native = true` + `show()`，不要用 `popup()` / `popup_centered()`。
2. `force_native` 只允许在窗口未显示时修改 → 必须先 `visible = false`，再设标志位。
3. **`transient` 与 `always_on_top` 互斥**（引擎侧 `ERR_FAIL_COND_MSG`）。又因为 `AcceptDialog` 构造即 `transient = true`，
   给提示框加 `always_on_top` 会让每次显示、关闭各报一条错：
   `Windows with the 'on top' can't become transient.` 与 `transient_parent == p_parent`。
4. 对话框只有两种做法，**不要混用**：
   - **保持 transient**（`popup_centered()`）：**不需要置顶**——附加子窗口本来就在父窗口之上，足以起警示作用。
     代价是同屏拖动卡顿。**本插件的提示框与文件选择器统一采用这一种。**
   - **需要置顶**：在窗口首次显示前显式 `transient = false` + `exclusive = false`，再 `show()` 并手动居中。
     不要在 `popup()` 之后再改 `transient`（会触发上述第二条报错）。
5. 文件选择器若要彻底避开卡顿：`FileDialog.use_native_dialog = true`（系统原生面板）。本项目实测与插件不合，未采用。
6. 内嵌子窗口（`gui_embed_subwindows = true`）拖动会触发父视口**全量重绘**，主视口内容重时明显卡顿 → 插件窗口优先用原生窗口。

## 原生窗口的必要配套

| 事项 | 做法 |
|---|---|
| `force_native` 设置时机 | `_init()` 中先 `visible = false` 再设 |
| 首次呈现不绘制内容（只有底色） | `show()` 之后跨帧做一次 1px 尺寸往返 |
| `Window` 不是容器 | 连接 `size_changed`，手动同步子控件尺寸 |
| 主题不继承编辑器 | 显式 `theme = EditorInterface.get_editor_theme()`，并自铺背景 |
| 没有 OK 按钮、没有 Esc | 自行连接 `close_requested`；Esc 用 `_unhandled_key_input` 处理 |

参考实现：`scripts/ui/text_viewer_window.gd`。
