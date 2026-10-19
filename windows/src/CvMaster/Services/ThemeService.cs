/**
 * 外观切换：跟随系统 / 浅色 / 深色，替换第一层主题字典并同步 DWM 标题栏。
 * @author helele
 * @since 2026-10-19
 */
using System.Windows;
using Microsoft.Win32;

namespace CvMaster.Services;

public enum AppAppearance
{
    System,
    Light,
    Dark
}

public sealed class ThemeService
{
    private static readonly Uri LightTheme = new("pack://application:,,,/cvMaster;component/Themes/Light.xaml");
    private static readonly Uri DarkTheme = new("pack://application:,,,/cvMaster;component/Themes/Dark.xaml");
    private ResourceDictionary? _currentTheme;

    public AppAppearance Appearance { get; private set; } = AppAppearance.System;

    public bool IsDark { get; private set; }

    public event EventHandler? ThemeChanged;

    public void Apply(AppAppearance appearance)
    {
        Appearance = appearance;
        var dark = appearance switch
        {
            AppAppearance.Light => false,
            AppAppearance.Dark => true,
            _ => IsSystemDark()
        };

        var dictionary = new ResourceDictionary
        {
            Source = dark ? DarkTheme : LightTheme
        };
        var merged = Application.Current.Resources.MergedDictionaries;
        if (_currentTheme is not null)
        {
            merged.Remove(_currentTheme);
        }

        merged.Insert(0, dictionary);
        _currentTheme = dictionary;
        IsDark = dark;
        foreach (Window window in Application.Current.Windows)
        {
            WindowAppearance.Apply(window, dark);
        }

        ThemeChanged?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>系统外观变化时，仅在“跟随系统”模式下重新解析主题。</summary>
    public void RefreshSystemAppearance()
    {
        if (Appearance == AppAppearance.System)
        {
            Apply(AppAppearance.System);
        }
    }

    public static bool IsSystemDark()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(
                @"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize",
                writable: false);
            return key?.GetValue("AppsUseLightTheme") is int value && value == 0;
        }
        catch (Exception)
        {
            return false;
        }
    }

    public static AppAppearance Parse(string value) => value switch
    {
        "light" => AppAppearance.Light,
        "dark" => AppAppearance.Dark,
        _ => AppAppearance.System
    };

    public static string ToStorageValue(AppAppearance appearance) => appearance switch
    {
        AppAppearance.Light => "light",
        AppAppearance.Dark => "dark",
        _ => "system"
    };

    public static string DisplayName(AppAppearance appearance) => appearance switch
    {
        AppAppearance.Light => "浅色",
        AppAppearance.Dark => "深色",
        _ => "跟随系统"
    };
}
