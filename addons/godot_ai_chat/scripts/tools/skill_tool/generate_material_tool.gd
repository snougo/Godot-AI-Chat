@tool
extends AiTool

## 自动扫描文件夹中的贴图并生成 StandardMaterial3D 资源。
## 智能处理分辨率后缀（例如 _1k）。

# --- Enums / Constants ---

## 贴图类型后缀映射
const TEXTURE_MAPS: Dictionary = {
	"albedo": ["_albedo", "_color", "_diffuse", "_basecolor", "_d", "_alb", "_diff"],
	"normal": ["_normal", "_n", "_norm", "_nor", "_nor_gl", "_nor_dx"],
	"roughness": ["_roughness", "_rough", "_r", "_rgh"],
	"metallic": ["_metallic", "_metal", "_m", "_met"],
	"emission": ["_emission", "_emissive", "_emit", "_e"],
	"ao": ["_ao", "_ambient", "_occlusion", "_o"]
}

## 支持的文件扩展名
const SUPPORTED_EXTENSIONS: Array[String] = ["png", "jpg", "jpeg", "tga", "webp", "bmp"]

## 分辨率后缀列表
const RESOLUTION_SUFFIXES: Array[String] = ["_1k", "_2k", "_4k", "_8k", "_512", "_1024", "_2048", "_4096"]


# --- Built-in Functions ---

func _init() -> void:
	tool_name = "generate_materials"
	tool_description = "Automatically scans a folder for textures and generates StandardMaterial3D resources."

# --- Public Functions ---

## 获取工具参数的 JSON Schema
func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"folder_path": {
				"type": "string",
				"description": "The resource path to the folder containing textures."
			}
		},
		"required": ["folder_path"]
	}


## 执行生成材质操作
## [param p_args]: 包含 folder_path 的参数字典
## [return]: 操作结果字典
func execute(p_args: Dictionary) -> Dictionary:
	var folder_path: String = p_args.get("folder_path", "")
	
	if folder_path.is_empty():
		return {"success": false, "data": "Error: folder_path is required."}
	
	folder_path = _ensure_trailing_slash(folder_path)
	
	var dir: DirAccess = DirAccess.open(folder_path)
	if not dir:
		return {"success": false, "data": "Error: Cannot open directory: " + folder_path}
	
	var material_groups: Dictionary = _scan_textures(folder_path, dir)
	
	if material_groups.is_empty():
		return {"success": false, "data": "No matching textures found in " + folder_path + ". Check if files have standard suffixes (e.g. _albedo, _diff)."}
	
	var generation_result: Dictionary = _generate_materials(folder_path, material_groups)
	ToolBox.update_editor_filesystem(folder_path)
	
	return generation_result


# --- Private Functions ---

## 确保路径以斜杠结尾
## [param p_path]: 路径
## [return]: 标准化后的路径
func _ensure_trailing_slash(p_path: String) -> String:
	if not p_path.ends_with("/"):
		return p_path + "/"
	return p_path


## 扫描文件夹中的贴图
## [param p_folder_path]: 文件夹路径
## [param p_dir]: DirAccess 对象
## [return]: 材质分组字典
func _scan_textures(p_folder_path: String, p_dir: DirAccess) -> Dictionary:
	var material_groups: Dictionary = {}
	
	p_dir.list_dir_begin()
	var file_name: String = p_dir.get_next()
	
	while file_name != "":
		if not p_dir.current_is_dir():
			var ext: String = file_name.get_extension().to_lower()
			if ext in SUPPORTED_EXTENSIONS:
				_process_texture_file(p_folder_path, file_name, material_groups)
		file_name = p_dir.get_next()
	
	p_dir.list_dir_end()
	
	return material_groups


## 处理贴图文件
## [param p_folder]: 文件夹路径
## [param p_file_name]: 文件名
## [param p_groups]: 材质分组字典
func _process_texture_file(p_folder: String, p_file_name: String, p_groups: Dictionary) -> void:
	var name_lower: String = p_file_name.to_lower().get_basename()
	var full_path: String = p_folder + p_file_name
	
	name_lower = _remove_resolution_suffix(name_lower)
	
	for type in TEXTURE_MAPS:
		var suffixes: Array = TEXTURE_MAPS[type]
		for suffix in suffixes:
			if name_lower.ends_with(suffix):
				var base_name_raw: String = _extract_base_name(p_file_name, suffix)
				
				if not p_groups.has(base_name_raw):
					p_groups[base_name_raw] = {}
				
				p_groups[base_name_raw][type] = full_path
				return


## 移除分辨率后缀
## [param p_name_lower]: 小写文件名（不含扩展名）
## [return]: 移除后缀后的名称
func _remove_resolution_suffix(p_name_lower: String) -> String:
	for res in RESOLUTION_SUFFIXES:
		if p_name_lower.ends_with(res):
			return p_name_lower.left(p_name_lower.length() - res.length())
	return p_name_lower


## 提取基础名称
## [param p_file_name]: 原始文件名
## [param p_suffix]: 后缀
## [return]: 基础名称
func _extract_base_name(p_file_name: String, p_suffix: String) -> String:
	var idx: int = p_file_name.to_lower().rfind(p_suffix)
	if idx != -1:
		var base_name_raw: String = p_file_name.left(idx)
		
		if base_name_raw.ends_with("_") and not p_suffix.begins_with("_"):
			base_name_raw = base_name_raw.left(-1)
		
		return base_name_raw
	
	return p_file_name


## 生成材质文件
## [param p_folder_path]: 文件夹路径
## [param p_material_groups]: 材质分组字典
## [return]: 生成结果字典
func _generate_materials(p_folder_path: String, p_material_groups: Dictionary) -> Dictionary:
	var created_count: int = 0
	var skipped_count: int = 0
	var results: Array[String] = []
	
	for base_name in p_material_groups:
		var textures: Dictionary = p_material_groups[base_name]
		var final_mat_name: String = _clean_material_name(base_name)
		var save_path: String = p_folder_path + final_mat_name + ".tres"
		
		if FileAccess.file_exists(save_path):
			skipped_count += 1
			results.append("Skipped (Exists): " + final_mat_name)
			continue
		
		var mat: StandardMaterial3D = _create_material(final_mat_name, textures)
		var err: Error = ResourceSaver.save(mat, save_path)
		
		if err == OK:
			created_count += 1
			results.append("Created: " + final_mat_name)
		else:
			results.append("Error Saving: " + final_mat_name)
	
	return {
		"success": true, 
		"data": "Processed %d groups. Created: %d, Skipped: %d.\nDetails: %s" % [p_material_groups.size(), created_count, skipped_count, ", ".join(results)]
	}


## 清理材质名称
## [param p_base_name]: 基础名称
## [return]: 清理后的名称
func _clean_material_name(p_base_name: String) -> String:
	var final_mat_name: String = p_base_name
	if final_mat_name.ends_with("_"):
		final_mat_name = final_mat_name.left(-1)
	return final_mat_name


## 创建材质
## [param p_name]: 材质名称
## [param p_textures]: 贴图字典
## [return]: StandardMaterial3D 实例
func _create_material(p_name: String, p_textures: Dictionary) -> StandardMaterial3D:
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.resource_name = p_name
	
	if "albedo" in p_textures:
		mat.albedo_texture = load(p_textures["albedo"])
	
	if "normal" in p_textures:
		mat.normal_enabled = true
		mat.normal_texture = load(p_textures["normal"])
	
	if "roughness" in p_textures:
		mat.roughness_texture = load(p_textures["roughness"])
		mat.roughness = 1.0
	
	if "metallic" in p_textures:
		mat.metallic_texture = load(p_textures["metallic"])
		mat.metallic = 1.0
	
	if "emission" in p_textures:
		mat.emission_enabled = true
		mat.emission_texture = load(p_textures["emission"])
		mat.emission = Color(1, 1, 1)
	
	if "ao" in p_textures:
		mat.ao_enabled = true
		mat.ao_light_affect = 1.0
		mat.ao_texture = load(p_textures["ao"])
	
	return mat
