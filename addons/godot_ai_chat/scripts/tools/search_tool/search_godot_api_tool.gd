@tool
extends AiTool

## 搜索 Godot ClassDB、自定义全局类和本地 API 文档。


# --- Constants ---

const LOCAL_DOC_PATH: String = "res://godot_doc"


# --- Built-in Functions ---

func _init() -> void:
	tool_name = "search_godot_api"
	tool_description = "Searches Godot ClassDB, custom global classes, and local API docs."


# --- Public Functions ---

func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"keyword": {
				"type": "string",
				"description": "Search keyword. Only support `ClassName` (Node2D, Control and CustomClass, etc). \n > **Warning: ** Do not search for multiple keywords at the same time."
			}
		},
		"required": ["keyword"]
	}


func execute(p_args: Dictionary) -> ToolResult:
	var raw_keywords: Variant = p_args.get("keyword", "")
	var keywords_list: PackedStringArray = _parse_keywords(raw_keywords)
	
	if keywords_list.is_empty():
		return ToolResult.fail("Error: Keywords cannot be empty.")
	
	var output: Array[String] = []
	var found_any: bool = false
	
	var api_result: String = _search_builtin_api_multi(keywords_list)
	if not api_result.is_empty():
		found_any = true
		output.append(api_result)
	
	var doc_keywords: PackedStringArray = []
	for kw in keywords_list:
		doc_keywords.append(kw)
		if "." in kw:
			var parts: PackedStringArray = kw.split(".", false, 1)
			if parts.size() == 2 and not parts[0].is_empty():
				doc_keywords.append(parts[0])
	
	var file_result: String = _search_local_files_multi(LOCAL_DOC_PATH, doc_keywords)
	if not file_result.is_empty():
		found_any = true
		output.append("\n---\n" + file_result)
	
	if not found_any:
		return ToolResult.fail("Error: no API definition or local docs found for: %s" % ", ".join(keywords_list))
	
	return ToolResult.ok("\n".join(output))


# --- Private Functions: Parsing ---

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


# --- Private Functions: Main Search ---

func _search_builtin_api_multi(p_keywords: PackedStringArray) -> String:
	var all_classes: PackedStringArray = ClassDB.get_class_list()
	var class_exact: Array[String] = []
	var class_fuzzy: Array[String] = []
	var member_results: Array[Dictionary] = []
	var failed_searches: Array[Dictionary] = []
	
	for kw in p_keywords:
		var kw_lower: String = kw.to_lower()
		
		if "." in kw:
			var parts: PackedStringArray = kw.split(".", false, 1)
			if parts.size() == 2:
				var target_class: String = parts[0]
				var member_name: String = parts[1]
				var result: Dictionary = ClassDBUtils.search_member_with_inheritance(target_class, member_name, all_classes)
				
				if result.is_empty():
					result = _search_custom_class_member(target_class, member_name.to_lower())
				
				if not result.is_empty():
					member_results.append(result)
				else:
					var suggestions: Dictionary = ClassDBUtils.generate_smart_suggestions(target_class, member_name, all_classes)
					failed_searches.append({
						"class": target_class,
						"member": member_name,
						"suggestions": suggestions
					})
				continue
		
		var found_class: bool = false
		if ClassDB.class_exists(kw):
			class_exact.append(kw)
			found_class = true
		else:
			for cls in all_classes:
				if cls.to_lower() == kw_lower:
					class_exact.append(cls)
					found_class = true
					break
		
		if not found_class:
			var global_classes: Array[Dictionary] = ProjectSettings.get_global_class_list()
			for cls_dict in global_classes:
				var global_class_name: String = cls_dict.get("class", "")
				if not global_class_name.is_empty() and global_class_name.to_lower() == kw_lower:
					class_exact.append(global_class_name)
					found_class = true
					break
		
		if not found_class:
			var variant_doc_path: String = LOCAL_DOC_PATH.path_join("classes/class_%s.md" % kw_lower)
			var f: FileAccess = FileAccess.open(variant_doc_path, FileAccess.READ)
			if f:
				f.close()
				class_exact.append(kw_lower.capitalize())
				found_class = true
		
		if not found_class:
			var member_search: Dictionary = ClassDBUtils.search_member_across_classes(kw, all_classes)
			if not member_search.is_empty():
				member_results.append(member_search)
		
		for cls in all_classes:
			if kw_lower in cls.to_lower():
				if cls not in class_exact and cls not in class_fuzzy:
					class_fuzzy.append(cls)
		
		var global_classes: Array[Dictionary] = ProjectSettings.get_global_class_list()
		for cls_dict in global_classes:
			var global_class_name: String = cls_dict.get("class", "")
			if not global_class_name.is_empty() and kw_lower in global_class_name.to_lower():
				if global_class_name not in class_exact and global_class_name not in class_fuzzy:
					class_fuzzy.append(global_class_name)
	
	var lines: Array[String] = []
	
	if not class_exact.is_empty() or not class_fuzzy.is_empty():
		lines.append(_format_class_results_detailed(class_exact, class_fuzzy))
	
	if not member_results.is_empty():
		lines.append(_format_member_results(member_results))
	
	if not failed_searches.is_empty():
		lines.append(_format_failed_searches(failed_searches))
	
	return "\n\n".join(lines)


# --- Private Functions: Class Formatting ---

func _format_class_results_detailed(p_exact: Array[String], p_fuzzy: Array[String]) -> String:
	var lines: Array[String] = []
	
	for cls in p_exact:
		lines.append(_format_class_detailed(cls))
	
	if not p_fuzzy.is_empty():
		if p_exact.is_empty():
			lines.append("## Related Classes\n")
			lines.append("No exact match. Related classes:\n")
			var count := 0
			for cls in p_fuzzy:
				if count < 3:
					lines.append(_format_class_detailed(cls))
				else:
					break
				count += 1
			
			if p_fuzzy.size() > 3:
				var other_lines: Array[String] = ["\n**Other related:**"]
				for cls in p_fuzzy.slice(3, 10):
					other_lines.append("- `%s`" % cls)
				if p_fuzzy.size() > 10:
					other_lines.append("- ... (%d more)" % (p_fuzzy.size() - 10))
				lines.append("\n".join(other_lines))
		else:
			var fuzzy_lines: Array[String] = ["\n**Also found:**"]
			for cls in p_fuzzy.slice(0, 10):
				fuzzy_lines.append("- `%s`" % cls)
			if p_fuzzy.size() > 10:
				fuzzy_lines.append("- ... (%d more)" % (p_fuzzy.size() - 10))
			lines.append("\n".join(fuzzy_lines))
	
	return "\n\n".join(lines)


func _format_class_detailed(p_class: String) -> String:
	var lines: Array[String] = []
	lines.append("## Class: `%s`" % p_class)
	
	var is_global_script_class: bool = false
	var global_script_info: Dictionary = {}
	var global_classes: Array[Dictionary] = ProjectSettings.get_global_class_list()
	for cls_dict in global_classes:
		if cls_dict.get("class", "") == p_class:
			is_global_script_class = true
			global_script_info = cls_dict
			break
	
	if is_global_script_class:
		return ClassDBUtils.format_global_class_detailed(p_class, global_script_info)
	
	var is_variant_type: bool = not ClassDB.class_exists(p_class)
	if is_variant_type:
		lines.append("**Type:** Built-in Variant type")
		var variant_doc_path: String = LOCAL_DOC_PATH.path_join("classes/class_%s.md" % p_class.to_lower())
		var f: FileAccess = FileAccess.open(variant_doc_path, FileAccess.READ)
		if f:
			f.close()
			lines.append("\n💡 This is a built-in Variant type. Use `read_file` to view full docs from the local documentation.")
		else:
			lines.append("\n💡 This is a built-in Variant type.")
		return "\n".join(lines)
	
	var parent: String = ClassDB.get_parent_class(p_class)
	if not parent.is_empty():
		lines.append("**Inherits:** `%s`" % parent)
	
	var constants: PackedStringArray = ClassDB.class_get_integer_constant_list(p_class, true)
	if not constants.is_empty():
		lines.append("\n**Constants:**")
		var limit := min(constants.size(), 8)
		for i in range(limit):
			var c_name: String = constants[i]
			var val: int = ClassDB.class_get_integer_constant(p_class, c_name)
			lines.append("- `%s` = %d" % [c_name, val])
		if constants.size() > limit:
			lines.append("- ... (%d more)" % (constants.size() - limit))
	
	var props: Array[Dictionary] = ClassDB.class_get_property_list(p_class, true)
	var prop_list: Array[String] = []
	for p in props:
		if p["usage"] & PROPERTY_USAGE_EDITOR or p["usage"] & PROPERTY_USAGE_SCRIPT_VARIABLE:
			prop_list.append("- `%s`: %s" % [p["name"], ClassDBUtils.type_to_string(p["type"])])
	
	if not prop_list.is_empty():
		lines.append("\n**Properties:**")
		if prop_list.size() > 15:
			lines.append_array(prop_list.slice(0, 15))
			lines.append("- ... (%d more)" % (prop_list.size() - 15))
		else:
			lines.append_array(prop_list)
	
	var signals: Array[Dictionary] = ClassDB.class_get_signal_list(p_class, true)
	if not signals.is_empty():
		lines.append("\n**Signals:**")
		var limit := min(signals.size(), 10)
		for i in range(limit):
			lines.append(ClassDBUtils.format_signal_signature(signals[i]))
		if signals.size() > limit:
			lines.append("- ... (%d more)" % (signals.size() - limit))
	
	var methods: Array[Dictionary] = ClassDB.class_get_method_list(p_class, true)
	if not methods.is_empty():
		lines.append("\n**Methods:**")
		var limit := min(methods.size(), 20)
		for i in range(limit):
			lines.append(ClassDBUtils.format_method_signature(methods[i]))
		if methods.size() > limit:
			lines.append("- ... (%d more)" % (methods.size() - limit))
	
	return "\n".join(lines)


# --- Private Functions: Member Formatting ---

func _format_member_results(p_results: Array[Dictionary]) -> String:
	var lines: Array[String] = []
	
	for result in p_results:
		if result.has("found_in_class"):
			lines.append(_format_inheritance_search_result(result))
		elif result.get("search_type") == "cross_class":
			lines.append(_format_cross_class_result(result))
	
	return "\n\n".join(lines)


func _format_inheritance_search_result(p_result: Dictionary) -> String:
	var lines: Array[String] = []
	var searched_class: String = p_result["searched_class"]
	var found_in: String = p_result["found_in_class"]
	var inheritance_chain: Array = p_result["inheritance_chain"]
	
	var member_name: String = ""
	var exact_methods: Array = p_result["methods"].filter(func(m): return m["exact"])
	var exact_signals: Array = p_result["signals"].filter(func(s): return s["exact"])
	var exact_properties: Array = p_result["properties"].filter(func(p): return p["exact"])
	
	if not exact_methods.is_empty():
		member_name = exact_methods[0]["name"]
	elif not exact_signals.is_empty():
		member_name = exact_signals[0]["name"]
	elif not exact_properties.is_empty():
		member_name = exact_properties[0]["name"]
	else:
		if not p_result["methods"].is_empty():
			member_name = p_result["methods"][0]["name"]
		elif not p_result["signals"].is_empty():
			member_name = p_result["signals"][0]["name"]
		elif not p_result["properties"].is_empty():
			member_name = p_result["properties"][0]["name"]
	
	lines.append("## `%s.%s`" % [searched_class, member_name])
	
	if searched_class != found_in:
		lines.append("**Defined in:** `%s`" % found_in)
		lines.append("**Inheritance:** `%s`" % " → ".join(inheritance_chain))
	else:
		lines.append("**Defined in:** `%s`" % found_in)
	
	if not exact_methods.is_empty():
		lines.append("\n**Method:**")
		for m in exact_methods:
			lines.append(ClassDBUtils.format_method_signature(m["data"]))
	
	if not exact_signals.is_empty():
		lines.append("\n**Signal:**")
		for s in exact_signals:
			lines.append(ClassDBUtils.format_signal_signature(s["data"]))
	
	if not exact_properties.is_empty():
		lines.append("\n**Property:**")
		for p in exact_properties:
			lines.append(ClassDBUtils.format_property_info(p["data"], found_in))
	
	var fuzzy_methods: Array = p_result["methods"].filter(func(m): return not m["exact"])
	var fuzzy_signals: Array = p_result["signals"].filter(func(s): return not s["exact"])
	var fuzzy_properties: Array = p_result["properties"].filter(func(p): return not p["exact"])
	
	if not fuzzy_methods.is_empty():
		lines.append("\n**Related methods:**")
		for m in fuzzy_methods.slice(0, 5):
			lines.append("- `%s()`" % m["name"])
		if fuzzy_methods.size() > 5:
			lines.append("- ... (%d more)" % (fuzzy_methods.size() - 5))
	
	if not fuzzy_signals.is_empty():
		lines.append("\n**Related signals:**")
		for s in fuzzy_signals.slice(0, 5):
			lines.append("- `%s`" % s["name"])
		if fuzzy_signals.size() > 5:
			lines.append("- ... (%d more)" % (fuzzy_signals.size() - 5))
	
	if not fuzzy_properties.is_empty():
		lines.append("\n**Related properties:**")
		for p in fuzzy_properties.slice(0, 5):
			lines.append("- `%s`" % p["name"])
		if fuzzy_properties.size() > 5:
			lines.append("- ... (%d more)" % (fuzzy_properties.size() - 5))
	
	return "\n".join(lines)


func _format_cross_class_result(p_result: Dictionary) -> String:
	var lines: Array[String] = []
	var member_name: String = p_result["member_name"]
	
	lines.append("## Cross-class Results: `%s`" % member_name)
	
	var exact_m: Array = p_result.get("exact_methods", [])
	var exact_s: Array = p_result.get("exact_signals", [])
	var exact_p: Array = p_result.get("exact_properties", [])
	var fuzzy_m: Array = p_result.get("fuzzy_methods", [])
	var fuzzy_s: Array = p_result.get("fuzzy_signals", [])
	var fuzzy_p: Array = p_result.get("fuzzy_properties", [])
	
	if not exact_m.is_empty():
		lines.append("\n**Methods (exact):**")
		for m in exact_m.slice(0, 10):
			lines.append("- `%s.%s` — %s" % [m["class"], m["name"], ClassDBUtils.get_method_short_info(m["data"])])
		if exact_m.size() > 10:
			lines.append("- ... (%d more)" % (exact_m.size() - 10))
	
	if not exact_s.is_empty():
		lines.append("\n**Signals (exact):**")
		for s in exact_s.slice(0, 10):
			lines.append("- `%s.%s` — %s" % [s["class"], s["name"], ClassDBUtils.get_signal_short_info(s["data"])])
		if exact_s.size() > 10:
			lines.append("- ... (%d more)" % (exact_s.size() - 10))
	
	if not exact_p.is_empty():
		lines.append("\n**Properties (exact):**")
		for p in exact_p.slice(0, 10):
			lines.append("- `%s.%s` → %s" % [p["class"], p["name"], ClassDBUtils.type_to_string(p["data"]["type"])])
		if exact_p.size() > 10:
			lines.append("- ... (%d more)" % (exact_p.size() - 10))
	
	if not fuzzy_m.is_empty():
		lines.append("\n**Methods (fuzzy):**")
		for m in fuzzy_m.slice(0, 5):
			lines.append("- `%s.%s()`" % [m["class"], m["name"]])
		if fuzzy_m.size() > 5:
			lines.append("- ... (%d more)" % (fuzzy_m.size() - 5))
	
	if not fuzzy_s.is_empty():
		lines.append("\n**Signals (fuzzy):**")
		for s in fuzzy_s.slice(0, 5):
			lines.append("- `%s.%s`" % [s["class"], s["name"]])
		if fuzzy_s.size() > 5:
			lines.append("- ... (%d more)" % (fuzzy_s.size() - 5))
	
	if not fuzzy_p.is_empty():
		lines.append("\n**Properties (fuzzy):**")
		for p in fuzzy_p.slice(0, 5):
			lines.append("- `%s.%s`" % [p["class"], p["name"]])
		if fuzzy_p.size() > 5:
			lines.append("- ... (%d more)" % (fuzzy_p.size() - 5))
	
	lines.append("\n💡 Search `ClassName.member_name` for full signature and inheritance info.")
	
	return "\n".join(lines)


func _format_failed_searches(p_failed: Array[Dictionary]) -> String:
	var lines: Array[String] = []
	
	for fail in p_failed:
		lines.append("## `%s.%s` — not found" % [fail["class"], fail["member"]])
		lines.append("No member named `%s` in class `%s` or its parent classes.\n" % [fail["member"], fail["class"]])
		
		var suggestions: Dictionary = fail["suggestions"]
		var has_suggestions: bool = false
		
		if suggestions.has("in_parent"):
			has_suggestions = true
			lines.append("**Found in parent class:**")
			for item in suggestions["in_parent"]:
				lines.append("- `%s.%s` — %s" % [item["class"], item["name"], item["type"]])
		
		if suggestions.has("in_child"):
			has_suggestions = true
			lines.append("**Found in subclasses:**")
			for item in suggestions["in_child"]:
				lines.append("- `%s.%s` — %s" % [item["class"], item["name"], item["type"]])
		
		if suggestions.has("similar"):
			has_suggestions = true
			lines.append("**Similar names in `%s`:**" % fail["class"])
			for item in suggestions["similar"]:
				lines.append("- `%s` — %s" % [item["name"], item["type"]])
		
		if not has_suggestions:
			lines.append("💡 Try searching `%s` across all classes (without class prefix)" % fail["member"])
	
	return "\n".join(lines)


# --- Private Functions: Local File Search ---

func _search_local_files_multi(p_path: String, p_keywords: PackedStringArray) -> String:
	var files: Array = _get_files_recursive(p_path)
	var matches := []
	
	var keywords_lower: Array[String] = []
	for k in p_keywords:
		keywords_lower.append(k.to_lower())
	
	var expanded_keywords: Array[String] = []
	for k in keywords_lower:
		expanded_keywords.append(k)
		if k.begins_with("@"):
			expanded_keywords.append(k.trim_prefix("@"))
	
	for f in files:
		var fname_lower: String = f.get_file().to_lower()
		for k in expanded_keywords:
			if k in fname_lower:
				var basename: String = f.get_file().get_basename().to_lower()
				if basename in expanded_keywords:
					matches.push_front(f)
				else:
					matches.append(f)
				break
	
	if matches.is_empty():
		return ""
	
	var lines: Array[String] = []
	lines.append("📁 **Local Docs Available (read for full API details):**")
	
	var limit := 10
	var display_count := min(matches.size(), limit)
	for i in range(display_count):
		lines.append("- `%s`" % matches[i])
	
	if matches.size() > limit:
		lines.append("- ... (%d more)" % (matches.size() - limit))
	
	lines.append("\n💡 **Tip:** Use `read_file` to open matched docs above — they contain descriptions, code examples, and parameter details beyond the ClassDB summary.")
	
	return "\n".join(lines)


func _search_custom_class_member(p_class: String, p_member_lower: String) -> Dictionary:
	var cls_dict: Dictionary = {}
	for d in ProjectSettings.get_global_class_list():
		if d.get("class", "").to_lower() == p_class.to_lower():
			cls_dict = d
			break
	if cls_dict.is_empty():
		return {}
	
	# 1. ClassDB 搜索（方法、信号）
	var result: Dictionary = {}
	if ClassDB.class_exists(p_class):
		result = ClassDBUtils.search_member_in_single_class(p_class, p_member_lower)
		if not result.is_empty():
			result["searched_class"] = p_class
			result["found_in_class"] = p_class
			result["inheritance_chain"] = ClassDBUtils.get_class_inheritance_chain(p_class)
			return result
	
	# 2. 源码回退（属性、常量等 ClassDB 不暴露的）
	var script_path: String = cls_dict.get("path", "")
	if script_path.is_empty() or not FileAccess.file_exists(script_path):
		return {}
	
	var source: String = FileAccess.get_file_as_string(script_path)
	var parsed: Dictionary = ClassDBUtils.parse_gdscript_docs(source)
	
	result["methods"] = []
	result["signals"] = []
	result["properties"] = []
	var found: bool = false
	
	for p in parsed.get("properties", []):
		var pname_lower: String = p["name"].to_lower()
		result["properties"].append({
			"name": p["name"],
			"data": {
				"name": p["name"],
				"type": TYPE_STRING,
				"usage": PROPERTY_USAGE_DEFAULT
			},
			"exact": pname_lower == p_member_lower,
			"type": "property"
		})
		if pname_lower == p_member_lower:
			found = true
	
	if not found:
		return {}
	
	result["searched_class"] = p_class
	result["found_in_class"] = p_class
	result["inheritance_chain"] = [p_class]
	return result


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
