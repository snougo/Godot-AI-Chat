@tool
extends AiTool

## Download and install a shader from godotshaders.com into the project.
## Requires the shader's page URL on godotshaders.com.

const REQUEST_TIMEOUT: float = 30.0
const POLL_DELAY: float = 0.01
const SETTING_SHADERS_PATH: String = "shader_library/general/shaders_folder"
const DEFAULT_SHADERS_PATH: String = "res://shaders/shaderlib/"


func _init() -> void:
	tool_name = "install_shader_from_library"
	tool_description = "Download and install a shader from godotshaders.com into the project. Requires the shader's page URL. Saves the .gdshader file to the configured shader library folder."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"shader_url": {
				"type": "string",
				"description": "The full godotshaders.com page URL of the shader to install. Required."
			},
			"shader_title": {
				"type": "string",
				"description": "Shader title (used for filename and file header comment). If omitted, it will be extracted from the page."
			}
		},
		"required": ["shader_url"]
	}


func execute(p_args: Dictionary) -> Dictionary:
	var url: String = p_args.get("shader_url", "").strip_edges()
	if url.is_empty():
		return {"success": false, "data": "Error: shader_url is required."}
	
	var title: String = p_args.get("shader_title", "").strip_edges()
	
	# 1. Download page HTML
	var html: String = await _fetch_html(url)
	if html.is_empty():
		return {"success": false, "data": "Error: Failed to download page from %s." % url}
	
	# 2. Extract shader code from HTML
	var shader_code: String = _extract_shader_code(html)
	if shader_code.is_empty():
		return {"success": false, "data": "Error: Could not extract shader code from the page. The URL may be invalid or the page format has changed.\nURL: %s" % url}
	
	# 3. Extract metadata
	var license: String = _extract_license(html)
	var author: String = _extract_author(html)
	
	# 4. Determine filename
	if title.is_empty():
		title = _extract_title(html)
	var filename: String = _sanitize_filename(title)
	
	# 5. Get save directory
	var shaders_dir: String = _get_shaders_dir()
	_ensure_directory(shaders_dir)
	
	var filepath: String = shaders_dir + filename + ".gdshader"
	
	# 6. Write file with attribution header
	var header: String = "// ============================================\n"
	header += "// Shader from godotshaders.com\n"
	header += "// ============================================\n"
	header += "// Title: " + title + "\n"
	header += "// Author: " + author + "\n"
	header += "// License: " + license + "\n"
	header += "// URL: " + url + "\n"
	header += "// ============================================\n\n"
	
	var file := FileAccess.open(filepath, FileAccess.WRITE)
	if file == null:
		return {"success": false, "data": "Error: Failed to write file %s." % filepath}
	
	file.store_string(header + shader_code)
	file.close()
	
	# 7. Refresh editor filesystem
	if Engine.is_editor_hint():
		EditorInterface.get_resource_filesystem().scan()
	
	return {"success": true, "data": "Shader installed successfully!\nTitle: %s\nAuthor: %s\nLicense: %s\nPath: %s" % [title, author, license, filepath]}


# --- Network ---

func _fetch_html(p_url: String) -> String:
	var client := HTTPClient.new()
	
	var is_https: bool = p_url.begins_with("https://")
	var url_body: String = p_url.trim_prefix("http://").trim_prefix("https://")
	var host_end: int = url_body.find("/")
	var host: String = url_body.substr(0, host_end) if host_end != -1 else url_body
	var path: String = url_body.substr(host_end) if host_end != -1 else "/"
	var port: int = 443 if is_https else 80
	
	if ":" in host:
		var parts: PackedStringArray = host.split(":")
		host = parts[0]
		port = int(parts[1])
	
	var tls_opts: TLSOptions = TLSOptions.client() if is_https else null
	var err: Error = client.connect_to_host(host, port, tls_opts)
	if err != OK:
		client.close()
		return ""
	
	var timer: float = 0.0
	while client.get_status() in [HTTPClient.STATUS_CONNECTING, HTTPClient.STATUS_RESOLVING]:
		client.poll()
		await Engine.get_main_loop().create_timer(POLL_DELAY).timeout
		timer += POLL_DELAY
		if timer >= REQUEST_TIMEOUT:
			client.close()
			return ""
	
	if client.get_status() != HTTPClient.STATUS_CONNECTED:
		client.close()
		return ""
	
	err = client.request(HTTPClient.METHOD_GET, path, ["User-Agent: GodotAIChat/1.0"])
	if err != OK:
		client.close()
		return ""
	
	timer = 0.0
	while client.get_status() == HTTPClient.STATUS_REQUESTING:
		client.poll()
		await Engine.get_main_loop().create_timer(POLL_DELAY).timeout
		timer += POLL_DELAY
		if timer >= REQUEST_TIMEOUT:
			client.close()
			return ""
	
	if client.get_response_code() != 200:
		client.close()
		return ""
	
	var response := PackedByteArray()
	while client.get_status() == HTTPClient.STATUS_BODY:
		client.poll()
		response.append_array(client.read_response_body_chunk())
		if client.get_status() == HTTPClient.STATUS_BODY:
			await Engine.get_main_loop().create_timer(POLL_DELAY).timeout
	
	client.close()
	
	return response.get_string_from_utf8()


# --- HTML Parsing (Shader Code Extraction) ---

func _extract_shader_code(html: String) -> String:
	var code: String = _extract_code_block(html)
	if not code.is_empty():
		return code
	code = _extract_pre_block(html)
	if not code.is_empty():
		return code
	code = _extract_shader_type_block(html)
	if not code.is_empty():
		return code
	return ""


func _extract_code_block(html: String) -> String:
	var regex := RegEx.new()
	regex.compile("(?s)<code[^>]*>(.*?)</code>")
	for m in regex.search_all(html):
		var content: String = m.get_string(1)
		if "shader_type" in content:
			return _clean_code(content)
	return ""


func _extract_pre_block(html: String) -> String:
	var regex := RegEx.new()
	regex.compile("(?s)<pre[^>]*>(.*?)</pre>")
	for m in regex.search_all(html):
		var content: String = m.get_string(1)
		if "shader_type" in content:
			content = content.replace("<code>", "").replace("</code>", "")
			return _clean_code(content)
	return ""


func _extract_shader_type_block(html: String) -> String:
	var start: int = html.find("shader_type")
	if start == -1:
		return ""
	
	var search_end: String = html.substr(start, 15000)
	var end_markers := ["</code>", "</pre>", "```", "<button", "Copy", "##### Live",
		"<div class=\"wp-", "<footer"]
	var end: int = search_end.length()
	for marker in end_markers:
		var pos: int = search_end.find(marker)
		if pos != -1 and pos < end:
			end = pos
	
	return _clean_code(search_end.substr(0, end))


func _clean_code(code: String) -> String:
	code = code.replace("<br>", "\n").replace("<br/>", "\n").replace("<br />", "\n")
	var regex := RegEx.new()
	regex.compile("<[^>]+>")
	code = regex.sub(code, "", true)
	code = _decode_html_entities(code)
	
	var lines := code.split("\n")
	var cleaned: Array[String] = []
	for line in lines:
		cleaned.append(line.rstrip(" \t\r"))
	return "\n".join(cleaned).strip_edges()


# --- HTML Parsing (Metadata Extraction) ---

func _extract_license(html: String) -> String:
	if "CC0" in html or "public domain" in html.to_lower():
		return "CC0"
	elif "MIT" in html:
		return "MIT"
	elif "GPL" in html:
		return "GNU GPL v.3"
	return "CC0"


func _extract_author(html: String) -> String:
	var regex := RegEx.new()
	regex.compile('class="author"[^>]*>([^<]+)<')
	var m := regex.search(html)
	if m:
		return _decode_html_entities(m.get_string(1).strip_edges())
	
	regex.compile('rel="author"[^>]*>([^<]+)<')
	m = regex.search(html)
	if m:
		return _decode_html_entities(m.get_string(1).strip_edges())
	
	return "Unknown"


func _extract_title(html: String) -> String:
	var regex := RegEx.new()
	regex.compile('<title>([^<]+)</title>')
	var m := regex.search(html)
	if m:
		var t: String = m.get_string(1).strip_edges()
		var dash: int = t.rfind(" - ")
		if dash != -1:
			t = t.substr(0, dash)
		return _decode_html_entities(t).strip_edges()
	return "untitled_shader"


# --- HTML Entity Decoding ---

func _decode_html_entities(text: String) -> String:
	var result := text
	
	var named: Dictionary = {
		"&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">",
		"&quot;": "\"", "&apos;": "'", "&ndash;": "-", "&mdash;": "-",
		"&hellip;": "...", "&copy;": "©", "&reg;": "®",
	}
	for entity in named:
		result = result.replace(entity, named[entity])
	
	var decimal_regex := RegEx.new()
	decimal_regex.compile("&#(\\d+);")
	for m in decimal_regex.search_all(result):
		var code: int = int(m.get_string(1))
		if code > 0 and code < 0x110000:
			result = result.replace(m.get_string(0), String.chr(code))
	
	var hex_regex := RegEx.new()
	hex_regex.compile("&#[xX]([0-9a-fA-F]+);")
	for m in hex_regex.search_all(result):
		var code: int = ("0x" + m.get_string(1)).hex_to_int()
		if code > 0 and code < 0x110000:
			result = result.replace(m.get_string(0), String.chr(code))
	
	return result


# --- File Operations ---

func _get_shaders_dir() -> String:
	var path: String = ProjectSettings.get_setting(SETTING_SHADERS_PATH, DEFAULT_SHADERS_PATH)
	if not path.ends_with("/"):
		path += "/"
	return path


func _ensure_directory(path: String) -> void:
	var relative: String = path.replace("res://", "")
	if relative.ends_with("/"):
		relative = relative.substr(0, relative.length() - 1)
	
	var dir := DirAccess.open("res://")
	if dir:
		var parts := relative.split("/")
		var current: String = ""
		for part in parts:
			if current.is_empty():
				current = part
			else:
				current += "/" + part
			if not dir.dir_exists(current):
				dir.make_dir(current)


func _sanitize_filename(name: String) -> String:
	var result: String = name.to_lower()
	result = result.replace(" ", "_").replace("-", "_")
	var valid: String = ""
	for c in result:
		if c in "abcdefghijklmnopqrstuvwxyz0123456789_":
			valid += c
	while "__" in valid:
		valid = valid.replace("__", "_")
	while valid.begins_with("_"):
		valid = valid.substr(1)
	while valid.ends_with("_"):
		valid = valid.substr(0, valid.length() - 1)
	if valid.is_empty():
		valid = "shader_" + str(randi() % 10000)
	return valid
