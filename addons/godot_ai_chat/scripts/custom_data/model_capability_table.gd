@tool
class_name ModelCapabilityTable
extends Resource

## 全局模型能力表
##
## 记录"模型 → 是否支持图片输入"，供所有 API Provider（含未来新增）统一查询。
## BaseLLMProvider.build_request_body（模板方法）会自动查询本表：
## - 命中且 supports_image=false（纯文本模型）→ 剥离消息中的图片并打印警告，避免网关挂起/无限等待
## - 未收录模型 → 默认放行（保守策略，不误伤新模型）
##
## 首次访问时若 .tres 不存在，将自动创建并写入默认条目（见 TEXT_ONLY_MODELS）。

# --- Constants ---

## 默认纯文本模型清单（社区实测确认不支持视觉输入）
## 来源: opencode issue #33942 / OmniRoute #2822
## 若实测某模型支持图片，请在 .tres 中将对应条目的 supports_image 改为 true 或删除条目
const TEXT_ONLY_MODELS: Array[String] = [
	"deepseek-v4-pro",
	"deepseek-v4-flash",
	"glm-5.3",
	"glm-5.2",
]

# --- @export Vars ---

## 模型能力条目列表（强类型，每条含模型名 + 图片能力）
@export var entries: Array[ModelCapabilityEntry] = []


# --- Public Functions ---

## 获取全局能力表实例（不存在时自动创建并保存）
static func get_table() -> ModelCapabilityTable:
	var path: String = PluginPaths.MODEL_CAPABILITY_TABLE_PATH
	if ResourceLoader.exists(path):
		return ResourceLoader.load(path, "", ResourceLoader.CacheMode.CACHE_MODE_IGNORE) as ModelCapabilityTable
	
	var table := ModelCapabilityTable.new()
	table._fill_defaults()
	ResourceSaver.save(table, path)
	ToolBox.update_editor_filesystem(path)
	AIChatLogger.info("[ModelCapabilityTable] Created default capability table at " + path)
	return table


## 查询模型是否支持图片输入
## 匹配规则（先精确，后前缀归一化，双向生效）：
## 1. 精确匹配: "deepseek-v4-flash" == "deepseek-v4-flash"
## 2. 前缀归一化: 表条目与实际模型名均剥离 provider 前缀后比较
##    例: "deepseek-ai/deepseek-v4-flash" ↔ "deepseek-v4-flash" 命中
##    例: "opencode-go/glm-5.2"           ↔ "glm-5.2"          命中
## 未收录模型默认返回 true（保守放行）
static func supports_image_input(p_model_name: String) -> bool:
	if p_model_name.is_empty():
		return true
	var table: ModelCapabilityTable = get_table()
	var normalized_actual: String = _normalize_model_name(p_model_name)
	for entry in table.entries:
		if _normalize_model_name(entry.model_name) == normalized_actual:
			return entry.supports_image
	return true


# --- Private Functions ---

# 用默认纯文本模型清单填充能力表（仅首次创建时调用）
func _fill_defaults() -> void:
	entries.clear()
	for model in TEXT_ONLY_MODELS:
		var entry := ModelCapabilityEntry.new()
		entry.model_name = model
		entry.supports_image = false
		entries.append(entry)


# 归一化模型名：
# 1. 去首尾空白 + 转小写（大小写不敏感匹配）
# 2. 剥离 provider 前缀（"/" 或 ":" 分隔的最后一段）
# 3. 剥离末尾版本/日期戳后缀（-YYYYMMDD 或 -YYYY-MM-DD，循环支持多层）
# 例: "DeepSeek-AI/deepseek-v4-flash-20260820" -> "deepseek-v4-flash"
# 例: "openai/gpt-4-turbo-2024-04-09"          -> "gpt-4-turbo"
# 不做子串模糊匹配（contains），避免误命中（如 "xxx-deepseek-v4-flash-lite"）
static func _normalize_model_name(p_name: String) -> String:
	var name: String = p_name.strip_edges().to_lower()
	var slash_idx: int = name.rfind("/")
	if slash_idx != -1:
		name = name.substr(slash_idx + 1)
	var colon_idx: int = name.rfind(":")
	if colon_idx != -1:
		name = name.substr(colon_idx + 1)
	# 剥离末尾日期戳（-YYYYMMDD 或 -YYYY-MM-DD），循环处理多层后缀
	var suffix_regex := RegEx.create_from_string("-(\\d{8}|\\d{4}-\\d{2}-\\d{2})$")
	var match_result := suffix_regex.search(name)
	while match_result != null:
		name = name.substr(0, match_result.get_start())
		match_result = suffix_regex.search(name)
	return name
