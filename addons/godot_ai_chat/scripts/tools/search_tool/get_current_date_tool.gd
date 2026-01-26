@tool
extends AiTool

## 获取当前日期。
## 以 YYYY-MM-DD 格式返回实时日期。


# --- Built-in Functions ---

func _init() -> void:
	tool_name = "get_current_date"
	tool_description = "Get real-time date in YYYY-MM-DD format."


# --- Public Functions ---

## 获取工具参数的 JSON Schema
func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {},
		"required": []
	}


## 执行获取当前日期操作
## [param p_args]: 参数字典（此工具不需要参数）
## [return]: 包含当前日期的字典
func execute(p_args: Dictionary) -> Dictionary:
	var date_dict: Dictionary = Time.get_date_dict_from_system()
	var date_str: String = "%04d-%02d-%02d" % [date_dict.year, date_dict.month, date_dict.day]
	return {"success": true, "data": "Current Date: " + date_str}
