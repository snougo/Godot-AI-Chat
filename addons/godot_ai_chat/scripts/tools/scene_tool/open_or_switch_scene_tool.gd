@tool
extends AiTool

# 定义黑名单路径片段
# 任何包含这些字符串的路径都将被禁止打开
const BLACKLIST_PATHS: Array[String] = [
	".godot/",  # 内部缓存目录
	"addons/godot_ai_chat/" # 示例：防止 AI 意外打开插件自身的 UI 场景
]


func _init():
	tool_name = "open_or_switch_scene"
	tool_description = "Open or Switch a scene file in the Godot Editor."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"path": {
				"type": "string",
				"description": "The full path to the scene file (e.g., res://path/main.tscn)."
			}
		},
		"required": ["path"]
	}


func execute(args: Dictionary, _context_provider) -> Dictionary:
	if not args.has("path"):
		return {"success": false, "data": "Missing 'path' argument."}
	
	var path: String = args["path"]
	
	# 1. 路径黑名单检查
	for blacklisted in BLACKLIST_PATHS:
		if path.find(blacklisted) != -1:
			return {"success": false, "data": "Access denied: Path contains blacklisted segment '%s'." % blacklisted}
	
	# 2. 文件存在性检查
	if not FileAccess.file_exists(path):
		return {"success": false, "data": "File not found: " + path}
		
	# 3. 文件类型检查
	if not (path.ends_with(".tscn") or path.ends_with(".scn") or path.ends_with(".escn")):
		return {"success": false, "data": "File is not a scene file (.tscn, .scn, .escn): " + path}
	
	# 执行打开操作
	EditorInterface.open_scene_from_path(path)
	return {"success": true, "data": "Opened scene: " + path}
