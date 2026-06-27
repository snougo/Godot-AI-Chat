@tool
extends AiTool

## 管理项目输入映射的工具。
## 支持三种操作：add（新建动作）、remove（删除动作）、list（列出全部动作）。


const USER_HINT: String = "\n[Notice] Changes saved. If not visible in 'Project Settings' UI, restart the editor."


func _init() -> void:
	tool_name = "manage_input_map"
	tool_description = "Manages InputMap actions. Supports: add (create new), remove (delete), list (show all)."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"operation": {
				"type": "string",
				"enum": ["add", "remove", "list"],
				"description": "Operation type: add (create new action with events), remove (delete an action), list (show all actions)."
			},
			"action_name": {
				"type": "string",
				"description": "Action name (e.g. 'move_forward'). Required for remove. Optional for add (auto-generated if empty). Ignored for list."
			},
			"events": {
				"type": "array",
				"items": { "type": "string" },
				"description": "Event bindings. Use Godot API constants: 'KEY_W', 'KEY_CTRL+KEY_S', etc."
			},
			"deadzone": {
				"type": "number",
				"minimum": 0.0,
				"maximum": 1.0,
				"description": "Deadzone value for analog inputs (default: 0.5)."
			}
		},
		"required": ["operation"]
	}


func execute(p_args: Dictionary) -> Dictionary:
	var operation: String = p_args.get("operation", "")
	if operation.is_empty():
		return {"success": false, "data": "Missing required parameter: operation"}
	
	match operation:
		"add":
			return _execute_add(p_args)
		"remove":
			return _execute_remove(p_args)
		"list":
			return _execute_list()
		_:
			return {"success": false, "data": "Unknown operation: %s" % operation}


# ==================== ADD ====================

func _execute_add(p_args: Dictionary) -> Dictionary:
	var action_name: String = p_args.get("action_name", "").strip_edges()
	var events_list: Array = p_args.get("events", [])
	var deadzone: float = p_args.get("deadzone", 0.5)
	
	if action_name.is_empty():
		action_name = "new_action_%d" % Time.get_ticks_msec()
	
	var path = "input/" + action_name
	if ProjectSettings.has_setting(path):
		return {
			"success": false,
			"data": "Action '%s' already exists. Use 'list' to see existing actions." % action_name
		}
	
	# 新建 ProjectSettings 条目
	var dict: Dictionary = {"deadzone": deadzone, "events": []}
	ProjectSettings.set_setting(path, dict)
	
	# 新建 InputMap 条目
	InputMap.add_action(action_name, deadzone)
	
	# 绑定事件
	var bound: int = 0
	for event_str in events_list:
		var ev: InputEvent = _parse_event_string(event_str)
		if ev:
			dict["events"].append(ev)
			InputMap.action_add_event(action_name, ev)
			bound += 1
	
	ProjectSettings.set_setting(path, dict)
	
	if ProjectSettings.save() != OK:
		return {"success": false, "data": "Failed to save ProjectSettings"}
	
	if bound > 0:
		return {"success": true, "data": "Created action '%s' with %d event(s)." % [action_name, bound]}
	return {"success": true, "data": "Created action '%s' (no events)." % action_name}


# ==================== REMOVE ====================

func _execute_remove(p_args: Dictionary) -> Dictionary:
	var action_name: String = p_args.get("action_name", "").strip_edges()
	if action_name.is_empty():
		return {"success": false, "data": "Missing required parameter: action_name"}
	
	var path = "input/" + action_name
	
	if not ProjectSettings.has_setting(path) and not InputMap.has_action(action_name):
		return {"success": false, "data": "Action not found: %s. Use 'list' to see existing actions." % action_name}
	
	if ProjectSettings.has_setting(path):
		ProjectSettings.clear(path)
	
	if InputMap.has_action(action_name):
		InputMap.erase_action(action_name)
	
	if ProjectSettings.save() != OK:
		return {"success": false, "data": "Action removed from InputMap but failed to save ProjectSettings."}
	
	return {"success": true, "data": "Removed action: %s" % action_name}


# ==================== LIST ====================

func _execute_list() -> Dictionary:
	var action_paths: Array[String] = []
	for prop in ProjectSettings.get_property_list():
		if prop.name.begins_with("input/") and not prop.name.substr(6).begins_with("ui_"):
			action_paths.append(prop.name)
	
	if action_paths.is_empty():
		return {"success": true, "data": "No InputMap actions found."}
	
	var result: String = "Found %d action(s):\n" % action_paths.size()
	for path in action_paths:
		var name: String = path.substr(6)
		var dict: Dictionary = ProjectSettings.get_setting(path)
		var events: Array = dict.get("events", [])
		result += "  - %s (deadzone: %.2f)\n" % [name, dict.get("deadzone", 0.5)]
		if events.is_empty():
			result += "      (no events)\n"
		else:
			for ev in events:
				result += "      -> %s\n" % _event_to_string(ev)
	
	return {"success": true, "data": result}


# ==================== 事件解析 ====================

func _parse_event_string(event_str: String) -> InputEvent:
	event_str = event_str.strip_edges().to_upper()
	if event_str.is_empty():
		return null
	
	if "+" in event_str:
		return _parse_key_combination(event_str)
	
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


func _get_keycode_from_constant(const_name: String) -> int:
	var key_name = const_name.substr(4) if const_name.begins_with("KEY_") else const_name
	var code = OS.find_keycode_from_string(key_name)
	if code != KEY_NONE:
		return code
	
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
			if const_name.is_valid_int():
				return const_name.to_int()
			return -1


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
			if const_name.is_valid_int():
				return const_name.to_int()
			return -1


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
