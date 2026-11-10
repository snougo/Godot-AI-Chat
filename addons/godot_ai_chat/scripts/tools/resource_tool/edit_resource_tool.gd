@tool
extends BaseResourceTool

## 改已有资源的属性。语义：全成功或全不写。
## 1. 先把每条属性解析成写入计划（类型校验在这一步完成）；
## 2. 有一条不合法 → 整份拒绝，内存与磁盘都不动；
## 3. 写盘失败 → 把已改的值回滚，文件保持原样；
## 4. 回执给 old_value / new_value / applied（读回来的值）。

func _init() -> void:
	tool_name = "edit_resource"
	tool_description = "Edits properties of an existing .tres/.res in one all-or-nothing pass."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"path": {
				"type": "string",
				"description": "Full path of an existing .tres/.res file."
			},
			"properties": {
				"type": "object",
				"description": "Property name -> new value. Sub-properties use ':' (e.g. \"xxx:xxxx\"). Values may be native JSON or strings like \"#8a7f70\", \"[1,2,3]\", \"res://x.png\", \"new:StandardMaterial3D\", \"null\"."
			}
		},
		"required": ["path", "properties"]
	}


func execute(p_args: Dictionary) -> ToolResult:
	var unknown: String = check_params(p_args, ["path", "properties"])
	if not unknown.is_empty():
		return ToolResult.fail(unknown)
	
	var path: String = text_of(p_args, "path")
	
	var loaded: Dictionary = load_resource_file(path)
	if loaded.resource == null:
		return ToolResult.fail(str(loaded.error))
	
	var resource: Resource = loaded.resource
	
	var props_raw: Variant = p_args.get("properties")
	if not (props_raw is Dictionary) or (props_raw as Dictionary).is_empty():
		return ToolResult.fail("'properties' must be a non-empty object, e.g. {\"roughness\": 0.8, \"albedo_color\": \"#8a7f70\"}.")
	
	var props: Dictionary = props_raw
	
	# 1) 解析（不落地）
	var writes: Array[Dictionary] = []
	var problems: Array[String] = []
	
	for raw_key in props.keys():
		var key: String = str(raw_key)
		var split: Dictionary = split_property_key(key)
		if not bool(split.get("ok", false)):
			problems.append(str(split.get("error", "")))
			continue
		
		var sub: Array = split.get("sub_path", [])
		var write: Dictionary = resolve_property_write(resource, str(split.get("property", "")), sub, props[raw_key])
		
		if not bool(write.get("ok", false)):
			problems.append("'%s': %s" % [key, str(write.get("error", ""))])
			continue
		
		write["key"] = key
		writes.append(write)
	
	if not problems.is_empty():
		return ToolResult.fail("Nothing was written — %d of %d properties are invalid:\n%s" % [problems.size(), props.size(), "\n".join(PackedStringArray(problems))])
	
	# 2) 落地并记录回滚点
	var rows: Array[Dictionary] = []
	for write: Dictionary in writes:
		var indexed: String = str(write.get("indexed"))
		var before: Variant = write.get("current")
		resource.set_indexed(indexed, write.get("value"))
		var after: Variant = resource.get_indexed(indexed)
		rows.append({
			"property": indexed,
			"old_value": json_safe(before),
			"new_value": json_safe(after),
			"applied": values_equal(after, write.get("value")),
			"rollback_value": before,
		})
	
	# 3) 写盘；失败则回滚内存里的改动
	var save_error: String = save_resource_file(resource, path)
	if not save_error.is_empty():
		for row: Dictionary in rows:
			resource.set_indexed(str(row.get("property")), row.get("rollback_value"))
		return ToolResult.fail("%s\nReverted %d change(s) in memory; the file on disk was not touched." % [save_error, rows.size()])
	
	var mismatched: int = 0
	for row: Dictionary in rows:
		row.erase("rollback_value")
		if not bool(row.get("applied", false)):
			mismatched += 1
	
	var summary: Dictionary = {
		"ok": true,
		"path": path,
		"resource_type": resource.get_class(),
		"script": script_path_of(resource),
		"changed": rows.size(),
		"mismatched": mismatched,
		"properties": rows,
	}
	
	return ToolResult.ok(JSON.stringify(summary, "\t") + "\n\n" + RESOURCE_SAVE_HINT)
