import Foundation
import Cocoa
import ImageIO

enum ExtraImages {
    static func convert(_ input: URL, to output: URL, format: String, stage: URL, backends: [String:String]) throws {
        guard let executable = backends["magick"] else { throw RMError("Install ImageMagick for this image format.") }
        let png = stage.appendingPathComponent("pixels.png")
        if ConversionManifest.extensionOf(input) == "svg" {
            guard (try input.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) < 16_000_000 else { throw RMError("SVG files are limited to 16 MB.") }
            let data = try Data(contentsOf: input)
            let text = String(decoding: data, as: UTF8.self)
            guard !["<!DOCTYPE","<!ENTITY","<script","<foreignObject"].contains(where: { text.range(of:$0,options:.caseInsensitive) != nil }), text.range(of: #"(?:href|src)\s*=\s*["'](?:https?:)?//"#,options:.regularExpression) == nil else { throw RMError("This SVG contains unsupported external resources or active content.") }
            let parser = SVGSize(); let xml = XMLParser(data:data); xml.shouldResolveExternalEntities = false; xml.delegate = parser
            guard xml.parse(), let size = parser.size else { throw RMError("The SVG needs a numeric width and height or a valid viewBox.") }
            let width = max(1024,size.width*2), height = width*size.height/size.width
            guard width.isFinite, height.isFinite, width >= 1, height >= 1, width <= 65535, height <= 65535, width*height <= 120_000_000 else { throw RMError("This SVG exceeds the image rendering limits.") }
            try ProcessRunner.run(executable,["-background","none","-density","192",input.path,"-resize","\(Int(width.rounded()))x\(Int(height.rounded()))!",png.path],in:stage)
        } else { try ImageConversion.write(input,to:png,format:"png") }
        if ["png","jpg","pdf"].contains(format) {
            if format == "pdf" { try ImageConversion.pdf([png],to:output) }
            else { try ImageConversion.write(png,to:output,format:format) }
        } else if format == "icns" {
            let iconset = stage.appendingPathComponent("App.iconset",isDirectory:true)
            try FileManager.default.createDirectory(at:iconset,withIntermediateDirectories:false)
            let pixels = try ImageConversion.image(png)
            for size in [16,32,128,256,512] {
                for scale in [1,2] {
                    let filename = "icon_\(size)x\(size)" + (scale == 2 ? "@2x" : "") + ".png"
                    try square(pixels,size:size*scale,to:iconset.appendingPathComponent(filename))
                }
            }
            try ProcessRunner.run("/usr/bin/iconutil",["-c","icns","-o",output.path,iconset.path],in:stage)
            guard let image = NSImage(contentsOf:output), image.isValid else { throw RMError("The generated app icon is unreadable.") }
        } else {
            var args = [png.path]
            if format == "ico" {
                let squareURL = stage.appendingPathComponent("square.png")
                try square(ImageConversion.image(png),size:256,to:squareURL)
                args = [squareURL.path,"-define","icon:auto-resize=256,128,64,48,32,16"]
            } else { args += ["-quality",format == "avif" ? "85" : "90"] }
            try ProcessRunner.run(executable,args + [output.path],in:stage)
            if format == "ico" {
                guard let image = NSImage(contentsOf:output), image.isValid else { throw RMError("The generated icon is unreadable.") }
            } else {
                let original = try ImageConversion.image(png), result = try ImageConversion.image(output)
                guard original.width == result.width, original.height == result.height else { throw RMError("The converted image dimensions do not match.") }
            }
        }
    }
    static func square(_ image: CGImage, size: Int, to output: URL) throws {
        let context = CGContext(data:nil,width:size,height:size,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        let scale = min(Double(size)/Double(image.width),Double(size)/Double(image.height))
        let width = Double(image.width)*scale, height = Double(image.height)*scale
        context.interpolationQuality = .high
        context.draw(image,in:CGRect(x:(Double(size)-width)/2,y:(Double(size)-height)/2,width:width,height:height))
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL,"public.png" as CFString,1,nil), let pixels = context.makeImage() else { throw RMError("Could not render the icon.") }
        CGImageDestinationAddImage(destination,pixels,nil)
        guard CGImageDestinationFinalize(destination) else { throw RMError("Could not save the icon.") }
    }
}

private final class SVGSize: NSObject, XMLParserDelegate {
    var size: CGSize?
    func parser(_ parser: XMLParser,didStartElement elementName: String,namespaceURI: String?,qualifiedName qName: String?,attributes: [String:String]) {
        guard elementName == "svg", size == nil else { return }
        func dimension(_ value: String?) -> Double? {
            guard let value else { return nil }
            let text = value.replacingOccurrences(of:"px",with:"").trimmingCharacters(in:.whitespaces)
            guard let number = Double(text), number > 0 else { return nil }; return number
        }
        if let width = dimension(attributes["width"]), let height = dimension(attributes["height"]) { size = CGSize(width:width,height:height); return }
        let box = attributes["viewBox"]?.split { $0.isWhitespace || $0 == "," }.compactMap { Double($0) } ?? []
        if box.count == 4,box[2]>0,box[3]>0 { size = CGSize(width:box[2],height:box[3]) }
    }
}
