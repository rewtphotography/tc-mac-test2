import XCTest
@testable import TraincullCore

/// Ported from the Android app's XmpTest, with the same expected values.
final class XmpTests: XCTestCase {
    private let lightroom = """
    <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Adobe XMP Core 7.0">
     <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
      <rdf:Description rdf:about=""
        xmlns:xmp="http://ns.adobe.com/xap/1.0/"
        xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
       xmp:Rating="2"
       xmp:Label="Red"
       crs:Exposure2012="+0.35">
       <dc:subject><rdf:Bag><rdf:li>wedding</rdf:li></rdf:Bag></dc:subject>
      </rdf:Description>
     </rdf:RDF>
    </x:xmpmeta>

    """

    func testNewSidecarRoundTrips() {
        for r in -1 ... 5 {
            let s = Xmp.newSidecar(r)
            XCTAssertEqual(Xmp.readRating(s), r)
            XCTAssertTrue(Xmp.isComplete(s))
        }
    }

    func testChangesOnlyTheRatingAttribute() {
        let out = Xmp.withRating(lightroom, -1)!
        XCTAssertEqual(Xmp.readRating(out), -1)
        XCTAssertEqual(out, lightroom.replacingOccurrences(of: "xmp:Rating=\"2\"", with: "xmp:Rating=\"-1\""))
    }

    func testChangesElementForm() {
        let s = "<x:xmpmeta><rdf:RDF><rdf:Description><xmp:Rating>4</xmp:Rating><a>b</a></rdf:Description></rdf:RDF></x:xmpmeta>"
        XCTAssertEqual(Xmp.withRating(s, 1)!, s.replacingOccurrences(of: ">4<", with: ">1<"))
    }

    func testAddsRatingWhenMissingAndDeclaresNamespace() {
        let s = #"<x:xmpmeta><rdf:RDF><rdf:Description rdf:about="" xmlns:dc="x" dc:a="1>2"><b/></rdf:Description></rdf:RDF></x:xmpmeta>"#
        let out = Xmp.withRating(s, 3)!
        XCTAssertEqual(Xmp.readRating(out), 3)
        XCTAssertTrue(out.contains("xmlns:xmp=\"http://ns.adobe.com/xap/1.0/\""))
        XCTAssertTrue(out.contains("dc:a=\"1>2\""))
        XCTAssertTrue(out.hasSuffix("><b/></rdf:Description></rdf:RDF></x:xmpmeta>"))
    }

    func testAddsRatingToSelfClosingDescriptionWithNamespace() {
        let s = #"<x:xmpmeta><rdf:RDF><rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmp:Label="Red"/></rdf:RDF></x:xmpmeta>"#
        let out = Xmp.withRating(s, 5)!
        XCTAssertEqual(Xmp.readRating(out), 5)
        XCTAssertEqual(out.components(separatedBy: "xmlns:xmp=").count - 1, 1)
        XCTAssertTrue(out.contains("xmp:Rating=\"5\"/>"))
    }

    func testRefusesFileWithoutDescription() {
        XCTAssertNil(Xmp.withRating("<x:xmpmeta></x:xmpmeta>", 3))
    }

    func testReadsSingleQuotesAndDecimals() {
        XCTAssertEqual(Xmp.readRating("<rdf:Description xmp:Rating='3.0'/>"), 3)
        XCTAssertNil(Xmp.readRating("<rdf:Description/>"))
    }

    func testReadsLightroomLabel() {
        XCTAssertEqual(Xmp.readLabel(lightroom), "Red")
        XCTAssertNil(Xmp.readLabel(Xmp.newSidecar(3)))
        XCTAssertEqual(Xmp.readLabel("<rdf:Description><xmp:Label>To Do</xmp:Label></rdf:Description>"), "To Do")
    }

    func testChangesOnlyTheLabel() {
        let out = Xmp.withLabel(lightroom, "Approved")!
        XCTAssertEqual(out, lightroom.replacingOccurrences(of: "xmp:Label=\"Red\"", with: "xmp:Label=\"Approved\""))
        XCTAssertEqual(Xmp.readRating(out), 2)
    }

    func testRemovesTheLabelLeavingTheRest() {
        let out = Xmp.withLabel(lightroom, nil)!
        XCTAssertNil(Xmp.readLabel(out))
        XCTAssertEqual(out, lightroom.replacingOccurrences(of: "\n   xmp:Label=\"Red\"", with: ""))
        let elem = "<rdf:Description>\n <xmp:Label>Review</xmp:Label>\n <a>b</a></rdf:Description>"
        XCTAssertEqual(Xmp.withLabel(elem, nil), "<rdf:Description>\n <a>b</a></rdf:Description>")
        // Nothing to remove: unchanged.
        let plain = Xmp.newSidecar(4)
        XCTAssertEqual(Xmp.withLabel(plain, nil), plain)
    }

    func testAddsLabelToSidecarWithoutOne() {
        let out = Xmp.withLabel(Xmp.newSidecar(4), "Second")!
        XCTAssertEqual(Xmp.readLabel(out), "Second")
        XCTAssertEqual(Xmp.readRating(out), 4)
        XCTAssertTrue(Xmp.isComplete(out))
    }

    func testNewSidecarWithLabelAndEscaping() {
        let s = Xmp.newSidecar(0, "Ben & Jo's <pick>")
        XCTAssertEqual(Xmp.readLabel(s), "Ben & Jo's <pick>")
        XCTAssertEqual(Xmp.readRating(s), 0)
        XCTAssertEqual(Xmp.readLabel(Xmp.withLabel(Xmp.newSidecar(1), "Ben & Jo's <pick>")!), "Ben & Jo's <pick>")
    }

    /// The Mac spec's rule: a sidecar that also holds Camera Raw edits keeps every other byte.
    func testCameraRawEditsSurviveRatingAndLabelChanges() throws {
        let d = MemDir(atomic: true)
        d.files["A.xmp"] = lightroom
        let name = try Ratings.write(d, baseName: "A", sidecarName: "A.xmp", SidecarValues(rating: 5, label: "Select"))
        XCTAssertEqual(name, "A.xmp")
        let expected = lightroom.replacingOccurrences(of: "xmp:Rating=\"2\"", with: "xmp:Rating=\"5\"")
            .replacingOccurrences(of: "xmp:Label=\"Red\"", with: "xmp:Label=\"Select\"")
        XCTAssertEqual(d.files["A.xmp"], expected)
    }

    func testNothingIsWrittenForAnUnratedFrameWithNoSidecar() throws {
        let d = MemDir(atomic: true)
        XCTAssertNil(try Ratings.write(d, baseName: "A", sidecarName: nil, SidecarValues(rating: 0, label: nil)))
        XCTAssertTrue(d.files.isEmpty)
        XCTAssertEqual(try Ratings.write(d, baseName: "A", sidecarName: nil, SidecarValues(rating: 3, label: nil)), "A.xmp")
        // Clearing a rating on an existing sidecar writes 0 and keeps the file.
        _ = try Ratings.write(d, baseName: "A", sidecarName: "A.xmp", SidecarValues(rating: 0, label: nil))
        XCTAssertEqual(Xmp.readRating(d.files["A.xmp"]!), 0)
    }

    // MARK: Adjustment fields

    func testChangesOnlyOneCameraRawField() {
        XCTAssertEqual(Xmp.readField(lightroom, "crs:Exposure2012"), "+0.35")
        let out = Xmp.withField(lightroom, .cameraRaw, "Exposure2012", "-1.00")!
        XCTAssertEqual(out, lightroom.replacingOccurrences(of: "crs:Exposure2012=\"+0.35\"", with: "crs:Exposure2012=\"-1.00\""))
    }

    func testAddsAndRemovesFieldsDeclaringEachNamespaceOnce() {
        let start = Xmp.newSidecar(3)
        var s = Xmp.withField(start, .cameraRaw, "Exposure2012", "+0.33")!
        s = Xmp.withField(s, .cameraRaw, "Temperature", "5200")!
        s = Xmp.withField(s, .trainCull, "Boost", "0.500")!
        s = Xmp.withField(s, .trainCull, "Contrast", "0.250")!
        XCTAssertEqual(Xmp.readField(s, "crs:Temperature"), "5200")
        XCTAssertEqual(Xmp.readField(s, "traincull:Boost"), "0.500")
        XCTAssertEqual(s.components(separatedBy: "xmlns:crs=").count - 1, 1)
        XCTAssertEqual(s.components(separatedBy: "xmlns:traincull=").count - 1, 1)
        XCTAssertEqual(Xmp.readRating(s), 3)
        XCTAssertTrue(Xmp.isComplete(s))
        // Removing a field that is not there changes nothing.
        XCTAssertEqual(Xmp.withField(s, .trainCull, "Sharpness", nil), s)
        s = Xmp.withField(s, .trainCull, "Boost", nil)!
        XCTAssertNil(Xmp.readField(s, "traincull:Boost"))
        XCTAssertEqual(Xmp.readField(s, "traincull:Contrast"), "0.250")
    }

    func testEditsLeaveCameraRawAndKeywordsAlone() throws {
        let d = MemDir(atomic: true)
        d.files["A.xmp"] = lightroom
        _ = try Edits.write(d, baseName: "A", sidecarName: "A.xmp", values: SidecarValues(rating: 2, label: "Red"), fields: [
            SidecarField(.cameraRaw, "Exposure2012", "+1.00"),
            SidecarField(.trainCull, "Boost", "0.800"),
            SidecarField(.trainCull, "Sharpness", nil),
        ])
        let out = d.files["A.xmp"]!
        XCTAssertTrue(out.contains("<dc:subject><rdf:Bag><rdf:li>wedding</rdf:li></rdf:Bag></dc:subject>"))
        XCTAssertEqual(Xmp.readRating(out), 2)
        XCTAssertEqual(Xmp.readLabel(out), "Red")
        XCTAssertEqual(Xmp.readField(out, "crs:Exposure2012"), "+1.00")
        XCTAssertEqual(Xmp.readField(out, "traincull:Boost"), "0.800")
        // Taking the TrainCull field out again leaves only its namespace declaration behind.
        let back = Xmp.withField(Xmp.withField(out, .trainCull, "Boost", nil)!, .cameraRaw, "Exposure2012", "+0.35")!
        XCTAssertEqual(back.replacingOccurrences(of: "\n    xmlns:traincull=\"http://ns.traincull.app/1.0/\"", with: ""), lightroom)
    }

    func testNoSidecarIsCreatedForUntouchedEdits() throws {
        let d = MemDir(atomic: true)
        XCTAssertNil(try Edits.write(d, baseName: "A", sidecarName: nil, values: SidecarValues(rating: 0, label: nil),
                                     fields: [SidecarField(.cameraRaw, "Exposure2012", nil)]))
        XCTAssertTrue(d.files.isEmpty)
    }
}
