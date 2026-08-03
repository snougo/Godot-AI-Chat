@tool
class_name BaseGithubTool
extends AiTool

## GitHub 工具公共基类
##
## 提供 GitHub 相关工具共享的能力：HTTPS 网络请求、repo/version/path 输入校验、文本截断。
## 子类只需聚焦各自的业务逻辑（仓库查看 / PR 阅读）。

# --- Enums / Constants ---

const REQUEST_TIMEOUT: float = 30.0
const POLL_DELAY: float = 0.01

const RAW_HOST: String = "raw.githubusercontent.com"
const API_HOST: String = "api.github.com"

# 输入白名单：防止 URL 注入
const _ALLOWED_REPO_CHARS: String = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
const _ALLOWED_PATH_CHARS: String = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._/-"
const _ALLOWED_VERSION_CHARS: String = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"


# --- Public Functions ---

## 规范化 repo 参数：空值回退到默认仓库
## [param p_repo]: 用户传入的仓库名
## [param p_default]: 默认仓库名
func normalize_repo(p_repo: String, p_default: String) -> String:
	var repo := p_repo.strip_edges()
	if repo.is_empty():
		repo = p_default
	return repo


## 校验 repo 格式（owner/repo）
## 两段均非空、长度 ≤ 100，且仅含 [A-Za-z0-9._-]
func is_valid_repo(p_repo: String) -> bool:
	if p_repo.count("/") != 1:
		return false
	var parts: PackedStringArray = p_repo.split("/")
	if parts.size() != 2:
		return false
	for part in parts:
		if part.is_empty() or part.length() > 100:
			return false
		for ch in part:
			if _ALLOWED_REPO_CHARS.find(ch) == -1:
				return false
	return true


## 校验版本号（tag / 分支 / commit hash）
func is_valid_version(p_version: String) -> bool:
	for ch in p_version:
		if _ALLOWED_VERSION_CHARS.find(ch) == -1:
			return false
	return true


## 校验仓库内路径（文件或目录）
func is_valid_path(p_path: String) -> bool:
	for ch in p_path:
		if _ALLOWED_PATH_CHARS.find(ch) == -1:
			return false
	return true


## 文本截断：超长时保留头部并追加截断标记
func truncate_text(p_text: String, p_max_length: int) -> String:
	if p_text.length() > p_max_length:
		return p_text.left(p_max_length) + "\n\n[...truncated at %d characters]" % p_max_length
	return p_text


## 通用 HTTPS GET 请求（固定 host + path 方式，host 无需解析）
## [return]: {"code": int, "body": PackedByteArray} 或 {"error": String}
func http_get(p_host: String, p_path: String) -> Dictionary:
	var client := HTTPClient.new()
	var err: Error = client.connect_to_host(p_host, 443, TLSOptions.client())
	if err != OK:
		client.close()
		return {"error": "Connection init failed (%d)" % err}
	
	var timer: float = 0.0
	while client.get_status() in [HTTPClient.STATUS_CONNECTING, HTTPClient.STATUS_RESOLVING]:
		client.poll()
		await Engine.get_main_loop().create_timer(POLL_DELAY).timeout
		timer += POLL_DELAY
		if timer >= REQUEST_TIMEOUT:
			client.close()
			return {"error": "Connection timeout"}
	
	if client.get_status() != HTTPClient.STATUS_CONNECTED:
		client.close()
		return {"error": "Connection failed (status: %d)" % client.get_status()}
	
	err = client.request(HTTPClient.METHOD_GET, p_path, ["User-Agent: GodotAIChat/1.0"])
	if err != OK:
		client.close()
		return {"error": "Request failed (%d)" % err}
	
	timer = 0.0
	while client.get_status() == HTTPClient.STATUS_REQUESTING:
		client.poll()
		await Engine.get_main_loop().create_timer(POLL_DELAY).timeout
		timer += POLL_DELAY
		if timer >= REQUEST_TIMEOUT:
			client.close()
			return {"error": "Request timeout"}
	
	var code: int = client.get_response_code()
	var body := PackedByteArray()
	while client.get_status() == HTTPClient.STATUS_BODY:
		client.poll()
		body.append_array(client.read_response_body_chunk())
		if client.get_status() == HTTPClient.STATUS_BODY:
			await Engine.get_main_loop().create_timer(POLL_DELAY).timeout
	
	client.close()
	return {"code": code, "body": body}
