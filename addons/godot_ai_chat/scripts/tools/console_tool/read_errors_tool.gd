@tool
extends AiTool

## 读取 Debugger Errors 标签页——游戏运行时的错误与警告历史（含引擎错误、源码行、堆栈）。


func _init() -> void:
	tool_name = "read_errors"
	tool_description = "Read the debugger's Errors tab — the error and warning history of game runs, stack traces included."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"limit": {
				"type": "integer",
				"description": "Newest error entries to return. Defaults to 10 with no cap."
			},
			"filter": {
				"type": "string",
				"description": "Optional case-insensitive substring; only entries whose text (time, message, or detail) contains it are returned."
			}
		},
		"required": []
	}


func execute(p_args: Dictionary) -> ToolResult:
	var limit: int = int(p_args.get("limit", 0))
	var filter: String = str(p_args.get("filter", ""))
	return ToolResult.ok(EditorConsoleReader.read_errors(limit, filter))
