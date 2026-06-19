# manage_input_map 工具使用指南

## 参数说明

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `operation` | string | **是** | 操作类型：`add` / `remove` / `list` |
| `action_name` | string | remove 时**是**，add 时可选 | 动作名称，如 `"move_forward"` |
| `events` | array[string] | 否 | 绑定的事件列表（见下方事件格式） |
| `deadzone` | number | 否 | 摇杆/扳机的死区值，默认 0.5 |

---

## 事件格式

### 键盘按键
- `KEY_A` ~ `KEY_Z` — 字母键
- `KEY_0` ~ `KEY_9` — 数字键
- `KEY_SPACE`, `KEY_ENTER`, `KEY_ESCAPE`, `KEY_TAB`
- `KEY_UP`, `KEY_DOWN`, `KEY_LEFT`, `KEY_RIGHT`
- `KEY_SHIFT`, `KEY_CTRL`, `KEY_ALT`, `KEY_META`

### 组合键
使用 `+` 连接修饰键和主键：
- `KEY_CTRL+KEY_S` — Ctrl + S
- `KEY_SHIFT+KEY_A` — Shift + A
- `KEY_CTRL+KEY_SHIFT+KEY_Z` — Ctrl + Shift + Z

### 鼠标按键
- `MOUSE_BUTTON_LEFT`
- `MOUSE_BUTTON_RIGHT`
- `MOUSE_BUTTON_MIDDLE`
- `MOUSE_BUTTON_WHEEL_UP` / `MOUSE_BUTTON_WHEEL_DOWN`

### 手柄按键
- `JOY_BUTTON_A`, `JOY_BUTTON_B`, `JOY_BUTTON_X`, `JOY_BUTTON_Y`
- `JOY_BUTTON_START`, `JOY_BUTTON_BACK`
- `JOY_BUTTON_DPAD_UP`, `JOY_BUTTON_DPAD_DOWN`, `JOY_BUTTON_DPAD_LEFT`, `JOY_BUTTON_DPAD_RIGHT`
- `JOY_BUTTON_LEFT_SHOULDER`, `JOY_BUTTON_RIGHT_SHOULDER`

### 手柄摇杆/扳机
- `JOY_AXIS_LEFT_X`, `JOY_AXIS_LEFT_Y`
- `JOY_AXIS_RIGHT_X`, `JOY_AXIS_RIGHT_Y`
- `JOY_AXIS_TRIGGER_LEFT`, `JOY_AXIS_TRIGGER_RIGHT`
- 正方向加 `+` 后缀，负方向加 `-` 后缀，如 `JOY_AXIS_LEFT_X+`、`JOY_AXIS_LEFT_Y-`

---

## 各操作完整示例

### 1. add — 新建动作

```json
{
  "operation": "add",
  "action_name": "move_left",
  "events": ["KEY_A"]
}
```

同时添加多个事件：

```json
{
  "operation": "add",
  "action_name": "jump",
  "events": ["KEY_SPACE", "JOY_BUTTON_A"]
}
```

组合键：

```json
{
  "operation": "add",
  "action_name": "save",
  "events": ["KEY_CTRL+KEY_S"]
}
```

不指定 `action_name` 时自动生成：

```json
{
  "operation": "add",
  "events": ["KEY_W"]
}
```

### 2. remove — 删除动作

```json
{
  "operation": "remove",
  "action_name": "move_left"
}
```

如需删除多个动作，请多次调用 `manage_input_map`：

```json
// 调用 1
{ "operation": "remove", "action_name": "move_left" }

// 调用 2（并行）
{ "operation": "remove", "action_name": "move_right" }
```

### 3. list — 列出所有动作

```json
{
  "operation": "list"
}
```

---

## 修改已有动作

`manage_input_map` 不提供直接修改操作。如需修改，请组合使用 `remove` + `add`：

1. 先删除旧动作：`{"operation": "remove", "action_name": "move_left"}`
2. 再新建动作：`{"operation": "add", "action_name": "move_left", "events": ["KEY_A"]}`

---

## 常见错误

| 错误信息 | 原因 | 解决方法 |
|---------|------|---------|
| `Action 'xxx' already exists. Use 'list' to see existing actions.` | add 时动作已存在 | 先用 `list` 查看，再决定是否使用 `remove` 删除后重新 `add` |
| `Action not found: xxx. Use 'list' to see existing actions.` | remove 时指定的动作不存在 | 先用 `list` 查看现有动作名 |
| `Missing required parameter: action_name` | remove 时未提供动作名 | 加上 `"action_name": "..."` |
| `Failed to parse: W` | 事件格式错误，应使用 Godot API 常量名 | 改为 `"KEY_W"` |
| `Unknown event format: ...` | 事件字符串不符合任何已知格式 | 检查是否使用了正确的前缀（`KEY_`、`MOUSE_BUTTON_`、`JOY_BUTTON_`、`JOY_AXIS_`） |
