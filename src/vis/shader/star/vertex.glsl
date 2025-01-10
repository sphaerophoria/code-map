#version 330

in vec2 vPos;
in vec2 vUv;
in vec3 vColor;

out vec2 uv;
out float weight;
out vec3 color;

void main()
{
    gl_Position = vec4(vPos, 0.0, 1.0);
    uv = vUv;
    color = vColor;
}
