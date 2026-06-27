@tool
class_name SketchfabSearchTool
extends AiTool

## 在 Sketchfab 上搜索 3D 模型。
## 使用公开的 Data API v3，无需认证。

# --- Enums / Constants ---

const API_HOST: String = "api.sketchfab.com"
const API_PORT: int = 443
const SEARCH_PATH: String = "/v3/models"
const REQUEST_TIMEOUT: float = 30.0
const POLL_DELAY: float = 0.01

const SORT_OPTIONS: Array[String] = [
	"-likeCount",
	"-viewCount",
	"-publishedAt",
	"likeCount",
	"viewCount",
	"publishedAt",
]

# --- Built-in Functions ---

func _init() -> void:
	tool_name = "search_sketchfab"
	tool_description = "Search 3D models on Sketchfab. Returns model name, UID, thumbnail URL, face/vertex count, and license info. Use this to browse and discover models before downloading."


# --- Public Functions ---

func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"query": {
				"type": "string",
				"description": "Search keyword. Leave empty to browse all models."
			},
			"categories": {
				"type": "string",
				"description": "Category slug filter (e.g., 'animals-pets', 'architecture', 'characters-creatures'). Leave empty for all categories."
			},
			"animated": {
				"type": "boolean",
				"description": "Filter for animated models only. Default: false."
			},
			"staffpicked": {
				"type": "boolean",
				"description": "Filter for Sketchfab staff-picked models only. Default: false."
			},
			"sort_by": {
				"type": "string",
				"enum": ["-likeCount", "-viewCount", "-publishedAt", "likeCount", "viewCount", "publishedAt"],
				"description": "Sort order. '-likeCount' = most liked first. Default: '-likeCount'."
			},
			"limit": {
				"type": "integer",
				"description": "Number of results per page (max 24). Default: 12."
			}
		},
		"required": ["query"]
	}


func execute(p_args: Dictionary) -> Dictionary:
	var query: String = p_args.get("query", "")
	var categories: String = p_args.get("categories", "")
	var animated: bool = p_args.get("animated", false)
	var staffpicked: bool = p_args.get("staffpicked", false)
	var sort_by: String = p_args.get("sort_by", "-likeCount")
	var limit: int = p_args.get("limit", 12)
	
	var uri := _build_uri(query, categories, animated, staffpicked, sort_by, limit)
	return await _fetch_models(uri)


# --- Private Functions ---

func _build_uri(p_query: String, p_categories: String, p_animated: bool, p_staffpicked: bool, p_sort_by: String, p_limit: int) -> String:
	var params := PackedStringArray()
	params.append("type=models")
	params.append("downloadable=true")
	
	if not p_query.is_empty():
		params.append("q=%s" % p_query.uri_encode())
	if not p_categories.is_empty():
		params.append("categories=%s" % p_categories)
	if p_animated:
		params.append("animated=true")
	if p_staffpicked:
		params.append("staffpicked=true")
	if p_sort_by in SORT_OPTIONS:
		params.append("sort_by=%s" % p_sort_by)
	params.append("count=%d" % clampi(p_limit, 1, 24))
	
	return "%s?%s" % [SEARCH_PATH, "&".join(params)]


func _fetch_models(p_uri: String) -> Dictionary:
	var client := HTTPClient.new()
	
	var err := client.connect_to_host(API_HOST, API_PORT, TLSOptions.client())
	if err != OK:
		client.close()
		return {"success": false, "data": "Error: Connection failed (%d)" % err}
	
	var timer := 0.0
	while client.get_status() in [HTTPClient.STATUS_CONNECTING, HTTPClient.STATUS_RESOLVING]:
		client.poll()
		await Engine.get_main_loop().create_timer(POLL_DELAY).timeout
		timer += POLL_DELAY
		if timer >= REQUEST_TIMEOUT:
			client.close()
			return {"success": false, "data": "Error: Connection timeout"}
	
	if client.get_status() != HTTPClient.STATUS_CONNECTED:
		client.close()
		return {"success": false, "data": "Error: Connection failed (status: %d)" % client.get_status()}
	
	err = client.request(HTTPClient.METHOD_GET, p_uri, [])
	if err != OK:
		client.close()
		return {"success": false, "data": "Error: Request failed (%d)" % err}
	
	timer = 0.0
	while client.get_status() == HTTPClient.STATUS_REQUESTING:
		client.poll()
		await Engine.get_main_loop().create_timer(POLL_DELAY).timeout
		timer += POLL_DELAY
		if timer >= REQUEST_TIMEOUT:
			client.close()
			return {"success": false, "data": "Error: Request timeout"}
	
	if client.get_response_code() != 200:
		var code := client.get_response_code()
		client.close()
		return {"success": false, "data": "Error: HTTP %d" % code}
	
	var response := PackedByteArray()
	while client.get_status() == HTTPClient.STATUS_BODY:
		client.poll()
		response.append_array(client.read_response_body_chunk())
		if client.get_status() == HTTPClient.STATUS_BODY:
			await Engine.get_main_loop().create_timer(POLL_DELAY).timeout
	
	client.close()
	return _format_results(response)


func _format_results(p_data: PackedByteArray) -> Dictionary:
	var json := JSON.parse_string(p_data.get_string_from_utf8())
	if json == null:
		return {"success": false, "data": "Error: Invalid JSON response"}
	
	var results: Array = json.get("results", [])
	if results.is_empty():
		return {"success": true, "data": "No models found."}
	
	var output := ""
	var next_url: String = json.get("next", "")
	if not next_url.is_empty():
		output += "More results available. Next cursor: %s\n\n" % json.get("cursors", {}).get("next", "")
	
	for item in results:
		var uid: String = item.get("uid", "")
		var name: String = item.get("name", "Unknown")
		var user_dict: Dictionary = item.get("user", {})
		var username: String = user_dict.get("username", "?")
		var display_name: String = user_dict.get("displayName", username)
		var face_count: int = item.get("faceCount", 0)
		var vertex_count: int = item.get("vertexCount", 0)
		var like_count: int = item.get("likeCount", 0)
		var view_count: int = item.get("viewCount", 0)
		var is_downloadable: bool = item.get("isDownloadable", false)
		var thumbnails: Dictionary = item.get("thumbnails", {})
		var images: Array = thumbnails.get("images", [])
		var thumb_url := ""
		if images.size() > 0:
			thumb_url = images[0].get("url", "")
		
		output += "- **%s**\n" % name
		output += "  UID: `%s` | by %s\n" % [uid, display_name]
		output += "  Faces: %d | Vertices: %d\n" % [face_count, vertex_count]
		output += "  Likes: %d | Views: %d | Downloadable: %s\n" % [like_count, view_count, "Yes" if is_downloadable else "No"]
		if not thumb_url.is_empty():
			output += "  Thumbnail: %s\n" % thumb_url
		output += "\n"
	
	return {"success": true, "data": output}
