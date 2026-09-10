import Foundation
import zlib

/// Reads only word/document.xml from a DOCX central directory; nothing is extracted to disk.
enum SparkDOCXReader {
    static func text(_ archive: Data) throws -> String {
        let bytes = [UInt8](archive)
        func number(_ offset: Int, _ count: Int) throws -> Int {
            guard offset >= 0, offset <= bytes.count - count else {
                throw SparkAttachmentError.unreadable
            }
            return (0..<count).reduce(0) { $0 | Int(bytes[offset + $1]) << (8 * $1) }
        }
        guard bytes.count >= 22 else { throw SparkAttachmentError.unreadable }
        let lower = max(0, bytes.count - 65_557)
        guard
            let end = stride(from: bytes.count - 22, through: lower, by: -1).first(where: {
                (try? number($0, 4)) == 0x06054b50
                    && (try? number($0 + 20, 2)) == bytes.count - $0 - 22
            }), try number(end + 4, 2) == 0, try number(end + 6, 2) == 0,
            try number(end + 8, 2) == number(end + 10, 2)
        else { throw SparkAttachmentError.unreadable }
        let count = try number(end + 10, 2)
        var cursor = try number(end + 16, 4)
        let directoryEnd = cursor + (try number(end + 12, 4))
        guard count <= 10_000, directoryEnd <= end else { throw SparkAttachmentError.unreadable }
        var document: Data?
        for _ in 0..<count {
            guard try number(cursor, 4) == 0x02014b50 else { throw SparkAttachmentError.unreadable }
            let nameCount = try number(cursor + 28, 2)
            let next =
                cursor + 46 + nameCount + (try number(cursor + 30, 2))
                + (try number(cursor + 32, 2))
            guard next <= directoryEnd else { throw SparkAttachmentError.unreadable }
            let name = String(
                bytes: bytes[(cursor + 46)..<(cursor + 46 + nameCount)],
                encoding: .utf8
            )
            if name == "word/document.xml" {
                guard document == nil, try number(cursor + 8, 2) & 1 == 0 else {
                    throw SparkAttachmentError.unreadable
                }
                let method = try number(cursor + 10, 2)
                let compressed = try number(cursor + 20, 4)
                let expanded = try number(cursor + 24, 4)
                guard expanded > 0, expanded <= 2 * 1024 * 1024 else {
                    throw SparkAttachmentError.tooLarge
                }
                let local = try number(cursor + 42, 4)
                guard try number(local, 4) == 0x04034b50,
                    try number(local + 8, 2) == method,
                    try number(local + 6, 2) & 1 == 0
                else { throw SparkAttachmentError.unreadable }
                let localNameCount = try number(local + 26, 2)
                guard local + 30 + localNameCount <= bytes.count,
                    String(
                        bytes: bytes[(local + 30)..<(local + 30 + localNameCount)],
                        encoding: .utf8
                    ) == name
                else { throw SparkAttachmentError.unreadable }
                let start = local + 30 + localNameCount + (try number(local + 28, 2))
                guard start <= archive.count, compressed <= archive.count - start,
                    start + compressed <= (try number(end + 16, 4))
                else { throw SparkAttachmentError.unreadable }
                let payload = Data(bytes[start..<(start + compressed)])
                if method == 0 {
                    guard compressed == expanded else { throw SparkAttachmentError.unreadable }
                    document = payload
                } else if method == 8 {
                    document = try inflate(payload, count: expanded)
                } else {
                    throw SparkAttachmentError.unsupported
                }
                let checksum = document!.withUnsafeBytes {
                    crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count))
                }
                guard checksum == (try number(cursor + 16, 4)) else {
                    throw SparkAttachmentError.unreadable
                }
            }
            cursor = next
        }
        guard let document, let xml = String(data: document, encoding: .utf8), !xml.contains("\0"),
            document.range(of: Data("<!DOCTYPE".utf8)) == nil,
            document.range(of: Data("<!ENTITY".utf8)) == nil
        else { throw SparkAttachmentError.unreadable }
        let reader = DocumentXMLReader()
        let parser = XMLParser(data: document)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        guard parser.parse() else {
            throw reader.tooLarge ? SparkAttachmentError.tooLarge : SparkAttachmentError.unreadable
        }
        return reader.text
    }

    private static func inflate(_ compressed: Data, count: Int) throws -> Data {
        var stream = z_stream()
        guard
            inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
                == Z_OK
        else { throw SparkAttachmentError.unreadable }
        defer { inflateEnd(&stream) }
        var output = Data(count: count + 1)
        let status: Int32 = compressed.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { result in
                stream.next_in = UnsafeMutablePointer(
                    mutating: input.bindMemory(to: Bytef.self).baseAddress
                )
                stream.avail_in = uInt(input.count)
                stream.next_out = result.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(result.count)
                return zlib.inflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END, stream.total_out == count, stream.avail_in == 0 else {
            throw SparkAttachmentError.unreadable
        }
        output.removeLast()
        return output
    }
}

private final class DocumentXMLReader: NSObject, XMLParserDelegate {
    var text = ""
    var tooLarge = false
    private var readingText = false
    private let wordNamespace = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String]
    ) {
        guard namespaceURI == wordNamespace else { return }
        if elementName == "t" { readingText = true }
        if elementName == "tab" { append("\t", parser) }
        if elementName == "br" { append("\n", parser) }
    }
    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        guard namespaceURI == wordNamespace else { return }
        if elementName == "t" { readingText = false }
        if elementName == "p" { append("\n", parser) }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if readingText { append(string, parser) }
    }
    private func append(_ value: String, _ parser: XMLParser) {
        guard text.utf8.count + value.utf8.count <= SparkChatAttachmentReader.maximumTextBytes
        else {
            tooLarge = true
            parser.abortParsing()
            return
        }
        text += value
    }
}
