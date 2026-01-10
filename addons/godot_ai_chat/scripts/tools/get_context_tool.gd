extends AiTool

# 定义每个上下文类型允许的扩展名白名单
const EXTENSION_MAP = {
	"scene_tree": ["tscn"],
	"gdscript": ["gd", "gdshader"],
	"text-based_file": ["txt", "md", "json", "cfg", "tres"],
	"image-meta": ["png", "jpg", "jpeg", "bmp", "tga", "exr"]
}


func _init():
	tool_name = "get_context"
	tool_description = "Retrieve context information in current workspace."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"context_type": {
				"type": "string",
				"enum": ["folder_structure", "scene_tree", "gdscript", "text-based_file", "image-meta"],
				"description": "The type of context to retrieve."
			},
			"path": {
				"type": "string",
				"description": "The relative path to the file or directory, starting with res://"
			}
		},
		"required": ["context_type", "path"]
	}


func execute(_args: Dictionary, _context_provider: ContextProvider) -> Dictionary:
	var context_type: String = _args.get("context_type", "")
	var path: String = _args.get("path", "")
	
	if context_type.is_empty() or path.is_empty():
		return {"success": false, "data": "Missing parameters: context_type or path"}
	
	# 1. 基础路径安全检查
	if not path.begins_with("res://"):
		return {"success": false, "data": "Error: Path must start with 'res://'."}
	if ".." in path:
		return {"success": false, "data": "Error: Path traversal ('..') is not allowed."}
	
	# 2. 针对 folder_structure 的特殊处理
	if context_type == "folder_structure":
		var dir = DirAccess.open("res://")
		if not dir.dir_exists(path):
			return {"success": false, "data": "Error: Directory not found: " + path}
		return _context_provider.get_folder_structure_as_markdown(path)
	
	# 3. 针对文件类型的白名单检查
	if not EXTENSION_MAP.has(context_type):
		return {"success": false, "data": "Error: Unknown context_type: " + context_type}
	
	var allowed_extensions: Array = EXTENSION_MAP[context_type]
	var ext: String = path.get_extension().to_lower()
	
	if ext not in allowed_extensions:
		return {
			"success": false, 
			"data": "Error: Extension '%s' is not allowed for context_type '%s'. Allowed: %s" % [ext, context_type, allowed_extensions]
		}
	
	# 4. 执行具体逻辑
	match context_type:
		"scene_tree": 
			return _context_provider.get_scene_tree_as_markdown(path)
		"gdscript": 
			return _context_provider.get_script_content_as_markdown(path)
		"text-based_file": 
			return _context_provider.get_text_content_as_markdown(path)
		"image-meta": 
			return _context_provider.get_image_metadata_as_markdown(path)
		_:
			return {"success": false, "data": "Internal Error: Unhandled context type."}
