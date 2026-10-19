/**
 * 单实例：命名互斥量 + 命名事件；第二个实例只负责唤起已有浮层。
 * @author helele
 * @since 2026-10-19
 */
using System.Threading;
using System.Windows.Threading;

namespace CvMaster.Services;

public sealed class SingleInstance : IDisposable
{
    private const string MutexName = @"Local\cvMaster.Instance";
    private const string ShowEventName = @"Local\cvMaster.Show";
    private Mutex? _mutex;
    private EventWaitHandle? _showEvent;
    private CancellationTokenSource? _cancellation;
    private Thread? _listener;
    private bool _disposed;

    /// <summary>已存在实例时发出唤起信号并返回 false。</summary>
    public bool TryAcquire()
    {
        _mutex = new Mutex(initiallyOwned: true, MutexName, out var createdNew);
        if (createdNew)
        {
            return true;
        }

        try
        {
            using var signal = EventWaitHandle.OpenExisting(ShowEventName);
            signal.Set();
        }
        catch (Exception exception) when (exception is WaitHandleCannotBeOpenedException or UnauthorizedAccessException)
        {
            // 首个实例可能仍在初始化；此时静默退出，避免创建第二个托盘图标。
        }

        _mutex.Dispose();
        _mutex = null;
        return false;
    }

    public void StartListener(Dispatcher dispatcher, Action show)
    {
        _showEvent = new EventWaitHandle(initialState: false, EventResetMode.AutoReset, ShowEventName);
        _cancellation = new CancellationTokenSource();
        var token = _cancellation.Token;
        _listener = new Thread(() =>
        {
            while (!token.IsCancellationRequested)
            {
                if (_showEvent.WaitOne(500))
                {
                    dispatcher.BeginInvoke(show);
                }
            }
        })
        {
            IsBackground = true,
            Name = "cvMaster single-instance"
        };
        _listener.Start();
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        _cancellation?.Cancel();
        _showEvent?.Set();
        if (_listener is { IsAlive: true } && Thread.CurrentThread != _listener)
        {
            _listener.Join(500);
        }

        _listener = null;
        _cancellation?.Dispose();
        _showEvent?.Dispose();
        try
        {
            _mutex?.ReleaseMutex();
        }
        catch (ApplicationException)
        {
            // 互斥量未由当前线程持有（例如初始化失败）。
        }

        _mutex?.Dispose();
    }
}
