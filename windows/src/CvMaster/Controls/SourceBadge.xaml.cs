/**
 * 来源应用小徽标：优先显示进程图标，无法解析时退回收首字符标记。
 * @author helele
 * @since 2026-10-19
 */
using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using CvMaster.Services;

namespace CvMaster.Controls;

public partial class SourceBadge : UserControl
{
    public static readonly DependencyProperty ProcessNameProperty = DependencyProperty.Register(
        nameof(ProcessName),
        typeof(string),
        typeof(SourceBadge),
        new PropertyMetadata(string.Empty, OnSourceChanged));

    public static readonly DependencyProperty DisplayNameProperty = DependencyProperty.Register(
        nameof(DisplayName),
        typeof(string),
        typeof(SourceBadge),
        new PropertyMetadata(string.Empty, OnSourceChanged));

    public SourceBadge()
    {
        InitializeComponent();
        Loaded += (_, _) => Refresh();
    }

    public string ProcessName
    {
        get => (string)GetValue(ProcessNameProperty);
        set => SetValue(ProcessNameProperty, value);
    }

    public string DisplayName
    {
        get => (string)GetValue(DisplayNameProperty);
        set => SetValue(DisplayNameProperty, value);
    }

    private static void OnSourceChanged(DependencyObject dependencyObject, DependencyPropertyChangedEventArgs args) =>
        ((SourceBadge)dependencyObject).Refresh();

    private void Refresh()
    {
        var process = ProcessCatalog.Normalize(ProcessName);
        var display = string.IsNullOrWhiteSpace(DisplayName)
            ? ProcessCatalog.DisplayName(process)
            : DisplayName.Trim();
        var letter = string.IsNullOrWhiteSpace(display)
            ? "?"
            : StringInfo.GetNextTextElement(display);
        Letter.Text = letter.ToUpperInvariant();

        var icon = ProcessCatalog.Icon(process);
        Glyph.Source = icon;
        Glyph.Visibility = icon is null ? Visibility.Collapsed : Visibility.Visible;
        Letter.Visibility = icon is null ? Visibility.Visible : Visibility.Collapsed;
    }
}
