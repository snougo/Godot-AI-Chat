# 写操作工具限制

本文汇总所有**会写入项目文件**的工具所共同遵守的限制，以及各工具的专属细则。

> `run_editor_script` 规则较多，已单独成篇：见 `run_editor_script_limitations.md`。

## 通用规则

- 路径必须为 `res://`，**禁止** `..`；
- 目标文件夹**必须先存在**；
- 以下目录**禁写**：`/.git/`、`/.import/`、`/.godot/`、`/android/`、`/addons/`；
- **创建类工具从不覆盖**同名文件（已存在即失败，改写请用编辑类工具）。

> 例外：`create_document_file`（`.md`）豁免上述黑名单限制。

## 各工具细则

| 工具 | 限制 |
|---|---|
| `create_script` | 仅 `.gd`；文件夹须已存在；**不能覆盖**同名文件（改写已有脚本用编辑类工具） |
| `create_folder` | 目录已存在则失败 |
| `save_edited_file` | 仅保存编辑器**当前打开**的场景 / 脚本；shader 需先 `open_file` |
| `run_editor_script` | 见 `run_editor_script_limitations.md` |

## 备注

- 上表未列出的写操作类工具，一律遵循「通用规则」；
- 涉及删除、覆盖、批量改写的操作，执行前请先确认备份（例如依赖 `res://rollback_files/` 中的自动备份）。
