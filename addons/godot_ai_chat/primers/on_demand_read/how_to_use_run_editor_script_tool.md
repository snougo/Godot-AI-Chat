#  `run_editor_script` 使用说明

> 本文是 `tool_limitations.md` 中 `run_editor_script` 一节的独立版本。
> **通用写操作限制**（路径必须 `res://`、...）见 `write_operation_limitations.md`。

## 前置条件

- 插件设置 `allow_editor_script_execution` 已开启（UI 上的 PandoraBox 开关）；
- 脚本**已落盘**，不接受内联代码。

## `script_path`

- `res://` + `.gd`；
- 不在黑名单区（**含 `rollback_files/`**）；
- 内容必须为：

```gdscript
@tool
extends EditorScript

func _run() -> void:
	pass
```

- ❌ 禁止 `class_name`。

## `file_paths`

- 每项必须是**精确文件路径**（声明目录不覆盖其内部文件）；
- 扩展名限：`md json txt csv cfg gdshader glsl tres tscn gd svg`；
- 代码里**每个** `res://` 字面量（含只读的 `load`）都要列出。

## 一律禁止

- **网络类全部**：`HTTPRequest` `HTTPClient` `WebSocketPeer` `StreamPeer*` `TCPServer` `PacketPeerUDP`
- **高危类全部方法**：`OS` `EditorInterface` `ProjectSettings` `Engine` `EditorFileSystem` `ScriptEditor`
- `DirAccess.remove* / rename* / copy* / make_dir_recursive*`、`ClassDB.instantiate/instance`

## 路径写法

**只能是字面量，或赋了字面量的变量**：

- ❌ `const` 常量
- ❌ 拼接 / 表达式

（涉及 `FileAccess.*` 首参、`ResourceSaver.save()` 次参。）

## 执行后审计

执行后会比对文件变更；若存在**未声明**的变更 → 返回失败，但**脚本已经执行过**，需用 `res://rollback_files/` 中的备份回滚。

## 报错对照

| 报错 | 含义 |
|---|---|
| `disabled` | 未开启 `allow_editor_script_execution` 开关 |
| `Invalid editor script` | 缺 `@tool` / `extends EditorScript` / `_run()`，或含 `class_name` |
| `Invalid file paths` | 扩展名不符，或落在受限区 |
| `Static analysis blocked` | 使用了禁止的危险 API |
| `undeclared file paths` | 代码中的字面量未在 `file_paths` 声明 |
| `Dynamic ... path detected` | 路径用了 `const` 或表达式 |
| `Security violations` | 执行后发生了越界写入 |
