/**
 * 面向用户的可控错误；日志只记录错误码，不记录正文或路径。
 * @author helele
 * @since 2026-10-19
 */
namespace CvMaster.Core;

public enum LibraryErrorCode
{
    Storage,
    Capacity,
    Unsupported,
    MissingContent,
    UnavailableFile,
    NameConflict,
    PlainTextUnavailable,
    RichTextTooLarge,
    PasteTargetUnavailable,
    PasteTargetNotReady,
    MissingGroup
}

public sealed class LibraryException : Exception
{
    public LibraryException(LibraryErrorCode code)
        : base(UserMessage(code))
    {
        Code = code;
    }

    public LibraryException(LibraryErrorCode code, Exception? innerException)
        : base(UserMessage(code), innerException)
    {
        Code = code;
    }

    public LibraryErrorCode Code { get; }

    public static string UserMessage(LibraryErrorCode code) => code switch
    {
        LibraryErrorCode.Storage => "本地存储不可用，请检查磁盘空间或重新打开应用。",
        LibraryErrorCode.Capacity => "存储已达上限，请清理记录；置顶和已分组内容不会被自动删除。",
        LibraryErrorCode.Unsupported => "内容格式暂不支持，或超过单条保存限额。",
        LibraryErrorCode.MissingContent => "内容文件不可用，无法再次复制。",
        LibraryErrorCode.UnavailableFile => "原文件已移动、删除或无权访问，无法复制文件引用。",
        LibraryErrorCode.NameConflict => "分组名称为空、过长或已存在。",
        LibraryErrorCode.MissingGroup => "分组已不存在，请重新选择。",
        LibraryErrorCode.PlainTextUnavailable => "此记录没有可用的纯文本或富文本表示，无法移除格式；原始剪贴板未改变。",
        LibraryErrorCode.RichTextTooLarge => "RTF 超过 256 KB 纯文本转换预算，未改变剪贴板；仍可使用普通粘贴保留原格式。",
        LibraryErrorCode.PasteTargetNotReady => "未能激活目标应用；剪贴板未改变，请重新打开列表后重试。",
        LibraryErrorCode.PasteTargetUnavailable => "未能向目标应用发送粘贴；内容已写入剪贴板，请手动按 Ctrl+V。",
        _ => "本地操作失败，请稍后重试。"
    };
}
