@tool
extends BaseGithubTool

## GitHub 仓库目录结构查看工具
##
## 列出任意公开 GitHub 仓库指定目录（或根目录）下的子目录与文件列表（单层），
## 让 LLM 逐层调查仓库结构。
## 路径参数经过健壮性规范化，支持 'core/'、'/core/'、'./core'、'a//b' 等任意写法。

# --- Enums / Constants ---

const DEFAULT_REPO: String = "godotengine/godot"
const DEFAULT_VERSION: String = "4.7.1-stable"


# --- Public Functions ---

func _init() -> void:
	tool_name = "list_github_repo_dir"
	tool_description = "Lists subdirectories and files in a directory of a public GitHub repository. Tips: Using `list_github_branches` to get branches first."


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
				"description": "Directory path inside the repo."
			},
			"version": {
				"type": "string",
				"description": "Git tag, branch or commit hash.",
				"default": DEFAULT_VERSION
			}
		},
		"required": ["repo"]
	}


func execute(p_args: Dictionary) -> ToolResult:
	var repo := normalize_repo(str(p_args.get("repo", DEFAULT_REPO)), DEFAULT_REPO)
	if not is_valid_repo(repo):
		return ToolResult.fail("Error: invalid repo '%s'. Expected format 'owner/repo' with [A-Za-z0-9._-] characters only." % repo)
	
	var path := normalize_path(str(p_args.get("path", "")))
	if not is_valid_path(path):
		return ToolResult.fail("Error: path contains invalid characters. Allowed: letters, digits, '.', '_', '-', '/'.")
	
	var version := normalize_version(str(p_args.get("version", DEFAULT_VERSION)), DEFAULT_VERSION)
	if version.is_empty():
		return ToolResult.fail("Error: version contains invalid characters. Allowed: letters, digits, '.', '_', '-'.")
	
	return await _list_directory(repo, path, version)


# --- Private Functions ---

# 通过 GitHub API 列出单层目录内容（contents API）
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
		return ToolResult.fail("Error: Invalid response from GitHub API (path may be a file, not a directory).")
	
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
