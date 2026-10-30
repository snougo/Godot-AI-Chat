# 写操作工具限制

**通用**：路径必须 `res://`、禁止 `..`；目标文件夹**必须先存在**（用 `create_folder` 建）；`/.git/` `/.import/` `/.godot/` `/android/` `/addons/` 禁写；创建类工具**从不覆盖**同名文件。
> 例外：`create_document_file`（`.md`）豁免黑名单。

## `run_editor_script`

前置：`allow_editor_script_execution` 已开启；脚本已落盘（不接受内联代码）。

`script_path`：`res://` + `.gd`，不在黑名单区（含 `rollback_files/`）；内容必须为：

```gdscript
@tool
extends EditorScript

func _run() -> void:
	pass
```

❌ 禁止 `class_name`。

`file_paths`：每项必须**精确文件路径**（声明目录不覆盖内部文件）；扩展名限 `md json txt csv cfg gdshader glsl tres tscn gd svg`；代码里**每个** `res://` 字面量（含只读 `load`）都要列出。

**一律禁止**

- 网络类全部：`HTTPRequest` `HTTPClient` `WebSocketPeer` `StreamPeer*` `TCPServer` `PacketPeerUDP`
- 高危类全部方法：`OS` `EditorInterface` `ProjectSettings` `Engine` `EditorFileSystem` `ScriptEditor`
- `DirAccess.remove* / rename* / copy* / make_dir_recursive*`、`ClassDB.instantiate/instance`

**路径只能是字面量或赋了字面量的变量**：❌ `const` 常量、❌ 拼接 / 表达式（涉及 `FileAccess.*` 首参、`ResourceSaver.save()` 次参）。

**审计**：执行后比对文件变更，有未声明变更 → 返回失败，但**脚本已执行**，需用 `res://rollback_files/` 备份回滚。

**报错对照**：`disabled` 未开开关 ｜ `Invalid editor script` 缺 `@tool` / `extends EditorScript` / `_run()` 或含 `class_name` ｜ `Invalid file paths` 扩展名或受限区 ｜ `Static analysis blocked` 危险 API ｜ `undeclared file paths` 字面量未声明 ｜ `Dynamic ... path detected` 用了 `const` / 表达式 ｜ `Security violations` 执行后越界写入。

## 其他

- `create_script`：仅 `.gd`；文件夹须存在；**不能覆盖**同名（改写已有脚本用编辑类工具）。
- `create_folder`：已存在则失败。
- `save_edited_file`：仅保存编辑器**当前打开**的场景 / 脚本；shader 需先 `open_file`。
