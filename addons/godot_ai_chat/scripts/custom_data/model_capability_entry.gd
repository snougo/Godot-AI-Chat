@tool
class_name ModelCapabilityEntry
extends Resource

## 模型能力条目
##
## 记录单个模型的图片输入能力，供全局能力表（ModelCapabilityTable）使用。

# --- @export Vars ---

## 模型名称（与 API 返回的模型 id 精确匹配）
@export var model_name: String = ""
## 是否支持图片输入（false = 纯文本模型，请求前剥离图片）
@export var supports_image: bool = true
