import Foundation

struct MediaStream: Decodable {
    var index: Int
    var codec_type: String
    var codec_name: String?
    var sample_fmt: String?
    var sample_rate: String?
    var channels: Int?
    var bits_per_raw_sample: String?
    var pix_fmt: String?
    var color_transfer: String?
    var disposition: [String:Int]?
}
struct MediaProbe: Decodable {
    struct Format: Decodable { var duration: String? }
    var streams: [MediaStream]
    var format: Format?
    var chapters: [[String:JSONValue]]?
    var duration: Double? { format?.duration.flatMap(Double.init) }
}
enum JSONValue: Decodable {
    case string(String), number(Double), object([String:JSONValue]), array([JSONValue]), bool(Bool), null
    init(from decoder: Decoder) throws {
        let box = try decoder.singleValueContainer()
        if box.decodeNil() { self = .null }
        else if let value = try? box.decode(String.self) { self = .string(value) }
        else if let value = try? box.decode(Bool.self) { self = .bool(value) }
        else if let value = try? box.decode(Double.self) { self = .number(value) }
        else if let value = try? box.decode([String:JSONValue].self) { self = .object(value) }
        else { self = .array(try box.decode([JSONValue].self)) }
    }
}

enum MediaConversion {
    static let videos = Set(["mov","mp4","mkv","avi","webm","m4v","flv","wmv"])
    static let audioTargets = Set(["mp3","m4a","wav","flac","aiff","m4r"])

    static func probe(_ input: URL, stage: URL, backends: [String:String]) throws -> MediaProbe {
        guard let probe = backends["ffprobe"] else { throw RMError("FFprobe is required to inspect this media file.") }
        let result = try ProcessRunner.run(probe, ["-v","error","-show_streams","-show_format","-show_chapters","-of","json",input.path], in: stage)
        guard result.output.utf8.count < 1_000_000 else { throw RMError("The media file has too much stream metadata.") }
        return try JSONDecoder().decode(MediaProbe.self, from: Data(result.output.utf8))
    }

    static func audioCodec(_ stream: MediaStream, target: String) throws -> [String] {
        let codec = stream.codec_name ?? ""
        if target == "mp3" {
            guard (stream.channels ?? 0) <= 2 else { throw RMError("MP3 supports mono or stereo here. Use M4A, WAV or FLAC to keep these channels.") }
            return codec == "mp3" ? ["-c:a","copy"] : ["-c:a","libmp3lame","-b:a","320k"]
        }
        if target == "m4a" { return ["aac","alac"].contains(codec) ? ["-c:a","copy"] : ["-c:a","aac","-b:a","256k"] }
        if target == "m4r" {
            guard (stream.channels ?? 0) <= 2 else { throw RMError("Ringtones need mono or stereo audio.") }
            return ["-c:a","aac","-b:a","256k","-t","40","-f","ipod"]
        }
        let sample = (stream.sample_fmt ?? "").replacingOccurrences(of: "p", with: "")
        if target == "flac" {
            if codec == "flac" { return ["-c:a","copy"] }
            guard ["u8","s16","s32","s64","flt","dbl"].contains(sample) else { throw RMError("This decoded audio sample format is not supported: \(sample).") }
            // Lossy decoders commonly produce floating-point samples. FLAC stores
            // integer PCM, so render those samples at 24 bits rather than reject them.
            let declaredBits = Int(stream.bits_per_raw_sample ?? "") ?? 0
            let inferredBits = sample == "s16" ? 16 : sample == "u8" ? 8 : 24
            let sourceBits = declaredBits > 0 ? declaredBits : inferredBits
            let bits = ["flt","dbl"].contains(sample) ? 24 : min(24, max(8, sourceBits))
            return ["-c:a","flac","-compression_level","8","-sample_fmt",bits <= 16 ? "s16" : "s32","-bits_per_raw_sample",String(bits)]
        }
        let endian = target == "aiff" ? "be" : "le"
        let types = ["u8":target == "aiff" ? "pcm_s8" : "pcm_u8", "s16":"pcm_s16" + endian, "s32":"pcm_s32" + endian, "s64":"pcm_s64" + endian, "flt":"pcm_f32" + endian, "dbl":"pcm_f64" + endian]
        guard let encoder = types[sample] else { throw RMError("This decoded audio sample format is not supported: \(sample).") }
        return ["-c:a",codec == encoder ? "copy" : encoder]
    }

    static func convert(_ input: URL, target: String, stage: URL, output: URL, backends: [String:String]) throws -> (URL, Bool, String) {
        guard let executable = backends["ffmpeg"] else { throw RMError("Install FFmpeg to convert this media file.") }
        let lock = try ProcessLock(name: "ffmpeg", slots: 2, timeout: 600)
        return try withExtendedLifetime(lock) {
            let before = try probe(input, stage: stage, backends: backends)
            let source = ConversionManifest.extensionOf(input)
            let base = ["-nostdin","-hide_banner","-loglevel","error","-n"]
            if audioTargets.contains(target) {
                let audio = before.streams.filter { $0.codec_type == "audio" }
                guard !audio.isEmpty else { throw RMError("This file has no audio track.") }
                let directoryOutput = videos.contains(source) || audio.count > 1
                let directory = stage.appendingPathComponent("audio", isDirectory: true)
                if directoryOutput { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false) }
                var copied = 0
                for (index, stream) in audio.enumerated() {
                    let file = directoryOutput ? directory.appendingPathComponent(String(format: "track-%02d.%@",index + 1,target)) : output
                    let encoding = try audioCodec(stream, target: target)
                    if encoding.contains("copy") { copied += 1 }
                    try ProcessRunner.run(executable, base + ["-i",input.path,"-map","0:\(stream.index)","-map_metadata","0"] + encoding + [file.path], in: stage, timeout: 600)
                    let after = try probe(file, stage: stage, backends: backends)
                    guard after.streams.filter({ $0.codec_type == "audio" }).count == 1, after.streams.first(where: { $0.codec_type == "audio" })?.channels == stream.channels else { throw RMError("The converted audio did not preserve its channel count.") }
                    if let a = before.duration, let b = after.duration {
                        let expected = target == "m4r" ? min(a,40) : a
                        guard abs(expected-b) <= max(0.2,expected*0.01) else { throw RMError("The converted audio duration does not match.") }
                    }
                }
                return (directoryOutput ? directory : output, directoryOutput, "\(copied) of \(audio.count) audio tracks copied without re-encoding." + (target == "m4r" ? " Ringtone limited to the first 40 seconds." : "") + (target == "flac" ? " FLAC uses integer PCM up to 24 bits; floating-point or higher-depth samples are quantised to that range." : "") + " Artwork is not included in audio extraction.")
            }
            if ["srt","vtt"].contains(target) {
                try ProcessRunner.run(executable, base + ["-i",input.path,"-map","0:s:0","-c:s",target == "vtt" ? "webvtt" : "srt",output.path], in: stage)
                guard !(try String(contentsOf: output, encoding: .utf8)).isEmpty else { throw RMError("No subtitle text was produced.") }
                return (output,false,"Text and timing retained; unsupported subtitle styling may be lost.")
            }
            let video = before.streams.filter { $0.codec_type == "video" && $0.disposition?["attached_pic"] != 1 }
            guard !video.isEmpty else { throw RMError("This file has no video stream.") }
            if target == "gif" || source == "gif" {
                guard video.count == 1, !video.contains(where: { ["smpte2084","arib-std-b67"].contains($0.color_transfer ?? "") }) else { throw RMError("This animation route needs one SDR video stream.") }
                let filter: String
                var args = base
                if source == "gif" { args += ["-ignore_loop","1"] }
                args += ["-i",input.path,"-an"]
                if target == "gif" {
                    filter = "fps=15,scale=w='min(640,iw)':h=-1:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse"
                    args += ["-filter_complex",filter,"-loop","0"]
                } else {
                    filter = "split[bg][fg];[bg]drawbox=c=white:t=fill:replace=1[white];[white][fg]overlay=shortest=1,pad=ceil(iw/2)*2:ceil(ih/2)*2:color=white,format=yuv420p"
                    args += ["-filter_complex",filter,"-c:v","libx264","-crf","18","-preset","medium","-movflags","+faststart"]
                }
                try ProcessRunner.run(executable,args + [output.path],in:stage,timeout:600)
                let after = try probe(output,stage:stage,backends:backends)
                guard after.streams.contains(where: { $0.codec_type == "video" }) else { throw RMError("The animation output has no video stream.") }
                return (output,false,target == "gif" ? "Animation rendered at up to 640 pixels wide and 15 fps; audio omitted." : "One animation cycle rendered on white.")
            }
            var args = base + ["-i",input.path,"-map","0","-map_metadata","0","-map_chapters","0","-c","copy"]
            var videoIndex = 0, audioIndex = 0, copied = 0, encoded = 0
            for stream in before.streams {
                let codec = stream.codec_name ?? ""
                switch stream.codec_type {
                case "video":
                    let allowed: Set<String>
                    switch target {
                    case "mp4": allowed = ["h264","hevc","av1","mpeg4","mjpeg","png"]
                    case "mov": allowed = ["h264","hevc","prores","mpeg4","mjpeg","png"]
                    case "webm": allowed = ["vp8","vp9","av1"]
                    default: allowed = Set([codec]).subtracting(["rawvideo"])
                    }
                    if allowed.contains(codec) { copied += 1 }
                    else {
                        guard stream.disposition?["attached_pic"] != 1, !["smpte2084","arib-std-b67"].contains(stream.color_transfer ?? "") else { throw RMError("This conversion needs an unsupported artwork or HDR rendering decision.") }
                        if target == "webm" { args += ["-c:v:\(videoIndex)","libvpx-vp9","-crf:v:\(videoIndex)","30","-b:v:\(videoIndex)","0"] }
                        else { args += ["-c:v:\(videoIndex)","libx264","-crf:v:\(videoIndex)","18","-preset:v:\(videoIndex)","medium"] }
                        args += ["-pix_fmt:v:\(videoIndex)","yuv420p"]; encoded += 1
                    }
                    videoIndex += 1
                case "audio":
                    let compatible = target == "mkv" || (target == "webm" ? ["opus","vorbis"].contains(codec) : ["aac","alac","mp3","ac3","eac3"].contains(codec) || (target == "mov" && codec.hasPrefix("pcm_")))
                    if compatible { copied += 1 }
                    else { args += ["-c:a:\(audioIndex)",target == "webm" ? "libopus" : "aac","-b:a:\(audioIndex)",target == "webm" ? "192k" : "256k"]; encoded += 1 }
                    audioIndex += 1
                case "subtitle":
                    guard target == "mkv" || (target == "webm" ? codec == "webvtt" : codec == "mov_text") else { throw RMError("This container cannot preserve the subtitle stream. Choose MKV.") }; copied += 1
                case "attachment": guard target == "mkv" else { throw RMError("Choose MKV to preserve attached files.") }; copied += 1
                case "data": guard target == "mov" && codec == "tmcd" else { throw RMError("This file has a data stream the target cannot preserve.") }; copied += 1
                default: throw RMError("Unsupported media stream type: \(stream.codec_type).")
                }
            }
            if target == "webm" && !(before.chapters ?? []).isEmpty { throw RMError("Choose MKV to preserve these chapters.") }
            if ["mp4","mov"].contains(target) { args += ["-movflags","+faststart"] }
            try ProcessRunner.run(executable,args + [output.path],in:stage,timeout:600)
            let after = try probe(output,stage:stage,backends:backends)
            for type in ["video","audio","subtitle","attachment"] {
                guard before.streams.filter({ $0.codec_type == type }).count == after.streams.filter({ $0.codec_type == type }).count else { throw RMError("The converted media did not preserve every \(type) stream.") }
            }
            if let a = before.duration, let b = after.duration { guard abs(a-b) <= max(0.2,a*0.01) else { throw RMError("The converted video duration does not match.") } }
            return (output,false,"\(copied) streams copied without re-encoding; \(encoded) encoded.")
        }
    }
}
