## Project Organizer Skill (Scene-Centric)

### Core Philosophy: "Everything is a Scene"
1.  **Object-Oriented Structure**: Organize folders by **Logical Entity** (What it is), NOT by **File Type** (What format it is).
2.  **Co-Location**: Keep the Scene (`.tscn`), its Script (`.gd`), and its exclusive Assets (Textures, Audio) in the **SAME** folder.
    - *Why?* This allows moving/copying a "Player" or "Enemy" folder to another project without breaking dependencies.
3.  **Components over Inheritance**: Encourage creating reusable "Micro-Scenes" (Components) for shared logic.

### Directory Rules (The Godot Way)

#### 1. Entity Domains (Domain Driven)
Create a dedicated folder for each distinct game object or system.
- **`res://player/`**
    - `Player.tscn` (The Main Scene)
    - `player_controller.gd` (The Logic)
    - `player_skin.png` (Exclusive Art)
    - `jump_sfx.wav` (Exclusive Audio)
    - `states/` (Sub-folder for specific state machine scripts)
- **`res://ui/main_menu/`**
    - `MainMenu.tscn`
    - `main_menu.gd`
    - `menu_background.jpg`

#### 2. Shared Resources (Common)
Only place assets here if they are truly used by *multiple, unrelated* entities.
- **`res://shared/components/`**: Reusable generic nodes (e.g., `HealthComponent`, `Hitbox`, `StateMachine`).
- **`res://shared/assets/`**: Global fonts, shaders, or UI themes.
- **`res://autoload/`**: Global Singletons (e.g., `Events.gd`, `GameManager.gd`).

#### 3. Levels
- **`res://levels/`**:
    - `world_01/`
        - `World01.tscn`
        - `level_data.tres`

### Naming Conventions
- **Folders**: `snake_case` (e.g., `enemy_boss`, `inventory_system`).
- **Scene Files**: `PascalCase` (Matches the Root Node name, e.g., `GoblinKing.tscn`).
- **Script Files**: `snake_case` (e.g., `goblin_ai.gd`).

### Execution Instructions
- **Strict Prohibition**: NEVER separate `Player.tscn` into a `scenes/` folder and `Player.gd` into a `scripts/` folder. They must live together.
- **Context Awareness**: When creating a new script, check if it belongs to an existing scene. If so, place it alongside that scene.
