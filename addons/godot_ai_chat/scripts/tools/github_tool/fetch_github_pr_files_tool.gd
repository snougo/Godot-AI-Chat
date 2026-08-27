@tool
extends BaseGithubTool

## GitHub Pull Request 变更文件工具
##
## 通过 GitHub API 获取单个 Pull Request 的变更文件列表及 diff 补丁，含新增/删除行数统计。

# --- Enums / Constants ---

const DEFAULT_REPO: String = "godotengine/godot"
const DEFAULT_LIMIT: int = 30
const MAX_LIMIT: int = 100


# --- Public Functions ---

func _init() -> void:
	tool_name = "fetch_github_pr_files"
	tool_description = "Fetches the changed files with diffs of a Pull Request from a GitHub repository via GitHub API."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"repo": {
				"type": "string",
				"description": "GitHub repository in 'owner/repo' format.",
				"default": DEFAULT_REPO
			},
			"pr": {
				"type": "integer",
				"description": "GitHub Pull Request number (e.g. 110933)."
			},
			"limit": {
				"type": "integer",
				"description": "Maximum number of files to return. Mirrors GitHub API per_page (max 100). Default: 30.",
				"default": DEFAULT_LIMIT
			},
			"max_length": {
				"type": "integer",
				"description": "Maximum character length of returned content. Default: 30000.",
				"default": 30000
			}
		},
		"required": ["repo", "pr"]
	}


func execute(p_args: Dictionary) -> ToolResult:
	var repo := normalize_repo(str(p_args.get("repo", DEFAULT_REPO)), DEFAULT_REPO)
	if not is_valid_repo(repo):
		return ToolResult.fail("Error: invalid repo '%s'. Expected format 'owner/repo' with [A-Za-z0-9._-] characters only." % repo)
	
	var pr_number := int(p_args.get("pr", 0))
	if pr_number <= 0:
		return ToolResult.fail("Error: must provide a valid 'pr' (pull request number).")
	
	var limit := int(p_args.get("limit", DEFAULT_LIMIT))
	if limit <= 0:
		limit = DEFAULT_LIMIT
	limit = mini(limit, MAX_LIMIT)
	
	var max_length := int(p_args.get("max_length", 30000))
	if max_length <= 0:
		max_length = 30000
	
	return await _fetch_pr_files(repo, pr_number, limit, max_length)


# --- Private Functions ---

# 抓取 PR 变更文件（GET /repos/{repo}/pulls/{pr}/files）
func _fetch_pr_files(p_repo: String, p_pr_number: int, p_limit: int, p_max_length: int) -> ToolResult:
	var url_path := "/repos/%s/pulls/%d/files?per_page=%d" % [p_repo, p_pr_number, p_limit]
	var resp: Dictionary = await http_get(API_HOST, url_path)
	
	if resp.has("error"):
		return ToolResult.fail("Error: " + str(resp.error))
	
	var code: int = resp.code
	if code != 200:
		return ToolResult.fail("Error: HTTP %d. PR #%d files not found (repo: %s)." % [code, p_pr_number, p_repo])
	
	var json: Variant = JSON.parse_string(resp.body.get_string_from_utf8())
	if json == null:
		return ToolResult.fail("Error: Invalid JSON response from GitHub API.")
	
	var text := _format_pr_files(json)
	return ToolResult.ok(truncate_text(text, p_max_length))


# 格式化 PR 变更文件列表与 diff
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
