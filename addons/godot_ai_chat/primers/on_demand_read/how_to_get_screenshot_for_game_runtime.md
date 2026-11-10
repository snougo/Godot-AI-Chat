# 运行中游戏截图 · 使用说明

> 本项目**没有**独立的截图工具、截图节点或截图脚本。
> 需要截图时，由 AI 把下面这段代码**直接合入现有的游戏脚本**，运行时按 `F12`，
> 画面会被覆盖写到固定路径，AI 再用 `view_image` 读取。

---

## 1 定位：它回答什么问题

| 想知道 | 该用什么 |
|---|---|
| 地形长什么样、障碍在哪、通道多宽、目标被什么挡住 | **本机制** |
| 编辑器里静止场景的渲染细节（材质 / 光照 / shader） | `capture_viewport_screenshot` |
| 精确数值（坐标、速度、接触体、射线距离、控件矩形） | AI Debug Probe 的 `pose` / `contacts` / `query` / `ui` |

截图给「空间关系」，数值给「精确值」。**两者叠加使用，不要互相替代。**

---

## 2 产物

```
res://screenshot/runtime/latest.png     画面，宽度 <= 1280，固定文件名，覆盖写
res://screenshot/runtime/.gdignore      代码自动创建，让 Godot 不扫描该目录
```

- 没有 JSON、没有元信息。**无法从文件判断新旧**，靠流程保证：
  用 `unit: "idle"` 触发并给 2~3 帧，触发调用返回后立刻读图。
- 目录里永远只有这一张图，不会堆积。
- `.gdignore` 的作用：该目录若被 Godot 扫描，每次覆盖 png 都会触发一次重新导入
  （编辑器卡顿 + `.godot/imported` 堆积）。

---

## 3 合入代码（整块复制，可安全删除）

### 3.1 常量 + 截图函数

放在目标脚本的常量区与私有函数区：

```gdscript
# --- DEBUG SCREENSHOT (整块可安全删除) ---

const DEBUG_SCREENSHOT_DIR: String = "res://screenshot/runtime"
const DEBUG_SCREENSHOT_PATH: String = "res://screenshot/runtime/latest.png"
const DEBUG_SCREENSHOT_MAX_WIDTH: int = 1280


# 截取当前画面到 res://screenshot/runtime/latest.png（固定文件名，覆盖写）
func _debug_capture_screenshot() -> void:
	if not DirAccess.dir_exists_absolute(DEBUG_SCREENSHOT_DIR):
		DirAccess.make_dir_recursive_absolute(DEBUG_SCREENSHOT_DIR)
	var ignore_path: String = DEBUG_SCREENSHOT_DIR + "/.gdignore"
	if not FileAccess.file_exists(ignore_path):
		var ignore_file: FileAccess = FileAccess.open(ignore_path, FileAccess.WRITE)
		if ignore_file != null:
			ignore_file.store_string("")
			ignore_file.close()
	# 等本帧渲染结束，否则拿到的是上一帧
	await RenderingServer.frame_post_draw
	var image: Image = get_viewport().get_texture().get_image()
	if image == null:
		push_warning("[DEBUG SCREENSHOT] cannot read the viewport texture")
		return
	if image.get_width() > DEBUG_SCREENSHOT_MAX_WIDTH:
		var thumb_height: int = maxi(int(round(float(image.get_height()) * float(DEBUG_SCREENSHOT_MAX_WIDTH) / float(image.get_width()))), 1)
		image.resize(DEBUG_SCREENSHOT_MAX_WIDTH, thumb_height, Image.INTERPOLATE_LANCZOS)
	var save_err: int = image.save_png(DEBUG_SCREENSHOT_PATH)
	if save_err != OK:
		push_warning("[DEBUG SCREENSHOT] cannot write %s (%s)" % [DEBUG_SCREENSHOT_PATH, error_string(save_err)])

# --- END DEBUG SCREENSHOT ---
```

### 3.2 触发：F12

**脚本里没有 `_input` 时**，新增整个函数：

```gdscript
func _input(p_event: InputEvent) -> void:
	var key_event: InputEventKey = p_event as InputEventKey
	if key_event == null or not key_event.pressed or key_event.echo:
		return
	if key_event.keycode != KEY_F12 and key_event.physical_keycode != KEY_F12:
		return
	_debug_capture_screenshot()
	get_viewport().set_input_as_handled()
```

**脚本里已有 `_input` 时**，在函数体最前面插入（**不要 `return`**，避免影响原有逻辑）：

```gdscript
	var key_event: InputEventKey = p_event as InputEventKey
	if key_event != null and key_event.pressed and not key_event.echo \
			and (key_event.keycode == KEY_F12 or key_event.physical_keycode == KEY_F12):
		_debug_capture_screenshot()
		get_viewport().set_input_as_handled()
```

### 3.3 选哪个脚本

| 优先级 | 目标 | 原因 |
|---|---|---|
| ① | 场景根节点上已有的脚本 | 通常没有每帧逻辑，副作用最小 |
| ② | 玩家脚本 | 一定随场景存在 |
| ③ | 任意常在的 UI / 管理器脚本 | 避免会被 `queue_free` 的临时对象 |
| ④ | 场景里一个脚本都没有 | 才需要新建一个最小 `Node` 脚本并挂到根节点 |

合入后**重启游戏**（脚本热重载会丢运行时状态，别指望 Synchronize Script Changes）。

---

## 4 触发

### 4.1 AI 自己触发（游戏由 AI Debug Probe 启动）

```jsonc
{"frames": 3, "unit": "idle", "plan": [{"at": 0, "press": ["F12"]}]}
```

- **用 `unit: "idle"`，给 2~3 帧**。按键事件是在**渲染帧的输入阶段**分发的，物理帧窗口内
  不保证一定发生；用 idle 帧才能保证「注入 → 分发 → 本帧渲染完成 → PNG 落盘」都发生在这次调用里。
- 只推 1 帧就 `view_image`，很可能读到上一张。
- **不需要改 `process_mode`**：probe 在 step 执行期间会把 `SceneTree.paused` 临时设为 `false`，
  所以默认（可暂停）节点在 step 内照样能收到 `_input`。改 `process_mode` 反而是错的（见第 6 节）。
- 截图可以夹在任何 step 之间，用来「看清这一帧到底长什么样」再继续推进。

### 4.2 用户手动按 F12（`run_game` / F5 / 导出运行）

跨进程 AI 无法注入输入，此时**直接请用户按一次 `F12`**，并提醒：游戏窗口需要处于焦点状态。

注意：如果游戏正被 probe 停在暂停状态（两次 step 之间），玩家脚本收不到输入 ——
让用户先把游戏跑起来，或由 AI 自己代按一次：

```jsonc
{"frames": 3, "unit": "idle", "plan": [{"at": 0, "press": ["F12"]}]}
```

---

## 5 读取截图

```
view_image(path="res://screenshot/runtime/latest.png")
```

- 固定文件名，每次覆盖；同一时间只有一张有效图，**不要指望读取历史帧**。
- 画面宽度 ≤ 1280，高度按比例；2D / 3D 都适用，UI 也在画面里。
- 图与当前状态明显不符 → 是旧图，重新触发一次再读。

---

## 6 严禁事项

| 禁止 | 后果 |
|---|---|
| 改目标脚本所属节点的 `process_mode = PROCESS_MODE_ALWAYS` | probe 暂停期间玩家会继续跑，暂停语义被破坏，实验数据全错 |
| 在 `_input` 里 `await _debug_capture_screenshot()` | `_input` 里等渲染帧会拖住输入分发；直接调用即可（函数内部自己 await） |
| 把触发写进 `_ready` / `_process` 每帧调用 | 每次运行都截图、每帧覆盖写盘，严重拖慢 |
| 把代码放进 `queue_free()` 的临时对象 | 触发时节点可能已不在树里 |
| 忘记保存脚本 / 不重启游戏 | 运行中的游戏跑的还是旧代码 |

---

## 7 成本控制

- 一张 1280 宽的图约 1~2k token。**一次任务控制在 5~10 张以内**。
- 先想清楚要看什么再触发，不要"连拍截图找线索"。
- 量距离、量通道宽度用 `query` 射线；看控件位置用 `ui.rects` —— 更准、更便宜。

---

## 8 Debug 绘制（碰撞体 / 路径 / 导航 / 避障）

引擎限制：`SceneTree.debug_collisions_hint`、`debug_paths_hint` **只在启动时读取**，
运行中修改无效。Debug 菜单那四项实际是「写 project metadata → 启动参数
`--debug-collisions` / `--debug-paths` / `--debug-navigation` / `--debug-avoidance`」。

要截带 debug 绘制的图：

1. 请用户在编辑器 **Debug 菜单**勾选需要的项
2. **重启游戏**（勾完不重启不生效）
3. 再按第 4 节触发截图

画面上的线框就是证据，不需要额外元信息。

---

## 9 边界与已知坑

| 现象 | 原因 / 处理 |
|---|---|
| 图不存在 | 代码没合入 / 脚本没保存 / 游戏没重启 / 不是那个场景 |
| 图是旧的 | 只推了 1 帧就读取（物理帧窗口内可能一次渲染帧都没有）。改用 `unit: "idle"` 给 2~3 帧 |
| 按 F12 没反应 | 游戏窗口没焦点；或游戏正处于 probe 暂停状态（见 4.2） |
| 一直等不到截图 | 窗口最小化 / 低处理器模式下视口可能不重绘。`await` 会一直等，此时改用数值观测 |
| 导出构建里失效 | 游戏运行包里 `res://` 只读，`save_png` 失败并打印 warning |
| 换场景后失效 | 代码随脚本所在的场景/节点销毁。多场景测试就每个场景各合入一次 |
| 编辑器 FileSystem 面板里看不到 runtime 目录 | 正常，`.gdignore` 忽略了它，`view_image` 仍可读 |
| 截图函数自己报错 | 用 `read_errors` 看 Error 面板，warning 带 `[DEBUG SCREENSHOT]` 前缀 |

---

## 10 清理

1. 全局搜索 `DEBUG SCREENSHOT`，把 `--- DEBUG SCREENSHOT ---` 与 `--- END DEBUG SCREENSHOT ---`
   之间的内容整块删掉。
2. 删掉 3.2 里插入的 `_input` 片段（若整个 `_input` 是你为截图新增的，就整函数删除）。
3. 可选：删除 `res://screenshot/runtime/` 目录。
4. 保存脚本、重启游戏确认无残留。

---

## 11 走位侦察：典型帧脚本

### 11.0 一条硬规则

截图是**固定文件名覆盖写**，所以 **一个 `step` 最多留下一张图**。
想「每走 30 帧截一张」就必须拆成多个 step：走一段 → 截一张 → 读图 → 再走。

下面配方里的键名（`ui_up` / `ui_left`）是示例，实际用项目 InputMap 里的动作名。

### 11.1 原地看前方（每次侦察的第一步）

```jsonc
{"frames": 4, "unit": "idle", "plan": [{"at": 1, "press": ["F12"]}]}
```

看：正前方有什么、地面在哪、HUD 状态。

### 11.2 前进一段再截（走廊 / 直路）

```jsonc
{"frames": 34, "unit": "idle", "plan": [
   {"at": 0,  "press": ["ui_up"]},
   {"at": 30, "release": ["ui_up"]},
   {"at": 31, "press": ["F12"]}
], "watch": ["pose", "contacts"]}
```

读图的同时看 `pose.moved`：**数值在前进但图里已经贴着墙**，说明下一段就会卡住。
判断「有没有在走」只看 `moved`，不要看 `velocity`（撞墙后会被 `move_and_slide()` 就地清零）。

### 11.3 原地环视（判断四周）

```jsonc
{"frames": 66, "unit": "idle", "plan": [
   {"at": 0,  "press": ["ui_right"]},
   {"at": 60, "release": ["ui_right"]},
   {"at": 62, "press": ["F12"]}
]}
```

60 帧 ≈ 90°（示例项目 `TURN_SPEED = 90°/s`）。实际转了多少用 `pose.camera.yaw` 确认，
不要凭帧数假设。转 4 次、截 4 张（每张独立 step + 独立 `view_image`）就能拼出全景。

### 11.4 疑似被挡：用 `query` 量出来，比截图更准

```jsonc
{"frames": 6, "unit": "idle", "plan": [
   {"at": 0, "query": [
      {"as": "front",  "kind": "ray", "from": "/root/MiniGame/Player", "offset": [0, 0.6, 0], "direction": [0, 0, -1], "length": 8},
      {"as": "ground", "kind": "ray", "from": "/root/MiniGame/Player", "offset": [0, -0.85, 0], "direction": [0, -1, 0], "length": 1.0},
      {"as": "around", "kind": "near", "from": "/root/MiniGame/Player", "radius": 3}
   ]},
   {"at": 3, "press": ["F12"]}
], "watch": ["queries", "pose"]}
```

| 字段 | 含义 |
|---|---|
| `from` | 起点节点路径（必须存在）。结果默认**排除该节点自身** |
| `offset` | 相对起点节点位置的偏移 |
| `direction` | 方向数组。**缺省时用起点节点的 -Z** |
| `length` | 射线长度，默认 10 |
| `radius` | `near` 的半径，默认 4 |
| `areas` | `near` 是否包含 Area（射线永远不会返回 Area，只能靠 `near`） |

**方向不要依赖缺省值**：很多项目（包括示例）是「身体不转、相机转」，缺省的 -Z 会指向错误方向。
显式写 `direction`，或先读 `pose.camera.forward` 再用它算方向。

结果读法：`front.distance` = 到墙的距离；`around.bodies` = 半径内的所有碰撞体；
`ground.hit` = 脚下有没有东西。结果按 `as` 标签粘住，后续帧的 `check` 仍能读到。

注意 `near` 里每个体的 `distance` 是**体块原点**到起点的距离，不是表面距离。
所以会出现 `distance` 略大于 `radius` 的条目（实测：`radius: 3` 时 Wall 报 `3.002`，
因为它的盒子表面仍在球内）。不要拿它当「超出半径就无效」来判断。

### 11.5 标准侦察循环

```
1. pose            → 我在哪、朝哪、上一段走了多远
2. 11.1 截图       → 前方 3~5 米内有什么形状的东西
3. 有通路          → 11.2 前进 30 帧
4. moved 变 0      → 撞墙：11.4 量距离，换方向或找缝
5. 每走 2~3 段重截 → 不要一口气走 200 帧再回头找问题
```

### 11.6 图与数值的分工

| 疑问 | 先看什么 |
|---|---|
| 前面是不是墙 | 图（形状）+ `query.front.hit` / `distance` |
| 这条缝能不能挤过去 | `query.near` 找体块 + 图看通道宽度 |
| 撞到了什么 | `pose.on_wall` / `contacts` + 图确认是哪一面 |
| 走了多远 | `pose.moved`（**不要用 `velocity`**） |
| 目标在哪、怎么绕 | `pose.pos` 与目标坐标算方位，截图确认路径 |

### 11.7 成本

每张图 1~2k token。一次侦察控制在 5~10 张；
能量出来的距离、宽度、接触体，就不要靠图上目测。
