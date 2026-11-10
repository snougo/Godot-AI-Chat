# `ai_debug_probe_step` 使用说明

> 一次调用 = **推进 N 帧** + **按帧下指令** + **按帧采样** + **按帧断言**，返回这段时间里发生了什么。
> 它是「帧」这个单位的唯一入口：时间就是帧号，不是秒。

---

## 1 调用前必须知道的四条

1. **只对 `ai_debug_launch` 启动的游戏有效**。游戏侧的 `AiDebugProbe` 节点是前提；
   `run_game` / 手动 F5 起的游戏里没有它，调用会直接报错。
   `ai_debug_launch` 现在会等到探针握手成功（最多 15 秒）才返回，返回值里带探针版本与支持的能力清单；
   如果返回值说「没等到握手」，先看 `read_output`，等游戏起来再调 step。
2. **一次调用期间，暂停控制权在探针手里**：开始时接管，结束时还回去。`auto_release_seconds` 只在
   **首次请求之前**生效——一旦发过 step，探针就一直持有暂停控制权到游戏结束（两次调用之间隔着模型
   思考时间，中途放开会让游戏自由跑，确定性也就没有了）。
3. **一个 step 最多留下一张截图**（截图是固定文件名覆盖写）。要连拍就必须拆成多个 step。
4. **优先用 `unit: "idle"`**，除非你明确要物理确定性。理由见第 2 节。

---

## 2 参数

| 参数 | 类型 | 说明 |
|---|---|---|
| `frames` | int | 推进帧数，1 ~ 600 |
| `unit` | string | `"physics"`（默认，确定性，等于物理 tick）/ `"idle"`（渲染帧） |
| `plan` | array | 帧偏移动作，见第 3 节 |
| `samples` | array | 要采样的帧偏移；**空 = 只采最后一帧** |
| `watch` | array | 采样哪些观测，默认 `["pose", "errors"]`，见第 4 节 |
| `timeout` | number | 等待回执的秒数。**不传则按帧数估算**：`frames / 速率 × 2 + 2`（physics 用 `Engine.physics_ticks_per_second`，idle 按 60fps 估），下限 5 秒 |

### `physics` 还是 `idle`

| 选 physics | 选 idle |
|---|---|
| 要可复现的位移/物理结果（同脚本跑两次逐位一致） | 游戏逻辑写在 `_process` 里 |
| 断言"30 帧应该走 50 单位"这类精确值 | 需要**按键被 `_input` 收到**（输入在渲染帧分发） |
| | 需要渲染帧（截图、粒子、动画） |

实测：物理步进**不保证**对应一次 `_process`（TPS Demo 上 30 物理帧只走完 77% 的应走距离）。
反过来，`idle` 的 delta 随真实时间浮动，**不要**用它做精确位移断言。

---

## 3 `plan`：13 个键

`at` 是帧偏移（从本步第一帧算起）。同一个 `at` 里的多个键按对象顺序执行。

### 3.1 输入类

#### `press` / `release`

```jsonc
{"at": 0,  "press": ["ui_up"]}
{"at": 30, "release": ["ui_up"]}
{"at": 4,  "press": ["F12"]}
```

- 名字**先查 InputMap action**，查不到就当作 Godot 键名（`"F12"` / `"Space"`），并发一个真实 `InputEventKey`。
- 按住的输入在每个后续帧被 `keep()` 补按（窗口失焦会丢虚拟按键状态）；step 结束、断开、断连时自动松开。
- 同一个 step 内持续按住 = 只写一次 `press`，到需要松手时写 `release`。

#### `click`

```jsonc
{"at": 9, "click": ["HUD.StartButton"]}
{"at": 9, "click": {"key": "HUD.Panel", "button": "right"}}
{"at": 9, "click": ["HUD.Ok", {"key": "HUD.Panel", "button": "middle"}]}
```

- `key` 就是 `watch: ["ui"]` 里 `texts` / `rects` / `elements` 的键，格式是 **`屏根名.控件名`**
  （如 `MainMenu.SettingsButton`；屏根自身是 `场景根名.屏名`，如 `UIMenu.MainMenu`）。
- 动作是"鼠标移到控件中心 → 按下 → 抬起"，走视口输入，**命中测试与遮挡都按真实鼠标算**。
- 回执 `fired` 表示控件的 `pressed` 信号有没有真的触发；`mask` 是按钮接受的键位。
  右键点一个只认左键的按钮 → `fired: false` + `mask: 1`，这是游戏设计，不是探针故障。

#### `type`

```jsonc
{"at": 5, "type": {"key": "Settings.NameEdit", "text": "Arthur",
				   "replace": true, "submit": false, "focus": true}}
```

| 字段 | 默认 | 说明 |
|---|---|---|
| `replace` | `true` | 先全选再输入（覆盖原内容）。全选走平台主修饰键（Ctrl / Cmd） |
| `submit` | `false` | 结束后补一个 Enter，触发 `text_submitted` |
| `focus` | `true` | 先点击控件聚焦并放置光标；设 `false` 时在**现有选区**上输入 |

- 控件被遮挡、禁用、只读 → `focused: false` + `error`，不会"文字凭空出现在玩家点不到的框里"。
- 回执 `text` 是输入后的实际内容（截断 200 字符）。

#### `set`

```jsonc
{"at": 5, "set": {"key": "Settings.VolumeSlider", "value": 30}}
{"at": 5, "set": {"key": "Settings.QualityOption", "index": 2}}
```

- 直接走控件 API：`value_changed` / `item_selected` 会正常触发，监听者都会跑。
- 它**不测可达性**（能不能点到、有没有被挡）—— 那是 `click` / `drag` 的工作。
- 回答的是"让游戏以为音量是 30"，不是"玩家能不能拖到 30"。

#### `drag`

```jsonc
{"at": 6, "drag": {"key": "Settings.VolumeSlider", "from": 20, "to": 85, "steps": 6}}
{"at": 6, "drag": {"key": "Settings.NotesEdit", "from": [100, 200], "to": [300, 260]}}
```

- `from` / `to` 是数值时按 Range 值映射到滑轨像素；是 `[x, y]` 时按视口像素。
- `steps` 是按下与抬起之间的移动次数（默认 6）。
- 回执带实际到达的 `value` / `ratio`，**不要**假设像素映射是精确的。

#### `hover`

```jsonc
{"at": 3, "hover": ["MainMenu.PlayButton"]}
{"at": 3, "hover": {"point": [300, 200]}}
{"at": 3, "hover": [300, 200]}
```

- 只移动不按键：这是 tooltip、hover 高亮、按钮亮起这类状态的唯一测试手段（`click` 太快，采样时已经结束了）。
- 回执 `over` 是视口**实际认为**悬停的控件键，`matches` 表示是否就是你指定的那个。
  "tooltip 没出现" 可以由此区分成"鼠标根本没在控件上"。

#### `select`

```jsonc
{"at": 4, "select": {"key": "Settings.NotesEdit", "from": [0, 0], "to": [0, 4]}}   // TextEdit: 行列
{"at": 4, "select": {"key": "Settings.NameEdit", "from": 0, "to": 4}}            // LineEdit: 列
{"at": 4, "select": {"key": "Settings.NotesEdit", "all": true}}
{"at": 4, "select": {"key": "Settings.NotesEdit", "clear": true}}
```

- 走控件 API 设置选区（确定性），不是拖鼠标。
- 配合 `type` 的 `{"focus": false, "replace": false}` 才能在**选区上覆盖输入** ——
  文本编辑器里"替换"与"插入"是两条不同代码路径。

### 3.2 订阅类（跨步存活，是实验配置不是每帧状态）

#### `probe`（属性订阅）

```jsonc
{"at": 0, "probe": [{"path": "/root/Game/Player", "props": ["hp", "state", "velocity.x"]}]}
{"at": 0, "probe": {"clear": true}}
```

- 订阅会**累加并跨步存活**；读回靠 `watch: ["props"]`。
- 支持私有成员（`_hp`）与子路径（`velocity.x`、`stats.kills`）。
- 回执里每个目标的 `resolved` 表示路径是否解析到节点。

#### `listen`（信号订阅）

```jsonc
{"at": 0, "listen": [{"path": "/root/Game", "signal": "level_completed"}]}
{"at": 0, "listen": {"clear": true}}        // 清空记录，保留订阅
{"at": 0, "listen": {"disconnect": true}}   // 连订阅一起断
```

- 回执逐条给 `bound`：路径不存在、信号拼错**当场报错**，不会静默无输出。
- 读回靠 `watch: ["events"]`。

#### `contact`（接触订阅）

```jsonc
{"at": 0, "contact": [{"path": "/root/Game/Wall"}]}
{"at": 0, "contact": {"targets": ["/root/Game/Wall", "/root/Game/Crate"]}}
{"at": 0, "contact": {"clear": true}}
```

- 让 `contacts` 观测额外报告这些节点的接触情况（出现在 `targets` 下）。
- StaticBody 自己不会报告接触，探针用它的形状去查物理空间 —— 所以"墙被谁顶着"是能回答的。
- 回执里的 `unresolved` 列出解析不到的路径。

### 3.3 帧末类（在本帧末尾求值）

#### `query`（物理查询）

```jsonc
{"at": 4, "query": [
   {"as": "front",  "kind": "ray",  "from": "/root/Game/Player", "offset": [0, 0.6, 0],
	"direction": [0, 0, -1], "length": 8},
   {"as": "ground", "kind": "ray",  "from": "/root/Game/Player", "offset": [0, -0.85, 0],
	"direction": [0, -1, 0], "length": 1},
   {"as": "around", "kind": "near", "from": "/root/Game/Player", "radius": 3, "areas": false},
   {"as": "path",   "kind": "scan", "from": "/root/Game/Player",
	"spread": 180, "step": 10, "length": 4, "radius": 0.35, "need": 1.5}
]}
```

| 字段 | 说明 |
|---|---|
| `as` | 标签。结果**按标签粘住**，后续帧仍能读、仍能断言 |
| `kind` | `"ray"`（默认）/ `"near"` / `"scan"`（体宽扇形扫描，见下） |
| `from` | 起点节点路径（必须存在）。结果默认**排除该节点自身** |
| `offset` | 相对起点节点位置的偏移 |
| `point` | 显式坐标（2 或 3 个数），没有 `from` 时可用 |
| `direction` | 方向数组。**缺省是 -Z**（2D 用 +X）：有起点节点时取它的朝向，只给 `point` 时也是 -Z。要向下探测必须显式写 `[0, -1, 0]` |
| `length` | 射线长度，默认 10；`scan` 的每个方向探多远，默认 6 |
| `radius` | `near` 半径，默认 4；`scan` 的身体半宽，默认 0.35（**0 = 退回细射线**） |
| `spread` | `scan` 总扫描角度（度），默认 180 |
| `step` | `scan` 相邻方向夹角（度），默认 10；方向数 = `floor(spread/step)+1` |
| `need` | `scan` 判定“走得通”的最小距离，默认 = `length` |
| `height` | `scan`（3D）胶囊总高，默认 1.8，**底面贴 `offset` 点** |
| `up` | `scan`（3D）扫描平面法线，默认 `[0,1,0]` |
| `detail` | `scan` 为 `true` 时额外附逐条 `rays`（含 `point` / `normal`） |
| `mask` | 碰撞层过滤，默认全部 |
| `areas` | 是否把 Area 算进来：`ray` / `near` / `scan`（含 `radius: 0` 的细射线）三种都认这个字段 |
| `exclude` | 额外排除的节点路径数组 |

- 回执（ray）：`hit` / `collider` / `distance` / `point` / `normal` / `from` / `to`
- 回执（near）：`count` / `truncated` / `bodies[{path, class, distance, layer}]`
- 回执（scan）：见下一个小节
- **`near` 的 `distance` 是体块原点到起点的距离，不是表面距离**，所以会出现略大于 `radius` 的条目。
- 方向别依赖缺省值：很多项目"身体不转、相机转"，缺省的 -Z 会指错。

#### `scan`（体宽扇形扫描）

回答的不是"这条线上有没有东西"，而是**"我这个身体能往哪个方向走过去、能走多远"**。
角色有宽度：细射线擦着障碍边过会报"通"，正对着会报"挡"，两者都给不出"怎么绕"——`scan` 就是补这个。

- `radius > 0`：每个方向用 `cast_motion` 扫掠一个胶囊（3D）/ 圆（2D），"通畅"= 身体过得去；
- `radius : 0`：退化成细射线（每个方向一条 `ray`）。

```jsonc
{"as":"path","kind":"scan","from":"/root/Game/Player",
 "spread":180,"step":10,"length":4,"radius":0.35,"height":1.8,"need":1.5}
```

| 回执字段 | 含义 |
|---|---|
| `passable` | 有没有任何一条方向能走通（`distance >= need`） |
| `open_spans` | 可通行的角度区间，如 `[[-95,-85],[20,80]]` |
| `widest` | 最宽的那段：`from` / `to` / `span` / `mid` / `rays` |
| `steer` | 建议方向：`angle` / `distance` / `open` / `direction` / **`waypoint`（世界坐标）** |
| `forward` | 正前方（最接近 0° 的那条），永远存在 |
| `nearest` | 最近的受阻方向（没受阻则缺省） |
| `hits` | 所有受阻方向 `[{angle, distance, collider}]` |
| `blocked_span` | 被挡的总角度 |
| `stuck` / `stuck_with` | **身体是否已经和谁重叠**（`cast_motion` 会忽略起始重叠的形状，不查就会把"卡住"读成"通畅"） |
| `rays` | 仅 `detail: true`：逐条 `angle` / `distance` / `point` / `normal` |

- **角度约定**：`0` = 正前方，**正数向右**（俯视顺时针），负数向左；2D 里正数 = 屏幕顺时针。
- `steer` 永远存在：不通时给"最不坏"的方向（`steer.open: false`）。
- 典型用法：`queries/path/passable` 判断能不能过、`queries/path/widest/span` 判断缺口够不够宽、
  `queries/path/steer/waypoint` 直接拿去当目标点、`queries/path/stuck` 排除"已经卡住"。
- **2D 的单位是像素**：`length` / `radius` / `need` 都要按像素写（如 `length: 400`, `radius: 16`）。
- 扫描半径建议 **3~4 米**（2D 按像素折算）：角步长固定时远端横向间隔会变稀（`d·tan(step)`），
  长距离靠"走到 `steer.waypoint` 再扫一次"迭代。

#### `check`（断言）

```jsonc
{"at": 29, "check": [
   {"sample": "pose", "path": "moved/2", "op": "==", "value": 0},
   {"sample": "ui",   "path": "texts/HUD.HpLabel", "op": "contains", "value": "80"},
   {"sample": "props","path": ["/root/Game/Player", "hp"], "op": ">=", "value": 1}
]}
```

| `op` | 说明 |
|---|---|
| `==` / `!=` | 深比较；数值容差 0.001；int 与 float 混用可判等（JSON 会把数字变成 float） |
| `<` `<=` `>` `>=` | 仅数值 |
| `has` / `missing` | 路径存在 / 不存在（不需要 `value`） |
| `contains` | 数组含某元素，或字符串含子串 |

- `sample` 是观测键，`path` 是该观测内部的路径（字符串用 `/` 分隔，也可以是数组）。
- 每条断言都返回一行 `{kind:"check", pass, actual, expected, error}` 到 `results`。
- 断言只活在本步：跨步要重新写。

#### `replay`（回归对拍）

```jsonc
{"at": 0, "replay": {"id": "hp-drain", "mode": "record"}}
{"at": 0, "replay": {"id": "hp-drain", "mode": "compare"}}
{"at": 0, "replay": {"id": "hp-drain", "mode": "clear"}}
```

- `record` 把本步的样本与 plan 结果存成基线（`user://`，**跨游戏重启有效**）。
- `compare` 与基线逐项比对，回执给 `identical: true` 或差异列表。
- **一个 step 只能有一个 replay**；第二次会报错。`replay` 行本身不参与对拍。

---

## 4 `watch`：9 个观测

| 键 | 内容 | 关键字段 |
|---|---|---|
| `pose` | 玩家位姿与运动 | `player` `class` `pos` `yaw`（2D 是 `rot`）`camera{path,yaw,pitch,forward}` `velocity` `real_velocity` `on_floor` `on_wall` `on_ceiling` `hits` `wall_normal` `moved` `moved_frames` |
| `contacts` | 玩家/订阅目标正接触什么 | `player` `kind` `count` `blocked` `truncated` `items[]`，订阅目标在 `targets` 下。`count` 是去重后的真实数量，`items` 最多 8 条，超出时 `truncated: true` |
| `actors` | 场景内所有 CharacterBody | 数组，每项 `{name, path, pos, velocity, on_floor, on_wall}` |
| `props` | 订阅的属性 | 按订阅路径分组，键是属性名（支持子路径） |
| `events` | `listen` 记录到的信号 | 信号名 / 节点 / 帧号 / 参数 |
| `queries` | 各 `as` 标签的最新查询结果（粘住） | 与 `query` 回执同结构（`ray` / `near` / `scan`） |
| `errors` | 错误与脚本错误 | **自上次采样以来**（drain 语义，读一次就清空）。缓冲上限 500 行，满了丢**最旧**的一条（不会因为满而丢掉刚发生的错误）；被丢掉的条数目前不随采样返回 |
| `scene` | 场景状态 | `scene`（文件路径）`paused` `time_scale` |
| `ui` | 可见文本 / 矩形 / 可交互控件 | `texts{键:文本}` `rects{键:[x,y,w,h]}` `elements[{key,class,rect,screen,...}]` |

`ui` 的键格式是 **`屏根名.控件名`**（如 `MainMenu.SettingsButton`、`HUD.StartButton`），
**和 `click` / `type` 的 `key` 完全一致**。屏根 Control 自己也会出现，键是 `场景根名.屏名`
（如 `UIMenu.MainMenu`）；**隐藏屏的控件不在采样里**。

---

## 5 帧内时序（唯一容易搞错的地方）

```
apply_plan(N)      帧边界：上一帧末注入，决定第 N+1 帧做什么
   ↓ 第 N+1 帧：游戏节点 _physics_process / _process
_run_queries(N)    帧末：物理查询（结果按 as 粘住）
collect(watch)     帧末：采样
_run_checks(N)     帧末：断言（读得到本帧的 query 结果）
```

- `at: N` 的 `query` / `check` 与 `samples` 里的 `N` 看到的是**同一帧末**。
- `at: 0` 不是"游戏第一帧之前"，而是"**本步第一帧结束时**"。
- 采样默认只取最后一帧；要看过程就显式写 `samples: [0, 15, 29]`。

---

## 6 返回结构

```jsonc
{
  "unit": "physics",
  "frame_start": 3, "frame_end": 33,       // 本步前后的计数器（该单位）
  "dt": 0.0167,                            // idle 时另有 dt_max
  "results": [ ...plan 动作回执、query 结果、check 行... ],
  "samples": [ {"frame": 33, "pose": {...}} ],
  "replay": { ...仅在使用 replay 时... }
}
```

`results` 里可能出现的行类型：`kind` 为 `press/click/type/set/drag/hover/select/probe/listen/contact/query/check/replay/plan`。

---

## 7 状态生命周期

| 状态 | 生命周期 |
|---|---|
| `results` / `checks` / `queries`（本步登记的）/ `replay_request` | **每步清空** |
| `probe` 订阅、`listen` 订阅与记录、`contact` 订阅 | **跨步存活** |
| `query` 结果（按 `as`） | **跨步粘住**（第 30 帧的射线第 200 帧仍可断言） |
| 按住的输入 | step 结束 / 清理时松开 |

推论：`probe` / `listen` / `contact` 写一次就够，别每步重复写；要重置用各自的 `clear`。

---

## 8 常用配方

### 8.1 位移断言（确定性）

```jsonc
{"frames": 30, "unit": "physics", "plan": [
   {"at": 0,  "press": ["ui_up"]},
   {"at": 29, "check": [{"sample": "pose", "path": "moved/2", "op": ">", "value": 40}]}
]}
```

### 8.2 UI 全流程（读 → 点 → 打 → 断言）

```jsonc
{"frames": 12, "plan": [
   {"at": 0,  "click": ["MainMenu.SettingsButton"]},
   {"at": 3,  "select": {"key": "Settings.NameEdit", "all": true}},
   {"at": 4,  "type":   {"key": "Settings.NameEdit", "text": "Arthur",
						  "focus": false, "replace": false}},
   {"at": 6,  "set":    {"key": "Settings.VolumeSlider", "value": 87}},
   {"at": 7,  "check":  [{"sample": "ui", "path": "texts/Settings.NameEdit",
						  "op": "==", "value": "Arthur"}]},
   {"at": 9,  "click":  ["Settings.BackButton"]},
   {"at": 11, "check":  [{"sample": "ui", "path": "texts/MainMenu.Status",
						  "op": "==", "value": "SAVED"}]}
], "watch": ["ui"]}
```

- 第一条断言写在 Settings 屏**可见期间**；点回 Back 之后 Settings 屏变隐藏，
  就只能断言主菜单上的控件（本例是 `MainMenu.Status` 变成 `SAVED`）。
- 用 `select {all:true}` + `type {focus:false, replace:false}` 而不是依赖 `replace`：
  这条路径不靠快捷键，跨平台最确定。

### 8.3 回归对拍

```
第 1 次： {"frames": 60, "plan": [{"at":0,"replay":{"id":"walk","mode":"record"}}, ...], "watch":["pose","queries"]}
改代码 / 重启游戏
第 2 次： 同上，把 mode 改成 "compare"
```

### 8.4 走位 + 截图

见 `how_to_get_screenshot_of_runtime_game.md` 第 11 节（含侦察循环与 `query` 配方）。

---

## 9 失败与错误对照

分两类看：**游戏侧回执**（`results` 里的行，说明这一步做了什么、哪里没做成）和
**工具侧失败**（整次调用没拿到结果，只有一句 `Error: ...`）。

### 9.1 游戏侧回执（`results` 里的行）

| 回执 | 含义 |
|---|---|
| `{"error": "no such control on screen"}` | 控件键在当前屏不存在（键通常带屏名前缀，跨屏会撞不到） |
| `{"error": "op '<x>' needs a 'value'"}` | `check` 少了 `value` |
| `{"error": "unknown sample 'x' (supported: ...)"}` | `check.sample` 写了不存在的观测 |
| `{"error": "unknown op 'x' (supported: ...)"}` | `check.op` 拼错 |
| `{"error": "path not found"}` | 路径在该观测里取不到值（**常见于切屏后断言旧屏的控件**） |
| `{"bound": false, "error": "no such signal on ..."}` | `listen` 信号名错 |
| `{"kind": "plan", "dropped": true, "error": "...offset N never happens"}` | `at` 超出本步帧数，该动作从未执行 |
| `{"kind": "plan", "clamped": true, "error": "a step runs between 1 and 600 frames: ..."}` | `frames` 超出 1~600，实际按上限执行 |
| `{"kind": "plan", "dropped": true, "sample": N, "error": "...sample offset N never happens"}` | `samples` 里的偏移超出本步帧数，该次采样不会发生 |
| `{"error": "...; one replay per step"}` | 一个 step 写了两次 `replay` |

### 9.2 工具侧失败（没有结果，只有 `Error: ...`）

| 回执 | 含义 |
|---|---|
| `Error: no running game has an AiDebugProbe node. Launch one with ai_debug_launch.` | 游戏不是 `ai_debug_launch` 起的，或已经结束 |
| `Error: the AI Debug Probe channel is not registered. ...` | 插件侧通道没注册（`godot_ai_chat` 未启用 / 探针模块缺失） |
| `Error: this game's probe build does not support: ...` | 请求里有该 build 不认识的 plan/watch 键；回执同时列出它支持的键与探针版本 |
| `Error: no reply from the game within X s. ...` | 发出去了，游戏在 `timeout` 内没走完这一帧（原因见 9.3）。回执会同时提示：长步进可能只是还没跑完，可以加大 `timeout` 再来一次 |
| `Error: the game's probe has not finished starting (no capability handshake yet). ...` | 会话已建立但还没收到 hello（游戏仍在启动）。等一下就重试，不要当成版本不匹配 |
| `Error: no reply: the probe session is gone ...` | 等待期间调试会话没了（游戏被停 / 调试器断开），重新 `ai_debug_launch` |
| `Error: a step is already running` | 上一步还没结束（游戏侧原话，工具原样转出）；多半就是 9.3 那种情况 |
| `Error: the step stopped advancing: ...` | 游戏侧 watchdog 判定这一帧卡住了（如采样代码里出错） |

### 9.3 「游戏卡在脚本错误」——最常见的"探针没反应"

后三类失败会自动带上这段提示：

> Likely cause: the game is paused on a script error. A GDScript runtime error hands control to the
> debugger (debug_break); with "Ignore Error Breaks" off, the game's main thread stays blocked in
> that break, so the probe cannot finish a frame and later requests answer "a step is already running".

含义与处理：

- GDScript 的运行时错误会让引擎把控制权交给调试器（`debug_break`）。编辑器 Debugger 面板的
  **「Ignore Error Breaks」（铃铛）没开**时，游戏主线程就停在那次中断里——探针**一帧都走不动**，
  但调试器通道还活着，所以后面的请求会一直回 `a step is already running`。
- 先 `read_errors` 看这次运行有没有新的脚本错误，修掉它；或者把铃铛打开。
- **然后重新 `ai_debug_launch`**：卡住的会话通常不会自己恢复。
- 只有 debug 运行会这样；导出版本 / 没挂调试器时错误只打印，不会冻结。

---

## 10 已知坑（12 条）

1. **`velocity` 不可信**：`move_and_slide()` 会就地把撞墙后的速度改成 0，和"没有输入"无法区分。
   判断"有没有在走"只看 `pose.moved`。
2. **`moved` 的两套计数器不可相减**：切 `unit` 会重置参考点，跨单位算是无意义的。
3. **`errors` 是 drain 语义**：watch 一次就把缓冲清空。多帧都要看错误，就把 `errors` 放在最后采样。
4. **物理步进 ≠ 一次 `_process`**：`_process` 驱动的逻辑用 `unit: "idle"`。
5. **`check` 会额外触发一次 collect**：带状态的观测（`moved`）已做同帧复用，但你自己写的观测要注意。
6. **控件键不跨屏**：隐藏屏上的控件报 `no such control on screen`，先 `watch: ["ui"]` 看当前屏有哪些键。
7. **`Timer` 在暂停期间不走**：过场/加载类逻辑要按"未暂停帧数"预算。
8. **`areas` 默认是关的**：`PhysicsRayQueryParameters*.create()` 把 `collide_with_areas` 设为 `false`，
   所以不写 `"areas": true` 时射线和 `near` 都不会报告 Area。探针现在对 `ray` / `near` / 细射线 `scan`
   统一读这个字段。
9. **导入关卡的 trimesh 射线是单向的**：从地板下往上打会 miss。
10. **玩家原点可能在脚底**：向下射线要带正偏移（如 `offset: [0, 0.05, 0]`）。
11. **切屏后旧屏的控件读不到**：`texts/旧屏.控件` 会 `path not found`，点击会 `no such control on screen`。
	断言要写在该屏可见的帧偏移上。
12. **`type` 的 `replace` 依赖平台主修饰键**（Ctrl+A / Cmd+A）：需要最确定的覆盖时，
	改用 `select {"all": true}` + `type {"focus": false, "replace": false}`。
13. **游戏侧脚本错误会让整局卡死，探针也跟着失联**：GDScript 运行时错误会触发 `debug_break`，
	而编辑器「Ignore Error Breaks」没开时主线程就停在那里——step 永远不结束、后续请求一直回
	`a step is already running`（详见 9.3）。同样的错误在无调试器运行时只打印、不冻结，
	所以"本地好好的、接了探针就卡"多半是这一条。
14. **`scan` 的 `stuck` 不是装饰**：`cast_motion` 会忽略"起点就重叠"的形状，所以角色已经卡进
	障碍时所有方向都会报"通畅"。判断"撞住了/路不通/角度不对"要看 `stuck`、`passable`、
	`widest` 三个一起，只看 `forward.distance` 必然误判。
15. **2D 场景里所有长度都是像素**：`scan` 的 `length` / `radius` / `need`、`near` 的 `radius`
	都按像素写，别照搬 3D 的"米"。

---

## 11 什么时候不要用它

| 事情 | 更好的选择 |
|---|---|
| 手感、节奏、视效、音频、构图 | 真人 |
| "好不好玩" | 真人 |
| 只看一眼画面长什么样 | `how_to_get_screenshot_of_runtime_game.md` |
| 编辑器里静止场景的渲染细节 | `capture_viewport_screenshot` |

探针擅长的是「给定断言 → 构造帧脚本 → 验证 → 报告证据」。
**不要**拿它"随便玩找 bug"：逐帧模型下没有直觉，只能穷举。
