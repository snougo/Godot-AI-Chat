@tool
extends AiTool

## 搜索 Godot ClassDB 和本地 API 文档。
## 支持搜索类、方法、信号、属性（支持精确和跨类搜索）。
## 包含继承链搜索和智能提示功能。

# --- Constants ---

const LOCAL_DOC_PATH: String = "res://godot_doc"

# --- Built-in Functions ---

func _init() -> void:
	tool_name = "search_api_documents"
	tool_description = "Searches Godot ClassDB and local API docs. Supports searching for classes, methods, signals, and properties with inheritance chain search and smart suggestions."


# --- Public Functions ---

func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"keywords": {
				"type": "string",
				"description": "Search keywords. Only support Class Name to search.\n> Do not search for multiple keywords at the same time."
			}
		},
		"required": ["keywords"]
	}


func execute(p_args: Dictionary) -> Dictionary:
	var raw_keywords: Variant = p_args.get("keywords", "")
	var keywords_list: PackedStringArray = _parse_keywords(raw_keywords)
	
	if keywords_list.is_empty():
		return {"success": false, "data": "Error: Keywords cannot be empty."}
	
	var output: Array[String] = []
	var found_any: bool = false
	
	var api_result: String = _search_builtin_api_multi(keywords_list)
	if not api_result.is_empty():
		found_any = true
		output.append(api_result)
	
	var file_result: String = _search_local_files_multi(LOCAL_DOC_PATH, keywords_list)
	if not file_result.is_empty():
		found_any = true
		output.append("\n---\n" + file_result)
	
	if not found_any:
		return {"success": false, "data": "No API definition or local docs found for: %s" % ", ".join(keywords_list)}
	
	return {"success": true, "data": "\n".join(output)}


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
		
		# 检测 "Class.member" 格式
		if "." in kw:
			var parts: PackedStringArray = kw.split(".", false, 1)
			if parts.size() == 2:
				var target_class: String = parts[0]
				var member_name: String = parts[1]
				var result: Dictionary = _search_member_with_inheritance(target_class, member_name, all_classes)
				
				if not result.is_empty():
					member_results.append(result)
				else:
					var suggestions: Dictionary = _generate_smart_suggestions(target_class, member_name, all_classes)
					failed_searches.append({
						"class": target_class,
						"member": member_name,
						"suggestions": suggestions
					})
				continue
		
		# 尝试作为类名
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
		
		# 不是类名，尝试成员搜索
		if not found_class:
			var member_search: Dictionary = _search_member_across_classes(kw, all_classes)
			if not member_search.is_empty():
				member_results.append(member_search)
		
		# 模糊匹配类名
		for cls in all_classes:
			if kw_lower in cls.to_lower():
				if cls not in class_exact and cls not in class_fuzzy:
					class_fuzzy.append(cls)
	
	# 构建结果
	var sb: Array[String] = []
	
	# 类搜索结果（详细显示）
	if not class_exact.is_empty() or not class_fuzzy.is_empty():
		sb.append(_format_class_results_detailed(class_exact, class_fuzzy))
	
	# 成员搜索结果
	if not member_results.is_empty():
		sb.append(_format_member_results(member_results))
	
	# 失败搜索的智能提示
	if not failed_searches.is_empty():
		sb.append(_format_failed_searches(failed_searches))
	
	return "\n\n".join(sb)


# --- Private Functions: Inheritance Chain Search ---

func _get_class_inheritance_chain(p_class: String) -> Array[String]:
	var chain: Array[String] = [p_class]
	var current: String = p_class
	
	while true:
		var parent: String = ClassDB.get_parent_class(current)
		if parent.is_empty():
			break
		chain.append(parent)
		current = parent
	
	return chain


func _search_member_with_inheritance(p_class_name: String, p_member_name: String, p_all_classes: PackedStringArray) -> Dictionary:
	var target_class: String = ""
	for cls in p_all_classes:
		if cls.to_lower() == p_class_name.to_lower():
			target_class = cls
			break
	
	if target_class.is_empty():
		return {}
	
	var inheritance_chain: Array[String] = _get_class_inheritance_chain(target_class)
	var member_lower: String = p_member_name.to_lower()
	
	for cls in inheritance_chain:
		var result: Dictionary = _search_member_in_single_class(cls, member_lower)
		if not result.is_empty():
			result["searched_class"] = target_class
			result["found_in_class"] = cls
			result["inheritance_chain"] = inheritance_chain
			return result
	
	return {}


func _search_member_in_single_class(p_class: String, p_member_lower: String) -> Dictionary:
	var result: Dictionary = {}
	
	# 使用 no_inheritance=true 只搜索当前类定义的成员
	var methods: Array[Dictionary] = ClassDB.class_get_method_list(p_class, true)
	var matched_methods: Array[Dictionary] = []
	for m in methods:
		var m_name: String = m["name"]
		if m_name.to_lower() == p_member_lower:
			matched_methods.append({"name": m_name, "data": m, "exact": true, "type": "method"})
		elif p_member_lower in m_name.to_lower():
			matched_methods.append({"name": m_name, "data": m, "exact": false, "type": "method"})
	
	var signals: Array[Dictionary] = ClassDB.class_get_signal_list(p_class, true)
	var matched_signals: Array[Dictionary] = []
	for s in signals:
		var s_name: String = s["name"]
		if s_name.to_lower() == p_member_lower:
			matched_signals.append({"name": s_name, "data": s, "exact": true, "type": "signal"})
		elif p_member_lower in s_name.to_lower():
			matched_signals.append({"name": s_name, "data": s, "exact": false, "type": "signal"})
	
	var properties: Array[Dictionary] = ClassDB.class_get_property_list(p_class, true)
	var matched_properties: Array[Dictionary] = []
	for p in properties:
		var p_name: String = p["name"]
		if p_name.to_lower() == p_member_lower:
			matched_properties.append({"name": p_name, "data": p, "exact": true, "type": "property"})
		elif p_member_lower in p_name.to_lower():
			matched_properties.append({"name": p_name, "data": p, "exact": false, "type": "property"})
	
	if matched_methods.is_empty() and matched_signals.is_empty() and matched_properties.is_empty():
		return {}
	
	result["methods"] = matched_methods
	result["signals"] = matched_signals
	result["properties"] = matched_properties
	
	return result


# --- Private Functions: Cross-Class Search ---

func _search_member_across_classes(p_member_name: String, p_all_classes: PackedStringArray) -> Dictionary:
	var member_lower: String = p_member_name.to_lower()
	
	var exact_methods: Array[Dictionary] = []
	var fuzzy_methods: Array[Dictionary] = []
	var exact_signals: Array[Dictionary] = []
	var fuzzy_signals: Array[Dictionary] = []
	var exact_properties: Array[Dictionary] = []
	var fuzzy_properties: Array[Dictionary] = []
	
	for cls in p_all_classes:
		var methods: Array[Dictionary] = ClassDB.class_get_method_list(cls, true)
		for m in methods:
			var m_name: String = m["name"]
			if m_name.to_lower() == member_lower:
				exact_methods.append({"class": cls, "name": m_name, "data": m})
			elif member_lower in m_name.to_lower():
				fuzzy_methods.append({"class": cls, "name": m_name, "data": m})
		
		var signals: Array[Dictionary] = ClassDB.class_get_signal_list(cls, true)
		for s in signals:
			var s_name: String = s["name"]
			if s_name.to_lower() == member_lower:
				exact_signals.append({"class": cls, "name": s_name, "data": s})
			elif member_lower in s_name.to_lower():
				fuzzy_signals.append({"class": cls, "name": s_name, "data": s})
		
		var properties: Array[Dictionary] = ClassDB.class_get_property_list(cls, true)
		for p in properties:
			var p_name: String = p["name"]
			if p_name.to_lower() == member_lower:
				exact_properties.append({"class": cls, "name": p_name, "data": p})
			elif member_lower in p_name.to_lower():
				fuzzy_properties.append({"class": cls, "name": p_name, "data": p})
	
	if exact_methods.is_empty() and fuzzy_methods.is_empty() \
		and exact_signals.is_empty() and fuzzy_signals.is_empty() \
		and exact_properties.is_empty() and fuzzy_properties.is_empty():
		return {}
	
	return {
		"member_name": p_member_name,
		"search_type": "cross_class",
		"exact_methods": exact_methods,
		"fuzzy_methods": fuzzy_methods,
		"exact_signals": exact_signals,
		"fuzzy_signals": fuzzy_signals,
		"exact_properties": exact_properties,
		"fuzzy_properties": fuzzy_properties
	}


# --- Private Functions: Smart Suggestions ---

func _generate_smart_suggestions(p_class_name: String, p_member_name: String, p_all_classes: PackedStringArray) -> Dictionary:
	var suggestions: Dictionary = {}
	var member_lower: String = p_member_name.to_lower()
	
	var target_class: String = ""
	for cls in p_all_classes:
		if cls.to_lower() == p_class_name.to_lower():
			target_class = cls
			break
	
	if not target_class.is_empty():
		var inheritance_chain: Array[String] = _get_class_inheritance_chain(target_class)
		var found_in_parent: Array[Dictionary] = []
		
		for cls in inheritance_chain:
			if cls == target_class:
				continue
			
			var result: Dictionary = _search_member_in_single_class(cls, member_lower)
			if not result.is_empty():
				for m in result.get("methods", []):
					if m["exact"]:
						found_in_parent.append({"class": cls, "name": m["name"], "type": "method"})
				for s in result.get("signals", []):
					if s["exact"]:
						found_in_parent.append({"class": cls, "name": s["name"], "type": "signal"})
				for p in result.get("properties", []):
					if p["exact"]:
						found_in_parent.append({"class": cls, "name": p["name"], "type": "property"})
		
		if not found_in_parent.is_empty():
			suggestions["in_parent"] = found_in_parent
	
	var child_classes: Array[String] = _get_child_classes(target_class, p_all_classes)
	var found_in_child: Array[Dictionary] = []
	
	for cls in child_classes:
		var result: Dictionary = _search_member_in_single_class(cls, member_lower)
		if not result.is_empty():
			for m in result.get("methods", []):
				if m["exact"]:
					found_in_child.append({"class": cls, "name": m["name"], "type": "method"})
			for s in result.get("signals", []):
				if s["exact"]:
					found_in_child.append({"class": cls, "name": s["name"], "type": "signal"})
			for p in result.get("properties", []):
				if p["exact"]:
					found_in_child.append({"class": cls, "name": p["name"], "type": "property"})
		
		if found_in_child.size() >= 3:
			break
	
	if not found_in_child.is_empty():
		suggestions["in_child"] = found_in_child
	
	var similar_names: Array[Dictionary] = _find_similar_members(target_class, member_lower)
	if not similar_names.is_empty():
		suggestions["similar"] = similar_names
	
	return suggestions


func _get_child_classes(p_parent_class: String, p_all_classes: PackedStringArray) -> Array[String]:
	var children: Array[String] = []
	for cls in p_all_classes:
		if ClassDB.get_parent_class(cls) == p_parent_class:
			children.append(cls)
	return children


func _find_similar_members(p_class: String, p_member_lower: String) -> Array[Dictionary]:
	var similar: Array[Dictionary] = []
	
	var methods: Array[Dictionary] = ClassDB.class_get_method_list(p_class, false)
	for m in methods:
		var m_name: String = m["name"]
		var m_lower: String = m_name.to_lower()
		if m_lower.begins_with(p_member_lower) or p_member_lower.begins_with(m_lower):
			similar.append({"name": m_name, "type": "method"})
			if similar.size() >= 3:
				break
	
	if similar.size() < 3:
		var signals: Array[Dictionary] = ClassDB.class_get_signal_list(p_class, false)
		for s in signals:
			var s_name: String = s["name"]
			var s_lower: String = s_name.to_lower()
			if s_lower.begins_with(p_member_lower) or p_member_lower.begins_with(s_lower):
				similar.append({"name": s_name, "type": "signal"})
				if similar.size() >= 3:
					break
	
	if similar.size() < 3:
		var properties: Array[Dictionary] = ClassDB.class_get_property_list(p_class, false)
		for p in properties:
			var p_name: String = p["name"]
			var p_lower: String = p_name.to_lower()
			if p_lower.begins_with(p_member_lower) or p_member_lower.begins_with(p_lower):
				similar.append({"name": p_name, "type": "property"})
				if similar.size() >= 3:
					break
	
	return similar


# --- Private Functions: Class Formatting (Detailed) ---

func _format_class_results_detailed(p_exact: Array[String], p_fuzzy: Array[String]) -> String:
	var sb: Array[String] = []
	
	for cls in p_exact:
		sb.append(_format_class_detailed(cls))
	
	if not p_fuzzy.is_empty():
		if p_exact.is_empty():
			sb.append("## Related Classes\n")
			sb.append("No exact match. Related classes:\n")
			var count := 0
			for cls in p_fuzzy:
				if count < 3:
					sb.append(_format_class_detailed(cls))
				else:
					break
				count += 1
			
			if p_fuzzy.size() > 3:
				sb.append("\n**Other related:** " + ", ".join(p_fuzzy.slice(3, 10)))
				if p_fuzzy.size() > 10:
					sb[-1] += " ... (%d more)" % (p_fuzzy.size() - 10)
		else:
			sb.append("\n**Also found:** " + ", ".join(p_fuzzy.slice(0, 5)))
			if p_fuzzy.size() > 5:
				sb[-1] += " ... (%d more)" % (p_fuzzy.size() - 5)
	
	return "\n\n".join(sb)


func _format_class_detailed(p_class: String) -> String:
	var sb: Array[String] = []
	sb.append("## Class: `%s`" % p_class)
	
	# 继承
	var parent: String = ClassDB.get_parent_class(p_class)
	if not parent.is_empty():
		sb.append("**Inherits:** `%s`" % parent)
	
	# 常量
	var constants: PackedStringArray = ClassDB.class_get_integer_constant_list(p_class, true)
	if not constants.is_empty():
		sb.append("\n**Constants:**")
		var limit := min(constants.size(), 8)
		for i in range(limit):
			var c_name: String = constants[i]
			var val: int = ClassDB.class_get_integer_constant(p_class, c_name)
			sb.append("- `%s` = %d" % [c_name, val])
		if constants.size() > limit:
			sb.append("- ... (%d more)" % (constants.size() - limit))
	
	# 属性（详细显示）
	var props: Array[Dictionary] = ClassDB.class_get_property_list(p_class, true)
	var prop_list: Array[String] = []
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
	
	# 信号（详细显示）
	var signals: Array[Dictionary] = ClassDB.class_get_signal_list(p_class, true)
	if not signals.is_empty():
		sb.append("\n**Signals:**")
		var limit := min(signals.size(), 10)
		for i in range(limit):
			sb.append(_format_signal_signature(signals[i]))
		if signals.size() > limit:
			sb.append("- ... (%d more)" % (signals.size() - limit))
	
	# 方法（详细显示）
	var methods: Array[Dictionary] = ClassDB.class_get_method_list(p_class, true)
	if not methods.is_empty():
		sb.append("\n**Methods:**")
		var limit := min(methods.size(), 20)
		for i in range(limit):
			sb.append(_format_method_signature(methods[i]))
		if methods.size() > limit:
			sb.append("- ... (%d more)" % (methods.size() - limit))
	
	return "\n".join(sb)


# --- Private Functions: Member Formatting ---

func _format_member_results(p_results: Array[Dictionary]) -> String:
	var sb: Array[String] = []
	
	for result in p_results:
		if result.has("found_in_class"):
			# 精确搜索结果（带继承信息）
			sb.append(_format_inheritance_search_result(result))
		elif result.get("search_type") == "cross_class":
			# 跨类搜索结果
			sb.append(_format_cross_class_result(result))
	
	return "\n\n".join(sb)


func _format_inheritance_search_result(p_result: Dictionary) -> String:
	var sb: Array[String] = []
	var searched_class: String = p_result["searched_class"]
	var found_in: String = p_result["found_in_class"]
	var inheritance_chain: Array = p_result["inheritance_chain"]
	
	# 确定成员名称（优先精确匹配）
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
	
	# 标题
	sb.append("## `%s.%s`" % [searched_class, member_name])
	
	# 继承信息
	if searched_class != found_in:
		sb.append("📍 **Defined in:** `%s` (parent class)" % found_in)
		sb.append("**Inheritance:** `%s`" % " → ".join(inheritance_chain))
	
	# 方法
	if not exact_methods.is_empty():
		sb.append("\n### 🔹 Method")
		for m in exact_methods:
			sb.append(_format_method_signature(m["data"]))
	
	# 信号
	if not exact_signals.is_empty():
		sb.append("\n### 🔹 Signal")
		for s in exact_signals:
			sb.append(_format_signal_signature(s["data"]))
	
	# 属性
	if not exact_properties.is_empty():
		sb.append("\n### 🔹 Property")
		for p in exact_properties:
			sb.append(_format_property_info(p["data"], found_in))
	
	# 相关成员（模糊匹配）
	var fuzzy_methods: Array = p_result["methods"].filter(func(m): return not m["exact"])
	var fuzzy_signals: Array = p_result["signals"].filter(func(s): return not s["exact"])
	var fuzzy_properties: Array = p_result["properties"].filter(func(p): return not p["exact"])
	
	if not fuzzy_methods.is_empty() or not fuzzy_signals.is_empty() or not fuzzy_properties.is_empty():
		sb.append("\n**Related members:**")
		var related: Array[String] = []
		for m in fuzzy_methods.slice(0, 3):
			related.append("`%s()` (method)" % m["name"])
		for s in fuzzy_signals.slice(0, 2):
			related.append("`%s` (signal)" % s["name"])
		for p in fuzzy_properties.slice(0, 2):
			related.append("`%s` (property)" % p["name"])
		sb.append(", ".join(related))
	
	return "\n".join(sb)


func _format_cross_class_result(p_result: Dictionary) -> String:
	var sb: Array[String] = []
	var member_name: String = p_result["member_name"]
	
	sb.append("## Search: `%s`" % member_name)
	
	var exact_m: Array = p_result.get("exact_methods", [])
	var exact_s: Array = p_result.get("exact_signals", [])
	var exact_p: Array = p_result.get("exact_properties", [])
	var fuzzy_m: Array = p_result.get("fuzzy_methods", [])
	var fuzzy_s: Array = p_result.get("fuzzy_signals", [])
	var fuzzy_p: Array = p_result.get("fuzzy_properties", [])
	
	# 精确匹配 - 方法
	if not exact_m.is_empty():
		sb.append("\n### 🔹 Methods (exact match)")
		for m in exact_m.slice(0, 10):
			sb.append("- **`%s.%s`** %s" % [m["class"], m["name"], _get_method_short_info(m["data"])])
		if exact_m.size() > 10:
			sb.append("- ... (%d more classes)" % (exact_m.size() - 10))
	
	# 精确匹配 - 信号
	if not exact_s.is_empty():
		sb.append("\n### 🔹 Signals (exact match)")
		for s in exact_s.slice(0, 10):
			sb.append("- **`%s.%s`** %s" % [s["class"], s["name"], _get_signal_short_info(s["data"])])
		if exact_s.size() > 10:
			sb.append("- ... (%d more classes)" % (exact_s.size() - 10))
	
	# 精确匹配 - 属性
	if not exact_p.is_empty():
		sb.append("\n### 🔹 Properties (exact match)")
		for p in exact_p.slice(0, 10):
			sb.append("- **`%s.%s`**: %s" % [p["class"], p["name"], _type_to_string(p["data"]["type"])])
		if exact_p.size() > 10:
			sb.append("- ... (%d more classes)" % (exact_p.size() - 10))
	
	# 模糊匹配
	if not fuzzy_m.is_empty() or not fuzzy_s.is_empty() or not fuzzy_p.is_empty():
		sb.append("\n**Related members:**")
		var related: Array[String] = []
		for m in fuzzy_m.slice(0, 3):
			related.append("`%s.%s()`" % [m["class"], m["name"]])
		for s in fuzzy_s.slice(0, 2):
			related.append("`%s.%s` (signal)" % [s["class"], s["name"]])
		for p in fuzzy_p.slice(0, 2):
			related.append("`%s.%s` (property)" % [p["class"], p["name"]])
		sb.append(", ".join(related))
		if fuzzy_m.size() + fuzzy_s.size() + fuzzy_p.size() > 7:
			sb[-1] += " ..."
	
	# 提示
	sb.append("\n💡 Use `ClassName.member_name` for detailed signature")
	
	return "\n".join(sb)


func _format_failed_searches(p_failed: Array[Dictionary]) -> String:
	var sb: Array[String] = []
	
	for fail in p_failed:
		sb.append("## ❌ `%s.%s` not found" % [fail["class"], fail["member"]])
		sb.append("No member named `%s` in class `%s` or its parent classes.\n" % [fail["member"], fail["class"]])
		
		var suggestions: Dictionary = fail["suggestions"]
		var has_suggestions: bool = false
		
		if suggestions.has("in_parent"):
			has_suggestions = true
			sb.append("💡 **Found in parent class:**")
			for item in suggestions["in_parent"]:
				sb.append("- **`%s.%s`** (%s)" % [item["class"], item["name"], item["type"]])
		
		if suggestions.has("in_child"):
			has_suggestions = true
			if suggestions.has("in_parent"):
				sb.append("")
			sb.append("💡 **Found in subclasses:**")
			for item in suggestions["in_child"]:
				sb.append("- **`%s.%s`** (%s)" % [item["class"], item["name"], item["type"]])
		
		if suggestions.has("similar"):
			has_suggestions = true
			if suggestions.has("in_parent") or suggestions.has("in_child"):
				sb.append("")
			sb.append("💡 **Similar names in this class:**")
			for item in suggestions["similar"]:
				sb.append("- `%s` (%s)" % [item["name"], item["type"]])
		
		if not has_suggestions:
			sb.append("💡 Try searching `%s` across all classes (without class prefix)" % fail["member"])
	
	return "\n".join(sb)


# --- Private Functions: Formatting Helpers ---

func _format_method_signature(p_method: Dictionary) -> String:
	var args_str: Array[String] = []
	for arg in p_method["args"]:
		var default_val: String = ""
		if arg.has("default_value"):
			default_val = " = " + str(arg["default_value"])
		args_str.append("%s: %s%s" % [arg["name"], _type_to_string(arg["type"]), default_val])
	
	var return_type: String = _get_return_type(p_method)
	return "- `%s(%s) → %s`" % [p_method["name"], ", ".join(args_str), return_type]


func _get_method_short_info(p_method: Dictionary) -> String:
	var arg_count: int = p_method.get("args", []).size()
	var return_type: String = _get_return_type(p_method)
	return "(%d args) → %s" % [arg_count, return_type]


func _get_return_type(p_method: Dictionary) -> String:
	if p_method.has("return"):
		return _type_to_string(p_method["return"]["type"])
	return "void"


func _format_signal_signature(p_signal: Dictionary) -> String:
	var args_str: Array[String] = []
	if p_signal.has("args"):
		for arg in p_signal["args"]:
			args_str.append("%s: %s" % [arg["name"], _type_to_string(arg["type"])])
	return "- `%s(%s)`" % [p_signal["name"], ", ".join(args_str)]


func _get_signal_short_info(p_signal: Dictionary) -> String:
	var arg_count: int = p_signal.get("args", []).size()
	return "(%d args)" % arg_count


func _format_property_info(p_property: Dictionary, p_class: String) -> String:
	var type_str: String = _type_to_string(p_property["type"])
	var hints: Array[String] = []
	
	var usage: int = p_property.get("usage", 0)
	if usage & PROPERTY_USAGE_READ_ONLY:
		hints.append("readonly")
	
	var getter: String = ClassDB.class_get_property_getter(p_class, p_property["name"])
	var setter: String = ClassDB.class_get_property_setter(p_class, p_property["name"])
	
	if not getter.is_empty() and not setter.is_empty():
		hints.append("get/set")
	elif not getter.is_empty():
		hints.append("getter only")
	elif not setter.is_empty():
		hints.append("setter only")
	
	var hint_str: String = ""
	if not hints.is_empty():
		hint_str = " [%s]" % ", ".join(hints)
	
	return "- `%s`: %s%s" % [p_property["name"], type_str, hint_str]


func _type_to_string(p_type: int) -> String:
	if p_type == TYPE_NIL:
		return "void"
	return type_string(p_type)


# --- Private Functions: Local File Search ---

func _search_local_files_multi(p_path: String, p_keywords: PackedStringArray) -> String:
	var files: Array = _get_files_recursive(p_path)
	var matches := []
	
	var keywords_lower: Array[String] = []
	for k in p_keywords:
		keywords_lower.append(k.to_lower())
	
	for f in files:
		var fname_lower: String = f.get_file().to_lower()
		for k in keywords_lower:
			if k in fname_lower:
				var basename: String = f.get_file().get_basename().to_lower()
				if basename in keywords_lower:
					matches.push_front(f)
				else:
					matches.append(f)
				break
	
	if matches.is_empty():
		return ""
	
	var sb: Array[String] = []
	sb.append("📁 **Local Docs:** `%s`" % "`, `".join(matches.slice(0, 5)))
	if matches.size() > 5:
		sb[-1] += " ... (%d more)" % (matches.size() - 5)
	
	return "\n".join(sb)


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
