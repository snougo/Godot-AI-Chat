@tool
extends BaseGithubTool

## GitHub Pull Request 提交列表工具
##
## 通过 GitHub API 获取单个 Pull Request 的提交列表（短 SHA、提交标题、提交时间）。

# --- Enums / Constants ---

const DEFAULT_REPO: String = "godotengine/godot"
const DEFAULT_LIMIT: int = 30
const MAX_LIMIT: int = 100


# --- Public Functions ---

func _init() -> void:
	tool_name = "fetch_github_pr_commits"
	tool_description = "Fetches the commit list of a Pull Request from a GitHub repository via GitHub API."


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
				"description": "Maximum number of commits to return. Mirrors GitHub API per_page (max 100). Default: 30.",
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
	
	return await _fetch_pr_commits(repo, pr_number, limit, max_length)


# --- Private Functions ---

# 抓取 PR 提交列表（GET /repos/{repo}/pulls/{pr}/commits）
func _fetch_pr_commits(p_repo: String, p_pr_number: int, p_limit: int, p_max_length: int) -> ToolResult:
	var url_path := "/repos/%s/pulls/%d/commits?per_page=%d" % [p_repo, p_pr_number, p_limit]
	var resp: Dictionary = await http_get(API_HOST, url_path)
	
	if resp.has("error"):
		return ToolResult.fail("Error: " + str(resp.error))
	
	var code: int = resp.code
	if code != 200:
		return ToolResult.fail("Error: HTTP %d. PR #%d commits not found (repo: %s)." % [code, p_pr_number, p_repo])
	
	var json: Variant = JSON.parse_string(resp.body.get_string_from_utf8())
	if json == null:
		return ToolResult.fail("Error: Invalid JSON response from GitHub API.")
	
	var text := _format_pr_commits(json)
	return ToolResult.ok(truncate_text(text, p_max_length))


# 格式化 PR 提交列表
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
