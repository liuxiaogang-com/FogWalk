import Foundation
import Combine
import CryptoKit

private final class RoadbookXML: NSObject, XMLParserDelegate {
    var tracks=[[RoadbookPoint]](), route=[RoadbookPoint](), waypoints=[RoadbookWaypoint]()
    var stack=[String](), text="", name="", point:RoadbookPoint?, pointName=""
    var count=0, routeCount=0
    var failure:String?
    var completedRoot = false
    func parser(_ parser:XMLParser,didStartElement element:String,namespaceURI:String?,qualifiedName:String?,attributes:[String:String]) {
        if stack.isEmpty && (element != "gpx" || (namespaceURI != nil && namespaceURI != "" && namespaceURI != "http://www.topografix.com/GPX/1/0" && namespaceURI != "http://www.topografix.com/GPX/1/1")) {
            failure = "请选择 GPX 路书文件，当前内容不是 GPX。"; parser.abortParsing(); return
        }
        stack.append(element); text=""
        if element=="trkseg" { tracks.append([]) }
        if element=="rte" { routeCount+=1 }
        if ["trkpt","rtept","wpt"].contains(element) {
            count+=1
            guard count<=30_000, let lat=Double(attributes["lat"] ?? ""),let lon=Double(attributes["lon"] ?? ""),
                  lat.isFinite,lon.isFinite,(-90...90).contains(lat),(-180...180).contains(lon) else {
                failure="坐标无效或点数超过 30,000 个。"; parser.abortParsing(); return
            }
            point=RoadbookPoint(latitude:lat,longitude:lon); pointName=""
        }
    }
    func parser(_ parser:XMLParser,foundCharacters string:String) { if text.utf8.count<4096 { text+=string } }
    func parser(_ parser:XMLParser,didEndElement element:String,namespaceURI:String?,qualifiedName:String?) {
        if element == "gpx", stack.count == 1 { completedRoot = true }
        if element=="name" {
            if stack.contains("wpt") { pointName=text.trimmingCharacters(in:.whitespacesAndNewlines) }
            else if name.isEmpty, !stack.contains("trkpt"),!stack.contains("rtept") { name=text.trimmingCharacters(in:.whitespacesAndNewlines) }
        }
        if let point {
            switch element {
            case "trkpt": if !tracks.isEmpty { tracks[tracks.count-1].append(point) }; self.point=nil
            case "rtept": route.append(point); self.point=nil
            case "wpt": waypoints.append(RoadbookWaypoint(name:pointName.isEmpty ? "途经点 \(waypoints.count+1)":pointName,point:point)); self.point=nil
            default: break
            }
        }
        if !stack.isEmpty { stack.removeLast() }; text=""
    }
    static func decode(_ data:Data,fallbackName:String,allowRecovery:Bool = true) throws -> Roadbook {
        guard data.count<=15_000_000 else { throw RoadbookError.message("GPX 文件不能超过 15 MB。") }
        let reader=RoadbookXML(), parser=XMLParser(data:data)
        parser.shouldResolveExternalEntities=false; parser.shouldProcessNamespaces=true; parser.delegate=reader
        let valid = parser.parse()
        if !valid {
            // Recover only a complete, independently valid GPX document followed
            // by export residue. Never invent closing tags or salvage partial tracks.
            if allowRecovery, reader.completedRoot, reader.failure == nil,
               let text = String(data:data,encoding:.utf8),
               let closing = text.range(of: #"</(?:[A-Za-z_][\w.-]*:)?gpx\s*>"#, options:.regularExpression) {
                let suffix = String(text[closing.upperBound...])
                let hasSecondDocument = suffix.range(of: #"<(?:[A-Za-z_][\w.-]*:)?gpx(?:\s|>)|<\?xml"#, options:.regularExpression) != nil
                if !hasSecondDocument {
                    let prefix = Data(text[..<closing.upperBound].utf8)
                    if var recovered = try? decode(prefix,fallbackName:fallbackName,allowRecovery:false) {
                        recovered.importWarning = "已恢复完整 GPX 路线，忽略结束标签后的 \(suffix.utf8.count) 字节异常附加内容；原文件未修改。"
                        return recovered
                    }
                }
            }
            throw RoadbookError.message(reader.failure ?? "GPX 文件不完整或含异常内容，无法安全导入。请重新导出完整文件。")
        }
        guard reader.completedRoot else { throw RoadbookError.message("文件中没有完整 GPX 路书。") }
        let segments=reader.tracks.filter { !$0.isEmpty }
        guard segments.count<=1, reader.routeCount<=1 else { throw RoadbookError.message("这份 GPX 含多段轨迹，请先导出一条连续路线，避免把断点误连成道路。") }
        let source=segments.first ?? reader.route
        var points=[RoadbookPoint]()
        for p in source { if points.last.map({RoadbookCourse.distance($0,p)>0.5}) ?? true { points.append(p) } }
        guard points.count>=2, RoadbookCourse(points:points).length>=10 else { throw RoadbookError.message("文件中没有至少 10 米长的有效路线。") }
        let fingerprint=SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()
        return Roadbook(id:UUID(),name:String((reader.name.isEmpty ? fallbackName:reader.name).prefix(100)),
                        importedAt:Date(),fingerprint:fingerprint,points:points,waypoints:reader.waypoints,
                        isLoop:RoadbookCourse.distance(points.first!,points.last!)<=20)
    }
}

@MainActor
final class RoadbookStore: ObservableObject {
    @Published private(set) var books=[Roadbook]()
    @Published private(set) var importing=false
    @Published var message:String?
    @Published var selectedID:UUID?
    private let directory:URL
    private var allBooks=[Roadbook]()
    private var loadFailed=false
    var libraryURL:URL { directory.appendingPathComponent("library-v1.json") }

    init(directory:URL? = nil) {
        self.directory=directory ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Roadbooks",isDirectory:true)
        do {
            if FileManager.default.fileExists(atPath:libraryURL.path) {
                allBooks=try JSONDecoder().decode([Roadbook].self,from:Data(contentsOf:libraryURL))
            }
            refresh()
        } catch { loadFailed=true; message="路书库读取失败，原文件已保留：\(error.localizedDescription)" }
    }
    private func refresh() { books=allBooks.filter{$0.deletedAt==nil}.sorted{$0.importedAt>$1.importedAt} }
    private func commit(_ candidate:[Roadbook]) throws {
        guard !loadFailed else { throw RoadbookError.message("路书库读取失败，暂不能写入，请保留数据并反馈。") }
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        try JSONEncoder().encode(candidate).write(to:libraryURL,options:.atomic)
        allBooks=candidate; refresh()
    }
    @discardableResult
    func importData(_ data:Data,name:String) throws -> UUID {
        let book=try RoadbookXML.decode(data,fallbackName:name)
        if let existing=allBooks.first(where:{$0.deletedAt==nil && $0.fingerprint==book.fingerprint}) { return existing.id }
        try commit(allBooks+[book]); return book.id
    }
    func importFile(_ url:URL) {
        guard !importing else { message="正在导入，请完成后再选择文件。"; return }
        guard ["gpx", "xml"].contains(url.pathExtension.lowercased()) else {
            message="请选择 .gpx 路书文件（也支持内容为 GPX 的 .xml 文件）。"; return
        }
        importing=true
        Task {
            do {
                let book=try await Task.detached(priority:.userInitiated) {
                    let access=url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                    if let size=try url.resourceValues(forKeys:[.fileSizeKey]).fileSize,size>15_000_000 { throw RoadbookError.message("GPX 文件不能超过 15 MB。") }
                    return try RoadbookXML.decode(Data(contentsOf:url),fallbackName:url.deletingPathExtension().lastPathComponent)
                }.value
                if let existing=allBooks.first(where:{$0.deletedAt==nil && $0.fingerprint==book.fingerprint}) { selectedID=existing.id }
                else { try commit(allBooks+[book]); selectedID=book.id }
            } catch { message=error.localizedDescription }
            importing=false
        }
    }
    func rename(_ id:UUID,to name:String) throws {
        let cleaned=name.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !cleaned.isEmpty,cleaned.count<=100 else { throw RoadbookError.message("名称请输入 1–100 个字符。") }
        var copy=allBooks; guard let i=copy.firstIndex(where:{$0.id==id}) else{return}
        copy[i].name=cleaned; try commit(copy)
    }
    func delete(_ id:UUID) throws {
        var copy=allBooks; guard let i=copy.firstIndex(where:{$0.id==id}) else{return}
        copy[i].deletedAt=Date(); try commit(copy)
    }
    func setLoop(_ id:UUID,enabled:Bool) throws {
        var copy=allBooks; guard let i=copy.firstIndex(where:{$0.id==id}) else{return}
        guard !enabled || copy[i].gap<=120 else { throw RoadbookError.message("起终点相距较远，请保持为非环线。") }
        copy[i].isLoop=enabled; try commit(copy)
    }
}
