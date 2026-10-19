/**
 * 筛选胶囊 / 类型按钮的选中状态附加属性，避免把 Tag 兼作数据字段。
 * @author helele
 * @since 2026-10-19
 */
using System.Windows;

namespace CvMaster.Controls;

public static class Chip
{
    public static readonly DependencyProperty IsActiveProperty = DependencyProperty.RegisterAttached(
        "IsActive",
        typeof(bool),
        typeof(Chip),
        new FrameworkPropertyMetadata(false));

    public static bool GetIsActive(DependencyObject element) => (bool)element.GetValue(IsActiveProperty);

    public static void SetIsActive(DependencyObject element, bool value) => element.SetValue(IsActiveProperty, value);
}
