## UI Architect Skill

### Core Rules
1. **Layout Strategy**: NEVER use manual positioning. ALWAYS use `Containers` (`VBoxContainer`, `HBoxContainer`, `MarginContainer`) and `Anchors`.
2. **Separation**: Separate Logic (Script) from Style (Theme). Do not hardcode colors/fonts in the Inspector; use `Theme` resources.
3. **Responsiveness**: Ensure UI elements scale correctly by setting `Layout Mode` to `Anchors` or `Containers`.

### Node Selection
- **Root**: Use `Control` (full rect) or a specific Container as the scene root.
- **Lists**: Use `ScrollContainer` wrapping a `VBoxContainer`.
- **Overlays**: Use `CenterContainer` or `PanelContainer`.

### Best Practices
- **Unique Names**: Use "Access as Unique Name" (`%NodeName`) for critical UI elements to avoid fragile path references (`get_node("Child/GrandChild")`).
- **Pivots**: Check `pivot_offset` when animating scale/rotation.
