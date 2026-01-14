extends AiTool

# 硬编码的本地文档路径
const LOCAL_DOC_PATH = "res://godot_doc"


func _init():
	tool_name = "api_documents_search"
	tool_description = "Searches Godot ClassDB and local API docs in `res://godot_doc`. Use this for engine API questions."


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


func execute(_args: Dictionary, _context_provider: ContextProvider) -> Dictionary:
	var raw_keywords = _args.get("keywords", "")
	var keywords_list: PackedStringArray = _parse_keywords(raw_keywords)
	
	if keywords_list.is_empty():
		return {"success": false, "data": "Error: Keywords cannot be empty."}
	
	var output: Array = []
	var found_any: bool = false
	
	# 1. Built-in API Search (ClassDB)
	var class_result: String = _search_builtin_api_multi(keywords_list)
	if not class_result.is_empty():
		found_any = true
		output.append("## [Quick Reference] Built-in API (ClassDB)\n" + class_result)
	
	# 2. Local File Search
	var file_result: String = _search_local_files_multi(LOCAL_DOC_PATH, keywords_list)
	if not file_result.is_empty():
		found_any = true
		output.append("## [Extended Docs] Local Documentation Files\n" + file_result)
		output.append("\n> **Tip:** To read the content of any file above, use the `get_context` tool with `context_type='text-based_file'` and the specific `path`.")
	
	if not found_any:
		return {"success": false, "data": "No API definition (ClassDB) or local documentation files found for keywords: %s" % ", ".join(keywords_list)}
	
	return {"success": true, "data": "\n\n".join(output)}


func _parse_keywords(keyword_input: Variant) -> PackedStringArray:
	var res: PackedStringArray = []
	
	if keyword_input is Array:
		for i in keyword_input:
			res.append(str(i).strip_edges())
	else:
		var s: String = str(keyword_input)
		# Split by comma or space, filtering empty strings
		var parts: PackedStringArray = s.replace(",", " ").split(" ", false)
		for p in parts:
			res.append(p.strip_edges())
	
	return res


# --- 内部辅助函数：内置 API 查询 ---

func _search_builtin_api_multi(_keywords: PackedStringArray) -> String:
	var exact_matches: Array[String] = []
	var fuzzy_matches: Array[String] = []
	var all_classes = ClassDB.get_class_list()
	
	for kw in _keywords:
		var kw_lower: String = kw.to_lower()
		var found_exact: bool = false
		
		# 1. Exact Match Check
		if ClassDB.class_exists(kw):
			if kw not in exact_matches: exact_matches.append(kw)
			found_exact = true
		else:
			# Case-insensitive exact check
			for cls in all_classes:
				if cls.to_lower() == kw_lower:
					if cls not in exact_matches: exact_matches.append(cls)
					found_exact = true
					break
		
		# 2. Fuzzy Match Check (only if we want to suggest related classes)
		# We collect fuzzy matches regardless, but might filter them later
		for cls in all_classes:
			if kw_lower in cls.to_lower():
				# Avoid duplicates and exact matches in fuzzy list
				if cls not in exact_matches and cls not in fuzzy_matches:
					fuzzy_matches.append(cls)

	if exact_matches.is_empty() and fuzzy_matches.is_empty():
		return ""
	
	var sb: Array = []
	
	# Output details for Exact Matches
	for cls in exact_matches:
		sb.append(_get_class_details(cls))
	
	# Handle Fuzzy Matches
	# Strategy: 
	# - If we have exact matches, list fuzzy matches as "Related".
	# - If no exact matches, show details for top 3 fuzzy, list others.
	
	if not fuzzy_matches.is_empty():
		var max_fuzzy_details: int = 3
		
		if exact_matches.is_empty():
			sb.append("No exact match found. Showing related classes:\n")
			var count = 0
			for cls in fuzzy_matches:
				if count < max_fuzzy_details:
					sb.append(_get_class_details(cls))
				else:
					break
				count += 1
			
			if fuzzy_matches.size() > max_fuzzy_details:
				var rest = fuzzy_matches.slice(max_fuzzy_details)
				# Limit the "rest" list to avoid huge output
				if rest.size() > 20:
					rest = rest.slice(0, 20)
					rest.append("... (%d more)" % (fuzzy_matches.size() - max_fuzzy_details - 20))
				sb.append("\n**Other related classes:** " + ", ".join(rest))
		else:
			# Just list names
			var display_list = fuzzy_matches
			if display_list.size() > 20:
				display_list = display_list.slice(0, 20)
				display_list.append("... (%d more)" % (fuzzy_matches.size() - 20))
			sb.append("\n**Also found these related classes:** " + ", ".join(display_list))
	
	return "\n\n".join(sb)


func _get_class_details(_target_class: String) -> String:
	var sb: Array = []
	sb.append("### Class: %s" % _target_class)
	sb.append("**Inherits:** %s" % ClassDB.get_parent_class(_target_class))
	
	# Constants
	var constants: PackedStringArray = ClassDB.class_get_integer_constant_list(_target_class, true)
	if not constants.is_empty():
		sb.append("\n**Constants:**")
		var limit: int = 8
		for i in range(min(constants.size(), limit)):
			var c_name = constants[i]
			var val: int = ClassDB.class_get_integer_constant(_target_class, c_name)
			sb.append("- `%s` = %d" % [c_name, val])
		if constants.size() > limit:
			sb.append("- ... (%d more)" % (constants.size() - limit))
	
	# Properties
	var props: Array[Dictionary] = ClassDB.class_get_property_list(_target_class, true)
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
	var methods: Array[Dictionary] = ClassDB.class_get_method_list(_target_class, true)
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

func _search_local_files_multi(_path: String, _keywords: PackedStringArray) -> String:
	var files: Array = _get_files_recursive(_path)
	var matches: Array = []
	
	# Convert keywords to lower case for case-insensitive search
	var keywords_lower: Array[String] = []
	for k in _keywords:
		keywords_lower.append(k.to_lower())
	
	for f in files:
		var fname_lower = f.get_file().to_lower()
		var is_match = false
		for k in keywords_lower:
			if k in fname_lower:
				is_match = true
				break
		
		if is_match:
			# Prioritize exact name matches (basename without extension)
			var basename = f.get_file().get_basename().to_lower()
			if basename in keywords_lower:
				matches.push_front(f)
			else:
				matches.append(f)
	
	if matches.is_empty():
		return ""
	
	var sb: Array = []
	sb.append("Found %d potentially relevant files in `%s`:" % [matches.size(), _path])
	
	var limit: int = 15
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
