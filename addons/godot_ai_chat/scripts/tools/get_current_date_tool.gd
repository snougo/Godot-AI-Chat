extends AiTool


func _init():
	tool_name = "get_current_date"
	tool_description = "Get the current system date in YYYY-MM-DD format. Use this to compare with your knowledge cutoff date to decide if you need to search for newer documents."


func get_parameters_schema() -> Dictionary:
	# 该工具不需要任何参数
	return {
		"type": "object",
		"properties": {},
		"required": []
	}


func execute(_args: Dictionary, _context_provider: ContextProvider) -> Dictionary:
	var date_dict = Time.get_date_dict_from_system()
	# 格式化为 YYYY-MM-DD
	var date_str = "%04d-%02d-%02d" % [date_dict.year, date_dict.month, date_dict.day]
	return {"success": true, "data": "Current Date: " + date_str}
