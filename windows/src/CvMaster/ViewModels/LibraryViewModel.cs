/**
 * 浮层与设置共享的 UI 状态：防抖查询、版本防串序、分组 / 检索 / 保留策略。
 * 所有内容读取都通过 HistoryStore 在后台完成，主线程只接收轻量投影。
 * @author helele
 * @since 2026-10-19
 */
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Windows;
using System.Windows.Data;
using System.Windows.Threading;
using CvMaster.Core;
using CvMaster.Services;

namespace CvMaster.ViewModels;

public sealed class LibraryViewModel : INotifyPropertyChanged, IDisposable
{
    private readonly HistoryStore _store;
    private readonly SettingsService _settings;
    private readonly ThemeService _theme;
    private readonly ThumbnailService _thumbnails;
    private readonly HotKeyService _hotKeys;
    private readonly DispatcherTimer _relativeTimeTimer;
    private readonly DispatcherTimer _feedbackTimer;
    private CancellationTokenSource? _searchCancellation;
    private int _searchVersion;
    private int _limit = StorageLimits.PageSize;
    private bool _panelVisible;
    private int _captureBusy;
    private bool _clearing;
    private bool _initialized;
    private ICollectionView? _rowsView;
    private ClipRow? _selectedClip;
    private int _total;
    private int _loadedCount;
    private int _storedEntries;
    private long _storedBytes;
    private bool _isLoading;
    private string _query = string.Empty;
    private string _scope = "all";
    private ClipKind? _kindFilter;
    private ClipTimeRange _timeRange = ClipTimeRange.All;
    private bool _paused;
    private bool _shortcutAvailable;
    private string? _feedback;
    private ObservableCollection<ClipGroup> _groups = [];
    private ObservableCollection<ExcludedAppRow> _excludedApplications = [];
    private bool _disposed;

    public LibraryViewModel(
        HistoryStore store,
        SettingsService settings,
        ThemeService theme,
        ThumbnailService thumbnails,
        HotKeyService hotKeys)
    {
        _store = store;
        _settings = settings;
        _theme = theme;
        _thumbnails = thumbnails;
        _hotKeys = hotKeys;
        _paused = settings.Paused;

        _relativeTimeTimer = new DispatcherTimer { Interval = TimeSpan.FromMinutes(1) };
        _relativeTimeTimer.Tick += (_, _) => RefreshRelativeTimes();
        _relativeTimeTimer.Start();

        _feedbackTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(5) };
        _feedbackTimer.Tick += (_, _) =>
        {
            _feedbackTimer.Stop();
            Feedback = null;
        };
    }

    public event PropertyChangedEventHandler? PropertyChanged;
    public event EventHandler? GroupsChanged;
    public event EventHandler? ScopeChanged;
    public event EventHandler? SearchCriteriaChanged;
    public event EventHandler? SelectionScrollRequested;
    public event EventHandler? StateChanged;

    public ClipboardMonitor? Monitor { get; set; }

    public ICollectionView? RowsView
    {
        get => _rowsView;
        private set
        {
            _rowsView = value;
            OnPropertyChanged();
        }
    }

    public ClipRow? SelectedClip
    {
        get => _selectedClip;
        set
        {
            if (ReferenceEquals(_selectedClip, value))
            {
                return;
            }

            _selectedClip = value;
            OnPropertyChanged();
            OnPropertyChanged(nameof(HasSelection));
        }
    }

    public bool HasSelection => _selectedClip is not null;

    public int Total
    {
        get => _total;
        private set
        {
            if (_total == value)
            {
                return;
            }

            _total = value;
            OnPropertyChanged();
            OnPropertyChanged(nameof(StatusText));
            OnPropertyChanged(nameof(HasMore));
            OnPropertyChanged(nameof(ShowMaximumLoadedHint));
        }
    }

    public int LoadedCount
    {
        get => _loadedCount;
        private set
        {
            if (_loadedCount == value)
            {
                return;
            }

            _loadedCount = value;
            OnPropertyChanged();
            OnPropertyChanged(nameof(HasMore));
            OnPropertyChanged(nameof(ShowMaximumLoadedHint));
            OnPropertyChanged(nameof(IsEmpty));
            OnPropertyChanged(nameof(IsEmptyVisible));
        }
    }

    public bool HasMore => LoadedCount > 0 && Total > LoadedCount && LoadedCount < StorageLimits.MaximumLoaded;

    public bool IsEmpty => !IsLoading && LoadedCount == 0;

    public bool IsLoading
    {
        get => _isLoading;
        private set
        {
            if (_isLoading == value)
            {
                return;
            }

            _isLoading = value;
            OnPropertyChanged();
            OnPropertyChanged(nameof(IsEmpty));
            OnPropertyChanged(nameof(IsEmptyVisible));
        }
    }

    public bool IsEmptyVisible => IsEmpty;

    public bool HasActiveFilters =>
        !string.IsNullOrWhiteSpace(Query) ||
        Scope != "all" ||
        KindFilter is not null ||
        TimeRange != ClipTimeRange.All;

    public string EmptyTitle => HasActiveFilters ? "没有找到内容" : "还没有内容";

    public string EmptyDescription => "换个分组、时间范围或关键词试试。";

    public bool ShowMaximumLoadedHint => !HasMore && LoadedCount >= StorageLimits.MaximumLoaded;

    public string Query
    {
        get => _query;
        set
        {
            if (_query == value)
            {
                return;
            }

            _query = value;
            OnPropertyChanged();
            NotifyEmptyState();
            SearchCriteriaChanged?.Invoke(this, EventArgs.Empty);
            ScheduleSearch(debounce: true);
        }
    }

    public string Scope
    {
        get => _scope;
        set
        {
            if (_scope == value)
            {
                return;
            }

            _scope = value;
            OnPropertyChanged();
            NotifyEmptyState();
            ScopeChanged?.Invoke(this, EventArgs.Empty);
            SearchCriteriaChanged?.Invoke(this, EventArgs.Empty);
            ScheduleSearch(debounce: false);
        }
    }

    public ClipKind? KindFilter
    {
        get => _kindFilter;
        set
        {
            if (_kindFilter == value)
            {
                return;
            }

            _kindFilter = value;
            OnPropertyChanged();
            NotifyEmptyState();
            SearchCriteriaChanged?.Invoke(this, EventArgs.Empty);
            ScheduleSearch(debounce: false);
        }
    }

    public ClipTimeRange TimeRange
    {
        get => _timeRange;
        set
        {
            if (_timeRange == value)
            {
                return;
            }

            _timeRange = value;
            OnPropertyChanged();
            OnPropertyChanged(nameof(TimeRangeText));
            OnPropertyChanged(nameof(SearchPlaceholder));
            NotifyEmptyState();
            SearchCriteriaChanged?.Invoke(this, EventArgs.Empty);
            ScheduleSearch(debounce: false);
        }
    }

    public string TimeRangeText => TimeRange.DisplayName();

    public string SearchPlaceholder => TimeRange == ClipTimeRange.All
        ? "搜索剪贴板…"
        : $"搜索剪贴板… · {TimeRange.DisplayName()}";

    public string StatusText => Feedback ?? $"{Total} 条 · 本地保存";

    public string? Feedback
    {
        get => _feedback;
        private set
        {
            if (_feedback == value)
            {
                return;
            }

            _feedback = value;
            OnPropertyChanged();
            OnPropertyChanged(nameof(StatusText));
        }
    }

    public ObservableCollection<ClipGroup> Groups
    {
        get => _groups;
        private set
        {
            _groups = value;
            OnPropertyChanged();
        }
    }

    public ObservableCollection<ExcludedAppRow> ExcludedApplications
    {
        get => _excludedApplications;
        private set
        {
            _excludedApplications = value;
            OnPropertyChanged();
            OnPropertyChanged(nameof(ExcludedCountText));
        }
    }

    public string ExcludedCountText => $"{ExcludedApplications.Count} 个应用";

    public bool RecordingEnabled
    {
        get => _settings.RecordingEnabled;
        set
        {
            if (_settings.RecordingEnabled == value)
            {
                return;
            }

            _settings.RecordingEnabled = value;
            Monitor?.ResetBaseline();
            OnPropertyChanged();
            OnPropertyChanged(nameof(RecordingBannerVisible));
            StateChanged?.Invoke(this, EventArgs.Empty);
        }
    }

    public bool RecordingBannerVisible => !RecordingEnabled;

    public bool Paused
    {
        get => _paused;
        set
        {
            if (_paused == value)
            {
                return;
            }

            _paused = value;
            _settings.Paused = value;
            Monitor?.ResetBaseline();
            OnPropertyChanged();
            OnPropertyChanged(nameof(PausedVisible));
            StateChanged?.Invoke(this, EventArgs.Empty);
        }
    }

    public bool PausedVisible => Paused;

    public bool AutoPaste
    {
        get => _settings.AutoPaste;
        set
        {
            if (_settings.AutoPaste == value)
            {
                return;
            }

            _settings.AutoPaste = value;
            OnPropertyChanged();
        }
    }

    public bool SkipSensitive
    {
        get => _settings.SkipSensitive;
        set
        {
            if (_settings.SkipSensitive == value)
            {
                return;
            }

            _settings.SkipSensitive = value;
            OnPropertyChanged();
        }
    }

    public bool RunAtStartup
    {
        get => _settings.RunAtStartup;
        set
        {
            if (_settings.RunAtStartup == value)
            {
                return;
            }

            _settings.RunAtStartup = value;
            OnPropertyChanged();
        }
    }

    public int RetentionDays
    {
        get => _settings.RetentionDays;
        set
        {
            if (_settings.RetentionDays == value)
            {
                return;
            }

            _settings.RetentionDays = value;
            OnPropertyChanged();
            OnPropertyChanged(nameof(RetentionText));
        }
    }

    public string RetentionText => RetentionDays == 0 ? "永久保留" : $"{RetentionDays} 天";

    public AppAppearance Appearance
    {
        get => _theme.Appearance;
        set
        {
            _settings.Appearance = ThemeService.ToStorageValue(value);
            _theme.Apply(value);
            OnPropertyChanged();
        }
    }

    public bool ShortcutAvailable
    {
        get => _shortcutAvailable;
        private set
        {
            if (_shortcutAvailable == value)
            {
                return;
            }

            _shortcutAvailable = value;
            OnPropertyChanged();
            OnPropertyChanged(nameof(ShortcutDisplay));
        }
    }

    public string ShortcutDisplay => ShortcutAvailable
        ? _hotKeys.Current?.Display ?? "Alt+Space"
        : "热键不可用";

    public int StoredEntries
    {
        get => _storedEntries;
        private set
        {
            if (_storedEntries == value)
            {
                return;
            }

            _storedEntries = value;
            OnPropertyChanged();
            OnPropertyChanged(nameof(StorageUsageText));
            OnPropertyChanged(nameof(StorageProgress));
        }
    }

    public long StoredBytes
    {
        get => _storedBytes;
        private set
        {
            if (_storedBytes == value)
            {
                return;
            }

            _storedBytes = value;
            OnPropertyChanged();
            OnPropertyChanged(nameof(StorageUsageText));
            OnPropertyChanged(nameof(StorageProgress));
        }
    }

    public string StorageUsageText =>
        $"{StoredEntries:N0} 条 / {StorageLimits.MaximumEntries:N0} 条 · {ByteSizeFormatter.Format(StoredBytes)} / {ByteSizeFormatter.Format(StorageLimits.MaximumBytes)}";

    public double StorageProgress
    {
        get
        {
            var byEntries = StoredEntries / (double)StorageLimits.MaximumEntries;
            var byBytes = StoredBytes / (double)StorageLimits.MaximumBytes;
            return Math.Clamp(Math.Max(byEntries, byBytes), 0, 1);
        }
    }

    public ThumbnailService Thumbnails => _thumbnails;

    public HistoryStore Store => _store;

    public async Task InitializeAsync()
    {
        if (_initialized)
        {
            return;
        }

        _initialized = true;
        await RefreshGroupsAsync();
        RefreshExcludedApplications();
        ScheduleSearch(debounce: false);
    }

    public void InitializeHotKey()
    {
        var gesture = HotKeyGesture.Parse(_settings.HotKey) ?? HotKeyGesture.Default;
        ShortcutAvailable = _hotKeys.TryRegister(gesture);
        if (!ShortcutAvailable)
        {
            AppLog.Error("hotkey-register");
        }

        OnPropertyChanged(nameof(ShortcutDisplay));
    }

    public bool TrySetHotKey(HotKeyGesture gesture, out string? error)
    {
        if (gesture.ValidationMessage is { } message)
        {
            error = message;
            return false;
        }

        var previous = _hotKeys.Current ?? HotKeyGesture.Default;
        if (_hotKeys.TryRegister(gesture))
        {
            _settings.HotKey = gesture.Display;
            ShortcutAvailable = true;
            OnPropertyChanged(nameof(ShortcutDisplay));
            error = null;
            return true;
        }

        _hotKeys.TryRegister(previous);
        ShortcutAvailable = _hotKeys.IsRegistered;
        error = "该快捷键已被其他应用占用，请换一个组合。";
        OnPropertyChanged(nameof(ShortcutDisplay));
        return false;
    }

    public void PanelOpened()
    {
        _panelVisible = true;
        _ = RefreshGroupsAsync();
        ScheduleSearch(debounce: false);
    }

    public void PanelClosed()
    {
        _panelVisible = false;
        _searchVersion++;
        _searchCancellation?.Cancel();
        IsLoading = false;
        if (LoadedCount > StorageLimits.PageSize)
        {
            _limit = StorageLimits.PageSize;
            ScheduleSearch(debounce: false, resetLimit: false);
        }
    }

    public void LoadMore()
    {
        if (!HasMore || IsLoading)
        {
            return;
        }

        _limit = Math.Min(_limit + StorageLimits.PageSize, StorageLimits.MaximumLoaded);
        ScheduleSearch(debounce: false, resetLimit: false);
    }

    public void MoveSelection(int offset)
    {
        if (RowsView is null)
        {
            return;
        }

        var rows = RowsView.Cast<ClipRow>().ToList();
        if (rows.Count == 0)
        {
            return;
        }

        var current = SelectedClip is null ? -1 : rows.FindIndex(item => item.Clip.Id == SelectedClip.Clip.Id);
        var index = Math.Clamp(current + offset, 0, rows.Count - 1);
        SelectedClip = rows[index];
        SelectionScrollRequested?.Invoke(this, EventArgs.Empty);
    }

    public void ScheduleSearch(bool debounce, bool resetLimit = true)
    {
        _searchVersion++;
        var version = _searchVersion;
        _searchCancellation?.Cancel();
        _searchCancellation?.Dispose();
        var cancellation = new CancellationTokenSource();
        _searchCancellation = cancellation;
        if (resetLimit)
        {
            _limit = StorageLimits.PageSize;
        }

        IsLoading = true;
        _ = SearchAsync(version, debounce, cancellation.Token);
    }

    private async Task SearchAsync(int version, bool debounce, CancellationToken cancellationToken)
    {
        try
        {
            if (debounce)
            {
                await Task.Delay(140, cancellationToken);
            }

            var page = await _store.GetPageAsync(
                new ClipSearchQuery(Query, Scope, KindFilter, TimeRange, _limit),
                cancellationToken);
            if (cancellationToken.IsCancellationRequested || version != _searchVersion)
            {
                return;
            }

            var previousId = SelectedClip?.Clip.Id;
            var rows = page.Clips.Select(clip => new ClipRow(clip)).ToList();
            var view = new ListCollectionView(rows);
            view.GroupDescriptions.Add(new PropertyGroupDescription(nameof(ClipRow.Section)));
            RowsView = view;
            LoadedCount = rows.Count;
            Total = page.Total;
            StoredEntries = page.StoredEntries;
            StoredBytes = page.StoredBytes;
            SelectedClip = previousId is { } id
                ? rows.FirstOrDefault(row => row.Clip.Id == id) ?? rows.FirstOrDefault()
                : rows.FirstOrDefault();
            IsLoading = false;
            OnPropertyChanged(nameof(IsEmpty));
            OnPropertyChanged(nameof(IsEmptyVisible));
            OnPropertyChanged(nameof(StatusText));
            if (SelectedClip is not null)
            {
                SelectionScrollRequested?.Invoke(this, EventArgs.Empty);
            }
        }
        catch (OperationCanceledException)
        {
        }
        catch (LibraryException exception)
        {
            IsLoading = false;
            ReportError(exception);
        }
        catch (Exception exception)
        {
            IsLoading = false;
            AppLog.Error("search", exception);
            SetFeedback("本地查询失败，请稍后重试。");
        }
    }

    public async Task RefreshGroupsAsync()
    {
        try
        {
            var groups = await _store.GetGroupsAsync();
            Groups = new ObservableCollection<ClipGroup>(groups);
            GroupsChanged?.Invoke(this, EventArgs.Empty);
        }
        catch (LibraryException exception)
        {
            ReportError(exception);
        }
    }

    /// <summary>保存分组；返回面向用户的错误，成功时刷新目录与列表。</summary>
    public async Task<string?> SaveGroupAsync(Guid? id, string name)
    {
        try
        {
            await _store.SaveGroupAsync(id, name);
            await RefreshGroupsAsync();
            ScheduleSearch(debounce: false);
            SetFeedback(id is null ? "已创建分组" : "已重命名分组");
            return null;
        }
        catch (LibraryException exception)
        {
            return exception.Message;
        }
    }

    public async Task TogglePinnedAsync(Clip clip)
    {
        try
        {
            await _store.SetPinnedAsync(clip.Id, !clip.Pinned);
            ScheduleSearch(debounce: false);
        }
        catch (LibraryException exception)
        {
            ReportError(exception);
        }
    }

    public async Task ToggleGroupAsync(Clip clip, Guid groupId)
    {
        try
        {
            var included = !clip.Groups.Contains(groupId);
            await _store.SetGroupAsync(clip.Id, groupId, included);
            ScheduleSearch(debounce: false);
        }
        catch (LibraryException exception)
        {
            ReportError(exception);
        }
    }

    public async Task DeleteAsync(Clip clip)
    {
        try
        {
            await _store.DeleteAsync(clip.Id);
            _thumbnails.Clear();
            ScheduleSearch(debounce: false);
            SetFeedback("记录已删除");
        }
        catch (LibraryException exception)
        {
            ReportError(exception);
        }
    }

    public async Task ClearAsync(DateTimeOffset? before)
    {
        _clearing = true;
        try
        {
            var removed = await _store.ClearAsync(before);
            _thumbnails.Clear();
            await RefreshStatsAsync();
            ScheduleSearch(debounce: false);
            SetFeedback(before is null
                ? "已清空全部历史"
                : removed > 0
                    ? $"已清理 {removed} 条记录"
                    : "没有早于该时间的记录");
        }
        catch (LibraryException exception)
        {
            ReportError(exception);
        }
        finally
        {
            _clearing = false;
            Monitor?.ResetBaseline();
        }
    }

    public async Task RefreshStatsAsync()
    {
        try
        {
            var stats = await _store.GetStorageStatsAsync();
            StoredEntries = stats.Entries;
            StoredBytes = stats.Bytes;
        }
        catch (LibraryException exception)
        {
            ReportError(exception);
        }
    }

    public async Task<ClipPreviewData> GetPreviewAsync(Guid id, CancellationToken cancellationToken) =>
        await _store.GetPreviewAsync(id, cancellationToken);

    public async Task AcceptCaptureAsync(ClipCapture capture)
    {
        if (_clearing)
        {
            AppLog.Info("capture-skipped-clearing");
            return;
        }

        if (Interlocked.Exchange(ref _captureBusy, 1) == 1)
        {
            AppLog.Info("capture-skipped");
            return;
        }

        try
        {
            await _store.SaveAsync(capture, RetentionDays);
            if (_panelVisible)
            {
                ScheduleSearch(debounce: false);
            }
        }
        catch (LibraryException exception)
        {
            ReportError(exception);
        }
        catch (Exception exception)
        {
            AppLog.Error("capture-save", exception);
            SetFeedback("本地保存失败，请检查磁盘空间。");
        }
        finally
        {
            Interlocked.Exchange(ref _captureBusy, 0);
        }
    }

    public void ReportCaptureError(LibraryErrorCode code)
    {
        AppLog.Error($"capture-{code}");
        if (_panelVisible)
        {
            SetFeedback(LibraryException.UserMessage(code));
        }
    }

    public void SetFeedback(string? message)
    {
        if (Application.Current.Dispatcher.CheckAccess() is false)
        {
            Application.Current.Dispatcher.BeginInvoke(() => SetFeedback(message));
            return;
        }

        Feedback = message;
        _feedbackTimer.Stop();
        if (!string.IsNullOrEmpty(message))
        {
            _feedbackTimer.Start();
        }
    }

    public void RefreshExcludedApplications()
    {
        var rows = _settings.ExcludedProcessList
            .Select(process => new ExcludedAppRow(
                process,
                ProcessCatalog.DisplayName(process),
                ProcessCatalog.Icon(process)))
            .ToList();
        ExcludedApplications = new ObservableCollection<ExcludedAppRow>(rows);
    }

    public string? AddExcludedProcess(string value)
    {
        var error = _settings.AddExcludedProcess(value);
        if (error is null)
        {
            RefreshExcludedApplications();
        }

        return error;
    }

    public void RemoveExcludedProcess(string processName)
    {
        _settings.RemoveExcludedProcess(processName);
        RefreshExcludedApplications();
    }

    private void ReportError(LibraryException exception)
    {
        AppLog.Error($"library-{exception.Code}");
        SetFeedback(exception.Message);
    }

    private void RefreshRelativeTimes()
    {
        if (RowsView is null)
        {
            return;
        }

        foreach (var row in RowsView.Cast<ClipRow>())
        {
            row.RefreshRelativeTime();
        }
    }

    private void NotifyEmptyState()
    {
        OnPropertyChanged(nameof(HasActiveFilters));
        OnPropertyChanged(nameof(EmptyTitle));
        OnPropertyChanged(nameof(EmptyDescription));
    }

    private void OnPropertyChanged([CallerMemberName] string? name = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        _relativeTimeTimer.Stop();
        _feedbackTimer.Stop();
        _searchCancellation?.Cancel();
        _searchCancellation?.Dispose();
    }
}
