@tool
extends BaseGithubTool

## GitHub Pull Request 概览工具
##
## 通过 GitHub API 获取单个 Pull Request 的核心信息：标题、状态、作者、分支关系、创建/更新时间、正文描述。
## 如需更详细内容，配合使用 fetch_github_pr_files / fetch_github_pr_commits / fetch_github_pr_comments / fetch_github_pr_reviews。

# --- Enums / Constants ---

const DEFAULT_REPO: String = "godotengine/godot"


# --- Public Functions ---

func _init() -> void:
	tool_name = "fetch_github_pr"
	tool_description = "Fetches the overview of a Pull Request (title, state, author, head/base branches, description) from a GitHub repository via GitHub API."


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
	
	var max_length := int(p_args.get("max_length", 30000))
	if max_length <= 0:
		max_length = 30000
	
	return await _fetch_pr_overview(repo, pr_number, max_length)


# --- Private Functions ---

# 抓取 PR 概览（GET /repos/{repo}/pulls/{pr}）
func _fetch_pr_overview(p_repo: String, p_pr_number: int, p_max_length: int) -> ToolResult:
	var url_path := "/repos/%s/pulls/%d" % [p_repo, p_pr_number]
	var resp: Dictionary = await http_get(API_HOST, url_path)
	
	if resp.has("error"):
		return ToolResult.fail("Error: " + str(resp.error))
	
	var code: int = resp.code
	if code != 200:
		return ToolResult.fail("Error: HTTP %d. PR #%d not found (repo: %s)." % [code, p_pr_number, p_repo])
	
	var json: Variant = JSON.parse_string(resp.body.get_string_from_utf8())
	if json == null:
		return ToolResult.fail("Error: Invalid JSON response from GitHub API.")
	
	var text := _format_pr_overview(json)
	return ToolResult.ok(truncate_text(text, p_max_length))


# 格式化 PR 概览信息
func _format_pr_overview(p_json: Variant) -> String:
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
