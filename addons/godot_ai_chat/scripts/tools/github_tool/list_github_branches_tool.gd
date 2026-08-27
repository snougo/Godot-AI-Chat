@tool
extends BaseGithubTool

## GitHub 仓库分支列表工具
##
## 获取任意公开 GitHub 仓库的默认分支（default branch）与全部分支名称列表。
## 解决 LLM 不确定主分支是 'main' 还是 'master'（或其它名称）的问题。
## 自动分页抓取所有分支（每页 100，循环取页直到取完）。

# --- Enums / Constants ---

const DEFAULT_REPO: String = "godotengine/godot"
const BRANCHES_PER_PAGE: int = 100


# --- Public Functions ---

func _init() -> void:
	tool_name = "list_github_branches"
	tool_description = "Lists the default branch and all branch names of a public GitHub repository."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"repo": {
				"type": "string",
				"description": "GitHub repository in 'owner/repo' format.",
				"default": DEFAULT_REPO
			}
		},
		"required": ["repo"]
	}


func execute(p_args: Dictionary) -> ToolResult:
	var repo := normalize_repo(str(p_args.get("repo", DEFAULT_REPO)), DEFAULT_REPO)
	if not is_valid_repo(repo):
		return ToolResult.fail("Error: invalid repo '%s'. Expected format 'owner/repo' with [A-Za-z0-9._-] characters only." % repo)
	
	var default_branch: String = await _fetch_default_branch(repo)
	if default_branch.is_empty():
		return ToolResult.fail("Error: failed to fetch repository info for '%s'." % repo)
	
	var branches: Array[String] = await _fetch_all_branches(repo)
	
	var output := "Repository: %s\n" % repo
	output += "Default branch: %s\n\n" % default_branch
	output += "Branches (%d):\n" % branches.size()
	for branch_name in branches:
		var marker := " (default)" if branch_name == default_branch else ""
		output += "  %s%s\n" % [branch_name, marker]
	
	return ToolResult.ok(output)


# --- Private Functions ---

# 获取仓库默认分支（GET /repos/{repo} 的 default_branch 字段）
func _fetch_default_branch(p_repo: String) -> String:
	var resp: Dictionary = await http_get(API_HOST, "/repos/%s" % p_repo)
	if resp.has("error") or resp.code != 200:
		return ""
	var json: Variant = JSON.parse_string(resp.body.get_string_from_utf8())
	if json is Dictionary:
		var data: Dictionary = json
		return str(data.get("default_branch", ""))
	return ""


# 分页抓取全部分支名（GET /repos/{repo}/branches?per_page=100&page=N）
func _fetch_all_branches(p_repo: String) -> Array[String]:
	var branches: Array[String] = []
	var page := 1
	while true:
		var api_path := "/repos/%s/branches?per_page=%d&page=%d" % [p_repo, BRANCHES_PER_PAGE, page]
		var resp: Dictionary = await http_get(API_HOST, api_path)
		if resp.has("error") or resp.code != 200:
			break
		var json: Variant = JSON.parse_string(resp.body.get_string_from_utf8())
		if json == null or not (json is Array):
			break
		var items: Array = json
		if items.is_empty():
			break
		for item in items:
			var branch: Dictionary = item
			branches.append(str(branch.get("name", "")))
		if items.size() < BRANCHES_PER_PAGE:
			break
		page += 1
	branches.sort()
	return branches
