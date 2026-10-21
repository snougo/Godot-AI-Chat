# 工具限制说明

> **用途**：汇总「写操作类」工具的硬性限制与失败原因，供 **首次调用前** 阅读，避免因反复试错浪费 token。
> **重点工具**：`run_editor_script`、`create_script`（均为「碰壁后才知道」的典型）。

---

## 一、通用规则（所有写操作工具）

| 规则 | 说明 |
|------|------|
| 路径前缀 | 必须以 `res://` 开头 |
| 目标文件夹 | **必须已存在**，工具不会自动创建 → 先用 `create_folder` |
| 只读黑名单 | 路径命中 `/.git/`、`/.import/`、`/.godot/`、`/android/`、`/addons/` 时**拒绝写入** |
| 禁止覆盖 | 创建类工具（`create_script` / `create_folder` / `create_document_file`）**不允许覆盖同名文件/文件夹**，只能换名 |
| 路径穿越 | 禁止出现 `..` |

> **黑名单例外**：`create_document_file`（`.md`）**豁免**黑名单，可在 `res://addons/` 等目录下写文档。

---

## 二、`run_editor_script`

### 2.1 用途与前置条件

在编辑器上下文执行一个**已落盘**的 `EditorScript`（不接受内联代码，不对脚本做任何改写）。

**前置条件（任一不满足直接失败）**：
1. 插件设置中的 `allow_editor_script_execution`（**PandoraBox** 开关）必须已打开；否则返回「Editor Script execution is disabled」。
2. `script` 必须**先创建好**（用 `create_script`），再传给 `script_path`。

### 2.2 执行流水线（10 道关卡）

| 关卡 | 校验内容 |
|------|----------|
| L0 | 主开关（PandoraBox） |
| L1A | `file_paths` 形态校验 |
| L1B | `script_path` 形态 + 结构校验 |
| L1C | 静态分析：危险 API |
| L1D | 代码内 `res://` 字面量 ⊆ 声明集 |
| L1E | 动态路径检测（`FileAccess` / `ResourceSaver` 参数） |
| L1.75 | 备份声明路径 → `res://rollback_files/` |
| L2 | 必须处于编辑器环境 |
| L3 | 编译并执行 `_run()` |
| L4 | 执行前后文件快照审计 |

### 2.3 `script_path` 限制（L1B）

- 必须 `res://` 前缀 + `.gd` 扩展名。
- **不能在受限区**：`res://addons/`、`.godot/`、`.git/`、`.import/`、`android/`、`rollback_files/`。
- 文件必须已存在、非空。
- **脚本结构**（基于分词 token 判定，`#` 注释与字符串中的同名文本不算）：
  - ✅ 必须 `@tool`
  - ✅ 必须 `extends EditorScript`
  - ✅ 必须 `func _run()`
  - ❌ **禁止 `class_name`**（脚本被编译为匿名 GDScript，全局类名会与项目类注册表冲突）

```gdscript
# 唯一合法骨架
@tool
extends EditorScript

func _run() -> void:
	pass
```

### 2.4 `file_paths` 限制（L1A + L4）

- 每项必须是字符串、`res://` 前缀。
- 扩展名必须在白名单（**无扩展名的目录路径也允许**）：
  `md` `json` `txt` `csv` `cfg` `gdshader` `glsl` `tres` `tscn` `gd` `svg`
- 不能落在受限区（同 2.3）。
- ⚠️ **必须声明「精确文件路径」**：L4 审计按**字符串精确匹配**，声明目录**不会**覆盖其内部文件。即若脚本会创建 `res://a/b.tscn`，就必须声明这一整条路径。

### 2.5 危险 API 黑名单（L1C）

> 检查基于「对象类型解析」：会追踪 `var x = DirAccess.new()` 之类的**别名**，`x.remove()` 同样会被拦截。

**① 网络类——全部禁止**
`HTTPRequest` `HTTPClient` `WebSocketPeer` `StreamPeerTCP` `StreamPeerTLS` `TCPServer` `PacketPeerUDP`

**② 高危类——该类的所有方法一律禁止**

| 类 | 备注 |
|----|------|
| `OS` | |
| `EditorInterface` | |
| `ProjectSettings` | |
| `Engine` | 连 `Engine.is_editor_hint()` 也被禁 |
| `EditorFileSystem` | |
| `ScriptEditor` | |

**③ 特定方法禁止**

| 调用 | 原因 |
|------|------|
| `DirAccess.remove()` / `remove_absolute()` | 禁止删文件 |
| `DirAccess.rename()` / `rename_absolute()` | 禁止改名/移动 |
| `DirAccess.copy()` / `copy_absolute()` | 禁止复制（可能覆盖） |
| `DirAccess.make_dir_recursive()` / `make_dir_recursive_absolute()` | **禁止建目录** |
| `ClassDB.instantiate()` / `ClassDB.instance()` | 动态实例化会绕过静态分析 |

**④ 链式调用保守拦截**
对象类型无法静态解析的链式调用，若方法名命中上述禁用名单（如 `).remove(`）→ 一律拦截。

### 2.6 路径字面量要求（L1D + L1E）

1. 代码中**所有** `res://` 字符串字面量（含 `load()`、`preload()`、`FileAccess.*` 等只读用途）**都必须出现在 `file_paths`**。
2. `FileAccess.*` 的第 1 个参数、`ResourceSaver.save()` 的第 2 个参数，**只能是**：
   - ✅ 字符串字面量：`ResourceSaver.save(res, "res://a/b.tscn")`
   - ✅ 赋值为字面量的**变量**：`var p: String = "res://a/b.tscn"` → `ResourceSaver.save(res, p)`
   - ❌ **`const` 常量**（`const P = "res://..."` 解析不了，**这是最常见的坑**）
   - ❌ 拼接/表达式：`"res://a/" + name`

### 2.7 执行后审计（L4）

- 执行前后扫描 `res://`（受限区已剪枝），比对 created / modified / deleted。
- 任何变更文件**不在 `file_paths`** 中 → 判定为安全违规，工具返回失败（**但脚本已实际执行完毕**，需靠备份回滚）。
- 每次调用都会生成备份（`res://rollback_files/`），返回 `Backup ID`，可用于手动回滚。

### 2.8 错误信息对照表

| 返回信息 | 含义 / 对策 |
|----------|-------------|
| `Editor Script execution is disabled.` | 未开 PandoraBox |
| `Invalid editor script:` | 缺 `@tool` / `extends EditorScript` / `func _run()`，或含 `class_name` |
| `Invalid file paths declared.` | 扩展名不在白名单 / 落在受限区 |
| `Static analysis blocked execution.` | 命中危险 API 黑名单（2.5） |
| `Code contains undeclared file paths.` | 代码有 `res://` 字面量未声明（2.6-1） |
| `Dynamic or undeclared file path detected in API call.` | API 路径用了 `const`/表达式（2.6-2） |
| `Security violations detected after execution.` | 执行后越界写入（2.7） |

---

## 三、`create_script`

| 项目 | 限制 |
|------|------|
| 扩展名 | **仅 `.gd`** |
| 目标文件夹 | **必须已存在**（否则提示先 `create_folder`） |
| 覆盖 | ❌ **不允许覆盖同名文件** → `Error: File already exists at ... Overwriting is not allowed.` |
| 路径 | `res://` 开头，且不得命中黑名单 `/.git/` `/.import/` `/.godot/` `/android/` `/addons/` |
| 参数 | `path`（文件夹）、`file_name`（含 `.gd`）、`content`（均不能为空） |

> **对策**：需要「改写」已有脚本时，不要用 `create_script`；改用文件编辑/保存类工具，或**换新文件名**创建后再处理旧文件。

---

## 四、相关工具速查

| 工具 | 关键限制 |
|------|----------|
| `create_folder` | 文件夹已存在时失败（`Folder already exists`）；受黑名单限制 |
| `create_document_file` | **豁免黑名单**（可在 `addons/` 下写 `.md`）；不允许覆盖同名；文件夹须已存在；禁止 `..` |
| `create_script` | 见第三节 |
| `run_editor_script` | 见第二节 |
| `save_edited_file` | 保存「编辑器当前打开」的场景/脚本/shader（非新建）；仅编辑器可用；shader 需先 `open_file` |

---

## 五、`run_editor_script` 正确写法模板

```gdscript
@tool
extends EditorScript

## 说明：目标目录需预先用 create_folder 建好（脚本内建目录会被拦截）。

func _run() -> void:
	var root := Node3D.new()
	root.name = "Root"
	# ... 构建节点树 ...
	# 注意：必须递归设置 owner，否则 PackedScene.pack() 会忽略未归属子节点
	_set_owner_recursive(root, root)

	var packed := PackedScene.new()
	if packed.pack(root) != OK:
		push_error("pack failed")
		root.free()
		return

	# 路径必须是字面量（不能用 const），且必须已声明在 file_paths 中
	var err := ResourceSaver.save(packed, "res://test/demo/out.tscn")
	root.free()
	if err != OK:
		push_error("save failed: %d" % err)
		return
	print("done")


func _set_owner_recursive(p_node: Node, p_owner: Node) -> void:
	for child in p_node.get_children():
		child.owner = p_owner
		_set_owner_recursive(child, p_owner)
```

调用时：
- `script_path` = `res://test/demo/build.gd`
- `file_paths` = `["res://test/demo/out.tscn"]`（**精确文件路径**，不要只给目录）

---

## 六、一句话备忘

1. 建目录 → 用 `create_folder`，**别无他法**（脚本内非法）。
2. 脚本路径/项目路径 → **只能用字面量**，`const` 无效。
3. 脚本里出现的每个 `res://` 字面量 → **都要在 `file_paths` 里逐一列出**。
4. `Engine` / `EditorInterface` / `DirAccess.make_dir*` / 删除 / 改名 → **一律禁止**。
5. 写文件工具 → **从不覆盖**，重名就换名。
6. 目标目录 → **必须先存在**。
