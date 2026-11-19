using System;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;
using Markdig;
using Markdig.Extensions.EmphasisExtras;
using Markdig.Extensions.Tables;
using Markdig.Extensions.TaskLists;
using Markdig.Syntax;
using Markdig.Syntax.Inlines;
using MediaBlock = System.Windows.Documents.Block;
using MediaInline = System.Windows.Documents.Inline;
using MediaTable = System.Windows.Documents.Table;
using MarkdownTable = Markdig.Extensions.Tables.Table;

namespace TapSnap.Windows;

internal static class OcrMarkdownPreview
{
    private static readonly MarkdownPipeline Pipeline = new MarkdownPipelineBuilder()
        .DisableHtml().UsePipeTables(new PipeTableOptions { UseGfmRules = true }).UseTaskLists()
        .UseEmphasisExtras(EmphasisExtraOptions.Strikethrough).Build();

    internal static MarkdownDocument Parse(string source) => Markdown.Parse(source, Pipeline);

    internal static FlowDocument Render(MarkdownDocument source)
    {
        var palette = SnapPalette.For(SnapTheme.IsDark);
        var document = new FlowDocument
        {
            FontSize = 14, PagePadding = new Thickness(15, 9, 15, 15),
            Foreground = palette.Foreground, Background = palette.Panel,
            LineHeight = 23, ColumnWidth = double.PositiveInfinity
        };
        Populate(document.Blocks, source, palette);
        return document;
    }

    private static void Populate(BlockCollection target, ContainerBlock source, SnapPalette palette)
    {
        foreach (var block in source) target.Add(RenderBlock(block, palette));
    }

    private static MediaBlock RenderBlock(Markdig.Syntax.Block block, SnapPalette palette)
    {
        switch (block)
        {
            case HeadingBlock heading:
                var title = Text(heading, palette);
                title.FontSize = heading.Level switch { 1 => 24, 2 => 20, _ => 17 };
                title.FontWeight = FontWeights.SemiBold;
                title.LineHeight = 30;
                return title;
            case CodeBlock code:
                return new Paragraph(new Run(code.Lines.ToString()))
                {
                    FontFamily = new FontFamily("Consolas"), FontSize = 12, Background = palette.Hover,
                    LineHeight = 18, Padding = new Thickness(9, 6, 9, 6), Margin = new Thickness(0, 6, 0, 6)
                };
            case QuoteBlock quote:
                var quotation = new Section
                {
                    BorderBrush = palette.Border, BorderThickness = new Thickness(3, 0, 0, 0),
                    Foreground = palette.Muted, Padding = new Thickness(9, 0, 0, 0)
                };
                Populate(quotation.Blocks, quote, palette);
                return quotation;
            case ListBlock list:
                var items = new List
                {
                    MarkerStyle = list.IsOrdered ? TextMarkerStyle.Decimal : TextMarkerStyle.Disc,
                    StartIndex = int.TryParse(list.OrderedStart, out int start) ? Math.Max(1, start) : 1,
                    Padding = new Thickness(22, 0, 0, 0), Margin = new Thickness(0, 4, 0, 4)
                };
                foreach (var item in list.OfType<ListItemBlock>())
                {
                    var entry = new ListItem();
                    Populate(entry.Blocks, item, palette);
                    items.ListItems.Add(entry);
                }
                return items;
            case MarkdownTable table:
                return RenderTable(table, palette);
            case ThematicBreakBlock:
                return new BlockUIContainer(new Border { Height = 1, Background = palette.Border, Margin = new Thickness(0, 8, 0, 8) });
            case LeafBlock leaf:
                return Text(leaf, palette);
            default:
                var section = new Section();
                if (block is ContainerBlock container) Populate(section.Blocks, container, palette);
                return section;
        }
    }

    private static MediaTable RenderTable(MarkdownTable table, SnapPalette palette)
    {
        var result = new MediaTable
        {
            CellSpacing = 0, BorderBrush = palette.Border, BorderThickness = new Thickness(1, 1, 0, 0),
            Margin = new Thickness(0, 8, 0, 8)
        };
        var group = new System.Windows.Documents.TableRowGroup();
        result.RowGroups.Add(group);
        foreach (var column in table.ColumnDefinitions)
            result.Columns.Add(new System.Windows.Documents.TableColumn { Width = new GridLength(1, GridUnitType.Star) });
        foreach (var sourceRow in table.OfType<Markdig.Extensions.Tables.TableRow>())
        {
            var row = new System.Windows.Documents.TableRow();
            group.Rows.Add(row);
            foreach (var sourceCell in sourceRow.OfType<Markdig.Extensions.Tables.TableCell>())
            {
                var cell = new System.Windows.Documents.TableCell
                {
                    Padding = new Thickness(6, 3, 6, 3), BorderThickness = new Thickness(0, 0, 1, 1),
                    BorderBrush = palette.Border
                };
                if (sourceRow.IsHeader)
                {
                    cell.FontWeight = FontWeights.SemiBold;
                    cell.Background = palette.Hover;
                }
                if (row.Cells.Count < table.ColumnDefinitions.Count)
                    cell.TextAlignment = table.ColumnDefinitions[row.Cells.Count].Alignment switch
                    {
                        TableColumnAlign.Center => TextAlignment.Center,
                        TableColumnAlign.Right => TextAlignment.Right,
                        _ => TextAlignment.Left
                    };
                Populate(cell.Blocks, sourceCell, palette);
                row.Cells.Add(cell);
            }
        }
        return result;
    }

    private static Paragraph Text(LeafBlock source, SnapPalette palette)
    {
        var paragraph = new Paragraph { Margin = new Thickness(0, 4, 0, 4) };
        if (source.Inline is { } content) AddInlines(paragraph.Inlines, content, palette);
        else paragraph.Inlines.Add(source.Lines.ToString());
        return paragraph;
    }

    private static void AddInlines(InlineCollection target, ContainerInline source, SnapPalette palette)
    {
        for (var node = source.FirstChild; node is not null; node = node.NextSibling)
        {
            MediaInline inline = node switch
            {
                LiteralInline literal => new Run(literal.Content.ToString()),
                HtmlEntityInline entity => new Run(entity.Transcoded.ToString()),
                LineBreakInline { IsHard: true } => new LineBreak(),
                LineBreakInline => new Run(" "),
                CodeInline code => new Run(code.Content)
                    { FontFamily = new FontFamily("Consolas"), Background = palette.Hover, FontSize = 12 },
                AutolinkInline link => new Run(link.Url) { TextDecorations = TextDecorations.Underline },
                TaskList task => new Run(task.Checked ? "☑ " : "☐ "),
                EmphasisInline { DelimiterChar: '~' } => new Span { TextDecorations = TextDecorations.Strikethrough },
                EmphasisInline { DelimiterCount: 2 } => new Bold(),
                EmphasisInline => new Italic(),
                LinkInline { IsImage: false } => new Span { TextDecorations = TextDecorations.Underline },
                _ => new Span()
            };
            // Links and images are displayed as text. The reader never loads a URL.
            if (inline is Span span && node is ContainerInline children) AddInlines(span.Inlines, children, palette);
            target.Add(inline);
        }
    }
}
