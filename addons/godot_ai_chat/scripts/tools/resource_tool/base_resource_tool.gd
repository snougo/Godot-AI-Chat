@tool
class_name BaseResourceTool
extends BaseSceneTool

## 资源工具基类：.tres / .res 的校验、加载、保存，以及资源类名候选。
##
## 继承 BaseSceneTool 只为复用与"是 Node 还是 Resource"无关的部分：参数白名单、值转换
## （convert_value）、属性写入解析（resolve_property_write）、JSON 化。
## 场景专属的节点路径 / 实例保护 / UndoRedo 编辑留在父类里，这里不用。


# --- Constants ---

## 允许的资源文件扩展名
const RESOURCE_EXTENSIONS: Array[String] = ["tres", "res"]

## 这些类型本身没有内容，存成文件等于空文件 —— 直接拒绝
const BASE_RESOURCE_TYPES: Array[String] = ["Resource", "RefCounted", "Object"]

## 资源是立即写盘的，回执用它说明"没有待保存状态"
const RESOURCE_SAVE_HINT: String = "The file was written immediately — there is no in-editor pending state (and no UndoRedo; use rollback_files or git to revert)."


# --- Public Functions ---

## 校验并加载资源。返回 {"resource": Resource, "error": String}。
func load_resource_file(p_path: String) -> Dictionary:
	var path: String = p_path.strip_edges()
	if path.is_empty():
		return {"resource": null, "error": "'path' is required."}
	
	var safety: String = validate_path_safety(path)
	if not safety.is_empty():
		return {"resource": null, "error": safety}
	
	if path.get_extension().to_lower() not in RESOURCE_EXTENSIONS:
		return {"resource": null, "error": "'%s' is not a resource file — expected .tres or .res." % path}
	
	if not FileAccess.file_exists(path):
		return {"resource": null, "error": "File not found: %s" % path}
	
	# CACHE_MODE_REUSE（默认值）：拿编辑器里那份实例，改完立刻在场景 / 检查器里生效
	var loaded: Resource = ResourceLoader.load(path, "", ResourceLoader.CacheMode.CACHE_MODE_REUSE)
	if loaded == null:
		return {"resource": null, "error": "Failed to load %s — the file may be corrupt or not a Resource." % path}
	
	return {"resource": loaded, "error": ""}


## 写盘。返回空字符串表示成功。
func save_resource_file(p_resource: Resource, p_path: String) -> String:
	if p_resource == null:
		return "Nothing to save."
	
	var err: Error = ResourceSaver.save(p_resource, p_path)
	if err != OK:
		return "ResourceSaver.save() failed (error %d) for %s." % [err, p_path]
	
	ToolBox.update_editor_filesystem(p_path)
	return ""


## 资源类名候选：引擎 Resource 子类 + 项目内脚本资源类（class_name 不在 ClassDB 里）。
func resource_candidates(p_input: String) -> Array[String]:
	var out: Array[String] = []
	var needle: String = p_input.strip_edges().to_lower()
	if needle.is_empty():
		return out
	
	for raw_name in ClassDB.get_inheriters_from_class("Resource"):
		var candidate: String = str(raw_name)
		if candidate.to_lower().contains(needle):
			out.append(candidate)
			if out.size() >= MAX_CANDIDATES:
				return out
	
	for entry in ProjectSettings.get_global_class_list():
		if not (entry is Dictionary):
			continue
		
		var info: Dictionary = entry
		var script_class: String = str(info.get("class", ""))
		if script_class.is_empty() or out.has(script_class):
			continue
		if not script_class.to_lower().contains(needle):
			continue
		if not _is_resource_script_class(info):
			continue
		
		out.append(script_class)
		if out.size() >= MAX_CANDIDATES:
			break
	
	return out


## 实例化一个具体资源类型：引擎类走 ClassDB，脚本 class_name 走全局类表。
func instantiate_resource_by_class(p_type: String) -> Resource:
	var type_name: String = p_type.strip_edges()
	if type_name.is_empty() or type_name in BASE_RESOURCE_TYPES:
		return null
	
	if ClassDB.class_exists(type_name):
		if not ClassDB.is_parent_class(type_name, "Resource"):
			return null
		if not ClassDB.can_instantiate(type_name):
			return null
		var made: Variant = ClassDB.instantiate(type_name)
		if made is Resource:
			return made
		return null
	
	for entry in ProjectSettings.get_global_class_list():
		if not (entry is Dictionary):
			continue
		
		var info: Dictionary = entry
		if str(info.get("class", "")) != type_name:
			continue
		
		if not _is_resource_script_class(info):
			return null
		
		var script_path: String = str(info.get("path", ""))
		if script_path.is_empty() or not ResourceLoader.exists(script_path):
			return null
		
		var script: Resource = load(script_path)
		if not (script is GDScript):
			return null
		
		var instance: Variant = (script as GDScript).new()
		if instance is Resource:
			return instance
	
	return null


## 把 "mesh:height" 拆成 {ok, property, sub_path}；把 "mesh/height" 变成明确报错。
func split_property_key(p_key: String) -> Dictionary:
	var prop: String = p_key.strip_edges()
	var sub: Array = []
	
	if prop.contains("/"):
		return {"ok": false, "property": "", "sub_path": sub,
			"error": "'%s': a node path is not a property path — use ':' for sub-properties, e.g. 'mesh:height'." % p_key}
	if prop.contains(":"):
		var parts: PackedStringArray = prop.split(":")
		prop = parts[0].strip_edges()
		for index in range(1, parts.size()):
			var piece: String = parts[index].strip_edges()
			if not piece.is_empty():
				sub.append(piece)
	if prop.is_empty():
		return {"ok": false, "property": "", "sub_path": sub, "error": "'%s' has no property name." % p_key}
	
	return {"ok": true, "property": prop, "sub_path": sub, "error": ""}


## 对象挂的脚本路径（没有则空字符串）。
func script_path_of(p_object: Object) -> String:
	if p_object == null:
		return ""
	
	var script: Variant = p_object.get_script()
	if script is Script:
		return (script as Script).resource_path
	
	return ""


# --- Private Functions ---

func _is_resource_script_class(p_info: Dictionary) -> bool:
	var base: String = str(p_info.get("base", ""))
	if base == "Resource":
		return true
	if not ClassDB.class_exists(base):
		return false
	
	return ClassDB.is_parent_class(base, "Resource")
