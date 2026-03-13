@tool
extends AiTool

## 管理项目输入映射 的工具
## 支持增删改查操作，使用 Godot API 原生常量: KEY_W, MOUSE_BUTTON_LEFT, JOY_BUTTON_A 等


const USER_HINT: String = "\n[Notice] Changes saved. If not visible in 'Project Settings' UI, restart the editor."


func _init() -> void:
	tool_name = "manage_input_map"
	tool_description = "Manage InputMap actions using Godot API constants."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"operation": {
				"type": "string",
				"enum": ["add", "update", "remove", "list", "clear"],
				"description": "Operation type: add/update/remove/list/clear"
			},
			"actions": {
				"type": "array",
				"items": {
					"type": "object",
					"properties": {
						"name": { "type": "string", "description": "Action name (e.g. 'move_forward')" },
						"events": {
							"type": "array",
							"items": { "type": "string" },
							"description": "Event strings: 'KEY_W', 'KEY_CTRL+KEY_S', 'MOUSE_BUTTON_LEFT', 'JOY_BUTTON_A', 'JOY_AXIS_LEFT_X' "
						},
						"clear_existing": { "type": "boolean", "description": "Clear existing events (default: true for add, false for update)" }
					},
					"required": ["name"]
				},
				"description": "Actions to process (not needed for 'list' operation)"
			},
			"deadzone": { "type": "number", "minimum": 0.0, "maximum": 1.0, "description": "Deadzone value (default: 0.5)" },
			"action_name": { "type": "string", "description": "Single action name for 'remove' or 'list' single action" }
		},
		"required": ["operation"]
	}


func execute(p_args: Dictionary) -> Dictionary:
	var operation: String = p_args.get("operation", "")
	if operation.is_empty():
		return {"success": false, "data": "Missing required parameter: operation"}
	
	match operation:
		"add", "update": return _execute_add_update(p_args)
		"remove": return _execute_remove(p_args)
		"list": return _execute_list(p_args)
		"clear": return _execute_clear(p_args)
		_: return {"success": false, "data": "Unknown operation: %s" % operation}


func _execute_add_update(p_args: Dictionary) -> Dictionary:
	var actions: Array = p_args.get("actions", [])
	var deadzone: float = p_args.get("deadzone", 0.5)
	var is_update: bool = p_args.get("operation") == "update"
	
	if actions.is_empty():
		return {"success": false, "data": "No actions provided."}
	
	var log_lines: Array = []
	var changed: bool = false
	
	for action_data in actions:
		var action_name: String = action_data.get("name", "")
		if action_name.is_empty():
			log_lines.append("! Skipped: Empty action name")
			continue
		
		var events_list: Array = action_data.get("events", [])
		var clear: bool = action_data.get("clear_existing", not is_update)
		
		var result = _add_or_update_action(action_name, events_list, clear, deadzone)
		log_lines.append(result.log)
		changed = result.changed or changed
	
	if changed:
		if ProjectSettings.save() != OK:
			return {"success": false, "data": "Failed to save ProjectSettings"}
		return {"success": true, "data": "\n".join(log_lines) + USER_HINT}
	return {"success": true, "data": "No changes made.\n" + "\n".join(log_lines)}


func _execute_remove(p_args: Dictionary) -> Dictionary:
	var names: Array = []
	if p_args.has("action_name") and not p_args.action_name.is_empty():
		names.append(p_args.action_name)
	for data in p_args.get("actions", []):
		if data.has("name") and not data.name.is_empty() and not names.has(data.name):
			names.append(data.name)
	
	if names.is_empty():
		return {"success": false, "data": "No action name specified for removal."}
	
	var log_lines: Array = []
	for name in names:
		var path = "input/" + name
		if ProjectSettings.has_setting(path):
			ProjectSettings.clear(path)
			log_lines.append("Removed from ProjectSettings: %s" % name)
		else:
			log_lines.append("! Not found in ProjectSettings: %s" % name)
		
		if InputMap.has_action(name):
			InputMap.erase_action(name)
			log_lines.append("Removed from InputMap: %s" % name)
		else:
			log_lines.append("! Not found in InputMap: %s" % name)
	
	if ProjectSettings.save() != OK:
		return {"success": false, "data": "Failed to save ProjectSettings"}
	return {"success": true, "data": "\n".join(log_lines) + USER_HINT}


func _execute_list(p_args: Dictionary) -> Dictionary:
	var action_name: String = p_args.get("action_name", "")
	if not action_name.is_empty():
		return _list_single_action(action_name)
	return _list_all_actions()


func _execute_clear(p_args: Dictionary) -> Dictionary:
	var action_name: String = p_args.get("action_name", "")
	if action_name.is_empty():
		return {"success": false, "data": "No action_name specified."}
	
	var path = "input/" + action_name
	if not ProjectSettings.has_setting(path):
		return {"success": false, "data": "Action not found: %s" % action_name}
	
	var dict: Dictionary = ProjectSettings.get_setting(path)
	var count: int = dict.get("events", []).size()
	dict["events"] = []
	ProjectSettings.set_setting(path, dict)
	
	if InputMap.has_action(action_name):
		InputMap.action_erase_events(action_name)
	
	if ProjectSettings.save() != OK:
		return {"success": false, "data": "Failed to save ProjectSettings"}
	
	return {"success": true, "data": "Cleared %d events for action: %s%s" % [count, action_name, USER_HINT]}


func _list_single_action(action_name: String) -> Dictionary:
	var path = "input/" + action_name
	if not ProjectSettings.has_setting(path):
		return {"success": false, "data": "Action not found: %s" % action_name}
	
	var dict: Dictionary = ProjectSettings.get_setting(path)
	var result: String = "Action: %s\n  Deadzone: %s\n  Events:\n" % [action_name, dict.get("deadzone", 0.5)]
	
	var events: Array = dict.get("events", [])
	if events.is_empty():
		result += "    (none)"
	else:
		for ev in events:
			result += "    - %s\n" % _event_to_string(ev)
	
	return {"success": true, "data": result}


func _list_all_actions() -> Dictionary:
	var actions: Array = []
	for prop in ProjectSettings.get_property_list():
		if prop.name.begins_with("input/") and not prop.name.substr(6).begins_with("ui_"):
			actions.append(prop.name.substr(6))
	
	if actions.is_empty():
		return {"success": true, "data": "No InputMap actions found."}
	
	var result: String = "Found %d action(s):\n" % actions.size()
	for name in actions:
		var dict: Dictionary = ProjectSettings.get_setting("input/" + name)
		var events: Array = dict.get("events", [])
		result += "  - %s (deadzone: %.2f)\n" % [name, dict.get("deadzone", 0.5)]
		for ev in events:
			result += "      → %s\n" % _event_to_string(ev)
	
	return {"success": true, "data": result}


func _add_or_update_action(action_name: String, events_list: Array, clear: bool, deadzone: float) -> Dictionary:
	var log_str: String = ""
	var changed: bool = false
	var path = "input/" + action_name
	var dict: Dictionary
	
	if ProjectSettings.has_setting(path):
		dict = ProjectSettings.get_setting(path)
		log_str += "Updated Action: %s\n" % action_name
	else:
		dict = {"deadzone": deadzone, "events": []}
		ProjectSettings.set_setting(path, dict)
		log_str += "Added Action: %s\n" % action_name
		changed = true
	
	if dict.get("deadzone", 0.5) != deadzone:
		dict["deadzone"] = deadzone
		changed = true
	
	if not dict.has("events"):
		dict["events"] = []
	
	if clear and not dict["events"].is_empty():
		dict["events"].clear()
		changed = true
	
	if not InputMap.has_action(action_name):
		InputMap.add_action(action_name, deadzone)
		changed = true
	elif clear:
		InputMap.action_erase_events(action_name)
	
	for event_str in events_list:
		var ev: InputEvent = _parse_event_string(event_str)
		if ev:
			dict["events"].append(ev)
			InputMap.action_add_event(action_name, ev)
			log_str += "  + Bound: %s -> %s\n" % [action_name, event_str]
			changed = true
		else:
			log_str += "  ! Failed to parse: %s\n" % event_str
	
	ProjectSettings.set_setting(path, dict)
	return {"log": log_str, "changed": changed}


# ==================== 核心：解析 Godot API 常量事件 ====================

func _parse_event_string(event_str: String) -> InputEvent:
	event_str = event_str.strip_edges().to_upper()
	if event_str.is_empty():
		return null
	
	# 组合键
	if "+" in event_str:
		return _parse_key_combination(event_str)
	
	# 单键 - 使用 OS.find_keycode_from_string 解析 KEY_* 常量
	if event_str.begins_with("KEY_"):
		var code = _get_keycode_from_constant(event_str)
		return _create_key_event(code) if code != KEY_NONE else null
	
	if event_str.begins_with("MOUSE_BUTTON_"):
		var idx = _get_mouse_button_from_constant(event_str)
		return _create_mouse_event(idx) if idx >= 0 else null
	
	if event_str.begins_with("JOY_BUTTON_"):
		var idx = _get_joy_button_from_constant(event_str)
		return _create_joy_button_event(idx) if idx >= 0 else null
	
	if event_str.begins_with("JOY_AXIS_"):
		return _parse_joy_axis(event_str)
	
	push_warning("Unknown event format: %s" % event_str)
	return null


func _parse_key_combination(event_str: String) -> InputEventKey:
	var parts = event_str.split("+")
	var main_key = parts[-1].strip_edges()
	var code = _get_keycode_from_constant(main_key)
	
	if code == KEY_NONE:
		push_warning("Invalid key constant: %s" % main_key)
		return null
	
	var ev = InputEventKey.new()
	ev.keycode = code
	ev.physical_keycode = code
	
	# 处理修饰键
	for i in range(parts.size() - 1):
		match parts[i].strip_edges():
			"KEY_CTRL", "KEY_CONTROL": ev.ctrl_pressed = true
			"KEY_SHIFT": ev.shift_pressed = true
			"KEY_ALT": ev.alt_pressed = true
			"KEY_META", "KEY_CMD", "KEY_COMMAND": ev.meta_pressed = true
	
	return ev


func _parse_joy_axis(event_str: String) -> InputEventJoypadMotion:
	var axis_str = event_str
	var value = 1.0
	
	if axis_str.ends_with("-"):
		value = -1.0
		axis_str = axis_str.trim_suffix("-")
	elif axis_str.ends_with("+"):
		axis_str = axis_str.trim_suffix("+")
	
	var axis = _get_joy_axis_from_constant(axis_str)
	if axis < 0:
		push_warning("Invalid joy axis constant: %s" % event_str)
		return null
	
	var ev = InputEventJoypadMotion.new()
	ev.axis = axis
	ev.axis_value = value
	return ev


## 使用 OS.find_keycode_from_string 解析 KEY_* 常量
func _get_keycode_from_constant(const_name: String) -> int:
	# 去除 KEY_ 前缀
	var key_name = const_name.substr(4) if const_name.begins_with("KEY_") else const_name
	
	# 使用 Godot API 查找 keycode
	var code = OS.find_keycode_from_string(key_name)
	if code != KEY_NONE:
		return code
	
	# 特殊处理一些常用别名（OS.find_keycode_from_string 可能无法识别的）
	match key_name:
		"CTRL": return KEY_CTRL
		"CONTROL": return KEY_CTRL
		"META": return KEY_META
		"CMD": return KEY_META
		"COMMAND": return KEY_META
		"ESC": return KEY_ESCAPE
		"UP": return KEY_UP
		"DOWN": return KEY_DOWN
		"LEFT": return KEY_LEFT
		"RIGHT": return KEY_RIGHT
		"ENTER": return KEY_ENTER
		"RET", "RETURN": return KEY_ENTER
		"SPACE": return KEY_SPACE
		"TAB": return KEY_TAB
		"SHIFT": return KEY_SHIFT
		"ALT": return KEY_ALT
		"CAPS": return KEY_CAPSLOCK
		"CAPSLOCK": return KEY_CAPSLOCK
		"NUM": return KEY_NUMLOCK
		"NUMLOCK": return KEY_NUMLOCK
		"SCROLL": return KEY_SCROLLLOCK
		"SCROLLLOCK": return KEY_SCROLLLOCK
		"INS": return KEY_INSERT
		"DEL": return KEY_DELETE
		"PGUP", "PAGEUP": return KEY_PAGEUP
		"PGDN", "PAGEDOWN": return KEY_PAGEDOWN
		"HOME": return KEY_HOME
		"END": return KEY_END
	
	return KEY_NONE


## 鼠标按钮常量映射（数量少，直接映射）
func _get_mouse_button_from_constant(const_name: String) -> int:
	match const_name:
		"MOUSE_BUTTON_NONE": return MOUSE_BUTTON_NONE
		"MOUSE_BUTTON_LEFT": return MOUSE_BUTTON_LEFT
		"MOUSE_BUTTON_RIGHT": return MOUSE_BUTTON_RIGHT
		"MOUSE_BUTTON_MIDDLE": return MOUSE_BUTTON_MIDDLE
		"MOUSE_BUTTON_WHEEL_UP": return MOUSE_BUTTON_WHEEL_UP
		"MOUSE_BUTTON_WHEEL_DOWN": return MOUSE_BUTTON_WHEEL_DOWN
		"MOUSE_BUTTON_WHEEL_LEFT": return MOUSE_BUTTON_WHEEL_LEFT
		"MOUSE_BUTTON_WHEEL_RIGHT": return MOUSE_BUTTON_WHEEL_RIGHT
		"MOUSE_BUTTON_XBUTTON1": return MOUSE_BUTTON_XBUTTON1
		"MOUSE_BUTTON_XBUTTON2": return MOUSE_BUTTON_XBUTTON2
		_:
			# 尝试解析纯数字
			if const_name.is_valid_int():
				return const_name.to_int()
			return -1


## 手柄按钮常量映射（数量少，直接映射）
func _get_joy_button_from_constant(const_name: String) -> int:
	match const_name:
		"JOY_BUTTON_INVALID": return JOY_BUTTON_INVALID
		"JOY_BUTTON_A": return JOY_BUTTON_A
		"JOY_BUTTON_B": return JOY_BUTTON_B
		"JOY_BUTTON_X": return JOY_BUTTON_X
		"JOY_BUTTON_Y": return JOY_BUTTON_Y
		"JOY_BUTTON_BACK": return JOY_BUTTON_BACK
		"JOY_BUTTON_GUIDE": return JOY_BUTTON_GUIDE
		"JOY_BUTTON_START": return JOY_BUTTON_START
		"JOY_BUTTON_LEFT_STICK": return JOY_BUTTON_LEFT_STICK
		"JOY_BUTTON_RIGHT_STICK": return JOY_BUTTON_RIGHT_STICK
		"JOY_BUTTON_LEFT_SHOULDER": return JOY_BUTTON_LEFT_SHOULDER
		"JOY_BUTTON_RIGHT_SHOULDER": return JOY_BUTTON_RIGHT_SHOULDER
		"JOY_BUTTON_DPAD_UP": return JOY_BUTTON_DPAD_UP
		"JOY_BUTTON_DPAD_DOWN": return JOY_BUTTON_DPAD_DOWN
		"JOY_BUTTON_DPAD_LEFT": return JOY_BUTTON_DPAD_LEFT
		"JOY_BUTTON_DPAD_RIGHT": return JOY_BUTTON_DPAD_RIGHT
		"JOY_BUTTON_MISC1": return JOY_BUTTON_MISC1
		"JOY_BUTTON_PADDLE1": return JOY_BUTTON_PADDLE1
		"JOY_BUTTON_PADDLE2": return JOY_BUTTON_PADDLE2
		"JOY_BUTTON_PADDLE3": return JOY_BUTTON_PADDLE3
		"JOY_BUTTON_PADDLE4": return JOY_BUTTON_PADDLE4
		"JOY_BUTTON_TOUCHPAD": return JOY_BUTTON_TOUCHPAD
		_:
			# 尝试解析纯数字
			if const_name.is_valid_int():
				return const_name.to_int()
			return -1


## 手柄轴常量映射（数量少，直接映射）
func _get_joy_axis_from_constant(const_name: String) -> int:
	match const_name:
		"JOY_AXIS_INVALID": return JOY_AXIS_INVALID
		"JOY_AXIS_LEFT_X": return JOY_AXIS_LEFT_X
		"JOY_AXIS_LEFT_Y": return JOY_AXIS_LEFT_Y
		"JOY_AXIS_RIGHT_X": return JOY_AXIS_RIGHT_X
		"JOY_AXIS_RIGHT_Y": return JOY_AXIS_RIGHT_Y
		"JOY_AXIS_TRIGGER_LEFT": return JOY_AXIS_TRIGGER_LEFT
		"JOY_AXIS_TRIGGER_RIGHT": return JOY_AXIS_TRIGGER_RIGHT
		"JOY_AXIS_SDL_MAX": return JOY_AXIS_SDL_MAX
		"JOY_AXIS_MAX": return JOY_AXIS_MAX
		_:
			# 尝试解析纯数字
			if const_name.is_valid_int():
				return const_name.to_int()
			return -1


func _create_key_event(code: int) -> InputEventKey:
	var ev = InputEventKey.new()
	ev.keycode = code
	ev.physical_keycode = code
	return ev


func _create_mouse_event(idx: int) -> InputEventMouseButton:
	var ev = InputEventMouseButton.new()
	ev.button_index = idx
	return ev


func _create_joy_button_event(idx: int) -> InputEventJoypadButton:
	var ev = InputEventJoypadButton.new()
	ev.button_index = idx
	return ev


func _event_to_string(event: InputEvent) -> String:
	if event is InputEventKey:
		var mods = ""
		if event.ctrl_pressed: mods += "KEY_CTRL+"
		if event.shift_pressed: mods += "KEY_SHIFT+"
		if event.alt_pressed: mods += "KEY_ALT+"
		if event.meta_pressed: mods += "KEY_META+"
		return mods + "KEY_" + OS.get_keycode_string(event.keycode)
	
	elif event is InputEventMouseButton:
		match event.button_index:
			MOUSE_BUTTON_LEFT: return "MOUSE_BUTTON_LEFT"
			MOUSE_BUTTON_RIGHT: return "MOUSE_BUTTON_RIGHT"
			MOUSE_BUTTON_MIDDLE: return "MOUSE_BUTTON_MIDDLE"
			MOUSE_BUTTON_WHEEL_UP: return "MOUSE_BUTTON_WHEEL_UP"
			MOUSE_BUTTON_WHEEL_DOWN: return "MOUSE_BUTTON_WHEEL_DOWN"
			MOUSE_BUTTON_WHEEL_LEFT: return "MOUSE_BUTTON_WHEEL_LEFT"
			MOUSE_BUTTON_WHEEL_RIGHT: return "MOUSE_BUTTON_WHEEL_RIGHT"
			MOUSE_BUTTON_XBUTTON1: return "MOUSE_BUTTON_XBUTTON1"
			MOUSE_BUTTON_XBUTTON2: return "MOUSE_BUTTON_XBUTTON2"
			_: return "MOUSE_BUTTON_" + str(event.button_index)
	
	elif event is InputEventJoypadButton:
		match event.button_index:
			JOY_BUTTON_A: return "JOY_BUTTON_A"
			JOY_BUTTON_B: return "JOY_BUTTON_B"
			JOY_BUTTON_X: return "JOY_BUTTON_X"
			JOY_BUTTON_Y: return "JOY_BUTTON_Y"
			JOY_BUTTON_BACK: return "JOY_BUTTON_BACK"
			JOY_BUTTON_GUIDE: return "JOY_BUTTON_GUIDE"
			JOY_BUTTON_START: return "JOY_BUTTON_START"
			JOY_BUTTON_LEFT_STICK: return "JOY_BUTTON_LEFT_STICK"
			JOY_BUTTON_RIGHT_STICK: return "JOY_BUTTON_RIGHT_STICK"
			JOY_BUTTON_LEFT_SHOULDER: return "JOY_BUTTON_LEFT_SHOULDER"
			JOY_BUTTON_RIGHT_SHOULDER: return "JOY_BUTTON_RIGHT_SHOULDER"
			JOY_BUTTON_DPAD_UP: return "JOY_BUTTON_DPAD_UP"
			JOY_BUTTON_DPAD_DOWN: return "JOY_BUTTON_DPAD_DOWN"
			JOY_BUTTON_DPAD_LEFT: return "JOY_BUTTON_DPAD_LEFT"
			JOY_BUTTON_DPAD_RIGHT: return "JOY_BUTTON_DPAD_RIGHT"
			_: return "JOY_BUTTON_" + str(event.button_index)
	
	elif event is InputEventJoypadMotion:
		var axis_name: String
		match event.axis:
			JOY_AXIS_LEFT_X: axis_name = "JOY_AXIS_LEFT_X"
			JOY_AXIS_LEFT_Y: axis_name = "JOY_AXIS_LEFT_Y"
			JOY_AXIS_RIGHT_X: axis_name = "JOY_AXIS_RIGHT_X"
			JOY_AXIS_RIGHT_Y: axis_name = "JOY_AXIS_RIGHT_Y"
			JOY_AXIS_TRIGGER_LEFT: axis_name = "JOY_AXIS_TRIGGER_LEFT"
			JOY_AXIS_TRIGGER_RIGHT: axis_name = "JOY_AXIS_TRIGGER_RIGHT"
			_: axis_name = "JOY_AXIS_" + str(event.axis)
		return axis_name + ("+" if event.axis_value >= 0 else "-")
	
	return "Unknown"
