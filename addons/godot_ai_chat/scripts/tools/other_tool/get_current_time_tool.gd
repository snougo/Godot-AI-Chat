extends AiTool

# 返回编辑器所在机器的当前本地日期与时间，精度到秒。
# 无需任何参数。


# --- Constants ---

# 星期名称（Time.Weekday 枚举从 0 = Sunday 开始）
const WEEKDAY_NAMES: Array[String] = [
	"Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"
]


# --- Built-in Functions ---

func _init() -> void:
	tool_name = "get_current_time"
	tool_description = "Returns the current local date and time, accurate to the second."


# --- Public Functions ---

# 获取工具参数的 JSON Schema（无参数）
func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {}
	}


# 读取系统本地时间并格式化为 "YYYY-MM-DD HH:MM:SS (Weekday)"
# [param _p_args]: 本工具不接受参数
func execute(_p_args: Dictionary) -> ToolResult:
	var datetime: Dictionary = Time.get_datetime_dict_from_system(false)
	# weekday: 0 = Sunday，与 Time.Weekday 枚举一致，可直接索引
	var weekday_name: String = WEEKDAY_NAMES[int(datetime["weekday"])]
	var time_text: String = Time.get_datetime_string_from_system(false, true)
	return ToolResult.ok("Local time: %s (%s)" % [time_text, weekday_name])
