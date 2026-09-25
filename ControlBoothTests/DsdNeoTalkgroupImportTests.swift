import Testing
import Foundation
@testable import ControlBooth

/// Converting other scanners' talkgroup lists into dsd-neo group lists.
struct DsdNeoTalkgroupImportTests {

    @Test func op25TSV() throws {
        let tsv = "1\tState Police: Troop A - Little Rock North - Information and District Calling\r\n"
            + "2601\t\"AWIN Mutual Aid Channel Pool (MAC) Mutual Aid Calling, (Used to announce Wx Info)\"\r\n"
            + "\r\n"
        let result = try DsdNeoTalkgroupImport.convert(tsv)
        #expect(result.format == .op25)
        #expect(result.list.header == DsdNeoTalkgroupImport.header)
        #expect(result.list.rows.map(\.talkgroup) == [1, 2601])
        let first = result.list.rows[0]
        #expect(first.mode == "A")
        #expect(first.name.utf8.count <= DsdNeoTalkgroupImport.nameLimit)
        #expect(first.name == first.name.trimmingCharacters(in: .whitespaces))
        #expect(result.list.displayNames[1] == "State Police: Troop A - Little Rock North - Information and District Calling")
        // Commas can't appear inside a dsd-neo CSV field, but Now Playing gets them back.
        #expect(!result.list.csvText.contains("Calling, ("))
        #expect(result.list.displayNames[2601] == "AWIN Mutual Aid Channel Pool (MAC) Mutual Aid Calling, (Used to announce Wx Info)")
    }

    @Test func radioReferenceCSV() throws {
        let csv = """
            Decimal,Hex,Alpha Tag,Mode,Description,Tag,Category
            3,003,ASP A LR S Disp,D,"State Police: Troop A, Little Rock South Dispatch",Law Dispatch,State Police
            30147,75c3,LRPD Main,DE,Little Rock Police Main Dispatch,Law Dispatch,Pulaski County
            44720,aeb0,PCSO Pri 1,De,Pulaski County Sheriff Primary 1,Law Dispatch,Pulaski County
            53643,d18b,Phase 2 Ops,T,Some TDMA Talkgroup,,
            """
        let result = try DsdNeoTalkgroupImport.convert(csv)
        #expect(result.format == .radioReference)
        let byTG = Dictionary(uniqueKeysWithValues: result.list.rows.map { ($0.talkgroup, $0) })
        #expect(byTG[3]?.name == "ASP A LR S Disp")
        #expect(byTG[3]?.mode == "A")
        #expect(result.list.displayNames[3] == "State Police: Troop A, Little Rock South Dispatch")
        #expect(byTG[3]?.fields[3] == "State Police")          // Category is the tag
        // Always-encrypted is locked out; sometimes-encrypted is kept.
        #expect(byTG[30147]?.mode == "DE")
        #expect(byTG[44720]?.mode == "A")
        #expect(byTG[53643]?.mode == "A")
    }

    @Test func sdrTrunkPlaylist() throws {
        let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <playlist version="4">
              <alias name="Fire Dispatch" group="Fire" list="AWIN">
                <id type="talkgroup" value="1449" protocol="APCO25"/>
              </alias>
              <alias name="Law Encrypted" group="Law" list="AWIN">
                <id type="talkgroup" value="22033" protocol="APCO25"/>
                <id type="priority" priority="-1"/>
              </alias>
              <alias name="DMR Thing" list="AWIN">
                <id type="talkgroup" value="9" protocol="DMR"/>
              </alias>
            </playlist>
            """
        let result = try DsdNeoTalkgroupImport.convert(xml)
        #expect(result.format == .sdrTrunk)
        #expect(result.list.rows.map(\.talkgroup) == [1449, 22033])
        #expect(result.list.rows[0].fields == ["1449", "A", "Fire Dispatch", "Fire", "Fire Dispatch"])
        #expect(result.list.rows[1].mode == "B")
        #expect(result.skipped == 1)   // the DMR alias
    }

    @Test func dsdNeoCSVPassesThrough() throws {
        let csv = "DEC,Mode(A- Allow; B - Block; DE - Digital Enc),Name of Group,Tag\n100,B,Example Name,Tag\n1449,A,Fire Dispatch,Fire\n"
        let result = try DsdNeoTalkgroupImport.convert(csv)
        #expect(result.format == .dsdNeo)
        #expect(result.list.rows.count == 2)
        #expect(result.list.rows[0].mode == "B")
    }

    @Test func unrecognizedAndEmpty() {
        #expect(throws: DsdNeoTalkgroupImport.ImportError.unrecognized) {
            try DsdNeoTalkgroupImport.convert("hello world\nthis is not a list\n")
        }
        #expect(throws: DsdNeoTalkgroupImport.ImportError.empty(.sdrTrunk)) {
            try DsdNeoTalkgroupImport.convert("<playlist version=\"4\"><alias name=\"x\"/></playlist>")
        }
    }

    @Test func csvQuoting() {
        #expect(DsdNeoTalkgroupImport.parseCSVLine(#"3,"a, b","say ""hi""",x"#) == ["3", "a, b", "say \"hi\"", "x"])
        #expect(DsdNeoTalkgroupImport.parseCSVLine("a,,c") == ["a", "", "c"])
    }
}
