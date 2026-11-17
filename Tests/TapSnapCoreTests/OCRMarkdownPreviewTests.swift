import XCTest
@testable import TapSnapApp

final class OCRMarkdownPreviewTests: XCTestCase {
    func testRendersNestedBlocksAndInlineStyles() {
        let html = OCRMarkdownHTML.body("""
        # 更新 *说明*

        7. **第一项**
           - `code`
        8. ~~第二项~~

        > 引用  
        > 换行

        ```swift
        print("<tag>")
        ```

        ---
        """)

        XCTAssertTrue(html.contains("<h1>更新 <em>说明</em></h1>"))
        XCTAssertTrue(html.contains("<ol start=\"7\"><li><p><strong>第一项</strong></p><ul><li><p><code>code</code></p></li></ul></li>"))
        XCTAssertTrue(html.contains("<li><p><del>第二项</del></p></li></ol>"))
        XCTAssertTrue(html.contains("<blockquote><p>引用<br>换行</p></blockquote>"))
        XCTAssertTrue(html.contains("<pre><code>print(&quot;&lt;tag&gt;&quot;)\n</code></pre>"))
        XCTAssertTrue(html.hasSuffix("<hr>"))
    }

    func testKeepsEmptyTableColumnsAndTaskState() {
        let html = OCRMarkdownHTML.body("""
        | 标题 | B | C |
        | :--- | :-: | ---: |
        | a | | c |
        | d |

        - [x] 完成
        - [ ] 待处理
        """)

        XCTAssertTrue(html.contains("<th style=\"text-align:center\">B</th>"))
        XCTAssertTrue(html.contains("<td style=\"text-align:left\">a</td><td></td><td style=\"text-align:right\">c</td>"))
        XCTAssertTrue(html.contains("<td style=\"text-align:left\">d</td><td></td><td></td>"))
        XCTAssertTrue(html.contains("<input class=\"task\" type=\"checkbox\" disabled checked>完成"))
        XCTAssertTrue(html.contains("<input class=\"task\" type=\"checkbox\" disabled>待处理"))
    }

    func testPreviewDoesNotEmbedSourceHTMLOrLoadImagesAndLinks() {
        let source = """
        <script>alert('example')</script>

        [文档](https://example.org) ![远程图片](https://example.org/image.png)
        """
        let html = OCRMarkdownHTML.document(source, isDark: true)

        XCTAssertTrue(html.contains("class=\"dark\""))
        XCTAssertTrue(html.contains("default-src 'none'"))
        XCTAssertTrue(html.contains("&lt;script&gt;"))
        XCTAssertTrue(html.contains("远程图片"))
        XCTAssertTrue(html.contains("文档"))
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertFalse(html.contains("<img"))
        XCTAssertFalse(html.contains("href="))
    }
}
