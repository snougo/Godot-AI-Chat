@tool
class_name ClassDBUtils
extends RefCounted

## ClassDB 查询 + API 格式化 + 自定义类文档解析 工具集


# --- Public: 查询 ---

static func get_class_inheritance_chain(p_class: String) -> Array[String]:
	var chain: Array[String] = [p_class]
	var current: String = p_class
	
	while true:
		var parent: String = ClassDB.get_parent_class(current)
		if parent.is_empty():
			break
		chain.append(parent)
		current = parent
	
	return chain


static func search_member_with_inheritance(p_class_name: String, p_member_name: String, p_all_classes: PackedStringArray) -> Dictionary:
	var target_class: String = ""
	for cls in p_all_classes:
		if cls.to_lower() == p_class_name.to_lower():
			target_class = cls
			break
	
	if target_class.is_empty():
		return {}
	
	var inheritance_chain: Array[String] = get_class_inheritance_chain(target_class)
	var member_lower: String = p_member_name.to_lower()
	
	for cls in inheritance_chain:
		var result: Dictionary = search_member_in_single_class(cls, member_lower)
		if not result.is_empty():
			result["searched_class"] = target_class
			result["found_in_class"] = cls
			result["inheritance_chain"] = inheritance_chain
			return result
	
	return {}


static func search_member_in_single_class(p_class: String, p_member_lower: String) -> Dictionary:
	var result: Dictionary = {}
	
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


static func search_member_across_classes(p_member_name: String, p_all_classes: PackedStringArray) -> Dictionary:
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


static func generate_smart_suggestions(p_class_name: String, p_member_name: String, p_all_classes: PackedStringArray) -> Dictionary:
	var suggestions: Dictionary = {}
	var member_lower: String = p_member_name.to_lower()
	
	var target_class: String = ""
	for cls in p_all_classes:
		if cls.to_lower() == p_class_name.to_lower():
			target_class = cls
			break
	
	if not target_class.is_empty():
		var inheritance_chain: Array[String] = get_class_inheritance_chain(target_class)
		var found_in_parent: Array[Dictionary] = []
		
		for cls in inheritance_chain:
			if cls == target_class:
				continue
			
			var result: Dictionary = search_member_in_single_class(cls, member_lower)
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
	
	var child_classes: Array[String] = get_child_classes(target_class, p_all_classes)
	var found_in_child: Array[Dictionary] = []
	
	for cls in child_classes:
		var result: Dictionary = search_member_in_single_class(cls, member_lower)
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
	
	if not target_class.is_empty():
		var similar_names: Array[Dictionary] = find_similar_members(target_class, member_lower)
		if not similar_names.is_empty():
			suggestions["similar"] = similar_names
	
	return suggestions


static func get_child_classes(p_parent_class: String, p_all_classes: PackedStringArray) -> Array[String]:
	var children: Array[String] = []
	for cls in p_all_classes:
		if ClassDB.get_parent_class(cls) == p_parent_class:
			children.append(cls)
	return children


static func find_similar_members(p_class: String, p_member_lower: String) -> Array[Dictionary]:
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


# --- Public: 格式化 ---

static func type_to_string(p_type: int) -> String:
	if p_type == TYPE_NIL:
		return "void"
	return type_string(p_type)


static func format_method_signature(p_method: Dictionary) -> String:
	var args_str: Array[String] = []
	for arg in p_method["args"]:
		var default_val: String = ""
		if arg.has("default_value"):
			default_val = " = " + str(arg["default_value"])
		args_str.append("%s: %s%s" % [arg["name"], type_to_string(arg["type"]), default_val])
	
	var return_type: String = get_return_type(p_method)
	return "- `%s(%s) → %s`" % [p_method["name"], ", ".join(args_str), return_type]


static func get_method_short_info(p_method: Dictionary) -> String:
	var arg_count: int = p_method.get("args", []).size()
	var return_type: String = get_return_type(p_method)
	return "(%d args) → %s" % [arg_count, return_type]


static func get_return_type(p_method: Dictionary) -> String:
	if p_method.has("return"):
		return type_to_string(p_method["return"]["type"])
	return "void"


static func format_signal_signature(p_signal: Dictionary) -> String:
	var args_str: Array[String] = []
	if p_signal.has("args"):
		for arg in p_signal["args"]:
			args_str.append("%s: %s" % [arg["name"], type_to_string(arg["type"])])
	return "- `%s(%s)`" % [p_signal["name"], ", ".join(args_str)]


static func get_signal_short_info(p_signal: Dictionary) -> String:
	var arg_count: int = p_signal.get("args", []).size()
	return "(%d args)" % arg_count


static func format_property_info(p_property: Dictionary, p_class: String) -> String:
	var type_str: String = type_to_string(p_property["type"])
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


# --- Public: 自定义类文档解析 ---

static func format_global_class_detailed(p_class: String, p_info: Dictionary) -> String:
	var lines: Array[String] = []
	lines.append("## Class: `%s`" % p_class)
	lines.append("**Type:** Custom Global Script Class")
	
	var base_class: String = p_info.get("base", "")
	if not base_class.is_empty():
		lines.append("**Inherits:** `%s`" % base_class)
	
	var script_path: String = p_info.get("path", "")
	if not script_path.is_empty():
		lines.append("**Script:** `%s`" % script_path)
	
	var language: String = p_info.get("language", "")
	if not language.is_empty():
		lines.append("**Language:** %s" % language)
	
	if p_info.get("is_tool", false):
		lines.append("**Tool:** `@tool`")
	
	var source: String = ""
	if not script_path.is_empty() and FileAccess.file_exists(script_path):
		source = FileAccess.get_file_as_string(script_path)
	
	if not source.is_empty():
		var parsed: Dictionary = parse_gdscript_docs(source)
		
		if not parsed.get("class_description", "").is_empty():
			lines.append("\n" + parsed["class_description"])
		
		var constants: Array = parsed.get("constants", [])
		if not constants.is_empty():
			lines.append("\n**Constants:**")
			for c in constants:
				var entry: String = "- `%s`" % c["name"]
				if not c.get("value", "").is_empty():
					entry += " = %s" % c["value"]
				if not c.get("description", "").is_empty():
					entry += " — %s" % c["description"]
				lines.append(entry)
		
		var properties: Array = parsed.get("properties", [])
		if not properties.is_empty():
			lines.append("\n**Properties:**")
			for p in properties:
				var entry: String = "- `%s: %s`" % [p["name"], p["type"]]
				if not p.get("default", "").is_empty():
					entry += " = %s" % p["default"]
				if not p.get("description", "").is_empty():
					entry += " — %s" % p["description"]
				lines.append(entry)
		
		var signals: Array = parsed.get("signals", [])
		if not signals.is_empty():
			lines.append("\n**Signals:**")
			for s in signals:
				var entry: String = "- `%s(%s)`" % [s["name"], s.get("args", "")]
				if not s.get("description", "").is_empty():
					entry += " — %s" % s["description"]
				lines.append(entry)
		
		var methods: Array = parsed.get("methods", [])
		if not methods.is_empty():
			lines.append("\n**Methods:**")
			for m in methods:
				var entry: String = "- `%s(%s)`" % [m["name"], m.get("args", "")]
				if not m.get("return_type", "").is_empty():
					entry += " → %s" % m["return_type"]
				if not m.get("description", "").is_empty():
					entry += " — %s" % m["description"]
				lines.append(entry)
	else:
		lines.append("\n💡 This is a custom global class. Use `open_file` to open its script or `read_file` to view its source.")
	
	return "\n".join(lines)


static func parse_gdscript_docs(p_source: String) -> Dictionary:
	var result: Dictionary = {
		"class_description": "",
		"constants": [],
		"properties": [],
		"signals": [],
		"methods": []
	}
	
	var pending_doc: String = ""
	var source_lines: PackedStringArray = p_source.split("\n")
	
	# 状态追踪：是否在 extends 之后、第一个声明之前的"类头"区域
	var in_class_header: bool = false
	
	var re_doc: RegEx = RegEx.create_from_string("^##\\s?(.*)")
	var re_const: RegEx = RegEx.create_from_string("^const\\s+([A-Z_][A-Z0-9_]*)\\s*=\\s*(.+)")
	# 支持 @export_file("*.md"), @export_range(1,100), @export_multiline 等带参注解
	# 同时支持 Array[String], Dictionary 等复合类型
	var re_export_var: RegEx = RegEx.create_from_string(
		"^@export(?:_\\w+)?(?:\\(.*?\\))?\\s+var\\s+(\\w+)\\s*:\\s*([\\w\\[\\]]+)\\s*(?:=\\s*(.+?))?\\s*$"
	)
	
	var re_var: RegEx = RegEx.create_from_string("^var\\s+(\\w+)\\s*:\\s*(\\w+)\\s*(?:=\\s*(.+?))?\\s*$")
	var re_signal: RegEx = RegEx.create_from_string("^signal\\s+(\\w+)\\s*(?:\\((.*?)\\))?")
	var re_func: RegEx = RegEx.create_from_string(
		"^(?:static\\s+)?func\\s+(\\w+)\\s*\\((.*?)\\)\\s*(?:->\\s*([\\w\\[\\],\\s]+))?\\s*:?\\s*$"
	)
	
	var re_class_name: RegEx = RegEx.create_from_string("^class_name\\s+\\w+")
	var re_enum: RegEx = RegEx.create_from_string("^enum\\s+(\\w+)")
	# 识别 # --- xxx --- 类分隔行
	var re_separator: RegEx = RegEx.create_from_string("^#\\s*-{3,}")
	
	for line in source_lines:
		# --- Doc comments ---
		var doc_match: RegExMatch = re_doc.search(line)
		if doc_match:
			var doc_text: String = doc_match.get_string(1).strip_edges()
			if pending_doc.is_empty():
				pending_doc = doc_text
			else:
				pending_doc += " " + doc_text
			continue
		
		# --- class_name ---
		if re_class_name.search(line):
			if not pending_doc.is_empty() and result["class_description"].is_empty():
				result["class_description"] = pending_doc
				pending_doc = ""
			continue
		
		# --- extends —— 进入类头区域，后续 ## 注释将累积为类描述 ---
		if line.begins_with("extends"):
			in_class_header = true
			pending_doc = ""
			continue
		
		# --- @tool / @icon ---
		if line.begins_with("@tool") or line.begins_with("@icon"):
			pending_doc = ""
			continue
		
		# --- 分隔行 (# --- xxx ---) —— 不丢弃 pending_doc，捕获类描述 ---
		if re_separator.search(line):
			if in_class_header and not pending_doc.is_empty() \
					and result["class_description"].is_empty():
				result["class_description"] = pending_doc.strip_edges()
				pending_doc = ""
			in_class_header = false
			continue
		
		# --- 退出类头区域：遇到声明前的非空、非分隔行，保存类描述 ---
		if in_class_header and not pending_doc.is_empty() \
				and not line.strip_edges().is_empty():
			if result["class_description"].is_empty():
				result["class_description"] = pending_doc.strip_edges()
			pending_doc = ""
			in_class_header = false
		
		# --- Constants ---
		var const_match: RegExMatch = re_const.search(line)
		if const_match:
			result["constants"].append({
				"name": const_match.get_string(1),
				"value": const_match.get_string(2).strip_edges(),
				"description": pending_doc
			})
			pending_doc = ""
			continue
		
		# --- Enums ---
		var enum_match: RegExMatch = re_enum.search(line)
		if enum_match:
			result["constants"].append({
				"name": enum_match.get_string(1),
				"value": "(enum)",
				"description": pending_doc
			})
			pending_doc = ""
			continue
		
		# --- @export var (支持 @export_file, @export_multiline, @export_range 等) ---
		var export_match: RegExMatch = re_export_var.search(line)
		if export_match:
			result["properties"].append({
				"name": export_match.get_string(1),
				"type": export_match.get_string(2),
				"default": export_match.get_string(3).strip_edges() \
						if export_match.get_string(3) else "",
				"description": pending_doc
			})
			pending_doc = ""
			continue
		
		# --- Signal ---
		var signal_match: RegExMatch = re_signal.search(line)
		if signal_match:
			result["signals"].append({
				"name": signal_match.get_string(1),
				"args": signal_match.get_string(2).strip_edges() \
						if signal_match.get_string(2) else "",
				"description": pending_doc
			})
			pending_doc = ""
			continue
		
		# --- Function ---
		var func_match: RegExMatch = re_func.search(line)
		if func_match:
			result["methods"].append({
				"name": func_match.get_string(1),
				"args": func_match.get_string(2).strip_edges(),
				"return_type": func_match.get_string(3),
				"description": pending_doc
			})
			pending_doc = ""
			continue
		
		# --- Non-@export var (仅有 doc 注释时捕获) ---
		var var_match: RegExMatch = re_var.search(line)
		if var_match and not pending_doc.is_empty():
			result["properties"].append({
				"name": var_match.get_string(1),
				"type": var_match.get_string(2),
				"default": var_match.get_string(3).strip_edges() \
						if var_match.get_string(3) else "",
				"description": pending_doc
			})
			pending_doc = ""
			continue
		
		# --- 非匹配的非空行 → 丢弃累积的 doc ---
		if not line.strip_edges().is_empty():
			pending_doc = ""
	
	return result
