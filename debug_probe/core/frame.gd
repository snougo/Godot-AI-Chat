extends RefCounted

# Number formatting shared by every observer: rounding to a fixed precision keeps the protocol
# small and stops floating point noise from leaking into a report.

const PRECISION: float = 0.001


static func vec3(p_value: Vector3) -> Array:
	return [
		snappedf(p_value.x, PRECISION),
		snappedf(p_value.y, PRECISION),
		snappedf(p_value.z, PRECISION),
	]


static func vec2(p_value: Vector2) -> Array:
	return [
		snappedf(p_value.x, PRECISION),
		snappedf(p_value.y, PRECISION),
	]


static func n(p_value: float, p_precision: float = PRECISION) -> float:
	return snappedf(p_value, p_precision)
