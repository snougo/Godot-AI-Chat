@tool
extends AiTool

# 定义支持的贴图后缀映射 (已包含 _diff, _nor_gl)
const TEXTURE_MAPS = {
	"albedo": ["_albedo", "_color", "_diffuse", "_basecolor", "_d", "_alb", "_diff"],
	"normal": ["_normal", "_n", "_norm", "_nor", "_nor_gl", "_nor_dx"],
	"roughness": ["_roughness", "_rough", "_r", "_rgh"],
	"metallic": ["_metallic", "_metal", "_m", "_met"],
	"emission": ["_emission", "_emissive", "_emit", "_e"],
	"ao": ["_ao", "_ambient", "_occlusion", "_o"]
}

const SUPPORTED_EXTENSIONS = ["png", "jpg", "jpeg", "tga", "webp", "bmp"]


func _init():
	tool_name = "generate_materials_from_textures"
	tool_description = "Automatically scans a folder for textures and generates StandardMaterial3D resources. Handles resolution suffixes (e.g., _1k) intelligently."


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


func execute(args: Dictionary) -> Dictionary:
	var folder_path = args.get("folder_path", "")
	
	if folder_path.is_empty():
		return {"success": false, "data": "Error: folder_path is required."}
	
	if not folder_path.ends_with("/"):
		folder_path += "/"
	
	var dir = DirAccess.open(folder_path)
	if not dir:
		return {"success": false, "data": "Error: Cannot open directory: " + folder_path}
	
	dir.list_dir_begin()
	var file_name = dir.get_next()
	
	var material_groups = {} 
	
	while file_name != "":
		if not dir.current_is_dir():
			var ext = file_name.get_extension().to_lower()
			if ext in SUPPORTED_EXTENSIONS:
				_process_texture_file(folder_path, file_name, material_groups)
		file_name = dir.get_next()
	
	if material_groups.is_empty():
		return {"success": false, "data": "No matching textures found in " + folder_path + ". Check if files have standard suffixes (e.g. _albedo, _diff)."}
	
	var created_count = 0
	var skipped_count = 0
	var results = []
	
	for base_name in material_groups:
		var textures = material_groups[base_name]
		
		# 移除可能残留的下划线作为材质名，例如 "Wood_" -> "Wood"
		var final_mat_name = base_name
		if final_mat_name.ends_with("_"):
			final_mat_name = final_mat_name.left(-1)
		
		var save_path = folder_path + final_mat_name + ".tres"
		
		if FileAccess.file_exists(save_path):
			skipped_count += 1
			results.append("Skipped (Exists): " + final_mat_name)
			continue
		
		var mat = StandardMaterial3D.new()
		mat.resource_name = final_mat_name
		
		if "albedo" in textures:
			mat.albedo_texture = load(textures["albedo"])
		
		if "normal" in textures:
			mat.normal_enabled = true
			mat.normal_texture = load(textures["normal"])
		
		if "roughness" in textures:
			mat.roughness_texture = load(textures["roughness"])
			mat.roughness = 1.0 
		
		if "metallic" in textures:
			mat.metallic_texture = load(textures["metallic"])
			mat.metallic = 1.0
		
		if "emission" in textures:
			mat.emission_enabled = true
			mat.emission_texture = load(textures["emission"])
			mat.emission = Color(1, 1, 1)
		
		if "ao" in textures:
			mat.ao_enabled = true
			mat.ao_light_affect = 1.0
			mat.ao_texture = load(textures["ao"])
		
		var err = ResourceSaver.save(mat, save_path)
		if err == OK:
			created_count += 1
			results.append("Created: " + final_mat_name)
		else:
			results.append("Error Saving: " + final_mat_name)
	
	if ClassDB.class_exists("EditorInterface"):
		var fs = EditorInterface.get_resource_filesystem()
		if fs: fs.scan()
	
	return {
		"success": true, 
		"data": "Processed %d groups. Created: %d, Skipped: %d.\nDetails: %s" % [material_groups.size(), created_count, skipped_count, ", ".join(results)]
	}


func _process_texture_file(folder: String, file_name: String, groups: Dictionary):
	var name_lower = file_name.to_lower().get_basename()
	var full_path = folder + file_name
	
	# --- 新增: 智能移除分辨率后缀 ---
	# 先尝试移除常见的 _1k, _2k 等后缀，以便匹配核心类型
	var res_suffixes = ["_1k", "_2k", "_4k", "_8k", "_512", "_1024", "_2048", "_4096"]
	for res in res_suffixes:
		if name_lower.ends_with(res):
			name_lower = name_lower.left(name_lower.length() - res.length())
			break
	# -----------------------------
	
	for type in TEXTURE_MAPS:
		for suffix in TEXTURE_MAPS[type]:
			if name_lower.ends_with(suffix):
				var base_len = name_lower.length() - suffix.length()
				var base_name_raw = file_name.left(base_len) # 注意：这里切分的是原始文件名，可能还带 _1k
				
				# 重新处理 base_name_raw 以去除原来的后缀和分辨率部分
				# 因为 file_name 是 "Wood_Albedo_1k.png"，name_lower 是 "wood_albedo"
				# 我们需要从原始字符串中精确提取出 "Wood"
				
				# 方法：找到后缀在原始字符串中的位置（忽略大小写）
				var idx = file_name.to_lower().rfind(suffix)
				if idx != -1:
					base_name_raw = file_name.left(idx)
				
				# 清理末尾下划线
				if base_name_raw.ends_with("_") and not suffix.begins_with("_"):
					base_name_raw = base_name_raw.left(-1)
				
				if not groups.has(base_name_raw):
					groups[base_name_raw] = {}
				
				groups[base_name_raw][type] = full_path
				return
