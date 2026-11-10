@tool
class_name BaseSceneTool
extends AiTool

## 场景工具基类：路径解析 / 属性转换 / 编辑执行 / 回执拼装。
##
## 与旧版的差异（每条都对应一个已经踩到的坑）：
## 1. 路径解析不再"猜"：相对路径优先；裸名字只在场景内唯一时生效；歧义与未找到都返回可执行的提示。
## 2. 属性写入拆成 property + sub_path（数组），不再靠字符串里的冒号猜层级；旧的 "a:b:c" 写法仍兼容。
## 3. 值转换以原生 JSON 类型为主（数组 / 数字 / 布尔 / 对象），字符串解析只作兼容，
##    并为 "Vector3(1,2,3)" / "Transform3D(...)" 这类引擎写法留了 str_to_var 通道。
## 4. 写入不走 call_deferred：commit 之后立刻读回真实值，回执里的 new_value 是"读到的"而不是"想写的"。
## 5. 回执统一带 scene / saved / unsaved；整棵场景树只在 verbose 时返回。
## 6. 外部实例（instance）内部的节点不可增删移：提前拒绝，而不是"报成功、保存后消失"。
## 7. 多余参数一律报错：静默忽略 "node_path" 正是"节点加到错父级"的成因。


# --- Constants ---

## 候选列表（相近类名 / 相近属性名）最多回多少个
const MAX_CANDIDATES: int = 12

## 未写盘时回执附带的提醒
const SAVE_HINT: String = "Changes are in the editor only — call save_edited_file(file_type=\"scene\") or pass \"save\": true to write them to disk."

## 视为"场景根"的路径写法
const ROOT_ALIASES: Array[String] = ["", ".", "/"]


# --- Public Functions：场景与路径 ---

## 读布尔开关：未提供、或 provider 把可选参数补成了 null 时返回 p_default。
func flag_with_default(p_args: Dictionary, p_key: String, p_default: bool) -> bool:
	if not p_args.has(p_key):
		return p_default
	if p_args.get(p_key) == null:
		return p_default
	
	return flag_of(p_args, p_key)


func get_active_scene_root() -> Node:
	if not Engine.is_editor_hint():
		return null
	
	return EditorInterface.get_edited_scene_root()


func scene_path_of(p_root: Node) -> String:
	if p_root == null:
		return ""
	
	return p_root.scene_file_path


func scene_label(p_root: Node) -> String:
	var path: String = scene_path_of(p_root)
	if path.is_empty():
		return "scene: <never saved>"
	
	return "scene: %s" % path


## 解析节点路径。返回 {"node": Node, "error": String}；两者必有一个为空。
## 支持："" / "." / "A/B" / "/RootName/A/B" / 唯一裸名字 "A"。
func resolve_node(p_root: Node, p_path: String) -> Dictionary:
	if p_root == null:
		return {"node": null, "error": "No active scene in the editor."}
	
	var target: String = p_path.strip_edges()
	if target in ROOT_ALIASES:
		return {"node": p_root, "error": ""}
	
	while target.begins_with("./"):
		target = target.substr(2)
	
	# "/RootName/A/B"：get_node() 的绝对路径从 SceneTree 根解析，而编辑中的场景并不在 /root 下，
	# 所以这里自己剥掉根名，把"文档说支持、实际找不到"变成真的能用。
	if target.begins_with("/"):
		target = target.substr(1)
		if target == p_root.name:
			return {"node": p_root, "error": ""}
		if target.begins_with(str(p_root.name) + "/"):
			target = target.substr(str(p_root.name).length() + 1)
	
	if target.is_empty() or target == p_root.name:
		return {"node": p_root, "error": ""}
	
	var direct: Node = p_root.get_node_or_null(target)
	if direct != null:
		return {"node": direct, "error": ""}
	
	# 裸名字：只有唯一时才解析。多义直接报错——模糊匹配会把"名字写错"变成"改了另一个节点"。
	if not target.contains("/"):
		var matches: Array[String] = get_all_node_paths_by_name(p_root, target)
		if matches.size() > 1:
			return {"node": null, "error": "Ambiguous node name '%s': %d nodes share it. Use a full path, one of: %s" % [target, matches.size(), ", ".join(PackedStringArray(matches))]}
		if matches.size() == 1:
			var found: Node = p_root.get_node_or_null(matches[0])
			if found != null:
				return {"node": found, "error": ""}
	
	return {"node": null, "error": get_node_path_error_hint(p_root, p_path)}


## 节点的相对路径（根为 "."），用于回执，让调用方拿到可直接复用的路径。
func node_path_of(p_root: Node, p_node: Node) -> String:
	if p_node == null:
		return ""
	if p_node == p_root:
		return "."
	
	var segments: Array[String] = []
	var current: Node = p_node
	
	while current != null and current != p_root:
		segments.push_front(str(current.name))
		current = current.get_parent()
	
	return "/".join(PackedStringArray(segments))


func get_all_node_paths(p_root: Node) -> Array[String]:
	var paths: Array[String] = []
	_collect_node_paths(p_root, p_root, ".", paths)
	return paths


func get_all_node_paths_by_name(p_root: Node, p_name: String) -> Array[String]:
	var paths: Array[String] = []
	_collect_node_paths_by_name(p_root, p_root, ".", p_name, paths)
	return paths


## 场景树字符串：外部实例标 [instance: res://...]，带脚本标 📜路径。
func get_scene_tree_string(p_root: Node) -> String:
	var lines: PackedStringArray = []
	_traverse_node(p_root, p_root, 0, lines)
	return "\n".join(lines)


func get_node_path_error_hint(p_root: Node, p_input_path: String) -> String:
	var all_paths: Array[String] = get_all_node_paths(p_root)
	var hint: String = "Node not found: '%s'\n%s" % [p_input_path, scene_label(p_root)]
	
	hint += "\nAvailable node paths:\n"
	for path in all_paths:
		hint += "  • %s\n" % path
	
	var similar: Array[String] = find_similar_paths(p_root, p_input_path)
	if not similar.is_empty():
		hint += "Did you mean:\n"
		for candidate in similar:
			hint += "  • %s\n" % candidate
	
	hint += "\nPath format: '.' = root, 'Parent/Child' = relative (recommended), '/RootName/Child' = absolute,"
	hint += " bare 'Name' only when unique."
	return hint


func find_similar_paths(p_root: Node, p_input_path: String) -> Array[String]:
	var similar: Array[String] = []
	var needle: String = p_input_path.strip_edges().to_lower()
	if needle.is_empty():
		return similar
	
	_collect_similar_paths(p_root, ".", needle, similar)
	return similar


# --- Public Functions：编辑操作 ---

## 加节点。返回 {"ok": bool, ...} 或 {"ok": false, "error": String}
func do_add_node(p_root: Node, p_args: Dictionary) -> Dictionary:
	var unknown: String = check_params(p_args, ["parent_path", "node_type", "scene_path", "node_name"])
	if not unknown.is_empty():
		return fail_op("add", unknown)
	
	if not p_args.has("parent_path") or text_of(p_args, "parent_path").is_empty():
		return fail_op("add", "'parent_path' is required. Use \".\" for the scene root.")
	
	var parent_result: Dictionary = resolve_node(p_root, text_of(p_args, "parent_path"))
	if parent_result.node == null:
		return fail_op("add", str(parent_result.error))
	
	var parent: Node = parent_result.node
	var blocker: Node = instance_owner_of(p_root, parent)
	if blocker != null:
		return fail_op("add", "'%s' is an internal node of the instanced scene '%s' — nodes added there are dropped when the scene is saved. Open that scene and edit it instead." % [node_path_of(p_root, parent), blocker.scene_file_path])
	
	var node_type: String = text_of(p_args, "node_type")
	var scene_path: String = text_of(p_args, "scene_path")
	if not node_type.is_empty() and not scene_path.is_empty():
		return fail_op("add", "Give either 'node_type' (built-in class) or 'scene_path' (res://...tscn), not both.")
	
	var new_node: Node = null
	if not scene_path.is_empty():
		var built: Dictionary = instantiate_by_scene(scene_path)
		if built.node == null:
			return fail_op("add", str(built.error))
		new_node = built.node
	elif not node_type.is_empty():
		new_node = instantiate_by_class(node_type)
		if new_node == null:
			return fail_op("add", "'%s' is not an instantiable Node class.%s" % [node_type, candidate_suffix(class_candidates(node_type))])
	else:
		return fail_op("add", "One of 'node_type' or 'scene_path' is required.")
	
	var requested: String = text_of(p_args, "node_name")
	var wanted: String = requested if not requested.is_empty() else str(new_node.name)
	
	wanted = wanted.validate_node_name()
	if wanted.is_empty():
		wanted = "Node"
	if has_child_named(parent, wanted):
		var free_name: String = unique_child_name(parent, wanted)
		if not requested.is_empty():
			new_node.free()
			return fail_op("add", "'%s' already has a child named '%s'. Pick another name — '%s' is free." % [node_path_of(p_root, parent), wanted, free_name])
		wanted = free_name
	
	var renamed: bool = not requested.is_empty() and wanted != requested
	
	new_node.name = wanted
	
	var ur: EditorUndoRedoManager = EditorInterface.get_editor_undo_redo()
	ur.create_action("AI Add Node %s" % wanted)
	ur.add_do_method(parent, "add_child", new_node)
	ur.add_do_property(new_node, "owner", p_root)
	ur.add_undo_method(parent, "remove_child", new_node)
	ur.add_do_reference(new_node)
	ur.commit_action()
	
	return {
		"ok": true,
		"op": "add",
		"node_path": node_path_of(p_root, new_node),
		"class": new_node.get_class(),
		"instance_of": new_node.scene_file_path,
		"name": str(new_node.name),
		"renamed": renamed,
	}


## 删节点。
func do_delete_node(p_root: Node, p_args: Dictionary) -> Dictionary:
	var unknown: String = check_params(p_args, ["node_path"])
	if not unknown.is_empty():
		return fail_op("delete", unknown)
	var path: String = text_of(p_args, "node_path")
	if path.is_empty():
		return fail_op("delete", "'node_path' is required.")
	var resolved: Dictionary = resolve_node(p_root, path)
	if resolved.node == null:
		return fail_op("delete", str(resolved.error))
	var node: Node = resolved.node
	if node == p_root:
		return fail_op("delete", "The scene root cannot be deleted.")
	var parent: Node = node.get_parent()
	if parent == null:
		return fail_op("delete", "'%s' has no parent." % path)
	var blocker: Node = instance_owner_of(p_root, node)
	if blocker != null:
		return fail_op("delete", "'%s' is an internal node of the instanced scene '%s' — it cannot be deleted from here. Open that scene and edit it." % [node_path_of(p_root, node), blocker.scene_file_path])

	var label: String = node_path_of(p_root, node)
	var node_class: String = node.get_class()
	var ur: EditorUndoRedoManager = EditorInterface.get_editor_undo_redo()
	ur.create_action("AI Delete Node %s" % node.name)
	ur.add_do_method(parent, "remove_child", node)
	ur.add_undo_method(parent, "add_child", node)
	ur.add_undo_property(node, "owner", p_root)
	ur.add_undo_reference(node)
	ur.commit_action()

	return {"ok": true, "op": "delete", "node_path": label, "class": node_class}


## 换父节点。
func do_move_node(p_root: Node, p_args: Dictionary) -> Dictionary:
	var unknown: String = check_params(p_args, ["node_path", "parent_path"])
	if not unknown.is_empty():
		return fail_op("move", unknown)
	
	var path: String = text_of(p_args, "node_path")
	var target_path: String = text_of(p_args, "parent_path")
	if path.is_empty() or target_path.is_empty():
		return fail_op("move", "Both 'node_path' and 'parent_path' are required.")
	
	var resolved: Dictionary = resolve_node(p_root, path)
	if resolved.node == null:
		return fail_op("move", str(resolved.error))
	
	var node: Node = resolved.node
	if node == p_root:
		return fail_op("move", "The scene root cannot be moved.")
	
	var blocker: Node = instance_owner_of(p_root, node)
	if blocker != null:
		return fail_op("move", "'%s' is an internal node of the instanced scene '%s' — it cannot be moved from here." % [node_path_of(p_root, node), blocker.scene_file_path])
	
	var target_result: Dictionary = resolve_node(p_root, target_path)
	if target_result.node == null:
		return fail_op("move", str(target_result.error))
	
	var new_parent: Node = target_result.node
	if new_parent == node:
		return fail_op("move", "A node cannot be its own parent.")
	
	var guard: Node = new_parent
	while guard != null:
		if guard == node:
			return fail_op("move", "Cannot move '%s' into its own descendant." % node_path_of(p_root, node))
		guard = guard.get_parent()
	
	if node.get_parent() == new_parent:
		return fail_op("move", "'%s' is already a child of '%s'." % [node_path_of(p_root, node), node_path_of(p_root, new_parent)])
	
	var new_parent_blocker: Node = instance_owner_of(p_root, new_parent)
	if new_parent_blocker != null:
		return fail_op("move", "'%s' is an internal node of the instanced scene '%s' — children added there are dropped on save." % [node_path_of(p_root, new_parent), new_parent_blocker.scene_file_path])
	
	var old_parent: Node = node.get_parent()
	var ur: EditorUndoRedoManager = EditorInterface.get_editor_undo_redo()
	ur.create_action("AI Move Node %s" % node.name)
	ur.add_do_method(old_parent, "remove_child", node)
	ur.add_do_method(new_parent, "add_child", node)
	ur.add_do_property(node, "owner", p_root)
	ur.add_undo_method(new_parent, "remove_child", node)
	ur.add_undo_method(old_parent, "add_child", node)
	ur.add_undo_property(node, "owner", p_root)
	ur.commit_action()
	
	return {
		"ok": true,
		"op": "move",
		"node_path": node_path_of(p_root, node),
		"class": node.get_class(),
	}


## 改名（改路径，所以单独一个工具；set_scene_node_properties 里的 "name" 会转到这里）。
func do_rename_node(p_root: Node, p_args: Dictionary) -> Dictionary:
	var unknown: String = check_params(p_args, ["node_path", "new_name"])
	if not unknown.is_empty():
		return fail_op("rename", unknown)
	
	var path: String = text_of(p_args, "node_path")
	var new_name: String = text_of(p_args, "new_name")
	if path.is_empty() or new_name.is_empty():
		return fail_op("rename", "Both 'node_path' and 'new_name' are required.")
	
	var resolved: Dictionary = resolve_node(p_root, path)
	if resolved.node == null:
		return fail_op("rename", str(resolved.error))
	
	var node: Node = resolved.node
	var sanitized: String = new_name.validate_node_name()
	if sanitized != new_name:
		return fail_op("rename", "'%s' is not a valid node name — Godot would store it as '%s'. Pass that instead." % [new_name, sanitized])
	if sanitized == str(node.name):
		return fail_op("rename", "'%s' is already named '%s'." % [node_path_of(p_root, node), sanitized])
	
	var parent: Node = node.get_parent()
	if parent != null and has_child_named(parent, sanitized):
		return fail_op("rename", "'%s' already has a child named '%s'. Pick another name — '%s' is free." % [node_path_of(p_root, parent), sanitized, unique_child_name(parent, sanitized)])
	
	var old_name: String = str(node.name)
	var path_before: String = node_path_of(p_root, node)
	var ur: EditorUndoRedoManager = EditorInterface.get_editor_undo_redo()
	ur.create_action("AI Rename Node %s" % old_name)
	ur.add_do_method(node, "set_name", sanitized)
	ur.add_undo_method(node, "set_name", old_name)
	ur.commit_action()
	
	return {
		"ok": true,
		"op": "rename",
		"node_path_before": path_before,
		"node_path": node_path_of(p_root, node),
		"class": node.get_class(),
	}


## 设属性。
## 特殊键：'name' 转交 rename_scene_node（改名会改路径）；'owner' 直接拒绝（会损坏场景归属）。
## 写入不走 call_deferred：commit 之后立刻读回真实值，回执里的 new_value 是"读到的"而不是"想写的"。
func do_set_property(p_root: Node, p_args: Dictionary) -> Dictionary:
	var unknown: String = check_params(p_args, ["node_path", "property", "property_name", "sub_path", "value", "save", "verbose"])
	if not unknown.is_empty():
		return fail_op("set", unknown)
	
	if not p_args.has("value"):
		return fail_op("set", "'value' is required (pass \"null\" to clear a Resource property).")
	
	var path: String = text_of(p_args, "node_path")
	var resolved: Dictionary = resolve_node(p_root, path)
	if resolved.node == null:
		return fail_op("set", str(resolved.error))
	
	var node: Node = resolved.node
	
	var prop: String = text_of(p_args, "property")
	if prop.is_empty():
		prop = text_of(p_args, "property_name")
	
	var sub_path: Array = sub_path_list(p_args)
	# 兼容旧的冒号写法 "mesh:material:albedo_color"
	if prop.contains(":"):
		var parts: PackedStringArray = prop.split(":")
		prop = parts[0].strip_edges()
		for index in range(1, parts.size()):
			var piece: String = parts[index].strip_edges()
			if not piece.is_empty():
				sub_path.append(piece)
	
	if prop.is_empty():
		return fail_op("set", "'property' is required.")
	
	if prop == "name":
		var new_name: String = text_of(p_args, "value")
		if new_name.is_empty():
			return fail_op("set", "Renaming through 'name' needs a non-empty string value — or call rename_scene_node directly.")
		return do_rename_node(p_root, {"node_path": path, "new_name": new_name})
	
	if prop == "owner":
		return fail_op("set", "Setting 'owner' corrupts scene ownership — use the add/delete/move tools instead.")
	
	var write: Dictionary = resolve_property_write(node, prop, sub_path, p_args.get("value"))
	if not bool(write.get("ok", false)):
		return fail_op("set", str(write.get("error", "cannot set property")))
	
	var current: Variant = write.get("current")
	var final_value: Variant = write.get("value")
	var indexed: String = str(write.get("indexed"))
	
	var ur: EditorUndoRedoManager = EditorInterface.get_editor_undo_redo()
	ur.create_action("AI Set %s on %s" % [indexed, node.name])
	if sub_path.is_empty():
		ur.add_do_property(node, prop, final_value)
		ur.add_undo_property(node, prop, current)
	else:
		ur.add_do_method(node, "set_indexed", indexed, final_value)
		ur.add_undo_method(node, "set_indexed", indexed, current)
	
	ur.commit_action()
	
	var actual: Variant = node.get_indexed(indexed)
	var applied: bool = values_equal(actual, final_value)
	
	var result: Dictionary = {
		"ok": true,
		"op": "set",
		"node_path": node_path_of(p_root, node),
		"property": indexed,
		"type": type_label(int(write.get("type", TYPE_NIL))),
		"old_value": json_safe(current),
		"new_value": json_safe(actual),
		"applied": applied,
	}
	
	if not applied:
		result["note"] = "The write was accepted but reads back differently: the value may be clamped, rewritten by a setter, or of a type that does not fit this property."
	
	return result


## 把请求里的 property/sub_path/value 解析成 {ok, error, indexed, current, value, type}。
## create_scene 与 set 共用（前者直接写，后者包进 UndoRedo）。
func resolve_property_write(p_object: Object, p_prop: String, p_sub: Array, p_raw: Variant) -> Dictionary:
	if not has_property(p_object, p_prop):
		return {"ok": false, "error": "Property '%s' not found on %s.%s" % [p_prop, object_label(p_object), candidate_suffix(property_candidates(p_object, p_prop))]}

	var indexed: String = join_property(p_prop, p_sub)
	var current: Variant = null
	var target_type: int = TYPE_NIL

	if p_sub.is_empty():
		current = p_object.get(p_prop)
		target_type = property_type(p_object, p_prop)
		if target_type == TYPE_NIL:
			target_type = typeof(current)
	else:
		var base_value: Variant = p_object.get(p_prop)
		if base_value == null:
			return {"ok": false, "error": "'%s' is null on %s, so '%s' cannot be set. Assign a resource to '%s' first." % [p_prop, object_label(p_object), indexed, p_prop]}
		if not (base_value is Object):
			return {"ok": false, "error": "'%s' is not an Object, so it has no sub-properties." % p_prop}
		if not has_sub_property(base_value, p_sub):
			return {"ok": false, "error": "Sub-path '%s' not found under '%s'." % [":".join(PackedStringArray(p_sub)), p_prop]}
		
		current = p_object.get_indexed(indexed)
		target_type = typeof(current)
		if target_type == TYPE_NIL:
			target_type = sub_property_type(base_value, p_sub)
	
	var conversion: Dictionary = convert_value(p_raw, target_type)
	if not bool(conversion.get("success", false)):
		return {"ok": false, "error": "Cannot set '%s' (%s): %s" % [indexed, type_label(target_type), str(conversion.get("error", ""))]}
	
	return {
		"ok": true,
		"error": "",
		"indexed": indexed,
		"current": current,
		"value": conversion.get("value"),
		"type": target_type,
	}


# --- Public Functions：回执 ---

## 统一收尾：补 scene / saved / unsaved，按需附带场景树。
func finish_edit(p_root: Node, p_out: Dictionary, p_args: Dictionary) -> ToolResult:
	if not bool(p_out.get("ok", false)):
		return ToolResult.fail("%s\n%s" % [str(p_out.get("error", "Unknown scene tool error.")), scene_label(p_root)])
	if not p_out.has("scene"):
		p_out["scene"] = scene_path_of(p_root)
	
	var save_error: String = save_if_requested(p_root, p_args)
	var saved: bool = flag_of(p_args, "save") and save_error.is_empty()
	
	p_out["saved"] = saved
	p_out["unsaved"] = not saved
	
	if not save_error.is_empty():
		p_out["save_error"] = save_error
	
	var output: String = JSON.stringify(p_out, "\t")
	if flag_of(p_args, "verbose"):
		output += "\n\nScene tree (%s):\n```\n%s\n```" % [scene_label(p_root), get_scene_tree_string(p_root)]
	elif not saved:
		output += "\n\n" + SAVE_HINT
	
	return ToolResult.ok(output)


func save_if_requested(p_root: Node, p_args: Dictionary) -> String:
	if not flag_of(p_args, "save"):
		return ""
	if scene_path_of(p_root).is_empty():
		return "The scene has never been saved, so 'save' cannot write it — save it once in the editor, then retry."
	
	var err: Error = EditorInterface.save_scene()
	if err != OK:
		return "save_scene() failed (error %d). Use save_edited_file(file_type=\"scene\")." % err
	
	return ""


# --- Public Functions：属性读取与转换 ---

## 列出一个对象（Node 或 Resource）的编辑器可见属性。
func get_all_object_properties(p_object: Object, p_include_raw: bool = false, p_include_resources: bool = false) -> Dictionary:
	var properties: Dictionary = {}
	if p_object == null:
		return properties
	for p in p_object.get_property_list():
		var usage: int = p.usage
		if not (usage & PROPERTY_USAGE_EDITOR):
			continue
		# 组 / 分类条目不是属性，别列出来
		if usage & (PROPERTY_USAGE_GROUP | PROPERTY_USAGE_CATEGORY | PROPERTY_USAGE_SUBGROUP):
			continue
		var prop_name: String = str(p.name)
		var value: Variant = p_object.get(prop_name)
		var entry: Dictionary = {"value": str(value), "type": type_label(p.type)}
		if p_include_raw:
			entry["raw"] = json_safe(value)
		if value is Resource:
			entry["resource"] = _resource_summary(value)
			if p_include_resources:
				entry["properties"] = _resource_properties(value)
		properties[prop_name] = entry
	return properties


## 兼容旧名（场景工具仍在用）。
func get_all_node_properties(p_node: Node, p_include_raw: bool = false, p_include_resources: bool = false) -> Dictionary:
	return get_all_object_properties(p_node, p_include_raw, p_include_resources)


func convert_value(p_value: Variant, p_target_type: int) -> Dictionary:
	if p_target_type == TYPE_NIL:
		return {"success": true, "value": p_value, "error": ""}
	
	if typeof(p_value) == p_target_type:
		return {"success": true, "value": p_value, "error": ""}
	
	match p_target_type:
		TYPE_BOOL:
			return _to_bool(p_value)
		TYPE_INT:
			return _to_int(p_value)
		TYPE_FLOAT:
			return _to_float(p_value)
		TYPE_STRING:
			if p_value is Object:
				return _conv_fail("Expected text, got an Object.")
			return {"success": true, "value": str(p_value), "error": ""}
		TYPE_STRING_NAME:
			if p_value is Object:
				return _conv_fail("Expected text, got an Object.")
			return {"success": true, "value": StringName(str(p_value)), "error": ""}
		TYPE_NODE_PATH:
			return {"success": true, "value": NodePath(str(p_value)), "error": ""}
		TYPE_VECTOR2, TYPE_VECTOR2I:
			return _to_vector2(p_value, p_target_type)
		TYPE_VECTOR3, TYPE_VECTOR3I:
			return _to_vector3(p_value, p_target_type)
		TYPE_COLOR:
			return _to_color(p_value)
		TYPE_ARRAY:
			return _to_array(p_value)
		TYPE_DICTIONARY:
			return _to_dictionary(p_value)
		TYPE_OBJECT:
			return _to_object(p_value)
		_:
			return _to_other(p_value, p_target_type)


## JSON 安全的展示值：Vector → 数组，Color → #RRGGBBAA，Resource → 路径。
func json_safe(p_value: Variant) -> Variant:
	match typeof(p_value):
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_STRING:
			return p_value
		TYPE_FLOAT:
			return snappedf(p_value, 0.0001)
		TYPE_STRING_NAME, TYPE_NODE_PATH:
			return str(p_value)
		TYPE_VECTOR2:
			var v2: Vector2 = p_value
			return [snappedf(v2.x, 0.0001), snappedf(v2.y, 0.0001)]
		TYPE_VECTOR2I:
			var v2i: Vector2i = p_value
			return [v2i.x, v2i.y]
		TYPE_VECTOR3:
			var v3: Vector3 = p_value
			return [snappedf(v3.x, 0.0001), snappedf(v3.y, 0.0001), snappedf(v3.z, 0.0001)]
		TYPE_VECTOR3I:
			var v3i: Vector3i = p_value
			return [v3i.x, v3i.y, v3i.z]
		TYPE_COLOR:
			var color: Color = p_value
			return color.to_html(true)
		TYPE_ARRAY:
			var items: Array = []
			for item in (p_value as Array):
				items.append(json_safe(item))
			return items
		TYPE_DICTIONARY:
			var dict: Dictionary = {}
			var source: Dictionary = p_value
			for key in source:
				dict[str(key)] = json_safe(source[key])
			return dict
		TYPE_OBJECT:
			var obj: Object = p_value
			if obj == null:
				return null
			if obj is Resource:
				var res: Resource = obj
				return res.resource_path if not res.resource_path.is_empty() else "<%s>" % res.get_class()
			if obj is Node:
				return str((obj as Node).name)
			return "<%s>" % obj.get_class()
		_:
			return str(p_value)


func type_label(p_type: int) -> String:
	if p_type == TYPE_OBJECT:
		return "Resource/Object"
	if p_type == TYPE_NIL:
		return "unknown"
	
	return str(type_string(p_type))


## Node 给节点名，Resource 给 resource_name / 路径，其余给类名。
func object_label(p_object: Object) -> String:
	if p_object == null:
		return "<null>"
	if p_object is Node:
		return str((p_object as Node).name)
	
	if p_object is Resource:
		var resource: Resource = p_object
		if not resource.resource_name.is_empty():
			return str(resource.resource_name)
		if not resource.resource_path.is_empty():
			return resource.resource_path
	
	return "<%s>" % p_object.get_class()


func values_equal(p_a: Variant, p_b: Variant) -> bool:
	var a_number: bool = p_a is int or p_a is float
	var b_number: bool = p_b is int or p_b is float
	if a_number and b_number:
		return is_equal_approx(float(p_a), float(p_b))
	
	if typeof(p_a) != typeof(p_b):
		return false
	
	match typeof(p_a):
		TYPE_FLOAT:
			return is_equal_approx(p_a, p_b)
		TYPE_VECTOR2:
			return (p_a as Vector2).is_equal_approx(p_b)
		TYPE_VECTOR3:
			return (p_a as Vector3).is_equal_approx(p_b)
		TYPE_COLOR:
			return (p_a as Color).is_equal_approx(p_b)
		_:
			return p_a == p_b


# --- Public Functions：类与节点构造 ---

func instantiate_by_class(p_type: String) -> Node:
	if p_type.is_empty():
		return null
	if not ClassDB.class_exists(p_type):
		return null
	if not ClassDB.is_parent_class(p_type, "Node"):
		return null
	if not ClassDB.can_instantiate(p_type):
		return null
	
	var instance: Variant = ClassDB.instantiate(p_type)
	if instance is Node:
		return instance
	
	return null


func instantiate_by_scene(p_scene_path: String) -> Dictionary:
	if not p_scene_path.begins_with("res://"):
		return {"node": null, "error": "scene_path must start with res:// (got '%s')." % p_scene_path}
	if not ResourceLoader.exists(p_scene_path):
		return {"node": null, "error": "No file at %s." % p_scene_path}
	
	var resource: Resource = load(p_scene_path)
	if not (resource is PackedScene):
		return {"node": null, "error": "%s is not a PackedScene (.tscn/.scn)." % p_scene_path}
	
	var packed: PackedScene = resource
	var instance: Node = packed.instantiate()
	if instance == null:
		return {"node": null, "error": "Failed to instantiate %s." % p_scene_path}
	
	return {"node": instance, "error": ""}


## 类名拼错时的候选（只在报错里用，帮模型一次改对）。
func class_candidates(p_input: String) -> Array[String]:
	var out: Array[String] = []
	var needle: String = p_input.strip_edges().to_lower()
	if needle.is_empty():
		return out
	
	for raw_name in ClassDB.get_inheriters_from_class("Node"):
		var candidate: String = str(raw_name)
		if candidate.to_lower().contains(needle) or needle.contains(candidate.to_lower()):
			out.append(candidate)
			if out.size() >= MAX_CANDIDATES:
				break
	
	return out


func property_candidates(p_object: Object, p_input: String) -> Array[String]:
	var out: Array[String] = []
	var needle: String = p_input.strip_edges().to_lower()
	
	if p_object == null:
		return out
	
	for p in p_object.get_property_list():
		if not (p.usage & PROPERTY_USAGE_EDITOR):
			continue
		var prop_name: String = str(p.name)
		if needle.is_empty() or prop_name.to_lower().contains(needle):
			out.append(prop_name)
			if out.size() >= MAX_CANDIDATES:
				break
	
	return out


func candidate_suffix(p_candidates: Array[String]) -> String:
	if p_candidates.is_empty():
		return ""
	
	return " Candidates: %s" % ", ".join(PackedStringArray(p_candidates))


# --- Public Functions：实例保护与工具函数 ---

## 返回 p_node 的"外部实例祖先"（不含自身、不含场景根）；null 表示可以自由编辑。
func instance_owner_of(p_root: Node, p_node: Node) -> Node:
	if p_root == null or p_node == null or p_node == p_root:
		return null
	
	var current: Node = p_node.get_parent()
	while current != null and current != p_root:
		if not current.scene_file_path.is_empty():
			return current
		current = current.get_parent()
	
	return null


## 参数白名单：多余字段直接报错，绝不静默忽略。
func check_params(p_args: Dictionary, p_allowed: Array) -> String:
	var unknown: Array[String] = []
	
	for raw_key in p_args.keys():
		var key: String = str(raw_key)
		if not p_allowed.has(key):
			unknown.append(key)
	
	if unknown.is_empty():
		return ""
	
	return "Unknown parameter(s): %s. Allowed here: %s." % [", ".join(PackedStringArray(unknown)), ", ".join(PackedStringArray(p_allowed))]


func fail_op(p_op: String, p_error: String) -> Dictionary:
	return {"ok": false, "op": p_op, "error": p_error}


func text_of(p_args: Dictionary, p_key: String, p_default: String = "") -> String:
	var value: Variant = p_args.get(p_key)
	if value == null:
		return p_default
	
	return str(value).strip_edges()


func flag_of(p_args: Dictionary, p_key: String) -> bool:
	var value: Variant = p_args.get(p_key)
	if value is bool:
		return value
	if value is String:
		return (value as String).strip_edges().to_lower() in ["true", "1", "yes", "on"]
	if value is int or value is float:
		return float(value) != 0.0
	
	return false


func has_property(p_object: Object, p_prop: String) -> bool:
	if p_object == null:
		return false
	
	for p in p_object.get_property_list():
		if str(p.name) == p_prop:
			return true
	
	return false


func property_type(p_object: Object, p_prop: String) -> int:
	if p_object == null:
		return TYPE_NIL
	
	for p in p_object.get_property_list():
		if str(p.name) == p_prop:
			return p.type
	
	return TYPE_NIL


func has_child_named(p_parent: Node, p_name: String) -> bool:
	for child in p_parent.get_children():
		if str(child.name) == p_name:
			return true
	
	return false


func unique_child_name(p_parent: Node, p_desired: String) -> String:
	var base: String = p_desired.validate_node_name()
	if base.is_empty():
		base = "Node"
	
	var candidate: String = base
	var index: int = 2
	while has_child_named(p_parent, candidate):
		candidate = "%s%d" % [base, index]
		index += 1
	
	return candidate


func join_property(p_prop: String, p_sub: Array) -> String:
	if p_sub.is_empty():
		return p_prop
	
	return p_prop + ":" + ":".join(PackedStringArray(p_sub))


func sub_path_list(p_args: Dictionary) -> Array:
	var out: Array = []
	var raw_value: Variant = p_args.get("sub_path")
	if raw_value is Array:
		for item in (raw_value as Array):
			var piece: String = str(item).strip_edges()
			if not piece.is_empty():
				out.append(piece)
	elif raw_value is String:
		for piece in (raw_value as String).split(":", false):
			var trimmed: String = piece.strip_edges()
			if not trimmed.is_empty():
				out.append(trimmed)
	
	return out


func has_sub_property(p_object: Object, p_sub: Array) -> bool:
	var current: Variant = p_object
	
	for raw_name in p_sub:
		if not (current is Object) or current == null:
			return false
		var prop_name: String = str(raw_name)
		if not has_property(current, prop_name):
			return false
		current = (current as Object).get(prop_name)
	
	return true


func sub_property_type(p_object: Object, p_sub: Array) -> int:
	var current: Object = p_object
	
	for index in range(p_sub.size()):
		if current == null:
			return TYPE_NIL
		var prop_name: String = str(p_sub[index])
		if index == p_sub.size() - 1:
			return property_type(current, prop_name)
		var next_value: Variant = current.get(prop_name)
		if not (next_value is Object) or next_value == null:
			return TYPE_NIL
		current = next_value
	
	return TYPE_NIL


# --- Private Functions ---

func _traverse_node(p_node: Node, p_root: Node, p_depth: int, p_lines: PackedStringArray) -> void:
	if p_node != p_root and p_node.owner != p_root:
		return
	
	var indent: String = "  ".repeat(p_depth)
	var extra: String = ""
	
	if p_node != p_root and not p_node.scene_file_path.is_empty():
		extra += " [instance: %s]" % p_node.scene_file_path
	
	var script: Variant = p_node.get_script()
	if script is Script:
		extra += " 📜%s" % (script as Script).resource_path
	
	p_lines.append("%s- %s (%s)%s" % [indent, p_node.name, p_node.get_class(), extra])
	
	for child in p_node.get_children():
		_traverse_node(child, p_root, p_depth + 1, p_lines)


func _collect_node_paths(p_node: Node, p_root: Node, p_current_path: String, p_paths: Array[String]) -> void:
	if p_current_path != ".":
		p_paths.append(p_current_path)
	if p_node != p_root and not p_node.scene_file_path.is_empty():
		return
	
	for child in p_node.get_children():
		_collect_node_paths(child, p_root, _child_path(p_current_path, str(child.name)), p_paths)


func _collect_node_paths_by_name(p_node: Node, p_root: Node, p_current_path: String, p_target_name: String, p_paths: Array[String]) -> void:
	if p_node != p_root and str(p_node.name) == p_target_name:
		p_paths.append(p_current_path)
	if p_node != p_root and not p_node.scene_file_path.is_empty():
		return
	
	for child in p_node.get_children():
		_collect_node_paths_by_name(child, p_root, _child_path(p_current_path, str(child.name)), p_target_name, p_paths)


func _collect_similar_paths(p_node: Node, p_current_path: String, p_needle: String, p_results: Array[String]) -> void:
	for child in p_node.get_children():
		var child_path: String = _child_path(p_current_path, str(child.name))
		var child_name: String = str(child.name).to_lower()
		if child_name.contains(p_needle) or (not p_needle.is_empty() and p_needle.contains(child_name)):
			p_results.append(child_path)
			if p_results.size() >= MAX_CANDIDATES:
				return
		
		if child.scene_file_path.is_empty():
			_collect_similar_paths(child, child_path, p_needle, p_results)


func _child_path(p_parent_path: String, p_name: String) -> String:
	if p_parent_path == ".":
		return p_name
	
	return p_parent_path + "/" + p_name


func _conv_fail(p_message: String) -> Dictionary:
	return {"success": false, "value": null, "error": p_message}


func _to_bool(p_value: Variant) -> Dictionary:
	if p_value is bool:
		return {"success": true, "value": p_value, "error": ""}
	if p_value is int:
		return {"success": true, "value": p_value != 0, "error": ""}
	if p_value is float:
		return {"success": true, "value": not is_zero_approx(p_value), "error": ""}
	if p_value is String:
		var text: String = (p_value as String).strip_edges().to_lower()
		if text in ["true", "1", "yes", "on"]:
			return {"success": true, "value": true, "error": ""}
		if text in ["false", "0", "no", "off"]:
			return {"success": true, "value": false, "error": ""}
		return _conv_fail("'%s' is not a bool. Use true or false." % p_value)
	
	return _conv_fail("Expected bool, got %s." % type_label(typeof(p_value)))


func _to_int(p_value: Variant) -> Dictionary:
	if p_value is int:
		return {"success": true, "value": p_value, "error": ""}
	if p_value is float:
		return {"success": true, "value": int(p_value), "error": ""}
	if p_value is bool:
		return {"success": true, "value": 1 if p_value else 0, "error": ""}
	if p_value is String:
		var text: String = (p_value as String).strip_edges()
		if text.is_valid_int():
			return {"success": true, "value": text.to_int(), "error": ""}
		if text.is_valid_float():
			return {"success": true, "value": int(text.to_float()), "error": ""}
		return _conv_fail("'%s' is not an int." % p_value)
	
	return _conv_fail("Expected int, got %s." % type_label(typeof(p_value)))


func _to_float(p_value: Variant) -> Dictionary:
	if p_value is float:
		return {"success": true, "value": p_value, "error": ""}
	if p_value is int:
		return {"success": true, "value": float(p_value), "error": ""}
	if p_value is bool:
		return {"success": true, "value": 1.0 if p_value else 0.0, "error": ""}
	if p_value is String:
		var text: String = (p_value as String).strip_edges()
		if text.is_valid_float():
			return {"success": true, "value": text.to_float(), "error": ""}
		return _conv_fail("'%s' is not a number." % p_value)
	
	return _conv_fail("Expected a number, got %s." % type_label(typeof(p_value)))


func _to_vector2(p_value: Variant, p_target_type: int) -> Dictionary:
	var parts: Array = []
	if p_value is Vector2:
		parts = [p_value.x, p_value.y]
	elif p_value is Vector2i:
		parts = [p_value.x, p_value.y]
	elif p_value is Array:
		parts = p_value
	elif p_value is Dictionary:
		var dict: Dictionary = p_value
		parts = [dict.get("x", 0), dict.get("y", 0)]
	elif p_value is String:
		parts = _split_numbers(p_value)
	
	if parts.size() < 2:
		return _conv_fail("Vector2 needs 2 numbers, e.g. [10, 20].")
	if not _is_number(parts[0]) or not _is_number(parts[1]):
		return _conv_fail("Vector2 needs numeric values, got %s." % str(parts))
	if p_target_type == TYPE_VECTOR2I:
		return {"success": true, "value": Vector2i(roundi(float(parts[0])), roundi(float(parts[1]))), "error": ""}
	
	return {"success": true, "value": Vector2(float(parts[0]), float(parts[1])), "error": ""}


func _to_vector3(p_value: Variant, p_target_type: int) -> Dictionary:
	var parts: Array = []
	if p_value is Vector3:
		parts = [p_value.x, p_value.y, p_value.z]
	elif p_value is Vector3i:
		parts = [p_value.x, p_value.y, p_value.z]
	elif p_value is Array:
		parts = p_value
	elif p_value is Dictionary:
		var dict: Dictionary = p_value
		parts = [dict.get("x", 0), dict.get("y", 0), dict.get("z", 0)]
	elif p_value is String:
		parts = _split_numbers(p_value)
	
	if parts.size() < 3:
		return _conv_fail("Vector3 needs 3 numbers, e.g. [1, 2, 3].")
	if not _is_number(parts[0]) or not _is_number(parts[1]) or not _is_number(parts[2]):
		return _conv_fail("Vector3 needs numeric values, got %s." % str(parts))
	if p_target_type == TYPE_VECTOR3I:
		return {"success": true, "value": Vector3i(roundi(float(parts[0])), roundi(float(parts[1])), roundi(float(parts[2]))), "error": ""}
	
	return {"success": true, "value": Vector3(float(parts[0]), float(parts[1]), float(parts[2])), "error": ""}


func _to_color(p_value: Variant) -> Dictionary:
	if p_value is Color:
		return {"success": true, "value": p_value, "error": ""}
	
	var parts: Array = []
	
	if p_value is String:
		var text: String = (p_value as String).strip_edges()
		if text.begins_with("#") or text.is_valid_html_color():
			return {"success": true, "value": Color(text), "error": ""}
		if text.begins_with("Color("):
			var parsed: Variant = str_to_var(text)
			if parsed is Color:
				return {"success": true, "value": parsed, "error": ""}
		parts = _split_numbers(text)
	elif p_value is Array:
		parts = p_value
	
	if parts.size() < 3:
		return _conv_fail("Color needs 3 or 4 numbers (r, g, b[, a]) or \"#RRGGBB\" / \"#RRGGBBAA\".")
	
	for index in range(mini(parts.size(), 4)):
		if not _is_number(parts[index]):
			return _conv_fail("Color needs numeric values, got %s." % str(parts))
	
	# 任一通道 > 1 时按 0-255 解释（避免 [255, 0, 0] 被静默 clamp 成白色）
	var scale: float = 1.0
	for index in range(mini(parts.size(), 4)):
		if absf(float(parts[index])) > 1.0:
			scale = 1.0 / 255.0
			break
	
	var alpha: float = float(parts[3]) * scale if parts.size() >= 4 else 1.0
	return {"success": true, "value": Color(float(parts[0]) * scale, float(parts[1]) * scale, float(parts[2]) * scale, alpha), "error": ""}


func _to_array(p_value: Variant) -> Dictionary:
	if p_value is Array:
		return {"success": true, "value": p_value, "error": ""}
	if p_value is PackedStringArray:
		return {"success": true, "value": Array(p_value), "error": ""}
	if p_value is String:
		var parsed: Variant = JSON.parse_string(p_value)
		if parsed is Array:
			return {"success": true, "value": parsed, "error": ""}
	
	return _conv_fail("Expected an array, e.g. [1, 2, 3].")


func _to_dictionary(p_value: Variant) -> Dictionary:
	if p_value is Dictionary:
		return {"success": true, "value": p_value, "error": ""}
	
	if p_value is String:
		var parsed: Variant = JSON.parse_string(p_value)
		if parsed is Dictionary:
			return {"success": true, "value": parsed, "error": ""}
	
	return _conv_fail("Expected an object, e.g. {\"x\": 1, \"y\": 2}.")


func _to_object(p_value: Variant) -> Dictionary:
	if p_value == null:
		return {"success": true, "value": null, "error": ""}
	if p_value is Object:
		return {"success": true, "value": p_value, "error": ""}
	if not (p_value is String):
		return _conv_fail("Expected \"res://path\", \"new:ClassName\", a class name, or \"null\".")
	
	var text: String = (p_value as String).strip_edges()
	if text.is_empty() or text.to_lower() == "null":
		return {"success": true, "value": null, "error": ""}
	if text.begins_with("res://"):
		if not ResourceLoader.exists(text):
			return _conv_fail("No resource at %s." % text)
		return {"success": true, "value": load(text), "error": ""}
	
	var type_name: String = text
	if type_name.begins_with("new:"):
		type_name = type_name.substr(4).strip_edges()
	
	if ClassDB.class_exists(type_name):
		if not ClassDB.can_instantiate(type_name):
			return _conv_fail("'%s' cannot be instantiated." % type_name)
		return {"success": true, "value": ClassDB.instantiate(type_name), "error": ""}
	
	return _conv_fail("'%s' is not a resource path or a class name.%s" % [text, candidate_suffix(class_candidates(type_name))])


# 其余类型（Transform3D / Basis / AABB / Rect2 …）：只接受引擎字符串写法。
func _to_other(p_value: Variant, p_target_type: int) -> Dictionary:
	if p_value is String:
		var parsed: Variant = str_to_var(p_value)
		if parsed != null and typeof(parsed) == p_target_type:
			return {"success": true, "value": parsed, "error": ""}
		return _conv_fail("Cannot read '%s' as %s. Use the engine form, e.g. \"%s(...)\"." % [p_value, type_label(p_target_type), type_label(p_target_type)])
	
	return _conv_fail("Property type %s must be passed as text, e.g. \"%s(...)\"." % [type_label(p_target_type), type_label(p_target_type)])


func _split_numbers(p_text: String) -> Array:
	var cleaned: String = p_text.replace("(", "").replace(")", "").replace("[", "").replace("]", "").strip_edges()
	var out: Array = []
	
	for piece in cleaned.split(",", false):
		var text: String = piece.strip_edges()
		if text.is_valid_float():
			out.append(text.to_float())
		else:
			return []
	
	return out


func _is_number(p_value: Variant) -> bool:
	return p_value is int or p_value is float


func _resource_summary(p_resource: Resource) -> Dictionary:
	var path: String = p_resource.resource_path
	if not path.is_empty():
		return {"class": p_resource.get_class(), "path": path}
	
	return {"class": p_resource.get_class(), "inline": true}


func _resource_properties(p_resource: Object) -> Dictionary:
	var properties: Dictionary = {}
	if p_resource == null:
		return properties
	
	for p in p_resource.get_property_list():
		if p.usage & PROPERTY_USAGE_EDITOR:
			properties[str(p.name)] = str(p_resource.get(p.name))
	
	return properties
