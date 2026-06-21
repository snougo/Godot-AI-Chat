@tool
extends AiTool

## 通过 Draw Things HTTP API 进行本地文生图。
##
## 调用本地运行的 Draw Things app 的 HTTP API Server，发送提示词并生成图像。
## 生成的图像以 PNG 格式保存到指定的路径（必填参数 output_path）。
## 最大支持 1024x1024 分辨率，steps 和 cfg_scale 固定为推荐值。
##
## [b]前置条件：[/b]
## 1. Draw Things app 已启动
## 2. Draw Things 设置中已开启 "API Server"（默认端口 7860）
##
## [b]验证服务是否运行：[/b]
## curl http://127.0.0.1:7860/sdapi/v1/sdapi
## Draw Things 是一款提供本地文生图功能的 Mac App
## 工具默认的文生图模型为 Z-image Turbo 1.0


# --- Enums / Constants ---

## 默认主机地址
const DEFAULT_HOST: String = "127.0.0.1"
## 默认端口
const DEFAULT_PORT: int = 7860
## API 端点路径
const TXT2IMG_ENDPOINT: String = "/sdapi/v1/txt2img"
## 最大可接受宽度
const MAX_WIDTH: int = 1024
## 最大可接受高度
const MAX_HEIGHT: int = 1024
## 固定采样步数（本地模型推荐值）
const FIXED_STEPS: int = 8
## 固定 CFG 比例（本地模型推荐值）
const FIXED_CFG_SCALE: float = 1.0
## HTTP 请求超时时间（秒）
const REQUEST_TIMEOUT: float = 120.0
## 轮询间隔（秒）
const POLL_DELAY: float = 0.05


# --- Built-in Functions ---

func _init() -> void:
	tool_name = "draw_things_generate_image"
	tool_description = "Generates an image using the local `Draw Things` app via its HTTP API. "


# --- Public Functions ---

func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"prompt": {
				"type": "string",
				"description": "Text description of the image to generate. Be as detailed as possible for better results."
			},
			"negative_prompt": {
				"type": "string",
				"description": "Elements or qualities to exclude from the generated image (e.g., 'blurry, low quality, deformed hands')."
			},
			"output_path": {
				"type": "string",
				"description": "Required. Full path to save the generated PNG image, e.g. 'res://artworks/my_image.png'. The parent directory must exist."
			},
			"width": {
				"type": "integer",
				"description": "Image width in pixels. Maximum: 1024. Default: 1024.",
				"default": 1024
			},
			"height": {
				"type": "integer",
				"description": "Image height in pixels. Maximum: 1024. Default: 1024.",
				"default": 1024
			},
			"seed": {
				"type": "integer",
				"description": "Random seed. Use -1 for random. Default: -1.",
				"default": -1
			}
		},
		"required": ["prompt", "negative_prompt", "output_path"]
	}


func execute(p_args: Dictionary) -> Dictionary:
	# --- 提取参数 ---
	var prompt: String = p_args.get("prompt", "").strip_edges()
	if prompt.is_empty():
		return {"success": false, "data": "Error: 'prompt' parameter is required and cannot be empty."}
	
	var negative_prompt: String = p_args.get("negative_prompt", "")
	var output_path: String = p_args.get("output_path", "").strip_edges()
	if output_path.is_empty():
		return {"success": false, "data": "Error: 'output_path' parameter is required and cannot be empty."}
	
	# 路径安全检查
	var safety_err: String = validate_path_safety(output_path)
	if not safety_err.is_empty():
		return {"success": false, "data": safety_err}
	
	var width: int = p_args.get("width", 1024)
	var height: int = p_args.get("height", 1024)
	var seed: int = p_args.get("seed", -1)
	
	# --- 参数校验 ---
	if width < 64 or width > MAX_WIDTH:
		return {"success": false, "data": "Error: 'width' must be between 64 and %d." % MAX_WIDTH}
	if height < 64 or height > MAX_HEIGHT:
		return {"success": false, "data": "Error: 'height' must be between 64 and %d." % MAX_HEIGHT}
	
	# --- 构建请求 Payload（steps 和 cfg_scale 使用固定推荐值）---
	var payload: Dictionary = {
		"prompt": prompt,
		"negative_prompt": negative_prompt,
		"width": width,
		"height": height,
		"steps": FIXED_STEPS,
		"cfg_scale": FIXED_CFG_SCALE,
		"seed": seed
	}
	
	return await _send_request(payload, output_path)


# --- Private Functions ---

## 异步发送 HTTP POST 请求到 Draw Things API
## 使用 await 协程，不阻塞编辑器主线程
func _send_request(p_payload: Dictionary, p_output_path: String) -> Dictionary:
	var client := HTTPClient.new()
	var err := client.connect_to_host(DEFAULT_HOST, DEFAULT_PORT)
	
	if err != OK:
		return {
			"success": false,
			"data": "Error: Cannot connect to Draw Things at %s:%d — %s. Make sure Draw Things is running and API Server is enabled." % [DEFAULT_HOST, DEFAULT_PORT, error_string(err)]
		}
	
	# --- 等待连接完成（异步）---
	var timer: float = 0.0
	while client.get_status() in [HTTPClient.STATUS_CONNECTING, HTTPClient.STATUS_RESOLVING]:
		client.poll()
		await Engine.get_main_loop().create_timer(POLL_DELAY).timeout
		timer += POLL_DELAY
		if timer >= 10.0:
			client.close()
			return {"success": false, "data": "Error: Connection to Draw Things timed out after 10 seconds."}
	
	if client.get_status() != HTTPClient.STATUS_CONNECTED:
		client.close()
		return {"success": false, "data": "Error: Failed to connect to Draw Things. Status: %d. Is the app running?" % client.get_status()}
	
	# --- 发送请求 ---
	var body: String = JSON.stringify(p_payload)
	var headers: PackedStringArray = ["Content-Type: application/json"]
	
	err = client.request(HTTPClient.METHOD_POST, TXT2IMG_ENDPOINT, headers, body)
	if err != OK:
		client.close()
		return {"success": false, "data": "Error: HTTP request failed — %s." % error_string(err)}
	
	# --- 等待响应（异步）---
	timer = 0.0
	while client.get_status() == HTTPClient.STATUS_REQUESTING:
		client.poll()
		await Engine.get_main_loop().create_timer(POLL_DELAY).timeout
		timer += POLL_DELAY
		if timer >= REQUEST_TIMEOUT:
			client.close()
			return {"success": false, "data": "Error: Image generation timed out after %.0f seconds. The model may be taking too long." % REQUEST_TIMEOUT}
	
	# --- 读取响应体 ---
	var response_code: int = client.get_response_code()
	var response_body := PackedByteArray()

	while client.get_status() == HTTPClient.STATUS_BODY:
		client.poll()
		var chunk: PackedByteArray = client.read_response_body_chunk()
		if chunk.size() > 0:
			response_body.append_array(chunk)
		if client.get_status() == HTTPClient.STATUS_BODY:
			await Engine.get_main_loop().create_timer(POLL_DELAY).timeout
	
	client.close()
	
	if response_code != 200:
		var error_body: String = response_body.get_string_from_utf8()
		return {"success": false, "data": "Error: Draw Things API returned HTTP %d — %s" % [response_code, error_body]}
	
	# --- 解析 JSON ---
	var json := JSON.new()
	var parse_err: Error = json.parse(response_body.get_string_from_utf8())
	if parse_err != OK:
		return {"success": false, "data": "Error: Failed to parse API response JSON — %s." % error_string(parse_err)}
	
	return _save_image(json.data, p_output_path)


## 解码 Base64 图片并保存到指定路径
func _save_image(p_response_data: Variant, p_output_path: String) -> Dictionary:
	var images_raw = p_response_data.get("images", [])
	if images_raw.is_empty():
		return {"success": false, "data": "Error: API returned no images in response."}
	
	# --- 检查同名文件冲突 ---
	if FileAccess.file_exists(p_output_path):
		return {"success": false, "data": "Error: File already exists at %s." % p_output_path}
	
	var base64_str: String = images_raw[0]
	var raw_data: PackedByteArray = Marshalls.base64_to_raw(base64_str)
	if raw_data.is_empty():
		return {"success": false, "data": "Error: Failed to decode base64 image data."}
	
	# 直接将原始 PNG 数据写入指定路径
	var file := FileAccess.open(p_output_path, FileAccess.WRITE)
	if not file:
		return {"success": false, "data": "Error: Cannot open file for writing: %s" % p_output_path}
	file.store_buffer(raw_data)
	file.close()
	
	# 刷新编辑器文件系统
	var editor_filesystem: EditorFileSystem = EditorInterface.get_resource_filesystem()
	editor_filesystem.scan()
	
	# 验证文件可加载
	var check := Image.new()
	var load_err: Error = check.load(p_output_path)
	if load_err != OK:
		return {"success": false, "data": "Error: Saved file at %s failed validation." % p_output_path}
	
	return {
		"success": true,
		"data": "Image generated and saved successfully: %s" % p_output_path,
		"attachments": {
			"image_data": raw_data,
			"mime": "image/png"
		}
	}
