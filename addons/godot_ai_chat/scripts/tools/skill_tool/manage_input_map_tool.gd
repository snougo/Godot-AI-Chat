@tool
extends AiTool

## 管理项目输入映射 的工具
## 支持增删改查操作，同时同步 ProjectSettings 和 InputMap


# ==================== 常量定义 ====================

const JOY_BUTTON_ALIASES: Dictionary = {
	# 面键
	"a": JOY_BUTTON_A, "cross": JOY_BUTTON_A, "face_down": JOY_BUTTON_A,
	"b": JOY_BUTTON_B, "circle": JOY_BUTTON_B, "face_right": JOY_BUTTON_B,
	"x": JOY_BUTTON_X, "square": JOY_BUTTON_X, "face_left": JOY_BUTTON_X,
	"y": JOY_BUTTON_Y, "triangle": JOY_BUTTON_Y, "face_up": JOY_BUTTON_Y,
	# 功能键
	"back": JOY_BUTTON_BACK, "select": JOY_BUTTON_BACK,
	"guide": JOY_BUTTON_GUIDE, "home": JOY_BUTTON_GUIDE,
	"start": JOY_BUTTON_START,
	# 摇杆按下
	"left_stick": JOY_BUTTON_LEFT_STICK, "l3": JOY_BUTTON_LEFT_STICK,
	"right_stick": JOY_BUTTON_RIGHT_STICK, "r3": JOY_BUTTON_RIGHT_STICK,
	# 肩键
	"left_shoulder": JOY_BUTTON_LEFT_SHOULDER, "l1": JOY_BUTTON_LEFT_SHOULDER,
	"right_shoulder": JOY_BUTTON_RIGHT_SHOULDER, "r1": JOY_BUTTON_RIGHT_SHOULDER,
	# 方向键
	"dpad_up": JOY_BUTTON_DPAD_UP,
	"dpad_down": JOY_BUTTON_DPAD_DOWN,
	"dpad_left": JOY_BUTTON_DPAD_LEFT,
	"dpad_right": JOY_BUTTON_DPAD_RIGHT,
}

const JOY_AXIS_ALIASES: Dictionary = {
	"left_x": JOY_AXIS_LEFT_X,
	"left_y": JOY_AXIS_LEFT_Y,
	"right_x": JOY_AXIS_RIGHT_X,
	"right_y": JOY_AXIS_RIGHT_Y,
	"trigger_left": JOY_AXIS_TRIGGER_LEFT, "l2": JOY_AXIS_TRIGGER_LEFT,
	"trigger_right": JOY_AXIS_TRIGGER_RIGHT, "r2": JOY_AXIS_TRIGGER_RIGHT,
}

const MOUSE_BUTTON_ALIASES: Dictionary = {
	"left": MOUSE_BUTTON_LEFT,
	"right": MOUSE_BUTTON_RIGHT,
	"middle": MOUSE_BUTTON_MIDDLE,
	"wheel_up": MOUSE_BUTTON_WHEEL_UP,
	"wheel_down": MOUSE_BUTTON_WHEEL_DOWN,
	"xbutton1": MOUSE_BUTTON_XBUTTON1,
	"xbutton2": MOUSE_BUTTON_XBUTTON2,
}


# ==================== 初始化 ====================

func _init() -> void:
	tool_name = "manage_input_map"
	tool_description = "Manage InputMap actions with CRUD operations. Args: operation (string), actions (Array[Dictionary]), deadzone (float)."


# ==================== 参数 Schema ====================

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
							"description": "Event strings: 'Key:W', 'Key:Ctrl+Shift+S', 'Mouse:Left', 'JoyBtn:A', 'JoyAxis:Left_X-'"
						},
						"clear_existing": { "type": "boolean", "description": "Clear existing events before adding new ones (default: true for add, false for update)" }
					},
					"required": ["name"]
				},
				"description": "Actions to process (not needed for 'list' operation)"
			},
			"deadzone": {
				"type": "number",
				"minimum": 0.0,
				"maximum": 1.0,
				"description": "Deadzone value for actions (default: 0.5)"
			},
			"action_name": {
				"type": "string",
				"description": "Single action name for 'remove' or 'list' single action"
			}
		},
		"required": ["operation"]
	}


# ==================== 主执行函数 ====================

func execute(p_args: Dictionary) -> Dictionary:
	var operation: String = p_args.get("operation", "")
	
	if operation.is_empty():
		return {"success": false, "data": "Missing required parameter: operation"}
	
	match operation:
		"add", "update":
			return _execute_add_update(p_args)
		"remove":
			return _execute_remove(p_args)
		"list":
			return _execute_list(p_args)
		"clear":
			return _execute_clear(p_args)
		_:
			return {"success": false, "data": "Unknown operation: %s" % operation}


# ==================== 操作实现 ====================

func _execute_add_update(p_args: Dictionary) -> Dictionary:
	var actions: Array = p_args.get("actions", [])
	var deadzone: float = p_args.get("deadzone", 0.5)
	var is_update: bool = p_args.get("operation") == "update"
	
	if actions.is_empty():
		return {"success": false, "data": "No actions provided."}
	
	var log_str: String = ""
	var changed_anything: bool = false
	
	for action_data in actions:
		var action_name: String = action_data.get("name", "")
		if action_name.is_empty():
			log_str += "! Skipped: Empty action name\n"
			continue
		
		var events_list: Array = action_data.get("events", [])
		var clear: bool = action_data.get("clear_existing", not is_update)
		
		var result = _add_or_update_action(action_name, events_list, clear, deadzone)
		log_str += result.log
		if result.changed:
			changed_anything = true
	
	if changed_anything:
		var err = ProjectSettings.save()
		if err != OK:
			return {"success": false, "data": "Failed to save ProjectSettings. Error code: %d" % err}
		
		var user_hint = "\n[Notice] Changes saved. If not visible in 'Project Settings' UI, restart the editor."
		return {"success": true, "data": "Input Map updated successfully.\n" + log_str + user_hint}
	else:
		return {"success": true, "data": "No changes made.\n" + log_str}


func _execute_remove(p_args: Dictionary) -> Dictionary:
	var action_name: String = p_args.get("action_name", "")
	var actions: Array = p_args.get("actions", [])
	
	# 支持通过 action_name 或 actions 数组删除
	var names_to_remove: Array = []
	if not action_name.is_empty():
		names_to_remove.append(action_name)
	for action_data in actions:
		var name = action_data.get("name", "")
		if not name.is_empty() and not names_to_remove.has(name):
			names_to_remove.append(name)
	
	if names_to_remove.is_empty():
		return {"success": false, "data": "No action name specified for removal."}
	
	var log_str: String = ""
	var changed_anything: bool = false
	
	for name in names_to_remove:
		var setting_path = "input/" + name
		
		# 从 ProjectSettings 移除
		if ProjectSettings.has_setting(setting_path):
			ProjectSettings.clear(setting_path)
			log_str += "Removed from ProjectSettings: %s\n" % name
			changed_anything = true
		else:
			log_str += "! Not found in ProjectSettings: %s\n" % name
		
		# 从内存 InputMap 移除
		if InputMap.has_action(name):
			InputMap.erase_action(name)
			log_str += "Removed from InputMap: %s\n" % name
		else:
			log_str += "! Not found in InputMap: %s\n" % name
	
	if changed_anything:
		var err = ProjectSettings.save()
		if err != OK:
			return {"success": false, "data": "Failed to save ProjectSettings. Error code: %d" % err}
		return {"success": true, "data": "Actions removed successfully.\n" + log_str}
	else:
		return {"success": true, "data": "No actions were removed.\n" + log_str}


func _execute_list(p_args: Dictionary) -> Dictionary:
	var action_name: String = p_args.get("action_name", "")
	
	# 列出单个动作
	if not action_name.is_empty():
		return _list_single_action(action_name)
	
	# 列出所有动作
	return _list_all_actions()


func _list_single_action(action_name: String) -> Dictionary:
	var setting_path = "input/" + action_name
	
	if not ProjectSettings.has_setting(setting_path):
		return {"success": false, "data": "Action not found: %s" % action_name}
	
	var action_dict: Dictionary = ProjectSettings.get_setting(setting_path)
	var result: String = "Action: %s\n" % action_name
	result += "  Deadzone: %s\n" % action_dict.get("deadzone", 0.5)
	result += "  Events:\n"
	
	var events: Array = action_dict.get("events", [])
	if events.is_empty():
		result += "    (none)\n"
	else:
		for event in events:
			result += "    - %s\n" % _event_to_string(event)
	
	return {"success": true, "data": result}


func _list_all_actions() -> Dictionary:
	var actions: Array = ProjectSettings.get_global_class_list()
	var input_actions: Array = []
	
	# 获取所有 input/ 开头的设置
	var property_list = ProjectSettings.get_property_list()
	for prop in property_list:
		var name: String = prop.name
		if name.begins_with("input/"):
			var action_name = name.substr(6)  # 去掉 "input/" 前缀
			input_actions.append(action_name)
	
	if input_actions.is_empty():
		return {"success": true, "data": "No InputMap actions found."}
	
	var result: String = "Found %d action(s):\n" % input_actions.size()
	for action_name in input_actions:
		var setting_path = "input/" + action_name
		var action_dict: Dictionary = ProjectSettings.get_setting(setting_path)
		var events: Array = action_dict.get("events", [])
		var event_count = events.size()
		var deadzone = action_dict.get("deadzone", 0.5)
		result += "  - %s (events: %d, deadzone: %.2f)\n" % [action_name, event_count, deadzone]
	
	return {"success": true, "data": result}


func _execute_clear(p_args: Dictionary) -> Dictionary:
	var action_name: String = p_args.get("action_name", "")
	
	if action_name.is_empty():
		return {"success": false, "data": "No action_name specified for clear operation."}
	
	var setting_path = "input/" + action_name
	
	if not ProjectSettings.has_setting(setting_path):
		return {"success": false, "data": "Action not found: %s" % action_name}
	
	# 清空 ProjectSettings 中的事件
	var action_dict: Dictionary = ProjectSettings.get_setting(setting_path)
	action_dict["events"] = []
	ProjectSettings.set_setting(setting_path, action_dict)
	
	# 清空内存 InputMap 中的事件
	if InputMap.has_action(action_name):
		InputMap.action_erase_events(action_name)
	
	var err = ProjectSettings.save()
	if err != OK:
		return {"success": false, "data": "Failed to save ProjectSettings. Error code: %d" % err}
	
	return {"success": true, "data": "Cleared all events for action: %s" % action_name}


# ==================== 动作添加/更新 ====================

func _add_or_update_action(action_name: String, events_list: Array, clear: bool, deadzone: float) -> Dictionary:
	var log_str: String = ""
	var changed: bool = false
	var setting_path = "input/" + action_name
	var action_dict: Dictionary
	
	# 处理 ProjectSettings
	if ProjectSettings.has_setting(setting_path):
		action_dict = ProjectSettings.get_setting(setting_path)
		log_str += "Updated Action: %s\n" % action_name
	else:
		action_dict = {"deadzone": deadzone, "events": []}
		ProjectSettings.set_setting(setting_path, action_dict)
		log_str += "Added Action: %s\n" % action_name
		changed = true
	
	# 更新 deadzone
	if action_dict.get("deadzone", 0.5) != deadzone:
		action_dict["deadzone"] = deadzone
		changed = true
	
	if not action_dict.has("events"):
		action_dict["events"] = []
	
	if clear and not action_dict["events"].is_empty():
		action_dict["events"].clear()
		changed = true
	
	# 处理内存 InputMap
	if not InputMap.has_action(action_name):
		InputMap.add_action(action_name, deadzone)
		changed = true
	elif clear:
		InputMap.action_erase_events(action_name)
	
	# 解析并绑定事件
	for event_str in events_list:
		var event: InputEvent = _parse_event_string(event_str)
		if event:
			action_dict["events"].append(event)
			InputMap.action_add_event(action_name, event)
			log_str += "  + Bound: %s -> %s\n" % [action_name, event_str]
			changed = true
		else:
			log_str += "  ! Failed to parse: %s\n" % event_str
	
	# 写回 ProjectSettings
	ProjectSettings.set_setting(setting_path, action_dict)
	
	return {"log": log_str, "changed": changed}


# ==================== 事件解析（拆分重构） ====================

func _parse_event_string(event_str: String) -> InputEvent:
	var parts = event_str.split(":")
	if parts.size() < 2:
		return null
	
	var type = parts[0].to_lower()
	var value = parts[1]
	
	match type:
		"key":
			return _parse_key_event(value)
		"mouse":
			return _parse_mouse_event(value)
		"joybtn", "joybutton":
			return _parse_joy_button_event(value)
		"joyaxis", "joyaxis_motion":
			return _parse_joy_axis_event(value)
		_:
			return null


func _parse_key_event(value: String) -> InputEventKey:
	var ev = InputEventKey.new()
	var parts = value.split("+")
	var key_name = parts[-1].to_lower()  # 最后一个是主键
	
	# 解析修饰键
	for i in parts.size() - 1:
		match parts[i].to_lower():
			"ctrl", "cmd", "control":
				ev.ctrl_pressed = true
			"shift":
				ev.shift_pressed = true
			"alt":
				ev.alt_pressed = true
			"meta":
				ev.meta_pressed = true
	
	# 解析主键
	var key_code = OS.find_keycode_from_string(key_name.to_upper())
	
	# 🔴 修复：验证 key_code 是否有效
	if key_code == KEY_NONE:
		push_warning("Invalid key name: %s" % key_name)
		return null
	
	ev.keycode = key_code
	ev.physical_keycode = key_code
	
	return ev


func _parse_mouse_event(value: String) -> InputEventMouseButton:
	var ev = InputEventMouseButton.new()
	var button_name = value.to_lower()
	
	if MOUSE_BUTTON_ALIASES.has(button_name):
		ev.button_index = MOUSE_BUTTON_ALIASES[button_name]
		return ev
	
	# 支持数字索引
	if value.is_valid_int():
		var btn_index = value.to_int()
		if btn_index >= 1 and btn_index <= 24:  # 合理的鼠标按钮范围
			ev.button_index = btn_index
			return ev
	
	push_warning("Invalid mouse button: %s" % value)
	return null


func _parse_joy_button_event(value: String) -> InputEventJoypadButton:
	var ev = InputEventJoypadButton.new()
	var btn_name = value.to_lower()
	
	# 查找别名映射
	if JOY_BUTTON_ALIASES.has(btn_name):
		ev.button_index = JOY_BUTTON_ALIASES[btn_name]
		return ev
	
	# 支持数字索引
	if value.is_valid_int():
		var btn_index = value.to_int()
		if btn_index >= 0 and btn_index <= 127:  # 合理的手柄按钮范围
			ev.button_index = btn_index
			return ev
	
	push_warning("Invalid joy button: %s" % value)
	return null


func _parse_joy_axis_event(value: String) -> InputEventJoypadMotion:
	var ev = InputEventJoypadMotion.new()
	var target_val_str = value.to_lower()
	var axis_val = 1.0  # 默认正值
	
	# 解析方向后缀
	if target_val_str.ends_with("-"):
		axis_val = -1.0
		target_val_str = target_val_str.trim_suffix("-")
	elif target_val_str.ends_with("+"):
		axis_val = 1.0
		target_val_str = target_val_str.trim_suffix("+")
	
	# 查找别名映射
	if JOY_AXIS_ALIASES.has(target_val_str):
		ev.axis = JOY_AXIS_ALIASES[target_val_str]
		ev.axis_value = axis_val
		return ev
	
	# 支持数字索引 (如 JoyAxis:0+, JoyAxis:1-)
	if target_val_str.is_valid_int():
		var axis_index = target_val_str.to_int()
		if axis_index >= 0 and axis_index <= 10:  # 合理的摇杆轴范围
			ev.axis = axis_index
			ev.axis_value = axis_val
			return ev
	
	push_warning("Invalid joy axis: %s" % value)
	return null


# ==================== 辅助函数 ====================

func _event_to_string(event: InputEvent) -> String:
	if event is InputEventKey:
		var result = "Key:"
		if event.ctrl_pressed:
			result += "Ctrl+"
		if event.shift_pressed:
			result += "Shift+"
		if event.alt_pressed:
			result += "Alt+"
		if event.meta_pressed:
			result += "Meta+"
		result += OS.get_keycode_string(event.keycode)
		return result
	
	elif event is InputEventMouseButton:
		var btn_name = MOUSE_BUTTON_ALIASES.find_key(event.button_index)
		var btn_str = btn_name if btn_name else str(event.button_index)
		return "Mouse:%s" % btn_str
	
	elif event is InputEventJoypadButton:
		var btn_name = JOY_BUTTON_ALIASES.find_key(event.button_index)
		var btn_str = btn_name if btn_name else str(event.button_index)
		return "JoyBtn:%s" % btn_str
	
	elif event is InputEventJoypadMotion:
		var axis_name = JOY_AXIS_ALIASES.find_key(event.axis)
		var axis_str = axis_name if axis_name else str(event.axis)
		var direction = "+" if event.axis_value >= 0 else "-"
		return "JoyAxis:%s%s" % [axis_str, direction]
	
	return "Unknown event type"
