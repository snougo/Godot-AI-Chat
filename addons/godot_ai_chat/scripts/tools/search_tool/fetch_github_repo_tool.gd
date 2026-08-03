@tool
extends BaseGithubTool

## 通用 GitHub 仓库查看工具
##
## 直接使用 HTTPClient 访问 raw.githubusercontent.com / api.github.com 抓取任意公开仓库内容，
## 完整保留原始排版。支持按 tag/分支/commit 抓取单个文件，也可逐层列出目录结构。
## 设计意图：让 LLM 逐层调查仓库目录，而非一次性接收整个文件树。

# --- Enums / Constants ---

const DEFAULT_REPO: String = "godotengine/godot"
const DEFAULT_VERSION: String = "4.7.1-stable"

const _ALLOWED_TYPES: Array[String] = ["auto", "file", "dir"]


func _init() -> void:
	tool_name = "fetch_github_repo"
	tool_description = "Fetches files or lists a directory from any public GitHub repository."


# --- Public Functions ---

func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"repo": {
				"type": "string",
				"description": "GitHub repository in 'owner/repo' format. Default: 'godotengine/godot'.",
				"default": DEFAULT_REPO
			},
			"path": {
				"type": "string",
				"description": "File or directory path inside the repo, e.g. 'core/object.cpp' or 'core/'. " + \
					"Empty (or omitted) lists the repo root directory."
			},
			"type": {
				"type": "string",
				"enum": _ALLOWED_TYPES,
				"description": "Target type: 'auto' (default: empty path or trailing '/' => dir, otherwise file), " + \
					"'file' (fetch raw content), 'dir' (list directory)."
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
		"required": ["repo", "version"]
	}


func execute(p_args: Dictionary) -> ToolResult:
	var repo := normalize_repo(str(p_args.get("repo", DEFAULT_REPO)), DEFAULT_REPO)
	if not is_valid_repo(repo):
		return ToolResult.fail("Error: invalid repo '%s'. Expected format 'owner/repo' with [A-Za-z0-9._-] characters only." % repo)
	
	var path := str(p_args.get("path", "")).strip_edges()
	if not is_valid_path(path):
		return ToolResult.fail("Error: path contains invalid characters. Allowed: letters, digits, '.', '_', '-', '/'.")
	
	var path_type := str(p_args.get("type", "auto")).strip_edges().to_lower()
	if not path_type in _ALLOWED_TYPES:
		return ToolResult.fail("Error: invalid type '%s'. Allowed: %s." % [path_type, ", ".join(_ALLOWED_TYPES)])
	
	var version := str(p_args.get("version", DEFAULT_VERSION)).strip_edges()
	if version.is_empty():
		version = DEFAULT_VERSION
	if not is_valid_version(version):
		return ToolResult.fail("Error: version contains invalid characters. Allowed: letters, digits, '.', '_', '-'.")
	
	var max_length := int(p_args.get("max_length", 30000))
	if max_length <= 0:
		max_length = 30000
	
	# 解析实际类型：auto 时按空路径/尾斜杠推断
	var resolved_type := path_type
	if resolved_type == "auto":
		resolved_type = "dir" if (path.is_empty() or path.ends_with("/")) else "file"
	
	if resolved_type == "dir":
		return await _list_directory(repo, path, version)
	return await _fetch_file(repo, path, version, max_length)


# --- Private: 文件抓取 ---

# 从 raw.githubusercontent.com 抓取单文件原始内容
func _fetch_file(p_repo: String, p_path: String, p_version: String, p_max_length: int) -> ToolResult:
	if p_path.is_empty():
		return ToolResult.fail("Error: 'type=file' requires a non-empty 'path'.")
	
	var url_path := "/%s/%s/%s" % [p_repo, p_version, p_path]
	var resp: Dictionary = await http_get(RAW_HOST, url_path)
	
	if resp.has("error"):
		return ToolResult.fail("Error: " + str(resp.error))
	
	var code: int = resp.code
	if code != 200:
		return ToolResult.fail("Error: HTTP %d. File '%s' not found (repo: %s, version: %s)." % [code, p_path, p_repo, p_version])
	
	var body: PackedByteArray = resp.body
	var text: String = body.get_string_from_utf8()
	if text.is_empty() and not body.is_empty():
		text = body.get_string_from_ascii()
	if text.is_empty():
		return ToolResult.fail("Error: Response body is empty (file may be binary).")
	
	var meta := "Source: https://github.com/%s/blob/%s/%s\n\n" % [p_repo, p_version, p_path]
	
	return ToolResult.ok(truncate_text(meta + text, p_max_length))


# --- Private: 目录列表 ---

# 通过 GitHub API 列出单层目录内容（contents API，不分页）
func _list_directory(p_repo: String, p_path: String, p_version: String) -> ToolResult:
	var api_path := "/repos/%s/contents" % p_repo
	if not p_path.is_empty():
		api_path += "/" + p_path
	api_path += "?ref=%s" % p_version
	var resp: Dictionary = await http_get(API_HOST, api_path)
	
	if resp.has("error"):
		return ToolResult.fail("Error: " + str(resp.error))
	
	var code: int = resp.code
	if code != 200:
		return ToolResult.fail("Error: HTTP %d. Directory '%s/' not found (repo: %s, version: %s)." % [code, p_path, p_repo, p_version])
	
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
	
	var display_path: String = p_path if not p_path.is_empty() else "(root)"
	var output := "Directory: %s/ (repo: %s, version: %s)\n\n" % [display_path, p_repo, p_version]
	output += "Subdirectories (%d):\n" % dir_names.size()
	for dir_name in dir_names:
		output += "  %s\n" % dir_name
	output += "\nFiles (%d):\n" % file_entries.size()
	for file_entry in file_entries:
		output += "  %s (%d KB)\n" % [file_entry.name, file_entry.size_kb]
	
	return ToolResult.ok(output)
