@tool
extends BaseGithubTool

## GitHub Pull Request 阅读工具
##
## 通过 GitHub API 抓取指定 Pull Request 的内容：描述、变更文件、提交、评论、审查。
## 一次调用只获取一个 section，配合 limit 控制条目数量。

# --- Enums / Constants ---

const DEFAULT_REPO: String = "godotengine/godot"
const DEFAULT_SECTION: String = "description"
const DEFAULT_LIMIT: int = 30
const MAX_LIMIT: int = 100

const _ALLOWED_SECTIONS: Array[String] = ["description", "files", "commits", "comments", "reviews"]


func _init() -> void:
	tool_name = "fetch_github_pr"
	tool_description = "Fetches Pull Request contents from a GitHub repository via GitHub API."


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
			"pr": {
				"type": "integer",
				"description": "GitHub Pull Request number (e.g. 110933)."
			},
			"section": {
				"type": "string",
				"enum": _ALLOWED_SECTIONS,
				"description": "PR section to fetch. " + \
					"'description' (default): title/body/state/branches; 'files': changed files with diffs; " + \
					"'commits': commit list; 'comments': discussion comments; 'reviews': review summaries.",
				"default": DEFAULT_SECTION
			},
			"limit": {
				"type": "integer",
				"description": "Maximum number of items to return for 'files'/'commits'/'comments'/'reviews'. " + \
					"Mirrors GitHub API per_page (max 100). Default: 30.",
				"default": DEFAULT_LIMIT
			},
			"max_length": {
				"type": "integer",
				"description": "Maximum character length of returned content. Default: 30000.",
				"default": 30000
			}
		},
		"required": ["pr"]
	}


func execute(p_args: Dictionary) -> ToolResult:
	var repo := normalize_repo(str(p_args.get("repo", DEFAULT_REPO)), DEFAULT_REPO)
	if not is_valid_repo(repo):
		return ToolResult.fail("Error: invalid repo '%s'. Expected format 'owner/repo' with [A-Za-z0-9._-] characters only." % repo)
	
	var pr_number := int(p_args.get("pr", 0))
	if pr_number <= 0:
		return ToolResult.fail("Error: must provide a valid 'pr' (pull request number).")
	
	var section := str(p_args.get("section", DEFAULT_SECTION)).strip_edges().to_lower()
	if section.is_empty() or not section in _ALLOWED_SECTIONS:
		return ToolResult.fail("Error: invalid section '%s'. Allowed: %s." % [section, ", ".join(_ALLOWED_SECTIONS)])
	
	var limit := int(p_args.get("limit", DEFAULT_LIMIT))
	if limit <= 0:
		limit = DEFAULT_LIMIT
	limit = mini(limit, MAX_LIMIT)
	
	var max_length := int(p_args.get("max_length", 30000))
	if max_length <= 0:
		max_length = 30000
	
	return await _fetch_pr(repo, pr_number, section, limit, max_length)


# --- Private: PR 抓取 ---

# 按 section 构建 GitHub API URL 并抓取
func _fetch_pr(p_repo: String, p_pr_number: int, p_section: String, p_limit: int, p_max_length: int) -> ToolResult:
	var url_path: String
	match p_section:
		"files":
			url_path = "/repos/%s/pulls/%d/files?per_page=%d" % [p_repo, p_pr_number, p_limit]
		"commits":
			url_path = "/repos/%s/pulls/%d/commits?per_page=%d" % [p_repo, p_pr_number, p_limit]
		"comments":
			url_path = "/repos/%s/issues/%d/comments?per_page=%d" % [p_repo, p_pr_number, p_limit]
		"reviews":
			url_path = "/repos/%s/pulls/%d/reviews?per_page=%d" % [p_repo, p_pr_number, p_limit]
		_:
			url_path = "/repos/%s/pulls/%d" % [p_repo, p_pr_number]
	
	var resp: Dictionary = await http_get(API_HOST, url_path)
	
	if resp.has("error"):
		return ToolResult.fail("Error: " + str(resp.error))
	
	var code: int = resp.code
	if code != 200:
		return ToolResult.fail("Error: HTTP %d. PR #%d (%s) not found (repo: %s)." % [code, p_pr_number, p_section, p_repo])
	
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

	return ToolResult.ok(truncate_text(text, p_max_length))


# --- Private: 格式化 ---

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
