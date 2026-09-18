@tool
extends BaseGithubTool

## GitHub Issue 详情工具
##
## 按编号获取单个 issue（对 PR 同样有效）的标题、状态、标签、里程碑、时间与正文，
## 并可选择连带抓取讨论评论。
## 与 fetch_github_pr_* 系列互补：那些工具走 /pulls 端点，本工具走 /issues 端点。

# --- Enums / Constants ---

const DEFAULT_REPO: String = "godotengine/godot"
const DEFAULT_COMMENTS_LIMIT: int = 20
const MAX_COMMENTS_LIMIT: int = 100
const DEFAULT_MAX_LENGTH: int = 30000


# --- Public Functions ---

func _init() -> void:
	tool_name = "fetch_github_issue"
	tool_description = "Fetches a single GitHub issue (also works for pull requests) by number: title, state, labels, milestone, body, and optionally its discussion comments."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"repo": {
				"type": "string",
				"description": "GitHub repository in 'owner/repo' format.",
				"default": DEFAULT_REPO
			},
			"issue": {
				"type": "integer",
				"description": "Issue (or pull request) number, e.g. 113290."
			},
			"include_comments": {
				"type": "boolean",
				"description": "Also fetch the discussion comments of the issue. Default: false.",
				"default": false
			},
			"comments_limit": {
				"type": "integer",
				"description": "Maximum number of comments to fetch when 'include_comments' is true (max 100). Default: 20.",
				"default": DEFAULT_COMMENTS_LIMIT
			},
			"max_length": {
				"type": "integer",
				"description": "Maximum character length of the returned content. Default: 30000.",
				"default": DEFAULT_MAX_LENGTH
			}
		},
		"required": ["repo", "issue"]
	}


func execute(p_args: Dictionary) -> ToolResult:
	var repo := normalize_repo(str(p_args.get("repo", DEFAULT_REPO)), DEFAULT_REPO)
	if not is_valid_repo(repo):
		return ToolResult.fail("Error: invalid repo '%s'. Expected format 'owner/repo' with [A-Za-z0-9._-] characters only." % repo)
	
	var issue_number := int(p_args.get("issue", 0))
	if issue_number <= 0:
		return ToolResult.fail("Error: must provide a valid 'issue' number.")
	
	var comments_limit := int(p_args.get("comments_limit", DEFAULT_COMMENTS_LIMIT))
	if comments_limit <= 0:
		comments_limit = DEFAULT_COMMENTS_LIMIT
	comments_limit = mini(comments_limit, MAX_COMMENTS_LIMIT)
	
	var max_length := int(p_args.get("max_length", DEFAULT_MAX_LENGTH))
	if max_length <= 0:
		max_length = DEFAULT_MAX_LENGTH
	
	return await _fetch_issue(repo, issue_number, bool(p_args.get("include_comments", false)), comments_limit, max_length)


# --- Private Functions ---

# 抓取 issue 详情（可选连带评论）
# [返回] ToolResult —— 错误一律用 ToolResult.fail()
func _fetch_issue(p_repo: String, p_issue_number: int, p_include_comments: bool, p_comments_limit: int, p_max_length: int) -> ToolResult:
	var resp: Dictionary = await http_get(API_HOST, "/repos/%s/issues/%d" % [p_repo, p_issue_number])
	
	if resp.has("error"):
		return ToolResult.fail("Error: " + str(resp.error))
	
	var code: int = resp.code
	var raw_body: String = resp.body.get_string_from_utf8()
	var api_message := _extract_api_message(raw_body)
	
	if code == 403 or code == 429:
		return ToolResult.fail("Error: HTTP %d - GitHub refused the request (unauthenticated core API allows 60 requests/hour per IP; the search API has a separate 10/minute pool). Wait before retrying. API message: %s" % [code, api_message])
	if code == 404:
		return ToolResult.fail("Error: HTTP 404. Issue #%d not found in '%s' (wrong number, or issues are disabled for that repository). API message: %s" % [p_issue_number, p_repo, api_message])
	if code == 410:
		return ToolResult.fail("Error: HTTP 410. Issues are disabled for '%s'." % p_repo)
	if code != 200:
		return ToolResult.fail("Error: HTTP %d. Failed to fetch issue #%d from '%s'. API message: %s" % [code, p_issue_number, p_repo, api_message])
	
	var json: Variant = JSON.parse_string(raw_body)
	if json == null or not (json is Dictionary):
		return ToolResult.fail("Error: invalid JSON response from GitHub API.")
	
	# 显式收窄为 Dictionary，避免把 Variant 传进强类型形参
	var data: Dictionary = json
	var output := _format_issue(data)
	
	if p_include_comments:
		output += await _fetch_comments(p_repo, p_issue_number, p_comments_limit)
	
	return ToolResult.ok(truncate_text(output, p_max_length))


# 从 GitHub 错误响应中提取 message 字段（回显限流/权限/参数错误原因）
func _extract_api_message(p_raw_body: String) -> String:
	var json: Variant = JSON.parse_string(p_raw_body)
	if json is Dictionary:
		var data: Dictionary = json
		return str(data.get("message", p_raw_body.left(200)))
	return p_raw_body.left(200)


# 格式化 issue 主体信息
func _format_issue(p_json: Dictionary) -> String:
	var labels: Array[String] = []
	for raw_label in p_json.get("labels", []):
		if raw_label is Dictionary:
			var label: Dictionary = raw_label
			labels.append(str(label.get("name", "")))
	var label_text := "-"
	if not labels.is_empty():
		label_text = ", ".join(PackedStringArray(labels))
	
	var user: Dictionary = p_json.get("user", {})
	var milestone: Dictionary = p_json.get("milestone", {})
	
	var output := "Issue #%d: %s\n" % [int(p_json.get("number", 0)), str(p_json.get("title", ""))]
	output += "State: %s" % str(p_json.get("state", "?"))
	if p_json.has("state_reason") and p_json.get("state_reason") != null:
		output += " (%s)" % str(p_json.get("state_reason"))
	output += "\n"
	output += "Labels: %s\n" % label_text
	output += "Author: @%s | created: %s | updated: %s | comments: %d\n" % [
		str(user.get("login", "?")),
		str(p_json.get("created_at", "")).left(10),
		str(p_json.get("updated_at", "")).left(10),
		int(p_json.get("comments", 0))
	]
	if not milestone.is_empty():
		output += "Milestone: %s\n" % str(milestone.get("title", ""))
	if p_json.has("pull_request"):
		output += "Type: pull request%s\n" % (" (draft)" if bool(p_json.get("draft", false)) else "")
	output += "URL: %s\n" % str(p_json.get("html_url", ""))
	output += "\n--- Body ---\n%s\n" % str(p_json.get("body", ""))
	return output


# 抓取讨论评论（失败时以提示形式附加，不影响主体信息）
# [返回] String —— 本函数的返回值会被拼接进 issue 正文，因此这里 return 字符串是正确的
func _fetch_comments(p_repo: String, p_issue_number: int, p_comments_limit: int) -> String:
	var api_path := "/repos/%s/issues/%d/comments?per_page=%d" % [p_repo, p_issue_number, p_comments_limit]
	var resp: Dictionary = await http_get(API_HOST, api_path)
	
	if resp.has("error"):
		return "\n--- Comments ---\n(unavailable: %s)\n" % str(resp.error)
	if resp.code != 200:
		return "\n--- Comments ---\n(unavailable: HTTP %d - %s)\n" % [resp.code, _extract_api_message(resp.body.get_string_from_utf8())]
	
	var json: Variant = JSON.parse_string(resp.body.get_string_from_utf8())
	if json == null or not (json is Array):
		return "\n--- Comments ---\n(unavailable: invalid JSON)\n"
	
	var comments: Array = json
	var output := "\n--- Comments (%d, oldest first) ---\n\n" % comments.size()
	for item in comments:
		var comment: Dictionary = item
		var user: Dictionary = comment.get("user", {})
		output += "--- @%s (%s) ---\n%s\n\n" % [
			str(user.get("login", "?")),
			str(comment.get("created_at", "")).left(10),
			str(comment.get("body", ""))
		]
	return output
