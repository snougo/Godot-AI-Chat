@tool
class_name SketchfabDownloadTool
extends AiTool

## 从 Sketchfab 下载 3D 模型（glTF 格式）并导入到 Godot 项目。
## 需 OAuth 注册
## 本工具暂时无法通过个人的 token 认证使用

# --- Enums / Constants ---

const API_HOST: String = "api.sketchfab.com"
const API_PORT: int = 443
const BASE_PATH: String = "/v3"
const CONFIG_PATH: String = "res://addons/godot_ai_chat/sketchfab_config.tres"
const REQUEST_TIMEOUT: float = 30.0
const DOWNLOAD_TIMEOUT: float = 120.0
const POLL_DELAY: float = 0.01


# --- Built-in Functions ---

func _init() -> void:
	tool_name = "download_sketchfab"
	tool_description = "Download a 3D model from Sketchfab by UID. Downloads the glTF ZIP archive, extracts it, and imports the model into the project. Requires a configured Sketchfab API token."


# --- Public Functions ---

func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"uid": {
				"type": "string",
				"description": "The Sketchfab model UID (32-character hex string). Obtain from search_sketchfab results."
			},
			"output_dir": {
				"type": "string",
				"description": "Output directory under 'res://'. Default: 'res://sketchfab_downloads/'."
			}
		},
		"required": ["uid"]
	}


func execute(p_args: Dictionary) -> Dictionary:
	var uid: String = p_args.get("uid", "")
	if uid.is_empty():
		return {"success": false, "data": "Error: Model UID is required."}
	
	var token: String = _get_token()
	if token.is_empty():
		return {"success": false, "data": "Error: Sketchfab API token is not configured. Please set it in sketchfab_config.tres."}
	
	var output_dir: String = p_args.get("output_dir", "res://sketchfab_downloads/")
	if not output_dir.ends_with("/"):
		output_dir += "/"
	
	if not output_dir.begins_with("res://"):
		return {"success": false, "data": "Error: output_dir must start with 'res://'."}
	
	return await _download_and_extract(uid, token, output_dir)


# --- Private Functions ---

func _get_token() -> String:
	if not FileAccess.file_exists(CONFIG_PATH):
		return ""
	var config: Resource = load(CONFIG_PATH)
	if not config or not "api_token" in config:
		return ""
	return config.get("api_token")


func _download_and_extract(p_uid: String, p_token: String, p_output_dir: String) -> Dictionary:
	# Step 1: Request download link
	var download_info := await _request_download_link(p_uid, p_token)
	if not download_info.success:
		return download_info
	
	var gltf_url: String = download_info.data.get("gltf_url", "")
	var file_size: int = download_info.data.get("file_size", 0)
	
	if gltf_url.is_empty():
		return {"success": false, "data": "Error: No glTF download URL returned. The model may not have a downloadable glTF version."}
	
	# Step 2: Parse host and path from download URL
	var host_idx := gltf_url.find("//") + 2
	var path_idx := gltf_url.find("/", host_idx)
	if host_idx < 2 or path_idx < 0:
		return {"success": false, "data": "Error: Invalid download URL format."}
	
	var dl_host: String = gltf_url.substr(host_idx, path_idx - host_idx)
	var dl_uri: String = gltf_url.substr(path_idx)
	
	# Step 3: Download zip to temp
	var zip_path: String = "user://sketchfab_temp_%s.zip" % p_uid
	var download_result := await _download_file(dl_host, dl_uri, zip_path, file_size)
	if not download_result.success:
		return download_result
	
	# Step 4: Extract ZIP
	var extract_result := await _extract_zip(zip_path, p_output_dir, p_uid)
	if not extract_result.success:
		DirAccess.remove_absolute(zip_path)
		return extract_result
	
	# Step 5: Cleanup temp and notify filesystem
	DirAccess.remove_absolute(zip_path)
	
	var imported_path: String = extract_result.data.get("imported_path", "")
	_notify_filesystem_scan()
	
	var output := "Model downloaded and extracted!\n\n"
	output += "- **UID**: %s\n" % p_uid
	output += "- **Path**: %s\n" % imported_path
	output += "- **Output Dir**: %s\n" % p_output_dir
	
	return {"success": true, "data": output}


func _request_download_link(p_uid: String, p_token: String) -> Dictionary:
	var uri := "%s/models/%s/download" % [BASE_PATH, p_uid]
	var headers := PackedStringArray(["Authorization: Bearer %s" % p_token])
	
	var client := HTTPClient.new()
	var err := client.connect_to_host(API_HOST, API_PORT, TLSOptions.client())
	if err != OK:
		client.close()
		return {"success": false, "data": "Error: Connection failed (%d)" % err}
	
	var timer := 0.0
	while client.get_status() in [HTTPClient.STATUS_CONNECTING, HTTPClient.STATUS_RESOLVING]:
		client.poll()
		await Engine.get_main_loop().create_timer(POLL_DELAY).timeout
		timer += POLL_DELAY
		if timer >= REQUEST_TIMEOUT:
			client.close()
			return {"success": false, "data": "Error: Connection timeout"}
	
	if client.get_status() != HTTPClient.STATUS_CONNECTED:
		client.close()
		return {"success": false, "data": "Error: Connection failed"}
	
	err = client.request(HTTPClient.METHOD_GET, uri, headers)
	if err != OK:
		client.close()
		return {"success": false, "data": "Error: Request failed (%d)" % err}
	
	timer = 0.0
	while client.get_status() == HTTPClient.STATUS_REQUESTING:
		client.poll()
		await Engine.get_main_loop().create_timer(POLL_DELAY).timeout
		timer += POLL_DELAY
		if timer >= REQUEST_TIMEOUT:
			client.close()
			return {"success": false, "data": "Error: Request timeout"}
	
	var code := client.get_response_code()
	if code == 401 or code == 403:
		client.close()
		return {"success": false, "data": "Error: Authentication failed (HTTP %d). Your API token may be invalid or expired." % code}
	if code != 200:
		client.close()
		return {"success": false, "data": "Error: Download request failed (HTTP %d). Model UID may be invalid." % code}
	
	var response := PackedByteArray()
	while client.get_status() == HTTPClient.STATUS_BODY:
		client.poll()
		response.append_array(client.read_response_body_chunk())
		if client.get_status() == HTTPClient.STATUS_BODY:
			await Engine.get_main_loop().create_timer(POLL_DELAY).timeout
	
	client.close()
	
	var json := JSON.parse_string(response.get_string_from_utf8())
	if json == null:
		return {"success": false, "data": "Error: Invalid JSON response from download API."}
	
	var gltf_dict: Dictionary = json.get("gltf", {})
	var gltf_url: String = gltf_dict.get("url", "")
	var gltf_size: int = gltf_dict.get("size", 0)
	
	if gltf_url.is_empty():
		return {"success": false, "data": "Error: No glTF download available for this model."}
	
	return {"success": true, "data": {"gltf_url": gltf_url, "file_size": gltf_size}}


func _download_file(p_host: String, p_uri: String, p_output_path: String, p_expected_size: int) -> Dictionary:
	var use_ssl := true
	var port := 443 if use_ssl else 80
	
	var client := HTTPClient.new()
	var tls_options := TLSOptions.client() if use_ssl else null
	var err := client.connect_to_host(p_host, port, tls_options)
	if err != OK:
		client.close()
		return {"success": false, "data": "Error: Download connection failed (%d)" % err}
	
	var timer := 0.0
	while client.get_status() in [HTTPClient.STATUS_CONNECTING, HTTPClient.STATUS_RESOLVING]:
		client.poll()
		await Engine.get_main_loop().create_timer(POLL_DELAY).timeout
		timer += POLL_DELAY
		if timer >= REQUEST_TIMEOUT:
			client.close()
			return {"success": false, "data": "Error: Download connection timeout"}
	
	if client.get_status() != HTTPClient.STATUS_CONNECTED:
		client.close()
		return {"success": false, "data": "Error: Download connection failed"}
	
	err = client.request(HTTPClient.METHOD_GET, p_uri, [])
	if err != OK:
		client.close()
		return {"success": false, "data": "Error: Download request failed (%d)" % err}
	
	timer = 0.0
	while client.get_status() == HTTPClient.STATUS_REQUESTING:
		client.poll()
		await Engine.get_main_loop().create_timer(POLL_DELAY).timeout
		timer += POLL_DELAY
		if timer >= REQUEST_TIMEOUT:
			client.close()
			return {"success": false, "data": "Error: Download request timeout"}
	
	if client.get_response_code() != 200:
		client.close()
		return {"success": false, "data": "Error: Download returned HTTP %d" % client.get_response_code()}
	
	var file := FileAccess.open(p_output_path, FileAccess.WRITE)
	if file == null:
		client.close()
		return {"success": false, "data": "Error: Cannot write to %s" % p_output_path}
	
	var downloaded_bytes := 0
	var status := client.get_status()
	
	while status == HTTPClient.STATUS_BODY:
		client.poll()
		var chunk := client.read_response_body_chunk()
		if chunk.size() > 0:
			file.store_buffer(chunk)
			downloaded_bytes += chunk.size()
		
		await Engine.get_main_loop().create_timer(POLL_DELAY).timeout
		timer += POLL_DELAY
		
		status = client.get_status()
		if timer >= DOWNLOAD_TIMEOUT:
			file.close()
			client.close()
			return {"success": false, "data": "Error: Download timeout after %.1f seconds (%d bytes downloaded)" % [DOWNLOAD_TIMEOUT, downloaded_bytes]}
		
		if status in [HTTPClient.STATUS_DISCONNECTED, HTTPClient.STATUS_CONNECTION_ERROR]:
			file.close()
			client.close()
			return {"success": false, "data": "Error: Connection lost during download (%d bytes downloaded)" % downloaded_bytes}
	
	file.close()
	client.close()
	
	if downloaded_bytes == 0:
		return {"success": false, "data": "Error: Downloaded 0 bytes."}
	
	return {"success": true, "data": {"bytes": downloaded_bytes, "path": p_output_path}}


func _extract_zip(p_zip_path: String, p_output_dir: String, p_uid: String) -> Dictionary:
	var reader := ZIPReader.new()
	var err := reader.open(p_zip_path)
	if err != OK:
		return {"success": false, "data": "Error: Cannot open ZIP file (%d)" % err}
	
	var files: PackedStringArray = reader.get_files()
	if files.is_empty():
		reader.close()
		return {"success": false, "data": "Error: ZIP file is empty."}
	
	if not DirAccess.dir_exists_absolute(p_output_dir):
		DirAccess.make_dir_recursive_absolute(p_output_dir)
	
	var model_subdir: String = "%s%s/" % [p_output_dir, p_uid]
	if not DirAccess.dir_exists_absolute(model_subdir):
		DirAccess.make_dir_recursive_absolute(model_subdir)
	
	var gltf_path := ""
	for file_name in files:
		var data: PackedByteArray = reader.read_file(file_name)
		var target_path := model_subdir.path_join(file_name)
		
		# Ensure subdirectories exist
		var target_dir := target_path.get_base_dir()
		if not DirAccess.dir_exists_absolute(target_dir):
			DirAccess.make_dir_recursive_absolute(target_dir)
		
		var out_file := FileAccess.open(target_path, FileAccess.WRITE)
		if out_file:
			out_file.store_buffer(data)
			out_file.close()
		
		if file_name.ends_with(".gltf") or file_name.ends_with(".glb"):
			gltf_path = target_path
	
	reader.close()
	
	if gltf_path.is_empty():
		return {"success": false, "data": "Error: No .gltf or .glb file found in archive."}
	
	return {"success": true, "data": {"imported_path": gltf_path}}


func _notify_filesystem_scan() -> void:
	if not Engine.is_editor_hint():
		return
	var editor_interface: Object = Engine.get_singleton("EditorInterface")
	if editor_interface and editor_interface.has_method("get_resource_filesystem"):
		var efs: EditorFileSystem = editor_interface.get_resource_filesystem()
		if efs:
			efs.scan()
