@tool
class_name QuickModelToolBase
extends BaseSceneTool

## QuickModel 系列 AI 工具的共同基类。
##
## 负责四件事（各工具只写自己的参数转换）：
## 1. 懒加载 quick_model_api.gd —— 工具本身不写死 preload，插件缺失时给出可读报错
##    （这样 quick_model 插件未安装时，本系列工具只会「报错」而不会「编译失败」）
## 2. 统一的目标节点解析：node_path → 编辑器当前选中 → 场景中唯一 QuickModel
## 3. 统一的「filter / indices → 目标元素」解析（谓词选择是给 LLM 用的主要入口）
## 4. 统一的回执收尾：只读工具直接 JSON，修改类工具沿用 BaseSceneTool.finish_edit
##    （带 scene / saved / unsaved，并可选择顺手保存场景）
##
## 参数约定（所有工具通用）：
## - node_path: 目标节点路径（省略 = 编辑器选中的 / 场景中唯一的 QuickModel）
## - save: 修改类工具是否顺手保存场景（默认 false）
## - 谓词筛选（任选其一或组合）：indices / all / axis / normal / tolerance
##   / near+radius / boundary / smooth  —— 不传则用「当前选中」


# --- Constants ---

const API_PATH: String = "res://addons/quick_model/api/quick_model_api.gd"
const MODEL_SCRIPT_PATH: String = "res://addons/quick_model/quick_model.gd"

## 谓词筛选参数名（各工具按需取子集）
const FILTER_KEYS: Array[String] = [
	"indices", "all", "axis", "normal", "near", "radius", "boundary", "smooth", "tolerance"
]


# --- Private Vars ---

var _api: Object = null


# --- Public Functions：API 载入 ---

## 取（缓存的）API 实例；quick_model 插件未安装时返回 null。
func api() -> Object:
	if _api == null:
		if not ResourceLoader.exists(API_PATH):
			return null
		
		var script: Script = load(API_PATH)
		if script == null:
			return null
		
		_api = script.new()
	
	return _api


## 插件缺失时的统一报错文本。
func missing_plugin_error() -> String:
	return "Quick Model plugin not found (%s). Install the plugin, or create the API file at that path first." % API_PATH


# --- Public Functions：目标节点解析 ---

## 节点是否为 QuickModel（脚本路径匹配，或按公开接口鸭子类型判定）。
func is_quick_model(p_node: Node) -> bool:
	if p_node == null or not (p_node is Node3D):
		return false
	
	var script: Variant = (p_node as Node3D).get_script()
	if script is Script and (script as Script).resource_path == MODEL_SCRIPT_PATH:
		return true
	
	return p_node.has_method("apply_result_selection") and p_node.has_method("mark_unsaved")


## 解析目标节点。返回 {"model": Node, "error": String}。
func resolve_model(p_args: Dictionary) -> Dictionary:
	var root: Node = get_active_scene_root()
	if root == null:
		return {"model": null, "error": "No active scene in the editor."}
	
	var path: String = text_of(p_args, "node_path")
	if not path.is_empty():
		var resolved: Dictionary = resolve_node(root, path)
		if resolved.node == null:
			return {"model": null, "error": str(resolved.error)}
		if not is_quick_model(resolved.node):
			return {
				"model": null,
				"error": "'%s' is not a QuickModel node (class %s). Use quick_model_create to make one." % [path, resolved.node.get_class()]
			}
		return {"model": resolved.node, "error": ""}
	
	# 1) 编辑器当前选中的 QuickModel
	var selection: EditorSelection = EditorInterface.get_selection()
	if selection != null:
		for node: Node in selection.get_selected_nodes():
			if is_quick_model(node):
				return {"model": node, "error": ""}
	
	# 2) 场景中唯一的 QuickModel
	var found: Array[Node] = []
	_collect_models(root, found)
	
	if found.size() == 1:
		return {"model": found[0], "error": ""}
	
	if found.is_empty():
		return {
			"model": null,
			"error": "No QuickModel node in the scene. Create one with quick_model_create, or pass 'node_path'."
		}
	
	var paths: Array[String] = []
	for node: Node in found:
		paths.append(node_path_of(root, node))
	
	return {
		"model": null,
		"error": "%d QuickModel nodes in the scene — pass 'node_path'. Candidates: %s" % [
			found.size(), ", ".join(PackedStringArray(paths))
		]
	}


# --- Public Functions：参数解析 ---

## mode 参数 → 模式值；省略时回落到节点的当前模式。
func mode_of(p_args: Dictionary, p_model: Node) -> int:
	var api_instance: Object = api()
	if api_instance == null:
		return -1
	
	var mode: int = api_instance.call("mode_from_name", text_of(p_args, "mode"))
	if mode >= 0:
		return mode
	
	return int(p_model.get("select_mode"))


## 返回「mode 缺省时按 p_default 补齐」的参数副本。
## 用于「只对某模式有意义」的工具（挤出/内插要面、倒角要边），避免节点当前模式
## 恰好是另一个模式时把调用方的意图打歪。
func with_default_mode(p_args: Dictionary, p_default: String) -> Dictionary:
	if p_args.has("mode"):
		return p_args
	
	var copy: Dictionary = p_args.duplicate()
	copy["mode"] = p_default
	
	return copy


## 从参数里收集谓词筛选键（只收集实际出现的键；空字典 = 用当前选中）。
func filter_of(p_args: Dictionary, p_keys: Array = FILTER_KEYS) -> Dictionary:
	var filter: Dictionary = {}
	
	for key: Variant in p_keys:
		var name: String = str(key)
		if p_args.has(name):
			filter[name] = p_args[name]
	
	return filter


## 解析「目标节点 + 目标元素索引 + 模式」。
## 返回 {"model": Node, "indices": PackedInt32Array, "mode": int, "error": String}。
func resolve_target(p_args: Dictionary, p_filter_keys: Array = FILTER_KEYS) -> Dictionary:
	var api_instance: Object = api()
	if api_instance == null:
		return {"model": null, "indices": PackedInt32Array(), "mode": -1, "error": missing_plugin_error()}
	
	var resolved: Dictionary = resolve_model(p_args)
	if resolved.model == null:
		return {"model": null, "indices": PackedInt32Array(), "mode": -1, "error": str(resolved.error)}
	
	var model: Node = resolved.model
	var mode: int = mode_of(p_args, model)
	if mode < 0:
		return {"model": model, "indices": PackedInt32Array(), "mode": -1, "error": "Unknown 'mode' value. Use vertex, edge or face."}
	
	var filter: Dictionary = filter_of(p_args, p_filter_keys)
	var indices: PackedInt32Array = PackedInt32Array()
	
	if filter.is_empty():
		indices = api_instance.call("current_indices", model, mode)
		if indices.is_empty():
			return {
				"model": model,
				"indices": indices,
				"mode": mode,
				"error": "Nothing selected in %s mode, and no filter given. Pass 'filter' keys (all / axis / normal / near+radius / indices) or select first with quick_model_select." % api_instance.call("mode_name", mode)
			}
	else:
		var picked: Dictionary = api_instance.call("resolve_indices", model, mode, filter)
		if not str(picked["error"]).is_empty():
			return {"model": model, "indices": PackedInt32Array(), "mode": mode, "error": str(picked["error"])}
		indices = picked["indices"]
	
	return {"model": model, "indices": indices, "mode": mode, "error": ""}


# --- Public Functions：回执 ---

## 回执收尾。
## p_apply_save = false 用于只读工具（不追加 "changes are in the editor only" 提示）。
func respond(p_args: Dictionary, p_data: Dictionary, p_apply_save: bool = true) -> ToolResult:
	p_data["ok"] = bool(p_data.get("ok", true))
	
	if not bool(p_data["ok"]):
		return ToolResult.fail(str(p_data.get("error", p_data.get("message", "QuickModel tool failed."))))
	
	p_data.erase("message")
	p_data.erase("error")
	
	var root: Node = get_active_scene_root()
	if root == null:
		return ToolResult.ok(JSON.stringify(p_data, "\t"))
	
	if not p_apply_save:
		p_data["scene"] = scene_path_of(root)
		return ToolResult.ok(JSON.stringify(p_data, "\t"))
	
	return finish_edit(root, p_data, p_args)


## 把 API 的操作结果直接转成 ToolResult（失败 → ToolResult.fail）。
func respond_op(p_args: Dictionary, p_model: Node, p_result: Dictionary) -> ToolResult:
	if not bool(p_result.get("ok", false)):
		return ToolResult.fail(str(p_result.get("message", "QuickModel operation failed.")))
	
	var data: Dictionary = p_result.duplicate(true)
	data["ok"] = true
	
	var root: Node = get_active_scene_root()
	if root != null:
		data["node_path"] = node_path_of(root, p_model)
	
	return respond(p_args, data)


# --- Public Functions：类型转换 ---

## 任意输入 → Vector3（Array / Vector3 / {"x","y","z"} / 引擎字符串）；失败返回零向量。
func vec3_of(p_raw: Variant) -> Vector3:
	if p_raw is Vector3:
		return p_raw
	
	if p_raw is Array:
		var array: Array = p_raw
		if array.size() >= 3:
			return Vector3(float(array[0]), float(array[1]), float(array[2]))
		return Vector3.ZERO
	
	if p_raw is Dictionary:
		var dict: Dictionary = p_raw
		return Vector3(
			float(dict.get("x", 0.0)),
			float(dict.get("y", 0.0)),
			float(dict.get("z", 0.0))
		)
	
	if p_raw is String:
		var parsed: Variant = str_to_var(p_raw)
		if parsed is Vector3:
			return parsed
	
	return Vector3.ZERO


# --- Private Functions ---

func _collect_models(p_node: Node, p_out: Array[Node]) -> void:
	if is_quick_model(p_node):
		p_out.append(p_node)
	
	for child: Node in p_node.get_children():
		_collect_models(child, p_out)
