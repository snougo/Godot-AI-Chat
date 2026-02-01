@tool
extends AiTool

## 管理项目输入映射 (Input Map) 的工具
## 同时修改 ProjectSettings (持久化) 和 InputMap (立即生效)
## 避免使用 load_from_project_settings() 以防止丢失编辑器内部临时动作


func _init() -> void:
	tool_name = "manage_input_map"
	tool_description = "Adds or updates InputMap actions and events. Args: actions (Array[Dictionary])."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"actions": {
				"type": "array",
				"items": {
					"type": "object",
					"properties": {
						"name": { "type": "string", "description": "Action name (e.g. 'move_forward')" },
						"events": { 
							"type": "array", 
							"items": { "type": "string" },
							"description": "List of events string format: 'Key:W', 'Key:Space', 'Mouse:Left', 'Mouse:Right', 'JoyBtn:A', 'JoyAxis:Left_X-'"
						},
						"clear_existing": { "type": "boolean", "description": "If true, clears existing events for this action." }
					},
					"required": ["name", "events"]
				}
			}
		},
		"required": ["actions"]
	}


func execute(p_args: Dictionary) -> Dictionary:
	var actions: Array = p_args.get("actions", [])
	if actions.is_empty():
		return {"success": false, "data": "No actions provided."}
	
	var log_str: String = ""
	var changed_anything: bool = false
	
	for action_data in actions:
		var action_name: String = action_data.get("name", "")
		var events_list: Array = action_data.get("events", [])
		var clear: bool = action_data.get("clear_existing", true)
		
		if action_name.is_empty():
			continue
		
		# --- 1. 操作 ProjectSettings (用于持久化保存) ---
		var setting_path = "input/" + action_name
		var action_dict: Dictionary
		
		if ProjectSettings.has_setting(setting_path):
			action_dict = ProjectSettings.get_setting(setting_path)
		else:
			action_dict = {"deadzone": 0.5, "events": []}
			# 如果是新动作，ProjectSettings 需要显式添加
			ProjectSettings.set_setting(setting_path, action_dict)
		
		if not action_dict.has("events"):
			action_dict["events"] = []
		
		if clear:
			action_dict["events"].clear()
		
		# --- 2. 操作内存 InputMap (用于立即生效) ---
		if not InputMap.has_action(action_name):
			InputMap.add_action(action_name)
			log_str += "Added Action: %s\n" % action_name
		elif clear:
			InputMap.action_erase_events(action_name)
			log_str += "Cleared events for: %s\n" % action_name
		
		# --- 3. 解析并绑定事件 ---
		for event_str in events_list:
			var event: InputEvent = _parse_event_string(event_str)
			if event:
				# 同步到 ProjectSettings
				action_dict["events"].append(event)
				# 同步到 内存 InputMap
				InputMap.action_add_event(action_name, event)
				
				log_str += "  + Bound: %s -> %s\n" % [action_name, event_str]
			else:
				log_str += "  ! Failed to parse: %s\n" % event_str
		
		# 写回 ProjectSettings 配置字典
		ProjectSettings.set_setting(setting_path, action_dict)
		changed_anything = true
	
	if changed_anything:
		# 仅保存文件，不再重载内存
		var err = ProjectSettings.save()
		if err != OK:
			return {"success": false, "data": "Failed to save ProjectSettings. Error code: %d" % err}
		
		# 添加用户提示信息
		var user_hint = "\n[Notice] Changes are saved and active. If they don't appear in 'Project Settings' UI immediately, Please restart the editor."
		return {"success": true, "data": "Input Map updated successfully.\n" + log_str + user_hint}
	else:
		return {"success": true, "data": "No changes made."}


func _parse_event_string(event_str: String) -> InputEvent:
	var parts = event_str.split(":")
	if parts.size() < 2:
		return null
	
	var type = parts[0].to_lower()
	var value = parts[1]
	
	if type == "key":
		var ev = InputEventKey.new()
		var key_code = OS.find_keycode_from_string(value)
		ev.keycode = key_code
		ev.physical_keycode = key_code
		return ev
	
	elif type == "mouse":
		var ev = InputEventMouseButton.new()
		match value.to_lower():
			"left": ev.button_index = MOUSE_BUTTON_LEFT
			"right": ev.button_index = MOUSE_BUTTON_RIGHT
			"middle": ev.button_index = MOUSE_BUTTON_MIDDLE
			"wheel_up": ev.button_index = MOUSE_BUTTON_WHEEL_UP
			"wheel_down": ev.button_index = MOUSE_BUTTON_WHEEL_DOWN
			"xbutton1": ev.button_index = MOUSE_BUTTON_XBUTTON1
			"xbutton2": ev.button_index = MOUSE_BUTTON_XBUTTON2
		return ev
	
	elif type == "joybtn":
		var ev = InputEventJoypadButton.new()
		var btn_index = -1
		
		if value.is_valid_int():
			btn_index = value.to_int()
		else:
			match value.to_lower():
				"a", "cross", "face_down": btn_index = JOY_BUTTON_A
				"b", "circle", "face_right": btn_index = JOY_BUTTON_B
				"x", "square", "face_left": btn_index = JOY_BUTTON_X
				"y", "triangle", "face_up": btn_index = JOY_BUTTON_Y
				"back", "select": btn_index = JOY_BUTTON_BACK
				"guide", "home": btn_index = JOY_BUTTON_GUIDE
				"start": btn_index = JOY_BUTTON_START
				"left_stick", "l3": btn_index = JOY_BUTTON_LEFT_STICK
				"right_stick", "r3": btn_index = JOY_BUTTON_RIGHT_STICK
				"left_shoulder", "l1": btn_index = JOY_BUTTON_LEFT_SHOULDER
				"right_shoulder", "r1": btn_index = JOY_BUTTON_RIGHT_SHOULDER
				"dpad_up": btn_index = JOY_BUTTON_DPAD_UP
				"dpad_down": btn_index = JOY_BUTTON_DPAD_DOWN
				"dpad_left": btn_index = JOY_BUTTON_DPAD_LEFT
				"dpad_right": btn_index = JOY_BUTTON_DPAD_RIGHT
		
		if btn_index != -1:
			ev.button_index = btn_index
			return ev
	
	elif type == "joyaxis":
		var ev = InputEventJoypadMotion.new()
		var axis_index = -1
		var axis_val = 1.0
		
		var target_val_str = value.to_lower()
		
		if target_val_str.ends_with("-"):
			axis_val = -1.0
			target_val_str = target_val_str.trim_suffix("-")
		elif target_val_str.ends_with("+"):
			axis_val = 1.0
			target_val_str = target_val_str.trim_suffix("+")
		
		match target_val_str:
			"left_x": axis_index = JOY_AXIS_LEFT_X
			"left_y": axis_index = JOY_AXIS_LEFT_Y
			"right_x": axis_index = JOY_AXIS_RIGHT_X
			"right_y": axis_index = JOY_AXIS_RIGHT_Y
			"trigger_left", "l2": axis_index = JOY_AXIS_TRIGGER_LEFT
			"trigger_right", "r2": axis_index = JOY_AXIS_TRIGGER_RIGHT
		
		if axis_index != -1:
			ev.axis = axis_index
			ev.axis_value = axis_val
			return ev
	
	return null
