// QA9715: the liquid touch of the shared glass, applied
// to the strip's ONE backdrop layer after its blur
// (ImageFilter.compose(outer: this, inner: blur); Impeller only).
//
//  * refraction: near a piece's edge the blurred page is sampled from
//    further inside, so what passes behind bends at the rim;
//  * adaptive veil: the thinnest veil, from the variant's least up to an
//    opaque one (the chrome of before), with which the ink and the weakest
//    ink of a piece (a title badge's, over its tint) read at AA over the
//    page right behind; thin where the page allows it, thick where not;
//  * specular rim: a thin highlight along the edge, facing the light,
//    brighter over a brighter page;
//  * fusion: the pieces' shapes join smoothly when they come close.
//
// Coordinates: FlutterFragCoord() is in physical pixels of the target
// (the screen); the pieces' rects come in the same space.
//
// Outside the pieces' (joined) shape it paints nothing: the backdrop
// layer is laid over the page as it is, so there the page stays sharp, and
// the strip can clip to a rectangle that holds the bridges of the fusion.
#include <flutter/runtime_effect.glsl>

uniform vec2 uSize;       // set by the engine: the size of uTexture
uniform vec4 uR0;         // pieces: x, y, width, height (physical px)
uniform vec4 uR1;
uniform vec4 uR2;
uniform vec4 uR3;
uniform vec4 uR4;
uniform vec4 uRadii;
uniform float uRadius4;
uniform float uCount;     // pieces in use (0..5)
uniform float uRefract;   // how far the rim bends the page (px)
uniform float uRimWidth;  // width of the highlight band (px)
uniform float uRim;       // highlight strength (0..1)
uniform float uFuse;      // fusion radius (px; 0: none)
uniform vec4 uVeil;       // veil colour (rgb) and its least opacity (a)
uniform vec3 uInk;        // the pieces' ink
uniform vec3 uWeak;       // their weakest ink (a title badge's)
uniform float uTint;      // the badge's tint of uInk under uWeak
uniform float uTarget;    // the contrast both must keep (AA: 4.5)
uniform vec2 uLight;      // unit vector towards the light (y down)

uniform sampler2D uTexture;

out vec4 fragColor;

float lum(vec3 c) {
  return dot(c, vec3(0.2126, 0.7152, 0.0722));
}

// WCAG 2 relative luminance and contrast, as ThemeContrast computes them.
float channel(float c) {
  return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4);
}

float wcag(vec3 c) {
  return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
}

float contrastOf(vec3 a, vec3 b) {
  float la = wcag(a);
  float lb = wcag(b);
  return (max(la, lb) + 0.05) / (min(la, lb) + 0.05);
}

bool readable(vec3 under) {
  vec3 tinted = mix(under, uInk, uTint);
  return contrastOf(uInk, under) >= uTarget &&
      contrastOf(uWeak, tinted) >= uTarget;
}

// A rounded box (a stadium when the radius is half its short side).
float roundBox(vec2 p, vec4 r, float corner) {
  vec2 halfSize = r.zw * 0.5;
  vec2 centre = r.xy + halfSize;
  float radius = min(corner, min(halfSize.x, halfSize.y));
  vec2 q = abs(p - centre) - halfSize + radius;
  return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
}

// Smooth union: shapes closer than k join.
float smoothMin(float a, float b, float k) {
  if (k <= 0.0) {
    return min(a, b);
  }
  float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
  return mix(b, a, h) - k * h * (1.0 - h);
}

float field(vec2 p) {
  float d = 100000.0;
  if (uCount > 0.5) d = smoothMin(d, roundBox(p, uR0, uRadii.x), uFuse);
  if (uCount > 1.5) d = smoothMin(d, roundBox(p, uR1, uRadii.y), uFuse);
  if (uCount > 2.5) d = smoothMin(d, roundBox(p, uR2, uRadii.z), uFuse);
  if (uCount > 3.5) d = smoothMin(d, roundBox(p, uR3, uRadii.w), uFuse);
  if (uCount > 4.5) d = smoothMin(d, roundBox(p, uR4, uRadius4), uFuse);
  return d;
}

vec2 toUv(vec2 p) {
  vec2 uv = p / uSize;
#ifdef IMPELLER_TARGET_OPENGLES
  uv.y = 1.0 - uv.y;
#endif
  return uv;
}

void main() {
  vec2 p = FlutterFragCoord().xy;
  float d = field(p);
  // Antialiased edge of the shape; nothing outside it.
  float coverage = 1.0 - smoothstep(-0.5, 0.5, d);
  if (coverage <= 0.0) {
    fragColor = vec4(0.0);
    return;
  }
  // The outward normal of the shape.
  vec2 n = vec2(
    field(p + vec2(1.0, 0.0)) - field(p - vec2(1.0, 0.0)),
    field(p + vec2(0.0, 1.0)) - field(p - vec2(0.0, 1.0))
  );
  float len = length(n);
  n = len > 0.0001 ? n / len : vec2(0.0, -1.0);

  // Refraction: 1 at the rim, 0 a refraction's width inside.
  float rim = 1.0 - clamp(-d / max(uRefract, 0.001), 0.0, 1.0);
  vec2 sampleAt = p - n * rim * rim * uRefract;
  vec4 sampleColour = texture(uTexture, clamp(toUv(sampleAt), 0.0, 1.0));
  vec3 behind = sampleColour.a > 0.0001
      ? sampleColour.rgb / sampleColour.a : uVeil.rgb;

  // Adaptive veil: the thinnest that keeps both inks at AA here.
  float veil = 1.0;
  for (int i = 0; i <= 12; i++) {
    float amount = mix(uVeil.a, 1.0, float(i) / 12.0);
    if (readable(mix(behind, uVeil.rgb, amount))) {
      veil = amount;
      break;
    }
  }
  vec3 colour = mix(behind, uVeil.rgb, veil);

  // Specular rim, facing the light, brighter over a brighter page.
  float band = 1.0 - smoothstep(0.0, max(uRimWidth, 0.001), -d);
  float facing = max(dot(n, uLight), 0.0);
  // No highlight under text, even in a small or unusually padded piece.
  float shine = band * uRim * (0.35 + 0.65 * facing) * (0.5 + 0.5 * lum(behind));
  if (!readable(min(colour + vec3(shine), vec3(1.0)))) shine = 0.0;
  colour = min(colour + vec3(shine), vec3(1.0));

  fragColor = vec4(colour * coverage, coverage);
}
