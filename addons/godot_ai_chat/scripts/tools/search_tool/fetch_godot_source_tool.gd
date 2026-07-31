@tool
extends AiTool

## 抓取 Godot 引擎 GitHub 源码工具
##
## 直接使用 HTTPClient 访问 raw.githubusercontent.com 获取纯文本源码，
## 完整保留原始排版（web_fetch_content 的 HTML 解析会破坏代码格式）。
## 支持按 tag/分支/commit 抓取文件内容，也可列出仓库目录结构。
## 支持通过 GitHub API 抓取 Pull Request 内容（描述/变更文件/提交/评论/审查）。

# --- Enums / Constants ---

const REQUEST_TIMEOUT: float = 30.0
const POLL_DELAY: float = 0.01

const DEFAULT_REPO: String = "godotengine/godot"
const DEFAULT_VERSION: String = "4.7.1-stable"
const RAW_HOST: String = "raw.githubusercontent.com"
const API_HOST: String = "api.github.com"

# 路径/版本字符白名单：防止 URL 注入
const _ALLOWED_PATH_CHARS: String = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._/-"
const _ALLOWED_VERSION_CHARS: String = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
const _ALLOWED_SECTIONS: Array[String] = ["description", "files", "commits", "comments", "reviews"]


func _init() -> void:
	tool_name = "fetch_godot_source"
	tool_description = "Fetches Godot engine source files from the official GitHub repo, and Pull Request contents via GitHub API."


# --- Public Functions ---

func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"path": {
				"type": "string",
				"description": "File or directory path inside the Godot repo. " + \
					"File: 'core/object/object.cpp'. Directory (must end with '/'): 'core/object/'. " + \
					"Provide either 'path' or 'pr'."
			},
			"pr": {
				"type": "integer",
				"description": "GitHub Pull Request number (e.g. 110933). When set, fetches PR content via GitHub API. " + \
					"Provide either 'path' or 'pr'."
			},
			"section": {
				"type": "string",
				"description": "PR section to fetch (only used with 'pr'). " + \
					"'description' (default): title/body/state/branches; 'files': changed files with diffs; " + \
					"'commits': commit list; 'comments': discussion comments; 'reviews': review summaries."
			},
			"version": {
				"type": "string",
				"description": "Git tag, branch or commit hash. Default: '4.7.1-stable'. " + \
					"Examples: 'master', '4.7-stable', 'a13da4f'.",
				"default": DEFAULT_VERSION
			},
			"max_length": {
				"type": "integer",
				"description": "Maximum character length of returned content. Default: 30000.",
				"default": 30000
			}
		},
		"required": []
	}


func execute(p_args: Dictionary) -> ToolResult:
	var path: String = str(p_args.get("path", "")).strip_edges()
	var pr_number: int = int(p_args.get("pr", 0))
	
	if pr_number <= 0 and path.is_empty():
		return ToolResult.fail("Error: must provide either 'path' (source file) or 'pr' (pull request number).")
	
	if pr_number > 0:
		var section: String = str(p_args.get("section", "description")).strip_edges().to_lower()
		if section.is_empty() or not section in _ALLOWED_SECTIONS:
			return ToolResult.fail("Error: invalid section '%s'. Allowed: %s." % [section, ", ".join(_ALLOWED_SECTIONS)])
		var pr_max_length: int = int(p_args.get("max_length", 30000))
		if pr_max_length <= 0:
			pr_max_length = 30000
		return await _fetch_pr(pr_number, section, pr_max_length)
	
	if not _is_valid_path(path):
		return ToolResult.fail("Error: path contains invalid characters. Allowed: letters, digits, '.', '_', '-', '/'.")
	
	var version: String = str(p_args.get("version", DEFAULT_VERSION)).strip_edges()
	if version.is_empty():
		version = DEFAULT_VERSION
	if not _is_valid_version(version):
		return ToolResult.fail("Error: version contains invalid characters. Allowed: letters, digits, '.', '_', '-'.")
	
	var max_length: int = int(p_args.get("max_length", 30000))
	if max_length <= 0:
		max_length = 30000
	
	if path.ends_with("/"):
		return await _list_directory(path.trim_suffix("/"), version)
	return await _fetch_file(path, version, max_length)


# --- Private: 校验 ---

func _is_valid_path(p_path: String) -> bool:
	for ch in p_path:
		if _ALLOWED_PATH_CHARS.find(ch) == -1:
			return false
	return true


func _is_valid_version(p_version: String) -> bool:
	for ch in p_version:
		if _ALLOWED_VERSION_CHARS.find(ch) == -1:
			return false
	return true


# --- Private: 网络 ---

# 通用 HTTPS GET 请求
# 返回 {"code": int, "body": PackedByteArray} 或 {"error": String}
func _http_get(p_host: String, p_path: String) -> Dictionary:
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


# --- Private: 文件抓取 ---

func _fetch_file(p_path: String, p_version: String, p_max_length: int) -> ToolResult:
	var url_path := "/%s/%s/%s" % [DEFAULT_REPO, p_version, p_path]
	var resp: Dictionary = await _http_get(RAW_HOST, url_path)
	
	if resp.has("error"):
		return ToolResult.fail("Error: " + str(resp.error))
	
	var code: int = resp.code
	if code != 200:
		return ToolResult.fail("Error: HTTP %d. File '%s' not found (version: %s)." % [code, p_path, p_version])
	
	var body: PackedByteArray = resp.body
	var text: String = body.get_string_from_utf8()
	if text.is_empty() and not body.is_empty():
		text = body.get_string_from_ascii()
	if text.is_empty():
		return ToolResult.fail("Error: Response body is empty (file may be binary).")
	
	var meta := "Source: https://github.com/%s/blob/%s/%s\n\n" % [DEFAULT_REPO, p_version, p_path]
	
	if text.length() > p_max_length:
		text = text.left(p_max_length) + "\n\n[...truncated at %d characters]" % p_max_length
	
	return ToolResult.ok(meta + text)


# --- Private: 目录列表 ---

func _list_directory(p_path: String, p_version: String) -> ToolResult:
	var url_path := "/repos/%s/contents/%s?ref=%s" % [DEFAULT_REPO, p_path, p_version]
	var resp: Dictionary = await _http_get(API_HOST, url_path)
	
	if resp.has("error"):
		return ToolResult.fail("Error: " + str(resp.error))
	
	var code: int = resp.code
	if code != 200:
		return ToolResult.fail("Error: HTTP %d. Directory '%s/' not found (version: %s)." % [code, p_path, p_version])
	
	var json: Variant = JSON.parse_string(resp.body.get_string_from_utf8())
	if json == null or not (json is Array):
		return ToolResult.fail("Error: Invalid response from GitHub API.")
	
	var items: Array = json
	var dir_names: Array[String] = []
	var file_entries: Array[Dictionary] = []
	
	for item in items:
		var entry: Dictionary = item
		var entry_name: String = str(entry.get("name", ""))
		var entry_type: String = str(entry.get("type", ""))
		if entry_type == "dir":
			dir_names.append(entry_name + "/")
		elif entry_type == "file":
			file_entries.append({
				"name": entry_name,
				"size_kb": int(entry.get("size", 0) / 1024.0)
			})
	
	dir_names.sort()
	file_entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a["name"]) < str(b["name"]))
	
	var output := "Directory: %s/ (version: %s)\n\n" % [p_path, p_version]
	output += "Subdirectories (%d):\n" % dir_names.size()
	for dir_name in dir_names:
		output += "  %s\n" % dir_name
	output += "\nFiles (%d):\n" % file_entries.size()
	for file_entry in file_entries:
		output += "  %s (%d KB)\n" % [file_entry.name, file_entry.size_kb]
	
	return ToolResult.ok(output)


# --- Private: PR 抓取 ---

func _fetch_pr(p_pr_number: int, p_section: String, p_max_length: int) -> ToolResult:
	var url_path: String
	match p_section:
		"files":
			url_path = "/repos/%s/pulls/%d/files" % [DEFAULT_REPO, p_pr_number]
		"commits":
			url_path = "/repos/%s/pulls/%d/commits" % [DEFAULT_REPO, p_pr_number]
		"comments":
			url_path = "/repos/%s/issues/%d/comments" % [DEFAULT_REPO, p_pr_number]
		"reviews":
			url_path = "/repos/%s/pulls/%d/reviews" % [DEFAULT_REPO, p_pr_number]
		_:
			url_path = "/repos/%s/pulls/%d" % [DEFAULT_REPO, p_pr_number]
	
	var resp: Dictionary = await _http_get(API_HOST, url_path)
	
	if resp.has("error"):
		return ToolResult.fail("Error: " + str(resp.error))
	
	var code: int = resp.code
	if code != 200:
		return ToolResult.fail("Error: HTTP %d. PR #%d (%s) not found." % [code, p_pr_number, p_section])
	
	var json: Variant = JSON.parse_string(resp.body.get_string_from_utf8())
	if json == null:
		return ToolResult.fail("Error: Invalid JSON response from GitHub API.")
	
	var text: String
	match p_section:
		"files":
			text = _format_pr_files(json)
		"commits":
			text = _format_pr_commits(json)
		"comments":
			text = _format_pr_comments(json)
		"reviews":
			text = _format_pr_reviews(json)
		_:
			text = _format_pr_description(json)
	
	if text.length() > p_max_length:
		text = text.left(p_max_length) + "\n\n[...truncated at %d characters]" % p_max_length
	
	return ToolResult.ok(text)


func _format_pr_description(p_json: Variant) -> String:
	var data: Dictionary = p_json
	var user: Dictionary = data.get("user", {})
	var head: Dictionary = data.get("head", {})
	var base: Dictionary = data.get("base", {})
	var output := "PR #%d: %s\n" % [int(data.get("number", 0)), str(data.get("title", ""))]
	output += "State: %s | Merged: %s\n" % [str(data.get("state", "?")), "yes" if data.get("merged", false) else "no"]
	output += "Author: %s\n" % str(user.get("login", "?"))
	output += "Branch: %s -> %s\n" % [str(head.get("ref", "?")), str(base.get("ref", "?"))]
	output += "Created: %s | Updated: %s\n" % [str(data.get("created_at", "")), str(data.get("updated_at", ""))]
	output += "URL: %s\n\n" % str(data.get("html_url", ""))
	output += "--- Description ---\n"
	output += str(data.get("body", "(no description)"))
	return output


func _format_pr_files(p_json: Variant) -> String:
	var files: Array = p_json
	var output := "Changed files (%d):\n\n" % files.size()
	var total_added: int = 0
	var total_deleted: int = 0
	for item in files:
		var file: Dictionary = item
		var additions: int = int(file.get("additions", 0))
		var deletions: int = int(file.get("deletions", 0))
		total_added += additions
		total_deleted += deletions
		output += "📄 %s (+%d -%d)\n" % [str(file.get("filename", "?")), additions, deletions]
		var patch: String = str(file.get("patch", ""))
		if not patch.is_empty():
			output += "```diff\n%s\n```\n\n" % patch
	output += "\nTotal: +%d -%d" % [total_added, total_deleted]
	return output


func _format_pr_commits(p_json: Variant) -> String:
	var commits: Array = p_json
	var output := "Commits (%d):\n\n" % commits.size()
	for item in commits:
		var commit: Dictionary = item
		var commit_data: Dictionary = commit.get("commit", {})
		var author: Dictionary = commit_data.get("author", {})
		var message: String = str(commit_data.get("message", ""))
		var first_line := message.split("\n")[0] if "\n" in message else message
		output += "• %s — %s (%s)\n" % [
			str(commit.get("sha", "")).left(7),
			first_line,
			str(author.get("date", ""))
		]
	return output


func _format_pr_comments(p_json: Variant) -> String:
	var comments: Array = p_json
	var output := "Comments (%d):\n\n" % comments.size()
	for item in comments:
		var comment: Dictionary = item
		var user: Dictionary = comment.get("user", {})
		output += "--- @%s (%s) ---\n%s\n\n" % [
			str(user.get("login", "?")),
			str(comment.get("created_at", "")),
			str(comment.get("body", ""))
		]
	return output


func _format_pr_reviews(p_json: Variant) -> String:
	var reviews: Array = p_json
	var output := "Reviews (%d):\n\n" % reviews.size()
	for item in reviews:
		var review: Dictionary = item
		var user: Dictionary = review.get("user", {})
		output += "--- @%s (%s) — %s ---\n%s\n\n" % [
			str(user.get("login", "?")),
			str(review.get("submitted_at", "")),
			str(review.get("state", "?")),
			str(review.get("body", "(no body)"))
		]
	return output
