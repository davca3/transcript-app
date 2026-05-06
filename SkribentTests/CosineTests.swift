import XCTest
@testable import Skribent

final class CosineTests: XCTestCase {
    func test_identicalVectors_returnsOne() {
        let v: [Float] = [1, 2, 3, 4]
        XCTAssertEqual(Cosine.similarity(v, v), 1.0, accuracy: 0.0001)
    }

    func test_orthogonalVectors_returnsZero() {
        let a: [Float] = [1, 0, 0]
        let b: [Float] = [0, 1, 0]
        XCTAssertEqual(Cosine.similarity(a, b), 0.0, accuracy: 0.0001)
    }

    func test_oppositeVectors_returnsMinusOne() {
        let a: [Float] = [1, 2, 3]
        let b: [Float] = [-1, -2, -3]
        XCTAssertEqual(Cosine.similarity(a, b), -1.0, accuracy: 0.0001)
    }

    func test_emptyVectors_returnZero() {
        XCTAssertEqual(Cosine.similarity([], []), 0.0)
    }

    func test_dimensionMismatch_returnsZero() {
        XCTAssertEqual(Cosine.similarity([1, 2, 3], [1, 2]), 0.0)
    }

    func test_zeroVector_returnsZero() {
        let a: [Float] = [0, 0, 0]
        let b: [Float] = [1, 2, 3]
        XCTAssertEqual(Cosine.similarity(a, b), 0.0, accuracy: 0.0001)
    }

    func test_isSymmetric() {
        let a: [Float] = [0.5, 0.3, 0.1]
        let b: [Float] = [0.2, 0.7, 0.4]
        let ab = Cosine.similarity(a, b)
        let ba = Cosine.similarity(b, a)
        XCTAssertEqual(ab, ba, accuracy: 0.00001)
    }

    func test_normalizedSimilarity_isInRange() {
        let a: [Float] = [0.3, 0.4, 0.5, 0.1]
        let b: [Float] = [0.2, 0.6, 0.3, 0.4]
        let s = Cosine.similarity(a, b)
        XCTAssertGreaterThanOrEqual(s, -1.0)
        XCTAssertLessThanOrEqual(s, 1.0)
    }
}
