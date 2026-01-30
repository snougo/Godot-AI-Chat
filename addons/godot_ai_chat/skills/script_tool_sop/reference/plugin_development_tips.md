# 插件开发小贴士 (Plugin Development Tips)

编写 Godot 编辑器插件（Addons）或工具脚本（Tool Scripts）时的关键注意事项。

## 1. @tool 关键字

*   **位置**：必须放在脚本的第一行（在 `extends` 之前）。
*   **作用**：告诉编辑器该脚本可以在编辑器模式下运行。
*   **生命周期**：
    *   `_init()`: 节点实例化时调用（包括在编辑器中拖入节点时）。
    *   `_ready()`: 节点进入场景树时调用（编辑器中加载场景时也会触发）。
    *   `_process()`: 编辑器中每一帧都会触发（**非常危险**，务必限制条件）。

## 2. 区分编辑器与游戏模式

使用 `Engine.is_editor_hint()` 来隔离逻辑，防止编辑器逻辑在游戏中运行，反之亦然。

```gdscript
func _ready():
    if Engine.is_editor_hint():
        # 编辑器专用逻辑 (例如：绘制辅助线)
        pass
    else:
        # 游戏运行时逻辑 (例如：开始游戏循环)
        pass
```

## 3. 安全的资源加载与保存

在插件中操作资源时，务必小心缓存和文件系统状态。

*   **加载**: 使用 `ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)` 可以强制从磁盘重新读取，避免获取到旧的缓存数据（在修改文件后特别重要）。
*   **保存**: 使用 `ResourceSaver.save(resource, path)`。
*   **刷新**: 修改文件后，调用 `EditorInterface.get_resource_filesystem().scan()` 或 `update_file(path)` 通知编辑器刷新文件系统，否则编辑器可能看不到新文件。

## 4. 内存管理与引用

*   **RefCounted**: 继承自 `RefCounted` 的对象（如自定义工具类）会自动管理内存。
*   **Nodes**: `Node` 及其子类需要手动 `queue_free()`，除非它们在场景树中被父节点管理。
*   **循环引用**: 小心 `signal` 连接导致的循环引用，确保在 `_exit_tree()` 中断开连接或清理资源。

## 5. 编辑器接口 (EditorInterface)

这是插件与编辑器交互的主要入口。

*   `EditorInterface.get_selection()`: 获取当前选中的节点。
*   `EditorInterface.get_edited_scene_root()`: 获取当前打开场景的根节点。
*   `EditorInterface.save_scene()`: 保存当前场景。
*   `EditorInterface.edit_resource(res)`: 在检视器中编辑资源。

## 6. 撤销/重做 (UndoRedo)

任何修改场景结构或属性的操作，**必须**通过 `EditorUndoRedoManager` 进行，否则用户无法撤销操作，且场景可能不会被标记为“未保存”。

```gdscript
var ur = EditorInterface.get_editor_undo_redo()
ur.create_action("Add Child Node")
ur.add_do_method(parent, "add_child", new_node)
ur.add_do_property(new_node, "owner", get_tree().edited_scene_root)
ur.add_undo_method(parent, "remove_child", new_node)
ur.commit_action()
```
