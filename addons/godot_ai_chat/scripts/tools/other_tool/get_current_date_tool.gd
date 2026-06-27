@tool
extends AiTool

## 获取当前日期和时间。
## 以 YYYY-MM-DD-HH-MM-SS 格式返回实时日期和时间。


# --- Built-in Functions ---

func _init() -> void:
	tool_name = "get_current_date"
	tool_description = "Get real-time date and time in YYYY-MM-DD-HH-MM-SS format."


# --- Public Functions ---

## 获取工具参数的 JSON Schema
func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {},
		"required": []
	}


## 执行获取当前日期和时间操作
## [param p_args]: 参数字典（此工具不需要参数）
## [return]: 包含当前日期和时间的字典
func execute(p_args: Dictionary) -> Dictionary:
	var datetime_dict: Dictionary = Time.get_datetime_dict_from_system()
	var datetime_str: String = "%04d-%02d-%02d-%02d-%02d-%02d" % [
		datetime_dict.year, datetime_dict.month, datetime_dict.day,
		datetime_dict.hour, datetime_dict.minute, datetime_dict.second
	]
	return {"success": true, "data": "Current Date and Time: " + datetime_str}
