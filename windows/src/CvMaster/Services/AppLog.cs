/**
 * 最小化本地日志：只记录时间、级别和错误码，不记录剪贴板正文、路径或进程信息。
 * @author helele
 * @since 2026-10-19
 */
using System.Globalization;
using System.IO;
using System.Text;

namespace CvMaster.Services;

public static class AppLog
{
    private static readonly object Gate = new();
    private static readonly string LogDirectory = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "cvMaster",
        "logs");
    private static readonly string LogPath = Path.Combine(LogDirectory, "cvmaster.log");

    public static void Info(string code) => Write("INFO", code);

    public static void Error(string code, Exception? exception = null)
    {
        var detail = exception is null ? code : $"{code} ({exception.GetType().Name})";
        Write("ERROR", detail);
    }

    private static void Write(string level, string message)
    {
        try
        {
            lock (Gate)
            {
                Directory.CreateDirectory(LogDirectory);
                var info = new FileInfo(LogPath);
                if (info.Exists && info.Length > 256 * 1024)
                {
                    var backup = LogPath + ".1";
                    File.Delete(backup);
                    File.Move(LogPath, backup);
                }

                var line = new StringBuilder()
                    .Append(DateTimeOffset.Now.ToString("yyyy-MM-dd HH:mm:ss.fff zzz", CultureInfo.InvariantCulture))
                    .Append(" [")
                    .Append(level)
                    .Append("] ")
                    .Append(message)
                    .AppendLine()
                    .ToString();
                File.AppendAllText(LogPath, line, Encoding.UTF8);
            }
        }
        catch (Exception)
        {
            // 日志失败不能影响剪贴板主流程。
        }
    }
}
