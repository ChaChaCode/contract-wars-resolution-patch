using System;
using UnityEngine;

// Управление режимом экрана для Contract Wars.
// Флаг режима хранится ЛОКАЛЬНО в PlayerPrefs "cw_fullscreen" (1=полный экран, 0=окно/borderless),
// не в профиле и не на сервере. Оконный режим ставит РЕАЛЬНОЕ разрешение монитора (не 800x600).
// Настоящий borderless достигается запуском игры с -popupwindow (BORDERLESS.vbs) — тогда
// оконный режим = безрамочное окно на весь монитор.
public static class CWScreen
{
    public static bool IsFullscreen()
    {
        if (!PlayerPrefs.HasKey("cw_fullscreen")) return Screen.fullScreen;
        return PlayerPrefs.GetInt("cw_fullscreen") != 0;
    }

    public static void SetFullscreen(bool fs)
    {
        PlayerPrefs.SetInt("cw_fullscreen", fs ? 1 : 0);
        Apply();
    }

    public static void Toggle()
    {
        SetFullscreen(!IsFullscreen());
    }

    // Для чекбокса в меню: принимает новое значение галки; применяет режим только при ИЗМЕНЕНИИ
    // (чекбокс рисуется каждый кадр, но SetResolution зовём лишь когда пользователь переключил).
    public static void CheckboxResult(bool newValue)
    {
        if (newValue != IsFullscreen())
            SetFullscreen(newValue);
    }

    // Применить режим. ВСЕГДА borderless (fullScreen=false) — это окно без рамки на весь монитор
    // при запуске с -popupwindow. Так alt-tab мгновенный и можно класть окна поверх (как в Arc Raiders).
    // Эксклюзивный fullscreen (true) НЕ используем — он ломает alt-tab и окна-поверх.
    // Чекбокс «Полный экран»: включён = на весь монитор, выключен = оконный размер (из настроек игры).
    public static void Apply()
    {
        try
        {
            bool full = IsFullscreen();
            int w = Screen.currentResolution.width;
            int h = Screen.currentResolution.height;
            if (!full)
            {
                // оконный (не на весь экран): окно 80% монитора по центру
                w = (int)(w * 0.8f);
                h = (int)(h * 0.8f);
            }
            if (w < 640) w = 1920;
            if (h < 480) h = 1080;
            Screen.SetResolution(w, h, false);   // всегда false = borderless, НЕ эксклюзив
        }
        catch { }
    }
}
