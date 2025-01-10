#version 330

in vec2 uv;
in vec3 color;

out vec4 fragment;

float bell(float x, float p, float c) {
     return exp(-(pow(abs(x), p)) / 2.0f / c / c);
}

void main()
{
    vec2 center_offs = uv - 0.5;
    float center_dist = length(center_offs);
    float c = 0.05;
    float center = bell(center_dist, 2.5f, 0.15);

    fragment = vec4(color, center);
}
