@tool
class_name SketchfabConfig
extends Resource

## Sketchfab API 配置。
## 在 https://sketchfab.com/settings/password 生成 Personal API Token 后填入。

# --- @export Vars ---

## Personal API Token，用于 Data API v3 和 Download API 认证。
@export var api_token: String = ""

# --- Public Functions ---

## 是否已配置有效的 token。
func is_configured() -> bool:
	return not api_token.is_empty()
