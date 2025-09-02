// res://shaders/sky_clouds.gdshader
shader_type spatial;
render_mode unshaded, cull_disabled; // fast, no lighting

uniform vec3 sky_top = vec3(0.12, 0.40, 0.95);   // deep blue
uniform vec3 sky_horizon = vec3(0.70, 0.85, 1.0);// pale near horizon
uniform float horizon_height = 0.25;             // where horizon blend sits (0..1)

uniform float cloud_scale = 0.6;   // bigger = puffier clouds
uniform float cloud_speed = 0.006; // world drift
uniform float cloud_amount = 0.55; // 0 none, 1 lots
uniform float cloud_softness = 0.25;

float hash(vec2 p){ return fract(sin(dot(p, vec2(27.16898, 91.0674))) * 43758.5453); }

float noise(vec2 p){
    vec2 i = floor(p); vec2 f = fract(p);
    float a = hash(i);
    float b = hash(i + vec2(1,0));
    float c = hash(i + vec2(0,1));
    float d = hash(i + vec2(1,1));
    vec2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(a,b,u.x), mix(c,d,u.x), u.y);
}

float fbm(vec2 p){
    float s = 0.0, a = 0.5;
    for(int i=0;i<5;i++){ s += a * noise(p); p *= 2.03; a *= 0.5; }
    return s;
}

void fragment(){
    // vertical gradient (Y points up in object space)
    float t = clamp((NORMAL.y * 0.5 + 0.5 - (1.0 - horizon_height)), 0.0, 1.0);
    vec3 grad = mix(sky_horizon, sky_top, t);

    // moving clouds (screen-stable)
	vec2 uv = UV * 200.0 * cloud_scale + vec2(TIME * cloud_speed, TIME * 0.7 * cloud_speed);
    uv += vec2(TIME * cloud_speed, TIME * cloud_speed * 0.7);
    float clouds = fbm(uv) * cloud_amount;
    clouds = smoothstep(1.0 - cloud_amount, 1.0, clouds);
    clouds = pow(clouds, 1.0 - cloud_softness);

    ALBEDO = mix(grad, vec3(1.0), clouds * 0.7); // soft white puffs
    ALPHA = 1.0;
}
