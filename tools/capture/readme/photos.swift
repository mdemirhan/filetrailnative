// The demo project's photos for the README: each .jpg in the folder given becomes the picture of that name in the
// folder of photos given second (tools/capture/readme/photos, public-domain pictures: SOURCES.md there says where each
// came from), and its PDF a contact sheet. Each file keeps its date. Run by scripts/readme-screenshots.sh on its copy
// of the project. A .jpg with no picture of its name stops the run.
import AppKit

func contactSheet() -> Data {
    let data = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    guard let consumer = CGDataConsumer(data: data), let pdf = CGContext(consumer: consumer, mediaBox: &box, nil)
    else { return Data() }
    pdf.beginPDFPage(nil)
    pdf.setFillColor(NSColor(white: 0.14, alpha: 1).cgColor)
    pdf.fill(CGRect(x: 0, y: 500, width: 612, height: 292))
    pdf.setFillColor(NSColor.white.cgColor)
    pdf.fill(CGRect(x: 50, y: 700, width: 300, height: 34))
    pdf.setFillColor(NSColor(white: 0.7, alpha: 1).cgColor)
    pdf.fill(CGRect(x: 50, y: 670, width: 180, height: 12))
    pdf.setFillColor(NSColor(white: 0.85, alpha: 1).cgColor)
    for row in 0..<9 { pdf.fill(CGRect(x: 50, y: 430 - row * 42, width: 512, height: 14)) }
    pdf.endPDFPage()
    pdf.closePDF()
    return data as Data
}

let folder = URL(fileURLWithPath: CommandLine.arguments[1])
let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
func replace(_ name: String, with data: Data?) throws {
    guard let data else { return }
    let file = folder.appendingPathComponent(name)
    let date = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate]
    try data.write(to: file)
    try FileManager.default.setAttributes([.modificationDate: date as Any], ofItemAtPath: file.path)
}
let pictures = URL(fileURLWithPath: CommandLine.arguments[2])
for name in files where name.hasSuffix(".jpg") {
    try replace(name, with: Data(contentsOf: pictures.appendingPathComponent(name)))
}
for name in files where name.hasSuffix(".pdf") { try replace(name, with: contactSheet()) }
