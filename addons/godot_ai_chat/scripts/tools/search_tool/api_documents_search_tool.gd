@tool
extends AiTool

## 搜索 Godot ClassDB 和本地 API 文档。
## 在 `res://godot_doc` 中查找本地文档。

# --- Enums / Constants ---

## 硬编码的本地文档路径
const LOCAL_DOC_PATH: String = "res://godot_doc"


# --- Built-in Functions ---

func _init() -> void:
	tool_name = "api_documents_search"
	tool_description = "Searches Godot ClassDB and local API docs in `res://godot_doc`."


# --- Public Functions ---

## 获取工具参数的 JSON Schema
func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"keywords": {
				"type": "string",
				"description": "The keyword(s) to search for (e.g., 'Node', 'Node2D', 'Node3D'). Supports multiple keywords and fuzzy matching."
			}
		},
		"required": ["keywords"]
	}


## 执行 API 文档搜索操作
## [param p_args]: 包含 keywords 的参数字典
## [return]: 搜索结果字典
func execute(p_args: Dictionary) -> Dictionary:
	var raw_keywords: Variant = p_args.get("keywords", "")
	var keywords_list: PackedStringArray = _parse_keywords(raw_keywords)
	
	if keywords_list.is_empty():
		return {"success": false, "data": "Error: Keywords cannot be empty."}
	
	var output: Array[String] = []
	var found_any: bool = false
	
	var class_result: String = _search_builtin_api_multi(keywords_list)
	if not class_result.is_empty():
		found_any = true
		output.append("## [Quick Reference] Built-in API (ClassDB)\n" + class_result)
	
	var file_result: String = _search_local_files_multi(LOCAL_DOC_PATH, keywords_list)
	if not file_result.is_empty():
		found_any = true
		output.append("## [Extended Docs] Local Documentation Files\n" + file_result)
		output.append("\n> **Tip:** To read the content of any file above, use the `retrieve_context` tool with `context_type='text-based_file'` and the specific `path`.")
	
	if not found_any:
		return {"success": false, "data": "No API definition (ClassDB) or local documentation files found for keywords: %s" % ", ".join(keywords_list)}
	
	return {"success": true, "data": "\n\n".join(output)}


# --- Private Functions ---

## 解析关键词
## [param p_keyword_input]: 关键词输入（字符串或数组）
## [return]: 关键词数组
func _parse_keywords(p_keyword_input: Variant) -> PackedStringArray:
	var result: PackedStringArray = []
	
	if p_keyword_input is Array:
		for i in p_keyword_input:
			result.append(str(i).strip_edges())
	else:
		var split_keywords: String = str(p_keyword_input)
		var parts: PackedStringArray = split_keywords.replace(",", " ").split(" ", false)
		for p in parts:
			result.append(p.strip_edges())
	
	return result


## 搜索内置 API（多关键词）
## [param p_keywords]: 关键词数组
## [return]: 搜索结果字符串
func _search_builtin_api_multi(p_keywords: PackedStringArray) -> String:
	var exact_matches: Array[String] = []
	var fuzzy_matches: Array[String] = []
	var all_classes: PackedStringArray = ClassDB.get_class_list()
	
	for kw in p_keywords:
		var kw_lower: String = kw.to_lower()
		var found_exact := false
		
		if ClassDB.class_exists(kw):
			if kw not in exact_matches:
				exact_matches.append(kw)
			found_exact = true
		else:
			for cls in all_classes:
				if cls.to_lower() == kw_lower:
					if cls not in exact_matches:
						exact_matches.append(cls)
					found_exact = true
					break
		
		for cls in all_classes:
			if kw_lower in cls.to_lower():
				if cls not in exact_matches and cls not in fuzzy_matches:
					fuzzy_matches.append(cls)
	
	if exact_matches.is_empty() and fuzzy_matches.is_empty():
		return ""
	
	return _format_api_results(exact_matches, fuzzy_matches)


## 格式化 API 搜索结果
## [param p_exact_matches]: 精确匹配的类名数组
## [param p_fuzzy_matches]: 模糊匹配的类名数组
## [return]: 格式化结果字符串
func _format_api_results(p_exact_matches: Array[String], p_fuzzy_matches: Array[String]) -> String:
	var sb: Array[String] = []
	
	for cls in p_exact_matches:
		sb.append(_get_class_details(cls))
	
	if not p_fuzzy_matches.is_empty():
		if p_exact_matches.is_empty():
			sb.append("No exact match found. Showing related classes:\n")
			var count := 0
			var max_fuzzy_details := 3
			
			for cls in p_fuzzy_matches:
				if count < max_fuzzy_details:
					sb.append(_get_class_details(cls))
				else:
					break
				count += 1
			
			if p_fuzzy_matches.size() > max_fuzzy_details:
				var rest: Array[String] = _get_limited_fuzzy_list(p_fuzzy_matches, max_fuzzy_details)
				sb.append("\n**Other related classes:** " + ", ".join(rest))
		else:
			var display_list: Array[String] = _get_limited_fuzzy_list(p_fuzzy_matches, 0)
			sb.append("\n**Also found these related classes:** " + ", ".join(display_list))
	
	return "\n\n".join(sb)


## 获取限制的模糊匹配列表
## [param p_fuzzy_matches]: 模糊匹配数组
## [param p_offset]: 偏移量
## [return]: 限制后的列表
func _get_limited_fuzzy_list(p_fuzzy_matches: Array[String], p_offset: int) -> Array[String]:
	var rest: Array[String] = p_fuzzy_matches.slice(p_offset)
	
	if rest.size() > 20:
		rest = rest.slice(0, 20)
		rest.append("... (%d more)" % (p_fuzzy_matches.size() - p_offset - 20))
	
	return rest


## 获取类详细信息
## [param p_target_class]: 目标类名
## [return]: 类详细信息字符串
func _get_class_details(p_target_class: String) -> String:
	var sb: Array[String] = []
	sb.append("### Class: %s" % p_target_class)
	sb.append("**Inherits:** %s" % ClassDB.get_parent_class(p_target_class))
	
	_format_constants(p_target_class, sb)
	_format_properties(p_target_class, sb)
	_format_methods(p_target_class, sb)
	
	return "\n".join(sb)


## 格式化常量信息
## [param p_target_class]: 目标类名
## [param p_sb]: 字符串构建器
func _format_constants(p_target_class: String, p_sb: Array[String]) -> void:
	var constants: PackedStringArray = ClassDB.class_get_integer_constant_list(p_target_class, true)
	
	if constants.is_empty():
		return
	
	p_sb.append("\n**Constants:**")
	var limit := 8
	
	for i in range(min(constants.size(), limit)):
		var c_name: String = constants[i]
		var val: int = ClassDB.class_get_integer_constant(p_target_class, c_name)
		p_sb.append("- `%s` = %d" % [c_name, val])
	
	if constants.size() > limit:
		p_sb.append("- ... (%d more)" % (constants.size() - limit))


## 格式化属性信息
## [param p_target_class]: 目标类名
## [param p_sb]: 字符串构建器
func _format_properties(p_target_class: String, p_sb: Array[String]) -> void:
	var props: Array[Dictionary] = ClassDB.class_get_property_list(p_target_class, true)
	var prop_list: Array[String] = []
	
	for p in props:
		if p["usage"] & PROPERTY_USAGE_EDITOR or p["usage"] & PROPERTY_USAGE_SCRIPT_VARIABLE:
			prop_list.append("- `%s`: %s" % [p["name"], _type_to_string(p["type"])])
	
	if prop_list.is_empty():
		return
	
	p_sb.append("\n**Properties:**")
	
	if prop_list.size() > 15:
		p_sb.append_array(prop_list.slice(0, 15))
		p_sb.append("- ... (%d more)" % (prop_list.size() - 15))
	else:
		p_sb.append_array(prop_list)


## 格式化方法信息
## [param p_target_class]: 目标类名
## [param p_sb]: 字符串构建器
func _format_methods(p_target_class: String, p_sb: Array[String]) -> void:
	var methods: Array[Dictionary] = ClassDB.class_get_method_list(p_target_class, true)
	
	if methods.is_empty():
		return
	
	p_sb.append("\n**Methods:**")
	var count := 0
	
	for m in methods:
		if count >= 20:
			p_sb.append("- ... (%d more)" % (methods.size() - count))
			break
		
		var args_str: Array[String] = []
		for arg in m["args"]:
			args_str.append("%s: %s" % [arg["name"], _type_to_string(arg["type"])])
		
		var return_type: String = "void"
		if m.has("return"):
			return_type = _type_to_string(m["return"]["type"])
		
		p_sb.append("- `%s(%s) -> %s`" % [m["name"], ", ".join(args_str), return_type])
		count += 1


## 类型转换为字符串
## [param p_type]: 类型整数
## [return]: 类型字符串
func _type_to_string(p_type: int) -> String:
	if p_type == TYPE_NIL:
		return "void"
	return type_string(p_type)


## 搜索本地文件（多关键词）
## [param p_path]: 搜索路径
## [param p_keywords]: 关键词数组
## [return]: 搜索结果字符串
func _search_local_files_multi(p_path: String, p_keywords: PackedStringArray) -> String:
	var files: Array = _get_files_recursive(p_path)
	var matches := []
	
	var keywords_lower: Array[String] = []
	for k in p_keywords:
		keywords_lower.append(k.to_lower())
	
	for f in files:
		var fname_lower: String = f.get_file().to_lower()
		var is_match: bool = _check_file_match(fname_lower, keywords_lower)
		
		if is_match:
			var basename: String = f.get_file().get_basename().to_lower()
			if basename in keywords_lower:
				matches.push_front(f)
			else:
				matches.append(f)
	
	if matches.is_empty():
		return ""
	
	return _format_file_results(matches, p_path)


## 检查文件是否匹配关键词
## [param p_fname_lower]: 文件名（小写）
## [param p_keywords_lower]: 关键词数组（小写）
## [return]: 是否匹配
func _check_file_match(p_fname_lower: String, p_keywords_lower: Array[String]) -> bool:
	for k in p_keywords_lower:
		if k in p_fname_lower:
			return true
	return false


## 格式化文件搜索结果
## [param p_matches]: 匹配的文件数组
## [param p_path]: 搜索路径
## [return]: 格式化结果字符串
func _format_file_results(p_matches: Array, p_path: String) -> String:
	var sb: Array[String] = []
	sb.append("Found %d potentially relevant files in `%s`:" % [p_matches.size(), p_path])
	
	var limit := 15
	for i in range(min(p_matches.size(), limit)):
		sb.append("- `%s`" % p_matches[i])
	
	if p_matches.size() > limit:
		sb.append("- ... (%d more files hidden)" % (p_matches.size() - limit))
	
	return "\n".join(sb)


## 递归获取文件列表
## [param p_dir_path]: 目录路径
## [return]: 文件路径数组
func _get_files_recursive(p_dir_path: String) -> Array:
	var files := []
	var dir: DirAccess = DirAccess.open(p_dir_path)
	
	if dir:
		dir.list_dir_begin()
		var file_name: String = dir.get_next()
		
		while file_name != "":
			if dir.current_is_dir():
				if file_name != "." and file_name != "..":
					files.append_array(_get_files_recursive(p_dir_path.path_join(file_name)))
			else:
				if file_name.ends_with(".md") or file_name.ends_with(".txt"):
					files.append(p_dir_path.path_join(file_name))
			file_name = dir.get_next()
	
	return files
