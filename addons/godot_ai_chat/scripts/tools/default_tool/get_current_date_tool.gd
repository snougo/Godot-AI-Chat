extends AiTool


func _init():
	tool_name = "get_current_date"
	tool_description = "Get real-time date in YYYY-MM-DD format."


func get_parameters_schema() -> Dictionary:
	# 该工具不需要任何参数
	return {
		"type": "object",
		"properties": {},
		"required": []
	}


func execute(_args: Dictionary) -> Dictionary:
	var date_dict: Dictionary = Time.get_date_dict_from_system()
	# 格式化为 YYYY-MM-DD
	var date_str = "%04d-%02d-%02d" % [date_dict.year, date_dict.month, date_dict.day]
	return {"success": true, "data": "Current Date: " + date_str}
