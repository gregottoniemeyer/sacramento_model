shader_type canvas_item;
uniform float scale = 8.0;
uniform float speed = 0.5;
uniform float stripe_width = 0.28;
uniform float custom_time = 0.0;

void fragment()
{
    vec2 uv = UV;
    uv.y += custom_time * speed;
    uv *= scale;
    float x = abs(fract(uv.x) - 0.5) * 2.0;
    float y = fract(uv.y);
    float chevron = step(abs(x - y), stripe_width);
    COLOR = vec4(vec3(chevron), 1.0);
}