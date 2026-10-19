/**
 * 侧边临时预览：只读取单条内容，限制文本预算与缩略图尺寸；不占用主列表高度。
 * @author helele
 * @since 2026-10-19
 */
using System.Windows;
using System.Windows.Input;
using CvMaster.Core;
using CvMaster.Services;
using CvMaster.ViewModels;

namespace CvMaster.Views;

public partial class SidePreviewWindow : Window
{
    private ClipRow? _row;
    private CancellationTokenSource? _cancellation;
    private bool _pinned;

    public SidePreviewWindow()
    {
        InitializeComponent();
    }

    private void Window_SourceInitialized(object? sender, EventArgs e) =>
        WindowAppearance.Apply(this, App.Services.Theme.IsDark);

    public void ShowFor(ClipRow row)
    {
        _cancellation?.Cancel();
        _cancellation?.Dispose();
        _cancellation = new CancellationTokenSource();
        _row = row;
        _pinned = row.Clip.Pinned;

        PreviewKindIcon.Data = row.KindIcon;
        PreviewTypeText.Text = row.Clip.Kind == ClipKind.Image
            ? $"图片 · {row.Clip.Source}"
            : $"{row.Clip.Kind.DisplayName()} · {row.Clip.Source}";
        PinButtonText.Text = _pinned ? "取消置顶" : "置顶";
        PreviewImage.Source = null;
        PreviewImage.Visibility = Visibility.Collapsed;
        PreviewText.Text = row.Clip.Excerpt;
        PreviewText.Visibility = row.Clip.Kind == ClipKind.Image ? Visibility.Collapsed : Visibility.Visible;
        PreviewEmpty.Visibility = Visibility.Collapsed;
        FooterText.Text = row.Clip.HasFileReference
            ? $"包含文件引用，原文件需保持可用 · {row.Clip.SizeText}"
            : $"{row.Clip.SizeText} · {row.Clip.Copies} 次复制";

        _ = LoadAsync(row, _cancellation.Token);
    }

    private async Task LoadAsync(ClipRow row, CancellationToken cancellationToken)
    {
        try
        {
            var preview = await App.Services.Library.GetPreviewAsync(row.Clip.Id, cancellationToken);
            if (cancellationToken.IsCancellationRequested || _row != row)
            {
                return;
            }

            if (row.Clip.Kind == ClipKind.Image)
            {
                if (preview.ImagePath is { } path)
                {
                    var image = await ThumbnailService.LoadPreviewAsync(path, cancellationToken);
                    if (cancellationToken.IsCancellationRequested || _row != row)
                    {
                        return;
                    }

                    if (image is not null)
                    {
                        PreviewImage.Source = image;
                        PreviewImage.Visibility = Visibility.Visible;
                        PreviewText.Visibility = Visibility.Collapsed;
                        PreviewEmpty.Visibility = Visibility.Collapsed;
                        return;
                    }
                }

                PreviewImage.Visibility = Visibility.Collapsed;
                PreviewText.Visibility = Visibility.Collapsed;
                PreviewEmpty.Text = row.Clip.IsImageFile
                    ? "原文件不可用、超出预览限制或格式不支持"
                    : "图片数据缺失或格式不支持";
                PreviewEmpty.Visibility = Visibility.Visible;
                return;
            }

            var text = string.IsNullOrWhiteSpace(preview.Text) ? row.Clip.Excerpt : preview.Text;
            PreviewText.Text = text;
            PreviewText.Visibility = Visibility.Visible;
            PreviewImage.Visibility = Visibility.Collapsed;
            if (string.IsNullOrWhiteSpace(text))
            {
                PreviewEmpty.Text = "内容不可预览";
                PreviewEmpty.Visibility = Visibility.Visible;
            }
        }
        catch (OperationCanceledException)
        {
        }
        catch (LibraryException exception)
        {
            if (cancellationToken.IsCancellationRequested)
            {
                return;
            }

            PreviewText.Visibility = Visibility.Collapsed;
            PreviewEmpty.Text = exception.Message;
            PreviewEmpty.Visibility = Visibility.Visible;
        }
        catch (Exception exception)
        {
            AppLog.Error("preview", exception);
            PreviewEmpty.Text = "预览加载失败。";
            PreviewEmpty.Visibility = Visibility.Visible;
        }
    }

    private async void PinButton_Click(object sender, RoutedEventArgs e)
    {
        if (_row is null)
        {
            return;
        }

        await App.Services.Library.TogglePinnedAsync(_row.Clip);
        _pinned = !_pinned;
        PinButtonText.Text = _pinned ? "取消置顶" : "置顶";
    }

    private void Window_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Escape)
        {
            Hide();
            e.Handled = true;
        }
    }

    private void Window_Closing(object sender, System.ComponentModel.CancelEventArgs e)
    {
        if (!App.CurrentApp.IsShuttingDown)
        {
            e.Cancel = true;
            Hide();
        }

        _cancellation?.Cancel();
        _cancellation?.Dispose();
        _cancellation = null;
    }
}
