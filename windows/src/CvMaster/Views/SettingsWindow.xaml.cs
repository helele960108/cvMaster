/**
 * 设置窗口：全部选项立即生效；快捷键录制期间临时注销旧组合。
 * 排除应用只记录进程名，清理历史必须二次确认。
 * @author helele
 * @since 2026-10-19
 */
using System.ComponentModel;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using CvMaster.Services;
using CvMaster.ViewModels;
using Microsoft.Win32;

namespace CvMaster.Views;

public partial class SettingsWindow : Window
{
    private readonly LibraryViewModel _vm;
    private bool _recordingHotKey;
    private bool _closed;

    public SettingsWindow()
    {
        InitializeComponent();
        _vm = App.Services.Library;
        DataContext = _vm;
        _vm.PropertyChanged += ViewModel_PropertyChanged;
        _vm.ExcludedApplications.CollectionChanged += ExcludedApplications_CollectionChanged;

        UpdateAppearanceVisuals();
        UpdateExcludedEmpty();
        UpdateShortcutDisplay();
        ShowTab(0);
    }

    private void Window_SourceInitialized(object? sender, EventArgs e) =>
        WindowAppearance.Apply(this, App.Services.Theme.IsDark);

    private void Header_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ButtonState != MouseButtonState.Pressed ||
            FindAncestor<Button>(e.OriginalSource as DependencyObject) is not null)
        {
            return;
        }

        DragMove();
    }

    private void Tab_Click(object sender, RoutedEventArgs e)
    {
        if (sender is ToggleButton { Tag: string tag } && int.TryParse(tag, out var index))
        {
            ShowTab(index);
        }
    }

    private void ShowTab(int index)
    {
        GeneralPanel.Visibility = index == 0 ? Visibility.Visible : Visibility.Collapsed;
        PrivacyPanel.Visibility = index == 1 ? Visibility.Visible : Visibility.Collapsed;
        StoragePanel.Visibility = index == 2 ? Visibility.Visible : Visibility.Collapsed;
        GeneralTab.IsChecked = index == 0;
        PrivacyTab.IsChecked = index == 1;
        StorageTab.IsChecked = index == 2;

        (PageTitle.Text, PageSubtitle.Text) = index switch
        {
            1 => ("记录与隐私", "敏感内容标记与来源应用排除"),
            2 => ("存储与清理", "本机容量、保留规则与手动清理"),
            _ => ("通用", "记录方式、粘贴行为与外观")
        };

        if (index == 1)
        {
            _vm.RefreshExcludedApplications();
        }
        else if (index == 2)
        {
            _ = _vm.RefreshStatsAsync();
        }
    }

    private void Appearance_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not ToggleButton { Tag: string tag })
        {
            return;
        }

        _vm.Appearance = tag switch
        {
            "light" => AppAppearance.Light,
            "dark" => AppAppearance.Dark,
            _ => AppAppearance.System
        };
        UpdateAppearanceVisuals();
    }

    private void UpdateAppearanceVisuals()
    {
        AppearanceSystem.IsChecked = _vm.Appearance == AppAppearance.System;
        AppearanceLight.IsChecked = _vm.Appearance == AppAppearance.Light;
        AppearanceDark.IsChecked = _vm.Appearance == AppAppearance.Dark;
    }

    private void HotKeyButton_Click(object sender, RoutedEventArgs e)
    {
        if (_recordingHotKey)
        {
            CancelHotKeyCapture();
            return;
        }

        _recordingHotKey = true;
        App.Services.HotKeys.Suspend();
        HotKeyText.Text = "请按下组合键…";
        HotKeyText.Foreground = (Brush)FindResource("AccentBrush");
        _vm.SetFeedback("按下包含 Ctrl / Alt / Win 的组合键；仅 Ctrl 会与复制粘贴冲突。Esc 取消。");
        Focus();
    }

    private void Window_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (!_recordingHotKey)
        {
            if (e.Key == Key.Escape)
            {
                Close();
                e.Handled = true;
            }

            return;
        }

        e.Handled = true;
        if (e.Key == Key.Escape)
        {
            CancelHotKeyCapture();
            return;
        }

        var gesture = HotKeyGesture.FromKeyEvent(e);
        if (gesture is null)
        {
            return;
        }

        if (_vm.TrySetHotKey(gesture, out var error))
        {
            _recordingHotKey = false;
            _vm.SetFeedback($"快捷键已更新为 {_vm.ShortcutDisplay}");
            UpdateShortcutDisplay();
            return;
        }

        // 校验或注册失败时保留原快捷键并继续录制，用户可以直接重试。
        _vm.SetFeedback(error ?? "快捷键注册失败。");
        HotKeyText.Text = "请按下组合键…";
        HotKeyText.Foreground = (Brush)FindResource("AccentBrush");
    }

    private void CancelHotKeyCapture()
    {
        if (!_recordingHotKey)
        {
            return;
        }

        _recordingHotKey = false;
        App.Services.HotKeys.Resume();
        UpdateShortcutDisplay();
        _vm.SetFeedback(null);
    }

    private void UpdateShortcutDisplay()
    {
        HotKeyText.Text = _recordingHotKey ? "请按下组合键…" : _vm.ShortcutDisplay;
        HotKeyText.SetResourceReference(TextBlock.ForegroundProperty, _recordingHotKey ? "AccentBrush" : "TextPrimaryBrush");
    }

    private void AddExcludedButton_Click(object sender, RoutedEventArgs e)
    {
        var menu = new ContextMenu
        {
            PlacementTarget = AddExcludedButton,
            Placement = PlacementMode.Bottom
        };

        var running = ProcessCatalog.ListRunningApplications(App.Services.Settings.ExcludedProcessList);
        if (running.Count == 0)
        {
            menu.Items.Add(new MenuItem { Header = "没有可添加的运行中应用", IsEnabled = false });
        }
        else
        {
            menu.Items.Add(new MenuItem { Header = "正在运行", IsEnabled = false, FontWeight = FontWeights.SemiBold });
            foreach (var application in running.Take(30))
            {
                var item = new MenuItem
                {
                    Header = $"{application.DisplayName}  ·  {application.ProcessName}",
                    Tag = application.ProcessName
                };
                if (application.Icon is { } icon)
                {
                    item.Icon = new Image
                    {
                        Source = icon,
                        Width = 16,
                        Height = 16,
                        Stretch = Stretch.Uniform
                    };
                }

                item.Click += (_, _) => AddExcludedProcess(application.ProcessName, application.DisplayName);
                menu.Items.Add(item);
            }
        }

        menu.Items.Add(new Separator());
        var chooseInstalled = new MenuItem { Header = "选择已安装的应用…" };
        chooseInstalled.Click += (_, _) => ChooseInstalledApplication();
        menu.Items.Add(chooseInstalled);

        var manual = new MenuItem { Header = "手动输入进程名…" };
        manual.Click += (_, _) => ShowManualProcessPrompt();
        menu.Items.Add(manual);

        menu.IsOpen = true;
    }

    private void ChooseInstalledApplication()
    {
        var dialog = new OpenFileDialog
        {
            Title = "选择要排除来源的应用",
            Filter = "应用程序 (*.exe)|*.exe",
            CheckFileExists = true,
            Multiselect = false
        };

        if (dialog.ShowDialog(this) == true)
        {
            AddExcludedProcess(Path.GetFileName(dialog.FileName), Path.GetFileNameWithoutExtension(dialog.FileName));
        }
    }

    private void ShowManualProcessPrompt()
    {
        var self = SettingsService.NormalizeProcessName(Path.GetFileName(Environment.ProcessPath) ?? "cvMaster.exe");
        var dialog = new TextPromptWindow(
            "手动输入进程名",
            "适用于未运行或找不到可执行文件的应用。只保存进程名，例如 1Password.exe。",
            string.Empty,
            120,
            value =>
            {
                var normalized = SettingsService.NormalizeProcessName(value);
                if (normalized.Length == 0)
                {
                    return "请输入应用进程名。";
                }

                if (normalized.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0 ||
                    Path.GetFileName(normalized) != normalized)
                {
                    return "进程名不能包含路径或非法字符。";
                }

                if (normalized.Equals(self, StringComparison.OrdinalIgnoreCase))
                {
                    return "不能排除 cvMaster 本身。";
                }

                if (_vm.ExcludedApplications.Any(row => row.ProcessName.Equals(normalized, StringComparison.OrdinalIgnoreCase)))
                {
                    return "该应用已在排除列表中。";
                }

                return null;
            })
        {
            Owner = this
        };

        if (dialog.ShowDialog() == true && dialog.Value is { } processName)
        {
            AddExcludedProcess(processName);
        }
    }

    private void AddExcludedProcess(string processName, string? displayName = null)
    {
        var error = _vm.AddExcludedProcess(processName);
        if (error is not null)
        {
            MessageBox.Show(this, error, "无法添加排除项", MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }

        var added = _vm.ExcludedApplications.FirstOrDefault(row =>
            row.ProcessName.Equals(SettingsService.NormalizeProcessName(processName), StringComparison.OrdinalIgnoreCase));
        _vm.SetFeedback($"已排除 {added?.DisplayName ?? displayName ?? processName}");
    }

    private void RemoveExcludedButton_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: string processName })
        {
            return;
        }

        var row = _vm.ExcludedApplications.FirstOrDefault(item =>
            item.ProcessName.Equals(processName, StringComparison.OrdinalIgnoreCase));
        var name = row?.DisplayName ?? processName;
        var result = MessageBox.Show(
            this,
            $"移除后，来自“{name}”的复制内容将不再被排除；已有历史不受影响。",
            "移除排除项？",
            MessageBoxButton.YesNo,
            MessageBoxImage.Question,
            MessageBoxResult.No);
        if (result != MessageBoxResult.Yes)
        {
            return;
        }

        _vm.RemoveExcludedProcess(processName);
        _vm.SetFeedback($"已取消排除 {name}");
    }

    private void RetentionButton_Click(object sender, RoutedEventArgs e)
    {
        var menu = new ContextMenu
        {
            PlacementTarget = (Button)sender,
            Placement = PlacementMode.Bottom
        };

        (int Days, string Label)[] options =
        [
            (7, "7 天"),
            (30, "30 天"),
            (90, "90 天"),
            (180, "180 天"),
            (365, "1 年"),
            (0, "永久保留")
        ];

        foreach (var (days, label) in options)
        {
            var item = new MenuItem
            {
                Header = label,
                IsCheckable = true,
                IsChecked = _vm.RetentionDays == days
            };
            item.Click += (_, _) =>
            {
                _vm.RetentionDays = days;
                _vm.SetFeedback($"历史保留已更新为{label}");
            };
            menu.Items.Add(item);
        }

        menu.IsOpen = true;
    }

    private void CleanupButton_Click(object sender, RoutedEventArgs e)
    {
        var menu = new ContextMenu
        {
            PlacementTarget = (Button)sender,
            Placement = PlacementMode.Bottom
        };

        (string Label, long? Seconds)[] options =
        [
            ("清理 1 小时前的记录", 3_600),
            ("清理 1 天前的记录", 86_400),
            ("清理 7 天前的记录", 604_800),
            ("清理 30 天前的记录", 2_592_000),
            ("清理 1 年前的记录", 31_536_000)
        ];

        foreach (var (label, seconds) in options)
        {
            var item = new MenuItem { Header = label, Tag = seconds };
            item.Click += (_, _) => _ = ConfirmCleanupAsync(seconds);
            menu.Items.Add(item);
        }

        menu.Items.Add(new Separator());
        var all = new MenuItem { Header = "清空全部历史…", Foreground = (Brush)FindResource("DangerBrush") };
        all.Click += (_, _) => _ = ConfirmCleanupAsync(null);
        menu.Items.Add(all);
        menu.IsOpen = true;
    }

    private async Task ConfirmCleanupAsync(long? seconds)
    {
        var cutoff = seconds is { } value ? DateTimeOffset.Now.AddSeconds(-value) : (DateTimeOffset?)null;
        var message = cutoff is { } point
            ? $"将永久删除早于 {point.LocalDateTime:yyyy/M/d HH:mm} 的记录，包含其中的置顶与分组内容；保留分组结构，不删除引用的原文件。"
            : "将永久删除全部历史记录，包含置顶与分组内容；保留分组结构，不删除引用的原文件。";
        var result = MessageBox.Show(
            this,
            message,
            "清理历史？",
            MessageBoxButton.YesNo,
            MessageBoxImage.Warning,
            MessageBoxResult.No);
        if (result != MessageBoxResult.Yes)
        {
            return;
        }

        await _vm.ClearAsync(cutoff);
    }

    private void CloseButton_Click(object sender, RoutedEventArgs e) => Close();

    private void ViewModel_PropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(LibraryViewModel.ShortcutDisplay))
        {
            UpdateShortcutDisplay();
        }
        else if (e.PropertyName == nameof(LibraryViewModel.ExcludedApplications))
        {
            UpdateExcludedEmpty();
        }
    }

    private void ExcludedApplications_CollectionChanged(object? sender, System.Collections.Specialized.NotifyCollectionChangedEventArgs e) =>
        UpdateExcludedEmpty();

    private void UpdateExcludedEmpty()
    {
        ExcludedEmpty.Visibility = _vm.ExcludedApplications.Count == 0
            ? Visibility.Visible
            : Visibility.Collapsed;
    }

    private void Window_Closing(object? sender, CancelEventArgs e)
    {
        if (_recordingHotKey)
        {
            CancelHotKeyCapture();
        }

        if (_closed)
        {
            return;
        }

        _closed = true;
        _vm.PropertyChanged -= ViewModel_PropertyChanged;
        _vm.ExcludedApplications.CollectionChanged -= ExcludedApplications_CollectionChanged;
        App.Services.HotKeys.Resume();
    }

    private static T? FindAncestor<T>(DependencyObject? element) where T : DependencyObject
    {
        while (element is not null)
        {
            if (element is T target)
            {
                return target;
            }

            element = VisualTreeHelper.GetParent(element);
        }

        return null;
    }
}
