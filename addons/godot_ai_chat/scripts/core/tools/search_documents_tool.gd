extends AiTool

# 硬编码的本地文档路径
const LOCAL_DOC_PATH = "res://godot_doc"


func _init():
	name = "search_documents"
	description = "Search for Godot documentation. Returns Built-in API structure (ClassDB) directly, and lists relevant local documentation files (paths only) from '%s' for further reading." % LOCAL_DOC_PATH


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"keywords": {
				"type": "string",
				"description": "The keyword(s) to search for (e.g., 'Node', 'Sprite2D', 'signal')."
			}
		},
		"required": ["keywords"]
	}


func execute(_args: Dictionary, _context_provider: ContextProvider) -> Dictionary:
	var keywords = _args.get("keywords", "")
	
	if keywords is Array:
		keywords = " ".join(keywords)
	
	keywords = str(keywords).strip_edges()
	
	if keywords.is_empty():
		return {"success": false, "data": "Error: Keywords cannot be empty."}
	
	var output: Array = []
	var found_any: bool = false
	
	# 1. Built-in API Search (ClassDB) - 直接返回核心内容
	var class_result: String = _search_builtin_api(keywords)
	if not class_result.is_empty():
		found_any = true
		output.append("## [Quick Reference] Built-in API (ClassDB)\n" + class_result)
	
	# 2. Local File Search - 只返回路径索引，使用硬编码路径
	var file_list_result: String = _search_local_files_index(LOCAL_DOC_PATH, keywords)
	if not file_list_result.is_empty():
		found_any = true
		output.append("## [Extended Docs] Local Documentation Files\n" + file_list_result)
		output.append("\n> **Tip:** To read the content of any file above, use the `get_context` tool with `context_type='text-based_file'` and the specific `path`.")
	
	if not found_any:
		return {"success": false, "data": "No API definition (ClassDB) or local documentation files found for '%s'." % keywords}
	
	return {"success": true, "data": "\n\n".join(output)}


# --- 内部辅助函数：内置 API 查询 ---

func _search_builtin_api(_keyword: String) -> String:
	var target_class: String = ""
	
	if ClassDB.class_exists(_keyword):
		target_class = _keyword
	else:
		var lower_k: String = _keyword.to_lower()
		
		for cls in ClassDB.get_class_list():
			if cls.to_lower() == lower_k:
				target_class = cls
				break
	
	if target_class.is_empty():
		return ""
	
	var sb: Array = []
	sb.append("### Class: %s" % target_class)
	sb.append("**Inherits:** %s" % ClassDB.get_parent_class(target_class))
	
	# Constants
	var constants: PackedStringArray = ClassDB.class_get_integer_constant_list(target_class, true)
	if not constants.is_empty():
		sb.append("\n**Constants:**")
		var limit: int = 8
		
		for i in range(min(constants.size(), limit)):
			var c_name = constants[i]
			var val: int = ClassDB.class_get_integer_constant(target_class, c_name)
			sb.append("- `%s` = %d" % [c_name, val])
		
		if constants.size() > limit:
			sb.append("- ... (%d more)" % (constants.size() - limit))
	
	# Properties
	var props: Array[Dictionary] = ClassDB.class_get_property_list(target_class, true)
	var prop_list: Array = []
	
	for p in props:
		if p["usage"] & PROPERTY_USAGE_EDITOR or p["usage"] & PROPERTY_USAGE_SCRIPT_VARIABLE:
			prop_list.append("- `%s`: %s" % [p["name"], _type_to_string(p["type"])])
	
	if not prop_list.is_empty():
		sb.append("\n**Properties:**")
		
		if prop_list.size() > 15:
			sb.append_array(prop_list.slice(0, 15))
			sb.append("- ... (%d more)" % (prop_list.size() - 15))
		else:
			sb.append_array(prop_list)
	
	# Methods
	var methods: Array[Dictionary] = ClassDB.class_get_method_list(target_class, true)
	if not methods.is_empty():
		sb.append("\n**Methods:**")
		var count: int = 0
		
		for m in methods:
			if count >= 20: 
				sb.append("- ... (%d more)" % (methods.size() - count))
				break
			
			var args_str: Array = []
			for arg in m["args"]:
				args_str.append("%s: %s" % [arg["name"], _type_to_string(arg["type"])])
			
			var return_type: String = "void"
			if m.has("return"):
				return_type = _type_to_string(m["return"]["type"])
			
			sb.append("- `%s(%s) -> %s`" % [m["name"], ", ".join(args_str), return_type])
			count += 1
	
	return "\n".join(sb)


func _type_to_string(_type: int) -> String:
	if _type == TYPE_NIL: return "void"
	return type_string(_type)


# --- 内部辅助函数：本地文件搜索 ---

func _search_local_files_index(_path: String, _keyword: String) -> String:
	var files: Array = _get_files_recursive(_path)
	var matches: Array = []
	var keyword_lower: String = _keyword.to_lower()
	
	for f in files:
		if f.get_file().get_basename().to_lower() == keyword_lower:
			matches.push_front(f)
		elif keyword_lower in f.get_file().to_lower():
			matches.append(f)
	
	if matches.is_empty():
		return ""
	
	var sb: Array = []
	sb.append("Found %d potentially relevant files in `%s`:" % [matches.size(), _path])
	
	var limit: int = 10
	for i in range(min(matches.size(), limit)):
		sb.append("- `%s`" % matches[i])
	
	if matches.size() > limit:
		sb.append("- ... (%d more files hidden)" % (matches.size() - limit))
	
	return "\n".join(sb)


func _get_files_recursive(_dir_path: String) -> Array:
	var files: Array = []
	var dir: DirAccess = DirAccess.open(_dir_path)
	
	if dir:
		dir.list_dir_begin()
		var file_name: String = dir.get_next()
		
		while file_name != "":
			if dir.current_is_dir():
				if file_name != "." and file_name != "..":
					files.append_array(_get_files_recursive(_dir_path.path_join(file_name)))
			else:
				if file_name.ends_with(".md") or file_name.ends_with(".txt"):
					files.append(_dir_path.path_join(file_name))
			file_name = dir.get_next()
	
	return files
