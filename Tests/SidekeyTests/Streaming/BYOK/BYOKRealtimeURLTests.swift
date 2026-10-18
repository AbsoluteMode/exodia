import XCTest
@testable import Sidekey

final class BYOKRealtimeURLTests: XCTestCase {
    func testNoBaseURLHasNoDefaultHost() {
        let url = BYOKRealtimeURL.openAIRealtime(baseURL: nil)
        XCTAssertNil(url)
    }

    func testEmptyBaseURLHasNoDefaultHost() {
        let url = BYOKRealtimeURL.openAIRealtime(baseURL: "")
        XCTAssertNil(url)
    }

    func testUnparseableBaseURLHasNoDefaultHost() {
        // The space in the host makes URLComponents reject the string.
        let url = BYOKRealtimeURL.openAIRealtime(baseURL: "http://my host:8000")
        XCTAssertNil(url)
    }

    func testSelfHostedHttpsBecomesWss() {
        let url = BYOKRealtimeURL.openAIRealtime(baseURL: "https://stt.example.com")
        XCTAssertEqual(url?.absoluteString, "wss://stt.example.com/v1/realtime?intent=transcription")
    }

    func testSelfHostedWithTrailingSlashAndPort() {
        let url = BYOKRealtimeURL.openAIRealtime(baseURL: "http://localhost:8000/")
        XCTAssertEqual(url?.absoluteString, "wss://localhost:8000/v1/realtime?intent=transcription")
    }
}
