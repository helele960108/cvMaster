/**
 * 列表卡片：图片缩略图按需加载；悬停只是通知浮层，不直接读取内容。
 * @author helele
 * @since 2026-10-19
 */
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using CvMaster.ViewModels;

namespace CvMaster.Controls;

public partial class ClipCard : UserControl
{
    private CancellationTokenSource? _thumbnailCancellation;

    public ClipCard()
    {
        InitializeComponent();
        Loaded += OnLoaded;
        Unloaded += OnUnloaded;
        DataContextChanged += (_, _) =>
        {
            CancelThumbnail();
            if (IsLoaded)
            {
                _ = LoadThumbnailAsync();
            }
        };
        MouseEnter += OnMouseEnter;
        MouseLeave += OnMouseLeave;
    }

    private void OnLoaded(object sender, RoutedEventArgs e) => _ = LoadThumbnailAsync();

    private void OnUnloaded(object sender, RoutedEventArgs e)
    {
        CancelThumbnail();
        ThumbBorder.Background = (Brush)FindResource("SubtleBrush");
        ThumbPlaceholder.Visibility = Visibility.Visible;
    }

    private async Task LoadThumbnailAsync()
    {
        if (DataContext is not ClipRow row || !row.IsImage)
        {
            return;
        }

        CancelThumbnail();
        var cancellation = new CancellationTokenSource();
        _thumbnailCancellation = cancellation;
        try
        {
            var image = await App.Services.Thumbnails.GetListThumbnailAsync(row.Clip.Id, cancellation.Token);
            if (cancellation.IsCancellationRequested || image is null)
            {
                return;
            }

            ThumbBorder.Background = new ImageBrush(image)
            {
                Stretch = Stretch.UniformToFill,
                AlignmentX = AlignmentX.Center,
                AlignmentY = AlignmentY.Center
            };
            ThumbPlaceholder.Visibility = Visibility.Collapsed;
        }
        catch (OperationCanceledException)
        {
        }
    }

    private void CancelThumbnail()
    {
        _thumbnailCancellation?.Cancel();
        _thumbnailCancellation?.Dispose();
        _thumbnailCancellation = null;
    }

    private void OnMouseEnter(object sender, System.Windows.Input.MouseEventArgs e)
    {
        if (Window.GetWindow(this) is CvMaster.Views.QuickPanelWindow panel && DataContext is ClipRow row)
        {
            panel.SchedulePreviewShow(this, row);
        }
    }

    private void OnMouseLeave(object sender, System.Windows.Input.MouseEventArgs e)
    {
        if (Window.GetWindow(this) is CvMaster.Views.QuickPanelWindow panel)
        {
            panel.SchedulePreviewHide(this);
        }
    }

    private void PreviewButton_Click(object sender, RoutedEventArgs e)
    {
        if (Window.GetWindow(this) is CvMaster.Views.QuickPanelWindow panel && DataContext is ClipRow row)
        {
            panel.ShowPreviewForCard(this, row);
            e.Handled = true;
        }
    }
}
