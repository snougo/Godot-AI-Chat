## Project Structure Manager

### 概览
本技能旨在帮助用户建立符合 Godot 引擎“节点化”与“自包含”设计哲学的项目目录结构。实现高内聚、低耦合，便于资产复用与团队协作。

### 触发条件
当用户请求执行以下操作时触发：
- "初始化项目结构"
- "创建新角色/模块/系统"
- "整理项目文件"
- "重构目录结构"

### 指令
1. **遵循功能模块化原则**
	- 摒弃根目录下 `scenes/`, `scripts/`, `textures/` 的传统分类方式。
	- **核心逻辑**：一个文件夹 = 一个功能模块或游戏实体。
	- **推荐的一级目录结构**：
		- `res://addons/`：插件（Godot 默认）。
		- `res://autoload/`：全局单例脚本。
		- `res://shared/`：多模块共用的通用资源（如 UI 主题、通用音效、全局配置）。
		- `res://game/` 或 `res://features/`：游戏核心逻辑模块。
			- 例如：`res://game/player/`, `res://game/enemies/`, `res://game/ui/`, `res://game/levels/`。

2. **模块内部结构规范**
	- 在创建具体模块（如 `player`）时，将所有相关文件放入该目录：
		- `res://game/player/player.tscn`
		- `res://game/player/player.gd`
		- `res://game/player/player_skin.png`
		- `res://game/player/jump_sfx.wav`
	- 仅当模块内部资源过多时，才在模块内部建立子文件夹（如 `animations/`, `states/`）。

3. **执行创建与整理**
	- **创建模块**：使用 `create_folder` 为新功能点创建独立文件夹。例如用户要制作“背包系统”，应创建 `res://game/inventory/`。
	- **资源归拢**：使用 `move_file` 将散落在外的相关资源移动到对应模块文件夹中。
	- **命名规范**：文件夹和文件名一律使用 `snake_case`（小写_下划线）。

4. **处理共享资源**
	- 如果一个资源被多个模块引用（例如“爆炸特效”或“通用字体”），将其移动到 `res://shared/` 下的对应分类中，而不是复制多份。

### 拓展引用
如需深入了解不同游戏类型的细分最佳实践，请查阅 `res://addons/godot_ai_chat/skills/script_tool_sop/reference/` 文件夹中的相关文档。

### 示列
**场景**：用户正在开发一个名为“Slime”的敌人，目前文件散乱在根目录。

**用户指令**："帮我整理一下 Slime 敌人的文件。"

**AI 执行流程**：
1.  **分析**：识别出功能主体为 "Slime"，属于敌人范畴。
2.  **规划**：决定建立 `res://game/enemies/slime/` 目录。
3.  **创建目录**：调用 `create_folder(path="res://game/enemies/slime")`。
4.  **移动资源**：
	- 将 `res://slime.tscn` 移动至 `res://game/enemies/slime/slime.tscn`
	- 将 `res://slime_script.gd` 移动至 `res://game/enemies/slime/slime.gd`
	- 将 `res://slime_jump.wav` 移动至 `res://game/enemies/slime/slime_jump.wav`
5.  **反馈**：回复用户“已将 Slime 相关的所有资源归档至 `res://game/enemies/slime/`，符合自包含模块结构。”
