@tool
extends RefCounted
class_name AiTool

# 统一的安全路径黑名单
# 这些目录包含 Godot 内部文件、插件源码或版本控制文件，禁止 AI 修改以免破坏项目结构
const PATH_BLACKLIST: Array[String] = [
	"/.git/", 
	"/.import/", 
	"/.godot/",
	"/android/", 
	"/addons/" 
]

# 工具的唯一标识符
var tool_name: String = ""
# 工具的描述，提供给 AI 阅读
var tool_description: String = ""


# [必须重写] 返回工具参数的 JSON Schema (OpenAI 格式)
# 只需要返回 "parameters" 字段对应的内容
func get_parameters_schema() -> Dictionary:
	return {"type": "object", "properties": {}}


# [必须重写] 执行工具逻辑
# args: AI 传入的参数字典
# context_provider: 上下文提供者实例 (依赖注入，来自 Godot Context Helper 插件)
# 返回: {"success": bool, "data": String}
func execute(_args: Dictionary, _context_provider: ContextProvider) -> Dictionary:
	return {"success": false, "data": "Not implemented"}


# 统一的路径安全检查函数
# 返回空字符串表示安全，返回错误信息表示违规
func validate_path_safety(path: String) -> String:
	if path.is_empty():
		return "Path is empty."
	
	if not path.begins_with("res://"):
		return "Path must start with 'res://'."
	
	# 标准化路径：移除 res:// 前缀，统一使用正斜杠
	# 例如: "res://my_folder\script.gd" -> "/my_folder/script.gd"
	var check_path = path.replace("res://", "/").replace("\\", "/")
	
	# 确保路径以斜杠结尾，以便精确匹配目录
	# 这能防止 "res://addons_test" (预期通过) 被误判为 "/addons/" (黑名单)
	# 同时也能拦截 "res://addons" (预期拦截) 这种未带斜杠的目录创建请求
	if not check_path.ends_with("/"):
		check_path += "/"
	
	# 检查是否是路径黑名单
	for blocked_pattern in PATH_BLACKLIST:
		if check_path.find(blocked_pattern) != -1:
			return "Security Error: Operation denied on restricted directory '%s'." % blocked_pattern
	
	return ""
