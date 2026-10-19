/**
 * 核心存储与文本提取冒烟验证。
 * 只使用临时目录与合成内容，不启动 UI、不读取真实剪贴板。
 * @author helele
 * @since 2026-10-19
 */
using System.Text;
using CvMaster.Core;

var checks = 0;
var failures = new List<string>();
var root = Path.Combine(Path.GetTempPath(), "cvMaster-smoke-" + Guid.NewGuid().ToString("N"));
var fixture = Path.Combine(root, "fixture");
Directory.CreateDirectory(fixture);

void Check(string name, bool condition)
{
    checks++;
    if (condition)
    {
        Console.WriteLine($"  PASS  {name}");
    }
    else
    {
        failures.Add(name);
        Console.WriteLine($"  FAIL  {name}");
    }
}

static ClipCapture Capture(ClipKind kind, string text, params ClipRepresentation[] representations) =>
    new()
    {
        Kind = kind,
        Title = TextExtraction.FirstLine(text, 120, "未命名内容"),
        Excerpt = TextExtraction.Truncate(text, 240),
        SearchText = TextExtraction.Truncate(text, StorageLimits.SearchableCharacters),
        Source = "冒烟测试",
        SourceProcess = "smoke.exe",
        Representations = representations
    };

static byte[] Text(string value) => Encoding.UTF8.GetBytes(value);

var onePixelPng = Convert.FromBase64String(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=");

static byte[] HtmlPayload(string body, string sourceUrl)
{
    const string html = "<html><body><!--StartFragment-->Same Body<!--EndFragment--></body></html>";
    const string fragment = "Same Body";
    string Header(int start, int end, int fragmentStart, int fragmentEnd) =>
        $"Version:0.9\r\nStartHTML:{start:D10}\r\nEndHTML:{end:D10}\r\nStartFragment:{fragmentStart:D10}\r\nEndFragment:{fragmentEnd:D10}\r\nSourceURL:{sourceUrl}\r\n";
    var placeholder = Header(0, 0, 0, 0);
    var startOffset = Encoding.UTF8.GetByteCount(placeholder);
    var endOffset = startOffset + Encoding.UTF8.GetByteCount(html);
    var fragmentStart = startOffset + Encoding.UTF8.GetByteCount("<html><body><!--StartFragment-->");
    var fragmentEnd = fragmentStart + Encoding.UTF8.GetByteCount(fragment);
    return Text(Header(startOffset, endOffset, fragmentStart, fragmentEnd) + html.Replace(fragment, body, StringComparison.Ordinal));
}

static async Task<HistoryPage> PageAsync(HistoryStore store, string query = "", string scope = "all", ClipKind? kind = null)
{
    var result = await store.GetPageAsync(new ClipSearchQuery(query, scope, kind, ClipTimeRange.All, StorageLimits.PageSize));
    return result;
}

await using var store = new HistoryStore(root);
try
{
    Console.WriteLine("Core smoke tests");
    await store.InitializeAsync();
    Check("数据库初始化创建 sqlite 文件", File.Exists(store.DatabasePath));
    Check("初始化时清空无引用资产目录", Directory.Exists(store.AssetsDirectory));

    var textValue = "把灵感留住，把时间还给生活。\n\n不必记住每一次复制，只需要在想起时，随手找回。";
    await store.SaveAsync(Capture(ClipKind.Text, textValue, new ClipRepresentation(0, "text/plain", Text(textValue))), 30);
    var page = await PageAsync(store);
    Check("文本入库可查询", page.Total == 1 && page.Clips.Count == 1);
    Check("文本标题取首行", page.Clips[0].Title.StartsWith("把灵感留住", StringComparison.Ordinal));
    Check("中文子串检索", (await PageAsync(store, "灵感")).Total == 1);
    Check("无结果检索", (await PageAsync(store, "绝不存在的词")).Total == 0);
    Check("类型筛选", (await PageAsync(store, kind: ClipKind.Text)).Total == 1);

    await store.SaveAsync(Capture(ClipKind.Text, textValue, new ClipRepresentation(0, "text/plain", Text(textValue))), 30);
    page = await PageAsync(store);
    Check("重复内容去重并累计次数", page.Total == 1 && page.Clips[0].Copies == 2);

    var link = "https://developer.apple.com/design/human-interface-guidelines";
    await store.SaveAsync(Capture(ClipKind.Link, link, new ClipRepresentation(0, "text/plain", Text(link))), 30);
    Check("链接入库", (await PageAsync(store, "developer.apple.com")).Total == 1);

    await store.SaveAsync(Capture(ClipKind.Image, "图片", new ClipRepresentation(0, "image/png", onePixelPng)), 30);
    Check("图片入库", (await PageAsync(store, kind: ClipKind.Image)).Total == 1);
    Check("图片不参与非空关键词搜索", (await PageAsync(store, "图片")).Total == 0);

    var fileA = Path.Combine(fixture, "设计说明.txt");
    var fileB = Path.Combine(fixture, "接口草稿.txt");
    await File.WriteAllTextAsync(fileA, "a");
    await File.WriteAllTextAsync(fileB, "b");
    var fileList = HistoryStore.EncodeFileList([fileA, fileB]);
    await store.SaveAsync(Capture(ClipKind.File, "设计说明.txt 等 2 个文件", new ClipRepresentation(0, "windows/file-list", fileList)), 30);
    Check("文件引用入库", (await PageAsync(store, "设计说明")).Total == 1);
    Check("文件记录标记引用", (await PageAsync(store, "设计说明")).Clips[0].HasFileReference);

    var fileClip = (await PageAsync(store, "设计说明")).Clips[0];
    var preview = await store.GetPreviewAsync(fileClip.Id);
    Check("文件预览只展示文件名", preview.Text.Contains("设计说明.txt", StringComparison.Ordinal) && preview.Text.Contains("接口草稿.txt", StringComparison.Ordinal));
    Check("文件预览不暴露完整路径", !preview.Text.Contains(fixture, StringComparison.Ordinal));

    File.Delete(fileB);
    var missingFileFailed = false;
    try
    {
        await store.GetRepresentationsAsync(fileClip.Id);
    }
    catch (LibraryException exception) when (exception.Code == LibraryErrorCode.UnavailableFile)
    {
        missingFileFailed = true;
    }

    Check("失效文件引用拒绝再次复制", missingFileFailed);

    await store.SaveGroupAsync(null, "工作");
    await store.SaveGroupAsync(null, "Test");
    var groups = await store.GetGroupsAsync();
    Check("分组创建", groups.Count == 2);
    var duplicateFailed = false;
    try
    {
        await store.SaveGroupAsync(null, "test");
    }
    catch (LibraryException exception) when (exception.Code == LibraryErrorCode.NameConflict)
    {
        duplicateFailed = true;
    }

    Check("分组名称大小写不重复", duplicateFailed);

    var work = groups.First(group => group.Name == "工作");
    var first = (await PageAsync(store)).Clips.First(clip => clip.Kind == ClipKind.Text);
    await store.SetGroupAsync(first.Id, work.Id, true);
    var scoped = await store.GetPageAsync(new ClipSearchQuery("", work.Id.ToString("D"), null, ClipTimeRange.All, StorageLimits.PageSize));
    Check("分组筛选", scoped.Total == 1 && scoped.Clips[0].Groups.Contains(work.Id));

    await store.SetPinnedAsync(first.Id, true);
    var pinnedPage = await PageAsync(store);
    Check("置顶排序", pinnedPage.Clips[0].Id == first.Id && pinnedPage.Clips[0].Pinned);

    var plain = await store.GetPlainTextAsync(first.Id, ClipKind.Text);
    Check("纯文本恢复", Encoding.UTF8.GetString(plain[0].Data) == textValue);

    var textPreview = await store.GetPreviewAsync(first.Id);
    Check("文本预览按需加载", textPreview.Text.Contains("不必记住", StringComparison.Ordinal));

    var imageClip = (await PageAsync(store, kind: ClipKind.Image)).Clips[0];
    var thumbnailPath = await store.GetThumbnailSourceAsync(imageClip.Id);
    Check("图片缩略图返回本地路径", thumbnailPath is not null && File.Exists(thumbnailPath));

    var imagePreview = await store.GetPreviewAsync(imageClip.Id);
    Check("图片预览返回图片路径", imagePreview.ImagePath is not null && File.Exists(imagePreview.ImagePath));

    var assetsBefore = Directory.GetFiles(store.AssetsDirectory).Length;
    await store.DeleteAsync(imageClip.Id);
    Check("删除记录同时回收内容资产", Directory.GetFiles(store.AssetsDirectory).Length == assetsBefore - 1);
    Check("删除后列表减少", (await PageAsync(store, kind: ClipKind.Image)).Total == 0);

    await store.SaveAsync(Capture(ClipKind.Text, "100% 完成", new ClipRepresentation(0, "text/plain", Text("100% 完成"))), 30);
    await store.SaveAsync(Capture(ClipKind.Text, "100 次", new ClipRepresentation(0, "text/plain", Text("100 次"))), 30);
    Check("LIKE 通配符转义", (await PageAsync(store, "100%")).Total == 1);

    var removed = await store.ClearAsync(null);
    Check("清空全部历史", removed > 0 && (await PageAsync(store)).Total == 0);
    Check("清空后保留分组结构", (await store.GetGroupsAsync()).Count == 2);
    Check("清空后资产目录无孤立文件", Directory.GetFiles(store.AssetsDirectory).Length == 0);

    Console.WriteLine("Text extraction tests");
    var html = "<html><body><p>Hello&nbsp;<b>世界</b></p><script>alert('bad')</script></body></html>";
    var htmlText = TextExtraction.FromHtml(Text(html));
    Check("HTML 提取可见文本", htmlText is not null && htmlText.Contains("Hello", StringComparison.Ordinal) && htmlText.Contains("世界", StringComparison.Ordinal));
    Check("HTML 不执行脚本内容", htmlText is not null && !htmlText.Contains("bad", StringComparison.Ordinal));
    Check("HTML 实体解码", htmlText is not null && htmlText.Contains("Hello 世界", StringComparison.Ordinal));

    var rtf = @"{\rtf1\ansi\deff0{\fonttbl{\f0 Arial;}}\f0 Hello \b \u19990?\u30028?\b0\par Next line}";
    var rtfText = TextExtraction.FromRtf(Text(rtf));
    Check("RTF 提取可见文本", rtfText is not null && rtfText.Contains("Hello", StringComparison.Ordinal) && rtfText.Contains("世界", StringComparison.Ordinal));
    Check("RTF 跳过字体表", rtfText is not null && !rtfText.Contains("Arial", StringComparison.Ordinal));

    var repA = new ClipRepresentation(0, "text/plain", Text("hello"));
    var repB = new ClipRepresentation(0, "text/html", Text(html));
    var fp1 = Fingerprint.Compute([repA, repB]);
    var fp2 = Fingerprint.Compute([repB, repA]);
    Check("指纹与表示顺序无关", fp1 == fp2);
    var htmlWithSource1 = HtmlPayload("Same Body", "https://example.com/one");
    var htmlWithSource2 = HtmlPayload("Same Body", "https://example.com/two");
    Check("HTML 头部提取稳定", TextExtraction.GetHtmlBody(htmlWithSource1).AsSpan().SequenceEqual(TextExtraction.GetHtmlBody(htmlWithSource2)));
}
catch (Exception exception)
{
    failures.Add("未处理异常: " + exception);
    Console.WriteLine(exception);
}
finally
{
    try
    {
        Directory.Delete(root, recursive: true);
    }
    catch (IOException)
    {
        // 临时目录清理失败不影响验证结论。
    }
}

Console.WriteLine();
if (failures.Count == 0)
{
    Console.WriteLine($"ALL PASS ({checks} checks)");
    return 0;
}

Console.WriteLine($"FAILED ({failures.Count}/{checks})");
foreach (var failure in failures)
{
    Console.WriteLine("  - " + failure);
}

return 1;
