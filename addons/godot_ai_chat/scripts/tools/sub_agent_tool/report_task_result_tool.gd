@tool
extends AiTool

## Sub Agent 专用的任务汇报工具
## 注意：这个工具不需要在 ToolRegistry 中注册，它是由 SubAgentOrchestrator 动态加载的。

func _init() -> void:
	tool_name = "report_task_result"
	tool_description = "MUST be called when you have fully completed the task, or if you failed. This returns control to the Main Agent."

func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"status": {
				"type": "string",
				"enum": ["success", "failure"],
				"description": "Whether the task was completed successfully."
			},
			"summary": {
				"type": "string",
				"description": "A detailed report of what you did, the final outcome, or the reason for failure."
			}
		},
		"required": ["status", "summary"]
	}

func execute(_args: Dictionary) -> Dictionary:
	# 这个工具的执行逻辑实际上会被 SubAgentOrchestrator 拦截，这里只是占位
	return {"success": true, "data": "Report Sent."}
