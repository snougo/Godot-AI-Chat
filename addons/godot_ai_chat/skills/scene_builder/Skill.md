## Scene Builder Skill

### Scene Structure
1. **Root Node**: Use a descriptive name (e.g., `Player`, `MainLevel`). The root type should match the scene's primary function (e.g., `CharacterBody3D` for entities, `Control` for UI).
2. **Inheritance**: Prefer scene inheritance (`.tscn`) over script inheritance for visual variations.
3. **Modularity**: Break complex scenes into smaller, reusable components (Nested Scenes). Avoid "God Nodes" with too many children.

### Naming Conventions
- **Nodes**: PascalCase (`HealthBar`, `CollisionShape2D`).
- **Files**: snake_case (`health_bar.tscn`, `player.tscn`).

### UI Design (Control Nodes)
1. **Anchors & Containers**: Use `VBoxContainer`, `HBoxContainer`, `GridContainer`, and `MarginContainer` for responsive layouts. Avoid manual positioning.
2. **Themes**: Use `Theme` resources for consistent styling across the project.
3. **Separation**: Keep logic (Scripts) separate from presentation (visual nodes) where possible.

### 2D/3D Best Practices
1. **Physics**: Place `CollisionShape` nodes as direct children of `PhysicsBody` nodes.
2. **Transforms**: Ensure local transforms (position, rotation, scale) are reset (0,0,0 / 0,0,0 / 1,1,1) for root nodes of instanced scenes unless intentional.
3. **Visibility**: Use `VisibleOnScreenNotifier` to optimize performance for off-screen objects.

### Workflow
1. **Instancing**: Always instantiate scenes via code or editor, do not duplicate complex node trees manually.
2. **Editable Children**: Use "Editable Children" sparingly; prefer exposing properties via the parent script.
