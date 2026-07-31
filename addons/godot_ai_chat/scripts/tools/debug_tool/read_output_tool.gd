@tool
extends AiTool

## 读取编辑器 Output 控制台（底部输出面板）——用户正在看的日志，包括运行中游戏的 print 和错误。


func _init() -> void:
	tool_name = "read_output"
	tool_description = "Read the editor's Output console — the log panel the user sees, including a running game's prints and errors; returns the newest lines, optionally filtered."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"lines": {
				"type": "integer",
				"description": "Newest lines to return. Defaults to 40 with no cap — raise it freely when you need more of the log."
			},
			"filter": {
				"type": "string",
				"description": "Optional case-insensitive substring; only lines containing it are returned (the newest of those)."
			}
		},
		"required": []
	}


func execute(p_args: Dictionary) -> ToolResult:
	var lines: int = int(p_args.get("lines", 0))
	var filter: String = str(p_args.get("filter", ""))
	return ToolResult.ok(EditorConsoleReader.read_output(lines, filter))
