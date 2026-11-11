// Localized reflections with a bright core, soft shoulder and darker bevel.
// SDR gets its sparkle from local contrast; only HDR exceeds reference white.
export const glassHighlightShader = /* wgsl */ `
struct Shape {
  rect: vec4f,
  material: vec4f,
};
struct Settings {
  extent: vec2f,
  light: vec2f,
  peak: f32,
  dark: f32,
  count: u32,
  ratio: f32,
  shapes: array<Shape, 8>,
};
@group(0) @binding(0) var<uniform> settings: Settings;

@vertex fn vertex(@builtin(vertex_index) index: u32) -> @builtin(position) vec4f {
  let corners = array<vec2f, 3>(vec2f(-1.0, -1.0), vec2f(3.0, -1.0), vec2f(-1.0, 3.0));
  return vec4f(corners[index], 0.0, 1.0);
}

fn reflection(point: vec2f, shape: Shape) -> vec4f {
  let center = shape.rect.xy + shape.rect.zw * 0.5;
  let radius = shape.rect.w * 0.5;
  let local = point - center;
  let span = max(0.0, shape.rect.z * 0.5 - radius);
  let nearest = vec2f(clamp(local.x, -span, span), 0.0);
  let delta = local - nearest;
  let distance = length(delta);
  let depth = radius - distance;
  let mask = smoothstep(-0.6 / settings.ratio, 0.6 / settings.ratio, depth);
  if (mask < 0.001) { return vec4f(0.0); }

  // A rounded surface normal changes through the bevel. Specularity is
  // confined to light-facing regions, rather than outlining the capsule.
  let bevel = mix(4.5, 3.5, shape.material.x);
  let slope = 0.95 * (1.0 - smoothstep(0.0, bevel, max(depth, 0.0)));
  let normalXY = delta / max(distance, 0.001) * slope;
  let normal = vec3f(normalXY, sqrt(max(0.0, 1.0 - dot(normalXY, normalXY))));
  let anchor = mix(shape.rect.xy + shape.rect.zw * vec2f(0.23, -0.5), settings.light, 0.12);
  let light = normalize(vec3f((anchor - point) / vec2f(max(100.0, shape.rect.z * 0.7), 85.0), 1.0));
  let halfVector = normalize(light + vec3f(0.0, 0.0, 1.0));
  let x = (point.x - anchor.x) / max(32.0, shape.rect.z * 0.25);
  let primary = pow(max(0.0, dot(normal, halfVector)), 110.0) * exp(-x * x);
  let secondaryLight = normalize(vec3f(0.28, 0.38, 0.85));
  let secondaryHalf = normalize(secondaryLight + vec3f(0.0, 0.0, 1.0));
  let farX = (local.x - shape.rect.z * 0.28) / max(18.0, shape.rect.z * 0.15);
  let secondary = 0.13 * pow(max(0.0, dot(normal, secondaryHalf)), 135.0) * exp(-farX * farX);
  // Keep the broad surface reflection quiet so a small core can reach
  // reference white on SDR without washing out the entire glass surface.
  let direction = delta / max(distance, 0.001);
  let facing = pow(max(0.0, dot(direction, normalize(vec2f(-0.16, -1.0)))), 5.0);
  let hotspotX = (point.x - anchor.x) / max(16.0, shape.rect.z * 0.15);
  let hotspot = exp(-hotspotX * hotspotX);
  let glint = exp(-pow((depth - 0.95) / 0.9, 2.0)) * facing * hotspot;
  let shoulder = exp(-pow((depth - 2.2) / 2.0, 2.0)) * facing * hotspot;
  let trough = exp(-pow((depth - 4.6) / 1.7, 2.0)) * facing * hotspot;
  let lowerFacing = pow(max(0.0, dot(direction, normalize(vec2f(0.35, 1.0)))), 6.0);
  let lowerGlint = exp(-pow((depth - 0.8) / 0.75, 2.0)) * lowerFacing * exp(-farX * farX);
  let enabled = mask * shape.material.y;
  let sdr = 1.0 - step(1.01, settings.peak);
  let shadeAlpha = trough * enabled * mix(0.10, 0.21, sdr) * mix(1.0, 0.7, settings.dark);
  let shade = vec4f(vec3f(0.025, 0.031, 0.043) * shadeAlpha, shadeAlpha);
  let core = glint * mix(0.86, 0.96, shape.material.x) * mix(1.0, 1.8, sdr);
  let sheen = primary * 0.10 + secondary * 0.14 + shoulder * 0.11 + lowerGlint * 0.24;
  let alpha = clamp(core + sheen, 0.0, 0.98) * enabled;
  let radiance = vec3f(0.97, 0.985, 1.0) * settings.peak * alpha;
  return vec4f(radiance, alpha) + shade * (1.0 - alpha);
}

@fragment fn fragment(@builtin(position) position: vec4f) -> @location(0) vec4f {
  let point = position.xy / settings.ratio;
  var result = vec4f(0.0);
  for (var i = 0u; i < 8u; i++) {
    if (i >= settings.count) { break; }
    let light = reflection(point, settings.shapes[i]);
    result = light + result * (1.0 - light.a);
  }
  return result;
}
`;
