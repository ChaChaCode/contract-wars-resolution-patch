using System;
using UnityEngine;

// Свой видимый трассер пули для Contract Wars.
// На каждый выстрел Spawn(start, end) создаёт короткоживущую ярко-красную 3D-линию
// (LineRenderer), которая гаснет за ~0.25с. Не зависит от родных частиц/материалов игры.
// Вызывается из Tracer.Create через вставленный IL.
public static class CWTracer
{
    private static Material _mat;

    // Общий непрозрачный аддитивный материал для всех линий (создаётся один раз).
    private static Material GetMat()
    {
        if (_mat == null)
        {
            // Particles/Additive — яркая линия, видимая на любом фоне, без освещения.
            Shader sh = Shader.Find("Particles/Additive");
            if (sh == null) sh = Shader.Find("Sprites/Default");
            if (sh == null) sh = Shader.Find("Unlit/Color");
            _mat = new Material(sh);
            _mat.color = new Color(1f, 0.05f, 0.05f, 1f);
        }
        return _mat;
    }

    public static void Spawn(Vector3 start, Vector3 end)
    {
        try
        {
            // Свой выстрел или чужой: своя пуля стартует у ствола рядом с камерой игрока
            // (~1-2 м), чужая — далеко. По расстоянию start до главной камеры различаем.
            bool isLocal = true;
            Camera cam = Camera.main;
            if (cam != null)
            {
                float d = (start - cam.transform.position).magnitude;
                isLocal = (d < 4f);
            }
            // своя линия — непрозрачная; чужая — на 25% прозрачнее (alpha 0.75).
            float a = isLocal ? 1f : 0.75f;
            // тоньше в 2 раза (0.03 -> 0.015)
            float width = 0.015f;
            Color col = new Color(1f, 0.05f, 0.05f, a);

            GameObject go = new GameObject("cw_tracer");
            LineRenderer lr = go.AddComponent<LineRenderer>();
            lr.material = GetMat();
            lr.SetWidth(width, width);
            lr.SetVertexCount(2);
            lr.SetPosition(0, start);
            lr.SetPosition(1, end);
            lr.SetColors(col, col);
            lr.useWorldSpace = true;
            lr.castShadows = false;
            lr.receiveShadows = false;
            CWTracerLife life = go.AddComponent<CWTracerLife>();
            life.ttl = 0.25f;
            life.baseAlpha = a;
            life.baseWidth = width;
        }
        catch { }
    }
}

// Гасит линию: плавно уводит альфу и уничтожает объект по истечении ttl.
public class CWTracerLife : MonoBehaviour
{
    public float ttl = 0.25f;
    public float baseAlpha = 1f;
    public float baseWidth = 0.015f;
    private float _age;
    private LineRenderer _lr;

    private void Awake() { _lr = GetComponent<LineRenderer>(); }

    private void Update()
    {
        _age += Time.deltaTime;
        float k = 1f - (_age / ttl);
        if (k <= 0f) { UnityEngine.Object.Destroy(gameObject); return; }
        if (_lr != null)
        {
            Color c = new Color(1f, 0.05f, 0.05f, baseAlpha * k);
            _lr.SetColors(c, c);
            float w = baseWidth * k;
            _lr.SetWidth(w, w);
        }
    }
}
