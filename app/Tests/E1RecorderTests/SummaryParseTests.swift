import XCTest
@testable import E1Recorder

/// 大模型整理结果的宽松解析：待办写成对象、时间写成「分:秒」都不能整组丢掉。
final class SummaryParseTests: XCTestCase {
    func testTodosAsStrings() {
        XCTAssertEqual(SummaryParse.todos(["张三：周五前交方案", "  ", "整理会议记录"]), ["张三：周五前交方案", "整理会议记录"])
    }

    func testTodosAsObjects() {
        let v: [Any] = [
            ["text": "交测试报告", "owner": "王芳", "due": "周五"],
            ["task": "约两位老用户试用"],
            ["负责人": "李明", "事项": "给出目录结构草案"],
            ["owner": "没有正文的会被跳过"],
        ]
        XCTAssertEqual(SummaryParse.todos(v), ["王芳：交测试报告（周五）", "约两位老用户试用", "李明：给出目录结构草案"])
    }

    func testTodosMixedAndGarbage() {
        XCTAssertEqual(SummaryParse.todos(["一条", ["text": "两条"], 3]), ["一条", "两条"])
        XCTAssertEqual(SummaryParse.todos("不是数组"), [])
        XCTAssertEqual(SummaryParse.todos(nil), [])
    }

    func testSeconds() {
        XCTAssertEqual(SummaryParse.seconds(95), 95)
        XCTAssertEqual(SummaryParse.seconds(95.7), 95)
        XCTAssertEqual(SummaryParse.seconds("95"), 95)
        XCTAssertEqual(SummaryParse.seconds("12:30"), 750)
        XCTAssertEqual(SummaryParse.seconds("1:02:03"), 3723)
        XCTAssertEqual(SummaryParse.seconds("第三章"), 0)
        XCTAssertEqual(SummaryParse.seconds(-5), 0)
        XCTAssertEqual(SummaryParse.seconds(nil), 0)
    }

    func testKeywordStrings() {
        XCTAssertEqual(SummaryParse.strings(["录音卡", " ", 7, "预算"]), ["录音卡", "预算"])
    }
}
