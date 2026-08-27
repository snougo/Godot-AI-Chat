@tool
extends BaseGithubTool

## GitHub 仓库文件内容抓取工具
##
## 从任意公开 GitHub 仓库抓取指定路径的单个文件原始内容，完整保留排版，全量返回（不截断）。
## 路径参数经过健壮性规范化，支持 'core/object.cpp'、'./core/object.cpp' 等写法。

# --- Enums / Constants ---

const DEFAULT_REPO: String = "godotengine/godot"
const DEFAULT_VERSION: String = "4.7.1-stable"


# --- Public Functions ---

func _init() -> void:
	tool_name = "fetch_github_file"
	tool_description = "Fetches the full raw content of a single file from a public GitHub repository."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"repo": {
				"type": "string",
				"description": "GitHub repository in 'owner/repo' format.",
				"default": DEFAULT_REPO
			},
			"path": {
				"type": "string",
				"description": "File path inside the repo."
			},
			"version": {
				"type": "string",
				"description": "Git tag, branch or commit hash.",
				"default": DEFAULT_VERSION
			}
		},
		"required": ["repo", "path", "version"]
	}


func execute(p_args: Dictionary) -> ToolResult:
	var repo := normalize_repo(str(p_args.get("repo", DEFAULT_REPO)), DEFAULT_REPO)
	if not is_valid_repo(repo):
		return ToolResult.fail("Error: invalid repo '%s'. Expected format 'owner/repo' with [A-Za-z0-9._-] characters only." % repo)
	
	var raw_path := str(p_args.get("path", "")).strip_edges()
	if raw_path.ends_with("/"):
		return ToolResult.fail("Error: 'path' ends with '/' so it points to a directory, not a file. " + \
			"This tool fetches file contents only; use 'list_github_repo_dir' to list directory contents.")
	
	var path := normalize_path(raw_path)
	if path.is_empty():
		return ToolResult.fail("Error: 'path' is required and must point to a file (e.g. 'core/object.cpp').")
	if not is_valid_path(path):
		return ToolResult.fail("Error: path contains invalid characters. Allowed: letters, digits, '.', '_', '-', '/'.")
	
	var version := normalize_version(str(p_args.get("version", DEFAULT_VERSION)), DEFAULT_VERSION)
	if version.is_empty():
		return ToolResult.fail("Error: version contains invalid characters. Allowed: letters, digits, '.', '_', '-'.")
	
	return await _fetch_file(repo, path, version)


# --- Private Functions ---

# 从 raw.githubusercontent.com 抓取单文件原始内容（全量返回，不截断）
func _fetch_file(p_repo: String, p_path: String, p_version: String) -> ToolResult:
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
	
	return ToolResult.ok(meta + text)
