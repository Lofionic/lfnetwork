import XCTest
@testable import LFNetwork

final class BackgroundHTTPServiceTests: XCTestCase {
    private let url = URL(string: "https://api.example.com/items")!

    private func response(statusCode: Int) -> HTTPURLResponse? {
        HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)
    }

    func testASuccessfulResponseDeliversItsData() throws {
        let data = Data("ok".utf8)

        let result = BackgroundHTTPService.result(data: data, response: response(statusCode: 201), error: nil)

        XCTAssertEqual(try result.get(), data)
    }

    func testATransportErrorIsDelivered() {
        let result = BackgroundHTTPService.result(data: Data(), response: nil, error: URLError(.notConnectedToInternet))

        XCTAssertThrowsError(try result.get()) { error in
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }
    }

    func testUnauthorizedAndOtherStatusesFail() {
        let unauthorized = BackgroundHTTPService.result(data: Data(), response: response(statusCode: 401), error: nil)
        let serverError = BackgroundHTTPService.result(data: Data(), response: response(statusCode: 503), error: nil)

        XCTAssertThrowsError(try unauthorized.get()) { error in
            guard case HTTPServiceError.notAuthorized = error else { return XCTFail("Unexpected \(error)") }
        }
        XCTAssertThrowsError(try serverError.get()) { error in
            guard case HTTPServiceError.invalidStatusCode(503) = error else { return XCTFail("Unexpected \(error)") }
        }
    }

    func testAMissingResponseIsInvalid() {
        let result = BackgroundHTTPService.result(data: Data(), response: nil, error: nil)

        XCTAssertThrowsError(try result.get()) { error in
            guard case HTTPServiceError.invalidResponse = error else { return XCTFail("Unexpected \(error)") }
        }
    }
}
