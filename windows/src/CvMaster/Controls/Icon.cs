/**
 * 轻量矢量图标控件：几何数据来自受控的 Icons.xaml 资源，不使用字体图标。
 * @author helele
 * @since 2026-10-19
 */
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace CvMaster.Controls;

public sealed class Icon : Control
{
    public static readonly DependencyProperty DataProperty = DependencyProperty.Register(
        nameof(Data),
        typeof(Geometry),
        typeof(Icon),
        new FrameworkPropertyMetadata(null));

    static Icon()
    {
        DefaultStyleKeyProperty.OverrideMetadata(typeof(Icon), new FrameworkPropertyMetadata(typeof(Icon)));
    }

    public Geometry? Data
    {
        get => (Geometry?)GetValue(DataProperty);
        set => SetValue(DataProperty, value);
    }
}
