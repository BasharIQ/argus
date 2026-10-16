import Foundation

enum JSONLines {
    struct Decoded<Record> {
        let records: [Record]
        let malformedLines: [Int]
    }

    static func decode<Record: Decodable>(_ type: Record.Type, data: Data) -> Decoded<Record> {
        let decoder = JSONDecoder()
        let lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        var records: [Record] = []
        var malformedLines: [Int] = []
        for (index, line) in lines.enumerated() {
            if line.allSatisfy({ $0 == 32 || $0 == 9 || $0 == 13 }) { continue }
            do {
                records.append(try decoder.decode(type, from: Data(line)))
            } catch {
                if index == lines.count - 1, data.last != UInt8(ascii: "\n"), isIncomplete(line) {
                    continue
                }
                malformedLines.append(index + 1)
            }
        }
        return Decoded(records: records, malformedLines: malformedLines)
    }

    private static func isIncomplete(_ bytes: Data.SubSequence) -> Bool {
        guard let first = bytes.first(where: { $0 != 32 && $0 != 9 && $0 != 13 }),
              first == UInt8(ascii: "{") || first == UInt8(ascii: "[") else { return false }
        var depth = 0
        var inString = false
        var escaped = false
        for byte in bytes {
            if inString {
                if escaped { escaped = false }
                else if byte == UInt8(ascii: "\\") { escaped = true }
                else if byte == UInt8(ascii: "\"") { inString = false }
            } else {
                switch byte {
                case UInt8(ascii: "\""): inString = true
                case UInt8(ascii: "{"), UInt8(ascii: "["): depth += 1
                case UInt8(ascii: "}"), UInt8(ascii: "]"): depth -= 1
                default: break
                }
            }
        }
        return depth > 0 || inString
    }
}
