using System;
using UnityEngine;

// Режим экрана Contract Wars. 3 режима, PlayerPrefs "cw_screenmode" (локально):
//   0 = Оконный (80% монитора), 1 = Без рамки (borderless), 2 = Полноэкранный (эксклюзив).
// Логика режима — здесь; сам выпадающий список рисуется в SettingsGUI (через IL, там доступен gui).
public static class CWScreen
{
    // Состояние «список раскрыт» — читается/пишется из вставленного в SettingsGUI IL-кода.
    public static bool dropOpen = false;

    public static int GetMode()
    {
        if (!PlayerPrefs.HasKey("cw_screenmode")) return 1;
        int m = PlayerPrefs.GetInt("cw_screenmode");
        return (m < 0 || m > 2) ? 1 : m;
    }
    public static void SetMode(int m)
    {
        if (m < 0) m = 0; if (m > 2) m = 2;
        PlayerPrefs.SetInt("cw_screenmode", m);
        Apply();
    }
    // Название режима по индексу — для текста кнопок списка.
    public static string ModeName(int m)
    {
        switch (m) { case 0: return "Оконный"; case 2: return "Полноэкранный"; default: return "Без рамки"; }
    }
    // Текущее название — для главной кнопки списка.
    public static string CurName() { return ModeName(GetMode()); }

    // F12: циклическое переключение режимов (Оконный -> Без рамки -> Полноэкранный -> ...).
    public static void Toggle() { SetMode((GetMode() + 1) % 3); }

    public static void Apply()
    {
        try
        {
            int mode = GetMode();
            int w = Screen.currentResolution.width, h = Screen.currentResolution.height;
            if (w < 640) w = 1920; if (h < 480) h = 1080;
            if (mode == 2) Screen.SetResolution(w, h, true);
            else if (mode == 0) Screen.SetResolution((int)(w * 0.8f), (int)(h * 0.8f), false);
            else Screen.SetResolution(w, h, false);
        }
        catch { }
    }
}
