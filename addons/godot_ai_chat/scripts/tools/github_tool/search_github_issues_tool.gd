@tool
extends BaseGithubTool

## GitHub Issue / PR 搜索工具
##
## 通过 GitHub 搜索 API 在指定仓库内按关键词与限定符检索 issue 与 pull request。
## 支持 GitHub 检索语法（label:、in:title、created:>2026-06-01、is:issue 等），
## 用于提交前查重、检索历史讨论、定位相关回归报告。
##
## 注意：搜索 API 未认证时限制为 10 次/分钟，调用时应尽量合并关键词、减少次数。

# --- Enums / Constants ---

const DEFAULT_REPO: String = "godotengine/godot"
const DEFAULT_RESULTS: int = 10
const MAX_RESULTS: int = 30
const DEFAULT_BODY_CHARS: int = 280

const ALLOWED_STATES: Array[String] = ["all", "open", "closed"]
const ALLOWED_SORTS: Array[String] = ["created", "updated", "comments"]
const ALLOWED_ORDERS: Array[String] = ["desc", "asc"]


# --- Public Functions ---

func _init() -> void:
	tool_name = "search_github_issues"
	tool_description = "Searches issues AND pull requests of a GitHub repository with the GitHub search API. The query supports GitHub qualifiers (e.g. label:\"topic:gui\", in:title, created:>2026-06-01, is:issue, is:pr). Use it to look for existing or duplicate reports before filing an issue. Unauthenticated search is limited to 10 requests per minute, so prefer few, well-combined queries."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"query": {
				"type": "string",
				"description": "Search keywords and GitHub qualifiers, e.g. '\"scroll_fit_content_height\" blank' or 'label:regression in:title scroll'."
			},
			"repo": {
				"type": "string",
				"description": "GitHub repository in 'owner/repo' format.",
				"default": DEFAULT_REPO
			},
			"state": {
				"type": "string",
				"description": "Filter by state: 'all', 'open' or 'closed'.",
				"default": "all"
			},
			"include_prs": {
				"type": "boolean",
				"description": "If false, only issues are returned (adds 'is:issue'). Default: true (issues and pull requests).",
				"default": true
			},
			"sort": {
				"type": "string",
				"description": "Sort field: 'created', 'updated' or 'comments'.",
				"default": "created"
			},
			"order": {
				"type": "string",
				"description": "Sort order: 'desc' or 'asc'.",
				"default": "desc"
			},
			"max_results": {
				"type": "integer",
				"description": "Maximum number of results to return (1-30). Default: 10.",
				"default": DEFAULT_RESULTS
			},
			"body_chars": {
				"type": "integer",
				"description": "Maximum characters of each result's body to include as a one-line snippet. 0 disables snippets. Default: 280.",
				"default": DEFAULT_BODY_CHARS
			}
		},
		"required": ["query"]
	}


func execute(p_args: Dictionary) -> ToolResult:
	var query := str(p_args.get("query", "")).strip_edges()
	if query.is_empty():
		return ToolResult.fail("Error: must provide a non-empty 'query'.")
	
	var repo := normalize_repo(str(p_args.get("repo", DEFAULT_REPO)), DEFAULT_REPO)
	if not is_valid_repo(repo):
		return ToolResult.fail("Error: invalid repo '%s'. Expected format 'owner/repo' with [A-Za-z0-9._-] characters only." % repo)
	
	var state := str(p_args.get("state", "all")).to_lower()
	if not ALLOWED_STATES.has(state):
		state = "all"
	
	var sort_field := str(p_args.get("sort", "created")).to_lower()
	if not ALLOWED_SORTS.has(sort_field):
		sort_field = "created"
	
	var order := str(p_args.get("order", "desc")).to_lower()
	if not ALLOWED_ORDERS.has(order):
		order = "desc"
	
	var max_results := int(p_args.get("max_results", DEFAULT_RESULTS))
	if max_results <= 0:
		max_results = DEFAULT_RESULTS
	max_results = mini(max_results, MAX_RESULTS)
	
	var body_chars := int(p_args.get("body_chars", DEFAULT_BODY_CHARS))
	if body_chars < 0:
		body_chars = 0
	
	# 组合检索式：仓库限定 + 用户查询 + 可选状态/类型限定
	var full_query := "repo:%s %s" % [repo, query]
	if state != "all":
		full_query += " state:%s" % state
	if not bool(p_args.get("include_prs", true)):
		full_query += " is:issue"
	
	return await _search_issues(full_query, sort_field, order, max_results, body_chars)


# --- Private Functions ---

# 执行搜索（GET /search/issues）
func _search_issues(p_query: String, p_sort: String, p_order: String, p_max_results: int, p_body_chars: int) -> ToolResult:
	var api_path := "/search/issues?q=%s&sort=%s&order=%s&per_page=%d" % [
		p_query.uri_encode(), p_sort, p_order, p_max_results
	]
	var resp: Dictionary = await http_get(API_HOST, api_path)
	
	if resp.has("error"):
		return ToolResult.fail("Error: " + str(resp.error))
	
	var code: int = resp.code
	var raw_body: String = resp.body.get_string_from_utf8()
	
	if code == 403 or code == 429:
		return ToolResult.fail("Error: HTTP %d - GitHub search rate limit exceeded (unauthenticated search allows 10 requests per minute). Wait before retrying. API message: %s" % [code, _extract_api_message(raw_body)])
	if code == 422:
		return ToolResult.fail("Error: HTTP 422 - GitHub rejected the query. Check the qualifiers (invalid label name, malformed 'created:>' value, ...). API message: %s" % _extract_api_message(raw_body))
	if code != 200:
		return ToolResult.fail("Error: HTTP %d from the GitHub search API. %s" % [code, _extract_api_message(raw_body)])
	
	var json: Variant = JSON.parse_string(raw_body)
	if json == null or not (json is Dictionary):
		return ToolResult.fail("Error: invalid JSON response from the GitHub search API.")
	
	# 显式收窄为 Dictionary，避免把 Variant 传进强类型形参
	var data: Dictionary = json
	return ToolResult.ok(_format_search_result(data, p_query, p_body_chars))


# 格式化搜索结果（总数 / 截断提示 / 逐条条目）
func _format_search_result(p_json: Dictionary, p_query: String, p_body_chars: int) -> String:
	var total_count := int(p_json.get("total_count", 0))
	var items: Array = p_json.get("items", [])
	
	var output := "Query: %s\n" % p_query
	output += "Total matches: %d (showing %d)\n" % [total_count, items.size()]
	if total_count > items.size():
		output += "Note: more matches exist. Narrow the query (e.g. in:title, label:, created:>) or raise 'max_results'.\n"
	if bool(p_json.get("incomplete_results", false)):
		output += "Note: GitHub flagged this result set as incomplete (search timeout).\n"
	output += "\n"
	
	if items.is_empty():
		output += "No matching issue or pull request.\n"
		return output
	
	var index := 1
	for item in items:
		var issue: Dictionary = item
		output += _format_item(issue, index, p_body_chars)
		index += 1
	return output


# 格式化单条结果
func _format_item(p_issue: Dictionary, p_index: int, p_body_chars: int) -> String:
	var kind := "PR" if p_issue.has("pull_request") else "issue"
	
	var labels: Array[String] = []
	for raw_label in p_issue.get("labels", []):
		if raw_label is Dictionary:
			var label: Dictionary = raw_label
			labels.append(str(label.get("name", "")))
	var label_text := "-"
	if not labels.is_empty():
		label_text = ", ".join(PackedStringArray(labels))
	
	var line := "%d. #%d [%s][%s] %s\n" % [
		p_index,
		int(p_issue.get("number", 0)),
		str(p_issue.get("state", "?")),
		kind,
		str(p_issue.get("title", ""))
	]
	line += "   labels: %s | comments: %d | created: %s | updated: %s\n" % [
		label_text,
		int(p_issue.get("comments", 0)),
		str(p_issue.get("created_at", "")).left(10),
		str(p_issue.get("updated_at", "")).left(10)
	]
	line += "   url: %s\n" % str(p_issue.get("html_url", ""))
	
	if p_body_chars > 0:
		var snippet := _make_snippet(str(p_issue.get("body", "")), p_body_chars)
		if not snippet.is_empty():
			line += "   body: %s\n" % snippet
	line += "\n"
	return line


# 生成单行正文摘要（折叠空白并截断）
func _make_snippet(p_text: String, p_max_chars: int) -> String:
	var flat := p_text.replace("\r", " ").replace("\n", " ").replace("\t", " ")
	while flat.find("  ") != -1:
		flat = flat.replace("  ", " ")
	flat = flat.strip_edges()
	if flat.length() > p_max_chars:
		flat = flat.left(p_max_chars) + "…"
	return flat


# 从 GitHub 错误响应中提取 message 字段（回显限流/限定符错误原因）
func _extract_api_message(p_raw_body: String) -> String:
	var json: Variant = JSON.parse_string(p_raw_body)
	if json is Dictionary:
		var data: Dictionary = json
		return str(data.get("message", p_raw_body.left(200)))
	return p_raw_body.left(200)
