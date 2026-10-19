/**
 * 轻量文本输入对话框：分组命名与手动排除进程共用；校验失败时保留输入。
 * @author helele
 * @since 2026-10-19
 */
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using CvMaster.Services;

namespace CvMaster.Views;

public partial class TextPromptWindow : Window
{
    private readonly Func<string, string?> _validator;

    public TextPromptWindow(
        string title,
        string description,
        string initialValue,
        int maxLength,
        Func<string, string?> validator)
    {
        InitializeComponent();
        _validator = validator;
        Title = title;
        TitleText.Text = title;
        DescriptionText.Text = description;
        Input.Text = initialValue;
        Input.MaxLength = maxLength;
    }

    public string? Value { get; private set; }

    private void Window_SourceInitialized(object? sender, EventArgs e) =>
        WindowAppearance.Apply(this, App.Services.Theme.IsDark);

    private void Window_Loaded(object sender, RoutedEventArgs e)
    {
        Input.Focus();
        Input.SelectAll();
    }

    private void Header_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ButtonState == MouseButtonState.Pressed &&
            FindAncestor<Button>(e.OriginalSource as DependencyObject) is null)
        {
            DragMove();
        }
    }

    private void Input_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter)
        {
            Save();
            e.Handled = true;
        }
        else if (e.Key == Key.Escape)
        {
            DialogResult = false;
            e.Handled = true;
        }
    }

    private void SaveButton_Click(object sender, RoutedEventArgs e) => Save();

    private void CancelButton_Click(object sender, RoutedEventArgs e) => DialogResult = false;

    private void Save()
    {
        var value = Input.Text.Trim();
        var error = _validator(value);
        if (error is not null)
        {
            ErrorText.Text = error;
            ErrorText.Visibility = Visibility.Visible;
            Input.Focus();
            return;
        }

        Value = value;
        DialogResult = true;
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
