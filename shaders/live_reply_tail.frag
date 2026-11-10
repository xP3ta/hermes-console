#include <flutter/runtime_effect.glsl>

uniform float uTop;
uniform float uBottom;
uniform float uCount;
uniform vec4 uRects[32];
uniform float uOpacity[32];

out vec4 fragColor;

void main() {
  vec2 point = FlutterFragCoord().xy;
  float alpha = 1.0;
  // The stable prefix is opaque. Only the last few glyphs need the loop.
  if (point.y >= uTop && point.y <= uBottom) {
    for (int i = 0; i < 32; i++) {
      if (float(i) >= uCount) break;
      vec4 box = uRects[i];
      if (point.x >= box.x && point.x <= box.z &&
          point.y >= box.y && point.y <= box.w) {
        alpha = min(alpha, uOpacity[i]);
      }
    }
  }
  fragColor = vec4(alpha);
}
