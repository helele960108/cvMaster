/**
 * 托盘图标下的唯一浮层：搜索、分组、类型筛选、列表、右键操作与侧边预览。
 * 不创建常规主窗口；点击外部、Esc 或粘贴后收起。
 * @author helele
 * @since 2026-10-19
 */
using System.Text;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using CvMaster.Controls;
using CvMaster.Core;
using CvMaster.Interop;
using CvMaster.Services;
using CvMaster.ViewModels;

namespace CvMaster.Views;

public partial class QuickPanelWindow : Window
{
    private readonly LibraryViewModel _vm;
    private SidePreviewWindow? _preview;
    private ClipRow? _previewRow;
    private ClipCard? _hoverCard;
    private DispatcherTimer? _previewShowTimer;
    private DispatcherTimer? _previewHideTimer;
    private DispatcherTimer? _autoHideTimer;
    private PasteTarget? _pasteTarget;
    private int _openMenus;
    private int _openDialogs;
    private bool _pasting;
    private bool _resizeDragging;
    private bool _resizeGripAtTop;
    private double _resizeStartHeight;
    private double _resizeStartCursorY;
    private double _resizeStartTop;
    private double _resizeBottom;

    public QuickPanelWindow()
    {
        InitializeComponent();
        _vm = App.Services.Library;
        DataContext = _vm;
        Height = Math.Clamp(App.Services.Settings.PanelHeight, 420, 1000);

        _vm.GroupsChanged += (_, _) =>
        {
            RebuildGroupChips();
            UpdateTypeChips();
        };
        _vm.ScopeChanged += (_, _) =>
        {
            RebuildGroupChips();
            UpdateTypeChips();
        };
        _vm.SearchCriteriaChanged += (_, _) => ClosePreviewImmediate();
        _vm.SelectionScrollRequested += (_, _) => ScrollSelectionIntoView();
        _vm.StateChanged += (_, _) => UpdateTrayTooltip();
        _vm.PropertyChanged += (_, args) =>
        {
            switch (args.PropertyName)
            {
                case nameof(LibraryViewModel.ShortcutDisplay):
                    UpdateTrayTooltip();
                    break;
                case nameof(LibraryViewModel.KindFilter):
                    UpdateTypeChips();
                    break;
                case nameof(LibraryViewModel.ChangingGroups):
                    RebuildGroupChips();
                    break;
            }
        };
        RebuildGroupChips();
        UpdateTypeChips();
        UpdateTimeFilterVisuals();
        UpdateSearchChrome();
        UpdateTrayTooltip();
    }

    public LibraryViewModel ViewModel => _vm;

    public void ShowPanel(PasteTarget? preservedTarget = null)
    {
        if (_pasting)
        {
            return;
        }

        if (IsVisible)
        {
            HidePanel();
            return;
        }

        _pasteTarget = preservedTarget ?? App.Services.Foreground.CaptureCurrentOrLast()?.ToTarget();
        _vm.PanelOpened();
        Height = Math.Clamp(App.Services.Settings.PanelHeight, 420, 1000);
        var placement = ScreenPlacement.PlacePanel(this, Width, Height, App.Services.Tray?.GetIconRect());
        UpdateResizeGripPlacement(placement);
        Show();
        Activate();
        Dispatcher.BeginInvoke(DispatcherPriority.Input, () =>
        {
            SearchBox.Focus();
            SearchBox.SelectAll();
            UpdateSearchChrome();
        });
    }

    public void HidePanel()
    {
        if (!IsVisible || _openDialogs > 0)
        {
            return;
        }

        ClosePreviewImmediate();
        _vm.PanelClosed();
        Hide();
    }

    /// <summary>粘贴前收起，但不重置粘贴目标；失败时由调用方重新展示。</summary>
    public void HideForPaste()
    {
        ClosePreviewImmediate();
        _vm.PanelClosed();
        Hide();
    }

    private async Task PasteAsync(ClipRow row, bool plainText)
    {
        if (_pasting)
        {
            return;
        }

        _pasting = true;
        ClosePreviewImmediate();
        try
        {
            var result = await App.Services.Paste.PasteAsync(
                row.Clip,
                plainText,
                _pasteTarget,
                HideForPaste,
                CancellationToken.None);
            if (result == PasteResult.Busy)
            {
                _vm.SetFeedback("正在准备内容…");
                return;
            }

            if (!result.ClipboardWritten)
            {
                _pasting = false;
                var message = LibraryException.UserMessage(result.Error ?? LibraryErrorCode.Storage);
                if (!IsVisible)
                {
                    ReopenAfterPasteFailure(message);
                }

                _vm.SetFeedback(message);
                return;
            }

            if (result.Error is { } error)
            {
                _pasting = false;
                var message = LibraryException.UserMessage(error);
                ReopenAfterPasteFailure(message);
                _vm.SetFeedback(message);
            }
            else if (!result.PasteSent)
            {
                App.Services.Tray?.ShowBalloon("cvMaster", "已复制到剪贴板，按 Ctrl+V 粘贴。");
            }
        }
        finally
        {
            _pasting = false;
        }
    }

    /// <summary>
    /// 失败后仅在原目标仍存活且前台仍是目标或本应用时重开列表；
    /// 第三方应用已在前台时不抢焦点，只用不夺焦的气泡说明结果。
    /// 重开沿用原目标并建立新的操作会话，不复用失败前的准备结果。
    /// </summary>
    private void ReopenAfterPasteFailure(string message)
    {
        if (IsVisible)
        {
            return;
        }

        var target = _pasteTarget;
        if (target is not null &&
            TargetPaster.IsTargetAlive(target) &&
            TargetPaster.IsOwnOrTargetForeground(target))
        {
            ShowPanel(target);
            return;
        }

        App.Services.Tray?.ShowBalloon("cvMaster", message);
    }

    public void SchedulePreviewShow(ClipCard card, ClipRow row)
    {
        _hoverCard = card;
        _previewHideTimer?.Stop();
        if (_previewRow?.Clip.Id == row.Clip.Id && _preview?.IsVisible == true)
        {
            return;
        }

        _previewShowTimer?.Stop();
        _previewShowTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(280) };
        _previewShowTimer.Tick += (_, _) =>
        {
            _previewShowTimer?.Stop();
            _ = ShowPreviewAsync(card, row);
        };
        _previewShowTimer.Start();
    }

    public void SchedulePreviewHide(ClipCard card)
    {
        if (_hoverCard == card)
        {
            _hoverCard = null;
        }

        if (_preview is { IsVisible: true, IsMouseOver: true })
        {
            return;
        }

        _previewHideTimer?.Stop();
        _previewHideTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(200) };
        _previewHideTimer.Tick += (_, _) =>
        {
            _previewHideTimer?.Stop();
            if (_preview is { IsVisible: true, IsMouseOver: true })
            {
                return;
            }

            if (card.IsMouseOver)
            {
                return;
            }

            ClosePreviewImmediate();
        };
        _previewHideTimer.Start();
    }

    private async Task ShowPreviewAsync(ClipCard card, ClipRow row)
    {
        if (Window.GetWindow(card) != this)
        {
            return;
        }

        _preview ??= CreatePreviewWindow();
        var point = card.PointToScreen(new Point(0, 0));
        if (PresentationSource.FromVisual(card)?.CompositionTarget is { } compositionTarget)
        {
            point = compositionTarget.TransformFromDevice.Transform(point);
        }

        _previewRow = row;
        _preview.ShowFor(row);
        ScreenPlacement.PlaceBesidePanel(this, _preview, 310, 300, point.Y);
        _preview.Show();
        await Task.CompletedTask;
    }

    public void ShowPreviewForCard(ClipCard card, ClipRow row) => _ = ShowPreviewAsync(card, row);

    private SidePreviewWindow CreatePreviewWindow()
    {
        var preview = new SidePreviewWindow { Owner = null };
        preview.MouseEnter += (_, _) =>
        {
            _previewHideTimer?.Stop();
            _previewShowTimer?.Stop();
        };
        preview.MouseLeave += (_, _) =>
        {
            _previewHideTimer?.Stop();
            _previewHideTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(200) };
            _previewHideTimer.Tick += (_, _) =>
            {
                _previewHideTimer?.Stop();
                if (preview.IsMouseOver)
                {
                    return;
                }

                ClosePreviewImmediate();
            };
            _previewHideTimer.Start();
        };
        preview.Deactivated += (_, _) =>
        {
            if (IsVisible)
            {
                ScheduleAutoHide();
            }
        };
        return preview;
    }

    private void ClosePreviewImmediate()
    {
        _previewShowTimer?.Stop();
        _previewShowTimer = null;
        _previewHideTimer?.Stop();
        _previewHideTimer = null;
        _hoverCard = null;
        _previewRow = null;
        _preview?.Hide();
    }

    private void Window_Deactivated(object sender, EventArgs e) => ScheduleAutoHide();

    private void ScheduleAutoHide()
    {
        _autoHideTimer?.Stop();
        _autoHideTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(150) };
        _autoHideTimer.Tick += (_, _) =>
        {
            _autoHideTimer?.Stop();
            if (!IsVisible || IsActive || _pasting || _openDialogs > 0 || _openMenus > 0)
            {
                return;
            }

            if (_preview is { IsVisible: true } && (_preview.IsActive || _preview.IsMouseOver))
            {
                return;
            }

            if (OwnedWindows.Cast<Window>().Any(window => window.IsVisible))
            {
                return;
            }

            HidePanel();
        };
        _autoHideTimer.Start();
    }

    private void Window_Closing(object sender, System.ComponentModel.CancelEventArgs e)
    {
        if (App.CurrentApp.IsShuttingDown)
        {
            return;
        }

        e.Cancel = true;
        HidePanel();
    }

    private void Window_LocationChanged(object? sender, EventArgs e) => ClosePreviewImmediate();

    private void Window_SourceInitialized(object? sender, EventArgs e) =>
        WindowAppearance.Apply(this, App.Services.Theme.IsDark);

    private void Window_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        // 菜单和模态确认各自处理 Esc，不能穿透到根窗口关闭命令。
        if (_openDialogs > 0 || _openMenus > 0)
        {
            return;
        }

        if (e.Key == Key.Escape)
        {
            if (_preview is { IsVisible: true })
            {
                ClosePreviewImmediate();
            }
            else
            {
                HidePanel();
            }

            e.Handled = true;
            return;
        }

        if (e.Key is Key.Down or Key.Up)
        {
            _vm.MoveSelection(e.Key == Key.Down ? 1 : -1);
            e.Handled = true;
            return;
        }

        if (e.Key == Key.Enter && _vm.SelectedClip is { } selected)
        {
            _ = PasteAsync(selected, plainText: false);
            e.Handled = true;
            return;
        }

        if (e.Key == Key.F && Keyboard.Modifiers == ModifierKeys.Control)
        {
            SearchBox.Focus();
            SearchBox.SelectAll();
            e.Handled = true;
            return;
        }

        if (e.Key == Key.OemComma && Keyboard.Modifiers == ModifierKeys.Control)
        {
            HidePanel();
            App.CurrentApp.OpenSettings();
            e.Handled = true;
        }
    }

    private void SearchBox_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        switch (e.Key)
        {
            case Key.Down:
                _vm.MoveSelection(1);
                e.Handled = true;
                break;
            case Key.Up:
                _vm.MoveSelection(-1);
                e.Handled = true;
                break;
            case Key.Enter:
                if (_vm.SelectedClip is { } selected)
                {
                    _ = PasteAsync(selected, plainText: false);
                }

                e.Handled = true;
                break;
            case Key.Escape:
                if (_preview is { IsVisible: true })
                {
                    ClosePreviewImmediate();
                }
                else
                {
                    HidePanel();
                }

                e.Handled = true;
                break;
        }
    }

    private void SearchBox_TextChanged(object sender, TextChangedEventArgs e) => UpdateSearchChrome();

    private void UpdateSearchChrome()
    {
        var empty = SearchBox.Text.Length == 0;
        SearchPlaceholder.Visibility = empty ? Visibility.Visible : Visibility.Collapsed;
        ClearSearchButton.Visibility = empty ? Visibility.Collapsed : Visibility.Visible;
    }

    private void ClearSearchButton_Click(object sender, RoutedEventArgs e)
    {
        SearchBox.Text = string.Empty;
        SearchBox.Focus();
        UpdateSearchChrome();
    }

    private void TypeAllButton_Click(object sender, RoutedEventArgs e) => _vm.KindFilter = null;

    private void TypeTextButton_Click(object sender, RoutedEventArgs e) => _vm.KindFilter = ClipKind.Text;

    private void TypeLinkButton_Click(object sender, RoutedEventArgs e) => _vm.KindFilter = ClipKind.Link;

    private void TypeImageButton_Click(object sender, RoutedEventArgs e) => _vm.KindFilter = ClipKind.Image;

    private void TypeFileButton_Click(object sender, RoutedEventArgs e) => _vm.KindFilter = ClipKind.File;

    private void UpdateTypeChips()
    {
        Chip.SetIsActive(TypeAllButton, _vm.KindFilter is null);
        Chip.SetIsActive(TypeTextButton, _vm.KindFilter == ClipKind.Text);
        Chip.SetIsActive(TypeLinkButton, _vm.KindFilter == ClipKind.Link);
        Chip.SetIsActive(TypeImageButton, _vm.KindFilter == ClipKind.Image);
        Chip.SetIsActive(TypeFileButton, _vm.KindFilter == ClipKind.File);
    }

    private void RebuildGroupChips()
    {
        GroupChipsPanel.Children.Clear();
        AddGroupChip("全部", "all");
        AddGroupChip("置顶", "pinned");
        foreach (var group in _vm.Groups)
        {
            AddGroupChip(
                group.Name,
                group.Id.ToString("D"),
                (Brush?)Application.Current.TryFindResource($"GroupColor{Math.Abs(group.ColorIndex) % 4}Brush"));
        }
    }

    private void AddGroupChip(string label, string scope, Brush? dot = null)
    {
        var content = new StackPanel { Orientation = Orientation.Horizontal };
        if (dot is not null)
        {
            content.Children.Add(new Border
            {
                Width = 6,
                Height = 6,
                Margin = new Thickness(0, 0, 5, 0),
                VerticalAlignment = VerticalAlignment.Center,
                Background = dot,
                CornerRadius = new CornerRadius(2)
            });
        }

        content.Children.Add(new TextBlock
        {
            Text = label,
            VerticalAlignment = VerticalAlignment.Center
        });
        var button = new Button
        {
            Style = (Style)FindResource("CapsuleButtonStyle"),
            Content = content
        };
        Chip.SetIsActive(button, _vm.Scope == scope);
        AutomationProperties.SetName(button, label);
        button.Click += (_, _) => _vm.Scope = scope;
        if (Guid.TryParse(scope, out var groupId))
        {
            var menu = new ContextMenu { PlacementTarget = button };
            TrackMenu(menu);
            menu.Opened += (_, _) =>
            {
                ClosePreviewImmediate();
                PopulateGroupActions(menu.Items, groupId);
            };
            button.ContextMenu = menu;
            var index = _vm.Groups.ToList().FindIndex(group => group.Id == groupId);
            AutomationProperties.SetHelpText(button,
                $"用户分组第 {index + 1} 个，共 {_vm.Groups.Count} 个；右键管理，也可使用更多菜单中的当前分组。");
        }

        GroupChipsPanel.Children.Add(button);
    }

    private void TimeFilterButton_Click(object sender, RoutedEventArgs e)
    {
        var menu = new ContextMenu
        {
            PlacementTarget = TimeFilterButton,
            Placement = PlacementMode.Bottom
        };
        TrackMenu(menu);
        foreach (var range in Enum.GetValues<ClipTimeRange>())
        {
            var item = new MenuItem
            {
                Header = range.DisplayName(),
                IsCheckable = true,
                IsChecked = _vm.TimeRange == range
            };
            item.Click += (_, _) =>
            {
                _vm.TimeRange = range;
                UpdateTimeFilterVisuals();
            };
            menu.Items.Add(item);
        }

        menu.IsOpen = true;
    }

    private void UpdateTimeFilterVisuals()
    {
        var active = _vm.TimeRange != ClipTimeRange.All;
        TimeFilterIcon.Foreground = (Brush)FindResource(active ? "AccentBrush" : "TextSecondaryBrush");
        TimeFilterDot.Visibility = active ? Visibility.Visible : Visibility.Collapsed;
        TimeFilterButton.ToolTip = $"时间筛选：{_vm.TimeRange.DisplayName()}";
    }

    private void MoreButton_Click(object sender, RoutedEventArgs e)
    {
        var menu = new ContextMenu
        {
            PlacementTarget = (Button)sender,
            Placement = PlacementMode.Bottom
        };
        TrackMenu(menu);

        var pause = new MenuItem
        {
            Header = _vm.Paused ? "恢复记录" : "暂停记录"
        };
        pause.Click += (_, _) => _vm.Paused = !_vm.Paused;
        menu.Items.Add(pause);

        var newGroup = new MenuItem { Header = "新建分组…", IsEnabled = _vm.CanChangeGroups };
        newGroup.Click += (_, _) => _ = OpenGroupDialogAsync(null);
        menu.Items.Add(newGroup);

        if (Guid.TryParse(_vm.Scope, out var scopeId) && _vm.Groups.Any(group => group.Id == scopeId))
        {
            var currentGroup = new MenuItem { Header = "当前分组" };
            PopulateGroupActions(currentGroup.Items, scopeId);
            currentGroup.SubmenuOpened += (_, _) => PopulateGroupActions(currentGroup.Items, scopeId);
            menu.Items.Add(currentGroup);
        }

        menu.Items.Add(new Separator());
        var settings = new MenuItem { Header = "设置…" };
        settings.Click += (_, _) =>
        {
            HidePanel();
            App.CurrentApp.OpenSettings();
        };
        menu.Items.Add(settings);
        menu.Items.Add(new Separator());
        var exit = new MenuItem { Header = "退出 cvMaster" };
        exit.Click += (_, _) => App.CurrentApp.ExitApplication();
        menu.Items.Add(exit);
        menu.IsOpen = true;
    }

    /// <summary>右键和更多菜单共用分组操作；固定范围从不传入此路径。</summary>
    private void PopulateGroupActions(ItemCollection items, Guid groupId)
    {
        items.Clear();
        var groups = _vm.Groups.ToList();
        var index = groups.FindIndex(group => group.Id == groupId);
        var available = _vm.CanChangeGroups && index >= 0;
        var rename = new MenuItem { Header = "重命名…", IsEnabled = available };
        rename.Click += (_, _) => _ = OpenGroupDialogAsync(groupId);
        items.Add(rename);
        var forward = new MenuItem { Header = "前移", IsEnabled = available && index > 0 };
        forward.Click += (_, _) => _ = MoveGroupAsync(groupId, -1);
        items.Add(forward);
        var backward = new MenuItem { Header = "后移", IsEnabled = available && index < groups.Count - 1 };
        backward.Click += (_, _) => _ = MoveGroupAsync(groupId, 1);
        items.Add(backward);
        items.Add(new Separator());
        var delete = new MenuItem { Header = "删除分组…", IsEnabled = available };
        delete.Click += (_, _) => _ = ConfirmDeleteGroupAsync(groupId);
        items.Add(delete);
    }

    private async Task MoveGroupAsync(Guid groupId, int offset)
    {
        if (!_vm.CanChangeGroups || !_vm.Groups.Any(group => group.Id == groupId))
        {
            return;
        }

        ClosePreviewImmediate();
        await _vm.MoveGroupAsync(groupId, offset);
    }

    private async Task ConfirmDeleteGroupAsync(Guid groupId)
    {
        var group = _vm.Groups.FirstOrDefault(group => group.Id == groupId);
        if (!_vm.CanChangeGroups || group is null || _openDialogs > 0)
        {
            return;
        }

        _openDialogs++;
        ClosePreviewImmediate();
        try
        {
            var result = MessageBox.Show(
                this,
                "仅删除此分组及其分组关系，不会删除历史记录或原文件。记录仍可在“全部”和其他所属分组中查看。",
                $"删除分组“{group.Name}”？",
                MessageBoxButton.YesNoCancel,
                MessageBoxImage.Warning,
                MessageBoxResult.Cancel);
            if (result == MessageBoxResult.Yes)
            {
                await _vm.DeleteGroupAsync(group.Id);
            }
        }
        finally
        {
            _openDialogs--;
            ScheduleAutoHide();
        }
    }

    private void AddGroupButton_Click(object sender, RoutedEventArgs e) => _ = OpenGroupDialogAsync(null);

    private async Task OpenGroupDialogAsync(Guid? groupId)
    {
        if (!_vm.CanChangeGroups || _openDialogs > 0)
        {
            return;
        }

        var current = groupId is { } id ? _vm.Groups.FirstOrDefault(group => group.Id == id) : null;
        if (groupId is not null && current is null)
        {
            return;
        }

        _openDialogs++;
        ClosePreviewImmediate();
        try
        {
            var dialog = new TextPromptWindow(
                groupId is null ? "新建分组" : "重命名分组",
                "1–20 个字符，名称不可重复。",
                current?.Name ?? string.Empty,
                20,
                value =>
                {
                    var trimmed = value.Trim();
                    if (trimmed.Length == 0)
                    {
                        return "请输入分组名称。";
                    }

                    if (TextExtraction.CountTextElements(trimmed) > StorageLimits.MaximumGroupNameCharacters ||
                        Encoding.UTF8.GetByteCount(value) > StorageLimits.MaximumGroupNameBytes ||
                        Encoding.UTF8.GetByteCount(trimmed) > StorageLimits.MaximumGroupNameBytes)
                    {
                        return $"分组名称最多 {StorageLimits.MaximumGroupNameCharacters} 个字符、{StorageLimits.MaximumGroupNameBytes} 字节。";
                    }

                    if (_vm.Groups.Any(group =>
                            group.Id != groupId &&
                            GroupNames.Equal(group.Name, trimmed)))
                    {
                        return "已存在同名分组。";
                    }

                    return null;
                })
            {
                Owner = this
            };

            if (dialog.ShowDialog() == true && dialog.Value is { } name)
            {
                var error = await _vm.SaveGroupAsync(groupId, name);
                if (error is not null)
                {
                    ShowMessage(error, "保存分组失败");
                }
            }
        }
        finally
        {
            _openDialogs--;
            ScheduleAutoHide();
        }
    }

    private void EnableRecordingButton_Click(object sender, RoutedEventArgs e)
    {
        _vm.RecordingEnabled = true;
        _vm.SetFeedback("剪贴板记录已开启");
    }

    private void ResumeRecordingButton_Click(object sender, RoutedEventArgs e)
    {
        if (!_vm.Paused)
        {
            return;
        }

        _vm.Paused = false;
        _vm.SetFeedback("剪贴板记录已恢复");
    }

    private void LoadMoreButton_Click(object sender, RoutedEventArgs e) => _vm.LoadMore();

    private void ClipList_SelectionChanged(object sender, SelectionChangedEventArgs e) => ClosePreviewImmediate();

    private void ClipList_MouseDoubleClick(object sender, MouseButtonEventArgs e)
    {
        if (FindAncestor<ListBoxItem>(e.OriginalSource as DependencyObject) is null ||
            _vm.SelectedClip is not { } row)
        {
            return;
        }

        _ = PasteAsync(row, plainText: false);
        e.Handled = true;
    }

    private void ClipList_PreviewMouseRightButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (FindAncestor<ListBoxItem>(e.OriginalSource as DependencyObject) is { } item)
        {
            item.IsSelected = true;
            item.Focus();
        }
    }

    private void ClipList_ContextMenuOpening(object sender, ContextMenuEventArgs e)
    {
        if (_vm.SelectedClip is not { } row)
        {
            e.Handled = true;
            return;
        }

        ClipList.ContextMenu = BuildClipMenu(row);
    }

    private ContextMenu BuildClipMenu(ClipRow row)
    {
        var menu = new ContextMenu();
        TrackMenu(menu);

        var preview = new MenuItem { Header = "预览内容" };
        preview.Click += (_, _) => ShowPreviewForClip(row);
        menu.Items.Add(preview);

        var paste = new MenuItem { Header = "粘贴" };
        paste.Click += (_, _) => _ = PasteAsync(row, plainText: false);
        menu.Items.Add(paste);

        if (row.IsTextLike)
        {
            var plain = new MenuItem { Header = "粘贴为纯文本" };
            plain.Click += (_, _) => _ = PasteAsync(row, plainText: true);
            menu.Items.Add(plain);
        }

        menu.Items.Add(new Separator());
        var pin = new MenuItem { Header = row.Clip.Pinned ? "取消置顶" : "置顶" };
        pin.Click += (_, _) => _ = _vm.TogglePinnedAsync(row.Clip);
        menu.Items.Add(pin);

        var groups = new MenuItem { Header = "加入分组" };
        if (_vm.Groups.Count == 0)
        {
            groups.Items.Add(new MenuItem { Header = "暂无分组，请先新建分组", IsEnabled = false });
        }
        else
        {
            foreach (var group in _vm.Groups)
            {
                var item = new MenuItem
                {
                    Header = group.Name,
                    IsCheckable = true,
                    IsChecked = row.Clip.Groups.Contains(group.Id),
                    IsEnabled = _vm.CanChangeGroups
                };
                item.Click += (_, _) => _ = _vm.ToggleGroupAsync(row.Clip, group.Id);
                groups.Items.Add(item);
            }
        }

        groups.Items.Add(new Separator());
        var newGroup = new MenuItem { Header = "新建分组…", IsEnabled = _vm.CanChangeGroups };
        newGroup.Click += (_, _) => _ = OpenGroupDialogAsync(null);
        groups.Items.Add(newGroup);
        menu.Items.Add(groups);

        menu.Items.Add(new Separator());
        var delete = new MenuItem { Header = "删除记录…" };
        delete.Click += (_, _) => _ = ConfirmDeleteAsync(row);
        menu.Items.Add(delete);
        return menu;
    }

    private async Task ConfirmDeleteAsync(ClipRow row)
    {
        if (_openDialogs > 0)
        {
            return;
        }

        _openDialogs++;
        ClosePreviewImmediate();
        try
        {
            var result = MessageBox.Show(
                this,
                "将移除内容及其分组关联，不会删除原文件。",
                "删除这条记录？",
                MessageBoxButton.YesNo,
                MessageBoxImage.Warning,
                MessageBoxResult.No);
            if (result == MessageBoxResult.Yes)
            {
                await _vm.DeleteAsync(row.Clip);
            }
        }
        finally
        {
            _openDialogs--;
            ScheduleAutoHide();
        }
    }

    private void ShowPreviewForClip(ClipRow row)
    {
        var container = ClipList.ItemContainerGenerator.ContainerFromItem(row) as ListBoxItem;
        var card = FindDescendant<ClipCard>(container);
        if (card is not null)
        {
            _ = ShowPreviewAsync(card, row);
            return;
        }

        _preview ??= CreatePreviewWindow();
        _previewRow = row;
        _preview.ShowFor(row);
        ScreenPlacement.PlaceBesidePanel(this, _preview, 310, 300, Top + 40);
        _preview.Show();
    }

    private void TrackMenu(ContextMenu menu)
    {
        menu.Opened += (_, _) => _openMenus++;
        menu.Closed += (_, _) =>
        {
            _openMenus = Math.Max(0, _openMenus - 1);
            if (_openMenus == 0)
            {
                ScheduleAutoHide();
            }
        };
    }

    private void ScrollSelectionIntoView()
    {
        if (_vm.SelectedClip is { } row)
        {
            ClipList.ScrollIntoView(row);
        }
    }

    private void UpdateTrayTooltip()
    {
        var suffix = _vm.Paused ? " · 已暂停" : string.Empty;
        App.Services.Tray?.UpdateTooltip($"cvMaster · {_vm.ShortcutDisplay}{suffix}");
    }

    private void UpdateResizeGripPlacement(PanelPlacement placement)
    {
        // 手柄放在远离图标的一端；靠近图标的一端保持固定，窗口向另一侧伸缩。
        var atTop = placement != PanelPlacement.BelowIcon;
        if (_resizeGripAtTop == atTop)
        {
            return;
        }

        _resizeGripAtTop = atTop;
        Grid.SetRow(ResizeGrip, atTop ? 0 : 2);
        ResizeGrip.VerticalAlignment = atTop ? VerticalAlignment.Top : VerticalAlignment.Bottom;
        ResizeGrip.ToolTip = atTop ? "向上拖动增加高度" : "向下拖动增加高度";
    }

    private void ResizeGrip_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        ClosePreviewImmediate();
        NativeMethods.GetCursorPos(out var cursor);
        var scale = GetWindowDpiScale();
        _resizeDragging = true;
        _resizeStartHeight = ActualHeight;
        _resizeStartCursorY = cursor.Y / scale;
        _resizeStartTop = Top;
        _resizeBottom = Top + ActualHeight;
        ResizeGrip.CaptureMouse();
        e.Handled = true;
    }

    private void ResizeGrip_MouseMove(object sender, MouseEventArgs e)
    {
        if (!_resizeDragging || e.LeftButton != MouseButtonState.Pressed)
        {
            return;
        }

        NativeMethods.GetCursorPos(out var cursor);
        var scale = GetWindowDpiScale();
        var cursorY = cursor.Y / scale;
        var work = ScreenPlacement.GetWorkArea(this);
        double newHeight;
        if (_resizeGripAtTop)
        {
            // 顶部手柄远离托盘，底部保持贴住图标；向上拖动增高。
            var maximum = Math.Min(1000, Math.Max(420, _resizeBottom - work.Top - 8));
            newHeight = Math.Clamp(
                _resizeStartHeight + (_resizeStartCursorY - cursorY),
                420,
                maximum);
            Top = _resizeBottom - newHeight;
        }
        else
        {
            // 底部手柄用于图标在上方的布局，顶部固定；向下拖动增高。
            var maximum = Math.Min(1000, Math.Max(420, work.Bottom - _resizeStartTop - 8));
            newHeight = Math.Clamp(
                _resizeStartHeight + (cursorY - _resizeStartCursorY),
                420,
                maximum);
            Top = _resizeStartTop;
        }

        Height = newHeight;
        e.Handled = true;
    }

    private void ResizeGrip_MouseLeftButtonUp(object sender, MouseButtonEventArgs e)
    {
        if (!_resizeDragging)
        {
            return;
        }

        _resizeDragging = false;
        ResizeGrip.ReleaseMouseCapture();
        App.Services.Settings.PanelHeight = (int)Math.Round(Height);
        e.Handled = true;
    }

    private double GetWindowDpiScale()
    {
        var handle = new WindowInteropHelper(this).Handle;
        var dpi = handle == IntPtr.Zero ? 96u : NativeMethods.GetDpiForWindow(handle);
        return dpi == 0 ? 1.0 : dpi / 96.0;
    }

    private void ShowMessage(string message, string title)
    {
        _openDialogs++;
        try
        {
            MessageBox.Show(this, message, title, MessageBoxButton.OK, MessageBoxImage.Information);
        }
        finally
        {
            _openDialogs--;
            ScheduleAutoHide();
        }
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

    private static T? FindDescendant<T>(DependencyObject? element) where T : DependencyObject
    {
        if (element is null)
        {
            return null;
        }

        var count = VisualTreeHelper.GetChildrenCount(element);
        for (var index = 0; index < count; index++)
        {
            var child = VisualTreeHelper.GetChild(element, index);
            if (child is T target)
            {
                return target;
            }

            var nested = FindDescendant<T>(child);
            if (nested is not null)
            {
                return nested;
            }
        }

        return null;
    }
}
