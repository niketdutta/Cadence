import SwiftUI
import AppKit
import IOKit.ps
import AVFoundation
import CoreImage
import CoreAudio
import Combine
import Carbon.HIToolbox

struct LyricLine { var t: Double; var text: String }

struct Track: Equatable {
    var app: String, title: String, artist: String
    var album = ""
    var playing: Bool
    var position: Double, duration: Double
}

@MainActor final class Player: ObservableObject {
    @Published var track: Track?
    @Published var art: NSImage?
    @Published var softArt: NSImage?  // heavily pre-blurred copy of the cover, for the living backdrop (blurred once, then only transformed)
    @Published var motionURL: URL? { didSet { rebuildMotion() } }  // Apple Music animated cover (HLS), when the album has one
    private(set) var motionPlayer: AVPlayer?  // one player shared by the backdrop and the cover (decoded once)
    private var motionObservers: [NSObjectProtocol] = []
    @Published var scrub: Double?  // 0...1 while the user drags/clicks the progress bar
    @Published var lyricsLoading = false  // a lookup is in flight for the current track
    @Published var lyrics: [LyricLine] = []  // synced lines for the current track (LRCLIB), empty if none
    var positionAt = Date()  // when `track.position` was sampled, for sub-second lyric timing
    @Published var thumbHidden = false  // card thumbnail hidden while the big cover is out / flying back to it
    @Published var cardOffset = CGSize.zero  // card position inside its (fixed) window, animated by SwiftUI = GPU transform, no window resize
    var cardWindow = CGSize(width: 290, height: 150)
    @Published var revealed = false  // drives the cover/backdrop animation
    @Published var lyricsOpen = UserDefaults.standard.bool(forKey: "lyricsOpen") { didSet { UserDefaults.standard.set(lyricsOpen, forKey: "lyricsOpen") } }  // lyrics panel opened from the player button
    @Published var expanded = false  // big album art shown
    @Published var liked = false  // visual only, not synced to the music app
    private var artKey = ""
    private let queue = DispatchQueue(label: "applescript")

    /// Full-screen animated cover mode: only when the user turned it on AND this album has an animated cover.
    var fullCoverActive: Bool { Settings.shared.fullCover && motionPlayer != nil }

    func livePosition(_ now: Date) -> Double {
        guard let t = track else { return 0 }
        return t.position + (t.playing ? now.timeIntervalSince(positionAt) : 0)
    }

    func currentLyric(_ now: Date) -> String? {
        guard !lyrics.isEmpty else { return nil }
        let pos = livePosition(now) + Settings.shared.lyricOffset
        guard let i = lyrics.lastIndex(where: { $0.t <= pos }) else { return nil }
        return lyrics[i].text.isEmpty ? "♪" : lyrics[i].text
    }

    private func rebuildMotion() {
        motionPlayer?.pause()
        motionObservers.forEach(NotificationCenter.default.removeObserver); motionObservers = []
        motionPlayer = nil
        guard let u = motionURL else { return }
        // Manual loop: AVPlayerLooper stops after one pass on HLS streams.
        let item = AVPlayerItem(url: u)
        let p = AVPlayer(playerItem: item)
        p.isMuted = true
        p.actionAtItemEnd = .none
        let nc = NotificationCenter.default
        motionObservers = [
            nc.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak p] _ in p?.seek(to: .zero); p?.play() },
            nc.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { n in dlog("motion failed: \(String(describing: n.userInfo))") },
            nc.addObserver(forName: .AVPlayerItemPlaybackStalled, object: item, queue: .main) { [weak p] _ in dlog("motion stalled"); p?.play() },
        ]
        motionPlayer = p
    }

    func start() {
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        poll()
    }

    func poll() {
        queue.async {
            let t0 = Date().timeIntervalSince1970
            let t = Player.read()
            let sampled = Date(timeIntervalSince1970: (t0 + Date().timeIntervalSince1970) / 2)  // position was read mid-call
            var img: NSImage?
            if let t, "\(t.title)|\(t.artist)" != DispatchQueue.main.sync(execute: { MainActor.assumeIsolated { self.artKey } }) {
                img = Player.fetchArt(t)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.track = t
                    self.positionAt = sampled
                    if let t, "\(t.title)|\(t.artist)" != self.artKey {
                        let key = "\(t.title)|\(t.artist)"
                        self.artKey = key
                        self.art = img
                        self.softArt = img.flatMap { Player.softened($0) }
                        self.motionURL = nil
                        self.lyrics = []
                        self.lyricsLoading = true
                        DispatchQueue.global().async {
                            let l = Player.fetchLyrics(t)
                            DispatchQueue.main.async { MainActor.assumeIsolated { if self.artKey == key { self.lyrics = l; self.lyricsLoading = false } } }
                        }
                        DispatchQueue.global().async {
                            let u = Player.fetchMotion(t)
                            dlog("motion cover for \(key): \(u?.absoluteString ?? "none")")
                            DispatchQueue.main.async { MainActor.assumeIsolated { if self.artKey == key { self.motionURL = u } } }
                        }
                    }
                }
            }
        }
    }

    /// Jump to a fraction of the song (click / drag on the progress bar).
    func seek(_ fraction: Double) {
        guard let t = track, t.duration > 0 else { return }
        let secs = min(max(fraction, 0), 1) * t.duration
        track?.position = secs
        positionAt = Date()
        queue.async { _ = Player.run("tell application \"\(t.app)\" to set player position to \(secs)") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.poll() }
    }

    func send(_ cmd: String) {
        guard let app = track?.app else { return }
        queue.async { _ = Player.run("tell application \"\(app)\" to \(cmd)") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.poll() }
    }

    // MARK: AppleScript (off main thread)
    nonisolated static func run(_ src: String) -> NSAppleEventDescriptor? {
        var err: NSDictionary?
        return NSAppleScript(source: src)?.executeAndReturnError(&err)
    }

    nonisolated static func running(_ id: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty
    }

    nonisolated static func read() -> Track? {
        var found: Track?
        if running("com.apple.Music"), let d = run("""
            tell application "Music"
              if player state is stopped then return {}
              set t to current track
              return {player state as text, name of t, artist of t, player position, duration of t, album of t}
            end tell
            """), d.numberOfItems >= 5 {
            found = Track(app: "Music", title: d.atIndex(2)?.stringValue ?? "", artist: d.atIndex(3)?.stringValue ?? "", album: d.atIndex(6)?.stringValue ?? "",
                          playing: d.atIndex(1)?.stringValue == "playing",
                          position: d.atIndex(4)?.doubleValue ?? 0, duration: d.atIndex(5)?.doubleValue ?? 0)
        }
        if found?.playing != true, running("com.spotify.client"), let d = run("""
            tell application "Spotify"
              if player state is stopped then return {}
              set t to current track
              return {player state as text, name of t, artist of t, player position, (duration of t) / 1000, album of t}
            end tell
            """), d.numberOfItems >= 5 {
            let s = Track(app: "Spotify", title: d.atIndex(2)?.stringValue ?? "", artist: d.atIndex(3)?.stringValue ?? "", album: d.atIndex(6)?.stringValue ?? "",
                          playing: d.atIndex(1)?.stringValue == "playing",
                          position: d.atIndex(4)?.doubleValue ?? 0, duration: d.atIndex(5)?.doubleValue ?? 0)
            if found == nil || s.playing { found = s }
        }
        return found
    }

    nonisolated static func px(_ i: NSImage) -> Int { i.representations.map(\.pixelsWide).max() ?? Int(i.size.width) }

    /// Best available cover: the player's own art if it is large, otherwise a 1500px lookup.
    nonisolated static func fetchArt(_ t: Track) -> NSImage? {
        var best: NSImage?
        if t.app == "Music", let d = run("tell application \"Music\" to get data of artwork 1 of current track") {
            best = NSImage(data: d.data)
        }
        if t.app == "Spotify", let u = run("tell application \"Spotify\" to get artwork url of current track")?.stringValue {
            // Spotify's CDN serves the full-size original under this image-id prefix instead of the 640px one.
            let hd = u.replacingOccurrences(of: "ab67616d0000b273", with: "ab67616d000082c1").replacingOccurrences(of: "ab67616d00001e02", with: "ab67616d000082c1")
            for cand in [hd, u] {
                if let url = URL(string: cand), let data = get(url), let img = NSImage(data: data) { best = img; break }
            }
        }
        if best == nil || px(best!) < 1000, let hd = itunesArt(t), px(hd) > (best.map(px) ?? 0) { best = hd }
        return best
    }

    nonisolated static func get(_ url: URL) -> Data? {
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        var out: Data?
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { d, _, _ in out = d; sem.signal() }.resume()
        sem.wait()
        return out
    }

    /// Apple Music album pages embed the animated-cover HLS link in public page data (no API token needed).
    /// Only some albums have one. ponytail: scrapes page markup; breaks if Apple renames the keys.
    nonisolated static func fetchMotion(_ t: Track) -> URL? {
        var c = URLComponents(string: "https://itunes.apple.com/search")!
        c.queryItems = [.init(name: "term", value: "\(t.title) \(t.artist)"), .init(name: "entity", value: "song"), .init(name: "limit", value: "10")]
        guard let url = c.url, let data = get(url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else { return nil }
        // Candidate album pages for this song. The player's own album first (singles usually have no animated cover).
        var seen = Set<String>(), cands: [(name: String, page: URL)] = []
        for r in results {
            guard let link = r["collectionViewUrl"] as? String, var pc = URLComponents(string: link) else { continue }
            pc.query = nil
            guard let page = pc.url, seen.insert(page.absoluteString).inserted else { continue }
            cands.append((r["collectionName"] as? String ?? "", page))
        }
        let want = t.album.lowercased()
        cands.sort { a, b in
            let am = !want.isEmpty && a.name.lowercased().contains(want), bm = !want.isEmpty && b.name.lowercased().contains(want)
            return am && !bm
        }
        for cand in cands.prefix(4) {
            guard let html = get(cand.page).flatMap({ String(data: $0, encoding: .utf8) }),
                  let r = html.range(of: "\"motionDetailSquare\"") else { continue }
            let seg = String(html[r.upperBound...].prefix(4000))
            if let re = try? NSRegularExpression(pattern: #""video":"(https://[^"]+\.m3u8)""#),
               let m = re.firstMatch(in: seg, range: NSRange(seg.startIndex..., in: seg)),
               let g = Range(m.range(at: 1), in: seg), let u = URL(string: String(seg[g])) { return u }
        }
        return nil
    }

    /// Synced lyrics from LRCLIB (free, no key). Exact match first, then a search on a cleaned title.
    nonisolated static func fetchLyrics(_ t: Track) -> [LyricLine] {
        func lrc(_ url: URL?) -> String? {
            guard let url, let d = get(url), let j = try? JSONSerialization.jsonObject(with: d) else { return nil }
            let obj = (j as? [String: Any]) ?? (j as? [[String: Any]])?.first(where: { ($0["syncedLyrics"] as? String)?.isEmpty == false })
            return obj?["syncedLyrics"] as? String
        }
        var c = URLComponents(string: "https://lrclib.net/api/get")!
        c.queryItems = [.init(name: "artist_name", value: t.artist), .init(name: "track_name", value: t.title), .init(name: "duration", value: String(Int(t.duration.rounded())))]
        var text = lrc(c.url)
        if text == nil {
            let clean = t.title.replacingOccurrences(of: #"\s*[\(\[].*?[\)\]]"#, with: "", options: .regularExpression)
            var s = URLComponents(string: "https://lrclib.net/api/search")!
            s.queryItems = [.init(name: "track_name", value: clean), .init(name: "artist_name", value: t.artist)]
            text = lrc(s.url)
        }
        guard let text, let re = try? NSRegularExpression(pattern: #"\[(\d+):(\d+(?:\.\d+)?)\]"#) else { return [] }
        var out: [LyricLine] = []
        for raw in text.split(separator: "\n") {
            let line = String(raw)
            let ns = line as NSString
            let ms = re.matches(in: line, range: NSRange(location: 0, length: ns.length))
            guard let last = ms.last else { continue }
            let body = ns.substring(from: last.range.location + last.range.length).trimmingCharacters(in: .whitespaces)
            for m in ms { out.append(LyricLine(t: (Double(ns.substring(with: m.range(at: 1))) ?? 0) * 60 + (Double(ns.substring(with: m.range(at: 2))) ?? 0), text: body)) }
        }
        dlog("lyrics for \(t.title): \(out.count) lines")
        return out.sorted { $0.t < $1.t }
    }

    /// 480px, lightly Gaussian-blurred copy of the cover: cheap to move around every frame, unlike a live blur.
    nonisolated static func softened(_ img: NSImage) -> NSImage? {
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let scale = 480.0 / Double(cg.width)
        let small = CIImage(cgImage: cg).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let f = CIFilter(name: "CIGaussianBlur") else { return nil }
        f.setValue(small.clampedToExtent(), forKey: kCIInputImageKey)
        f.setValue(6.0, forKey: kCIInputRadiusKey)  // light blur: the art stays recognisable
        guard let blurred = f.outputImage?.cropped(to: small.extent) else { return nil }
        let boost = CIFilter(name: "CIColorControls")
        boost?.setValue(blurred, forKey: kCIInputImageKey); boost?.setValue(1.2, forKey: kCIInputSaturationKey)  // livelier blobs
        guard let out = boost?.outputImage ?? Optional(blurred),
              let done = CIContext().createCGImage(out, from: blurred.extent) else { return nil }
        return NSImage(cgImage: done, size: NSSize(width: done.width, height: done.height))
    }

    nonisolated static func itunesArt(_ t: Track) -> NSImage? {
        var c = URLComponents(string: "https://itunes.apple.com/search")!
        c.queryItems = [.init(name: "term", value: "\(t.title) \(t.artist)"), .init(name: "entity", value: "song"), .init(name: "limit", value: "1")]
        guard let url = c.url, let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let u = ((json["results"] as? [[String: Any]])?.first?["artworkUrl100"] as? String)?
                  .replacingOccurrences(of: "100x100", with: "1500x1500"),
              let imgURL = URL(string: u), let img = try? Data(contentsOf: imgURL) else { return nil }
        return NSImage(data: img)
    }
}

func mmss(_ s: Double) -> String {
    let n = Int(max(0, s)); return String(format: "%d:%02d", n / 60, n % 60)
}

/// Title that scrolls sideways (and repeats) when it doesn't fit; sits still when it does.
struct MarqueeText: View {
    var text: String
    var size: CGFloat
    var weight: NSFont.Weight = .semibold
    var alignment: Alignment = .leading

    static func width(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight) -> CGFloat {
        ceil((s as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)]).width)
    }
    var swiftWeight: Font.Weight { weight == .bold ? .bold : weight == .medium ? .medium : weight == .regular ? .regular : .semibold }

    var body: some View {
        GeometryReader { g in
            let w = Self.width(text, size, weight)
            let label = Text(text).font(.system(size: size, weight: swiftWeight)).lineLimit(1).fixedSize()
            if w <= g.size.width {
                label.frame(width: g.size.width, alignment: alignment)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { ctx in
                    let gap: CGFloat = 40, speed: Double = 32, pause = 1.6
                    let cycle = Double(w + gap)
                    let period = cycle / speed + pause
                    let phase = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period)
                    let off = CGFloat(max(0, phase - pause) * speed)  // rests at the start, scrolls one full title length, repeats
                    HStack(spacing: gap) { label; label }
                        .offset(x: -off)
                        .frame(width: g.size.width, alignment: .leading)
                        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.06), .init(color: .black, location: 0.94), .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: size + 6)
    }
}

/// "Now playing" bars: bounce while music plays, rest flat when paused.
struct PlayingBars: View {
    var playing: Bool
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: !playing)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    Capsule().fill(.white.opacity(playing ? 0.8 : 0.4))
                        .frame(width: 2.5, height: playing ? 4 + 9 * abs(sin(t * (3.2 + Double(i) * 0.9) + Double(i) * 1.7)) : 3)
                }
            }
            .frame(width: 16, height: 14)
        }
        .animation(.smooth(duration: 0.3), value: playing)
    }
}

struct WidgetView: View {
    @ObservedObject var player: Player
    @ObservedObject var output = OutputModel.shared
    @ObservedObject var settings = Settings.shared

    var body: some View {
        let t = player.track
        VStack(spacing: player.expanded ? 6 : 8) {
            if player.expanded {
                ZStack {
                    VStack(spacing: 1) {
                        MarqueeText(text: t?.title ?? "Nothing playing", size: 13, weight: .semibold, alignment: .center)
                        Text(t?.artist ?? "Open Music or Spotify").font(.system(size: 12)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    }
                    .padding(.horizontal, 48)
                    HStack {
                        // back to the small widget
                        btn("arrow.down.right.and.arrow.up.left", 12) { withAnimation(Settings.shared.animation) { player.expanded = false } }
                        Spacer()
                        HStack(spacing: 10) {
                            // full-screen animated cover: only for albums that have one
                            if player.motionURL != nil {
                                btn(settings.fullCover ? "play.rectangle.fill" : "play.rectangle", 13) {
                                    withAnimation(Settings.shared.animation) { settings.fullCover.toggle() }
                                }
                            }
                            if settings.lyrics && (!player.lyrics.isEmpty || player.lyricsLoading) {
                                // lyrics: cover slides left and lyrics open on the right (turns full-screen off).
                                // Stays in place while the lookup runs (dim, inactive); filled only when lyrics are really showing.
                                let ready = !player.lyrics.isEmpty
                                btn(ready && player.lyricsOpen && !settings.fullCover ? "quote.bubble.fill" : "quote.bubble", 13) {
                                    withAnimation(Settings.shared.animation) {
                                        if settings.fullCover { settings.fullCover = false; player.lyricsOpen = true } else { player.lyricsOpen.toggle() }
                                    }
                                }
                                .opacity(ready ? 1 : 0.35)
                                .allowsHitTesting(ready)
                            }
                            if player.motionURL == nil && (!settings.lyrics || (player.lyrics.isEmpty && !player.lyricsLoading)) {
                                PlayingBars(playing: t?.playing == true)
                            }
                        }
                    }
                }
            } else {
                HStack(spacing: 10) {
                    Button { withAnimation(Settings.shared.animation) { player.expanded.toggle() } } label: {
                        Group {
                            if let art = player.art { Image(nsImage: art).resizable().scaledToFill() }
                            else { Color.white.opacity(0.15).overlay(Image(systemName: "music.note")) }
                        }
                        .frame(width: 50, height: 50).clipShape(RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.plain)
                    .opacity(player.thumbHidden ? 0 : 1)
                    VStack(alignment: .leading, spacing: 1) {
                        MarqueeText(text: t?.title ?? "Nothing playing", size: 13, weight: .semibold, alignment: .leading)
                        Text(t?.artist ?? "Open Music or Spotify").font(.system(size: 12)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    PlayingBars(playing: t?.playing == true)
                }
            }
            let dur = max(t?.duration ?? 1, 1)
            let frac = player.scrub ?? min(max((t?.position ?? 0) / dur, 0), 1)
            let shown = frac * dur
            HStack(spacing: 6) {
                Text(mmss(shown))
                // click anywhere to jump, drag to scrub; the seek is sent when you let go
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.25))
                        Capsule().fill(.white.opacity(0.85)).frame(width: max(0, g.size.width * frac))
                    }
                    .frame(height: player.scrub != nil ? 7 : 4)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { v in player.scrub = min(max(v.location.x / max(g.size.width, 1), 0), 1) }
                        .onEnded { v in
                            let f = min(max(v.location.x / max(g.size.width, 1), 0), 1)
                            player.seek(f)
                            player.scrub = nil
                        })
                    .animation(.easeOut(duration: 0.12), value: player.scrub != nil)
                }
                .frame(height: 16)
                Text("-" + mmss(dur - shown))
            }
            .font(.system(size: 9)).foregroundStyle(.white.opacity(0.7))
            HStack {
                btn(player.liked ? "heart.fill" : "heart", 17) { player.liked.toggle() }
                Spacer()
                btn("backward.fill", 19) { player.send("previous track") }
                Spacer()
                btn(t?.playing == true ? "pause.fill" : "play.fill", 24) { player.send("playpause") }
                Spacer()
                btn("forward.fill", 19) { player.send("next track") }
                Spacer()
                btn(output.currentSymbol, 17) { output.toggle() }
            }
            .padding(.horizontal, 6)
        }
        .animation(Settings.shared.animation, value: player.expanded)
        .foregroundStyle(.white)
        .padding(.horizontal, 16).padding(.vertical, player.expanded ? 8 : 14)
        .frame(width: player.expanded ? 260 : 290, height: player.expanded ? 108 : 150)  // card resizes inside the fixed window
        .background {
            // no blur on purpose: see-through tint + glass-style edge highlight
            glassBackground(26, faint: player.expanded)
        }
        .environment(\.colorScheme, .dark)
        .frame(width: 290, height: 150)
        .offset(x: player.cardOffset.width, y: -player.cardOffset.height)
        .frame(width: player.cardWindow.width, height: player.cardWindow.height, alignment: .bottomLeading)
        .animation(Settings.shared.animation, value: player.cardOffset)
    }

    func btn(_ name: String, _ size: CGFloat, _ action: @escaping () -> Void) -> some View {
        // The icon must move ONLY with the card. Its own symbol cross-fade (plain <-> filled) was drawn at the card's
        // destination while the card was still sliding there, so it appeared to jump ahead: no implicit animation inside.
        Button(action: action) {
            Image(systemName: name).font(.system(size: size))
                .contentTransition(.identity)
                .animation(nil, value: name)  // only the icon swap is un-animated; its movement with the card is untouched
        }
        .buttonStyle(.plain).foregroundStyle(.white.opacity(0.9))
    }
}

enum AnimStyle: String, CaseIterable { case smooth, snappy, bouncy, instant }
enum BackStyle: String, CaseIterable { case wavy, blur, sharp }
enum LyricStyle: String, CaseIterable { case line, full }  // full = Apple Music style

/// User-facing style options, persisted in UserDefaults.
@MainActor final class Settings: ObservableObject {
    static let shared = Settings()
    private let d = UserDefaults.standard
    @Published var open = false  // settings panel expanded (not persisted)
    @Published var anim: AnimStyle { didSet { d.set(anim.rawValue, forKey: "anim") } }
    @Published var back: BackStyle { didSet { d.set(back.rawValue, forKey: "back2") } }
    @Published var blur: Double { didSet { d.set(blur, forKey: "blur2") } }
    @Published var wave: Double { didSet { d.set(wave, forKey: "wave") } }
    @Published var lyricOffset: Double { didSet { d.set(lyricOffset, forKey: "lyricOffset") } }  // seconds the lyrics run ahead
    @Published var fullCover: Bool { didSet { d.set(fullCover, forKey: "fullCover") } }  // animated cover fills the screen, nothing else but the player
    @Published var lyrics: Bool { didSet { d.set(lyrics, forKey: "lyrics") } }
    @Published var lyricStyle: LyricStyle { didSet { d.set(lyricStyle.rawValue, forKey: "lyricStyle") } }

    init() {
        anim = .smooth  // option removed from the panel: fixed default
        back = .blur  // option removed from the panel: fixed default
        blur = 36
        wave = 1
        lyrics = d.object(forKey: "lyrics") as? Bool ?? true
        fullCover = d.bool(forKey: "fullCover")
        lyricOffset = d.object(forKey: "lyricOffset") as? Double ?? 1.5
        lyricStyle = .full  // lyrics are Apple Music style only, shown when the cover is expanded
    }

    var animation: Animation? {
        switch anim {
        case .smooth: .timingCurve(0.32, 0.72, 0, 1, duration: 0.65)
        case .snappy: .timingCurve(0.2, 0.9, 0.1, 1, duration: 0.38)
        case .bouncy: .spring(response: 0.55, dampingFraction: 0.68)
        case .instant: nil
        }
    }
    var settle: Double { duration + 0.05 }  // when the cover has landed back on the thumbnail
    var duration: Double { switch anim { case .smooth: 0.6; case .snappy: 0.35; case .bouncy: 0.6; case .instant: 0 } }
}

func glassBackground(_ r: CGFloat, faint: Bool = false) -> some View {
    let k = faint ? 0.45 : 1.0  // expanded card is nearly see-through, like Canopy
    return RoundedRectangle(cornerRadius: r).fill(LinearGradient(colors: [.white.opacity(0.16 * k), .white.opacity(0.04 * k)], startPoint: .top, endPoint: .bottom))
        .overlay(RoundedRectangle(cornerRadius: r).strokeBorder(LinearGradient(colors: [.white.opacity(0.55 * k), .white.opacity(0.08 * k), .white.opacity(0.3 * k)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
}

/// "Fri 16 Oct", the way the lock screen writes it for the user's locale.
func dateString(_ d: Date) -> String {
    let f = DateFormatter()
    f.setLocalizedDateFormatFromTemplate("EEE d MMM")
    return f.string(from: d)
}

/// The system's own big lock-screen clock (LoginUIKit's LUI2BigTimeViewController), configured from the user's saved
/// clock settings (font identifier + weight), same as the real lock screen. Private API: falls back if missing.
/// It hosts its own SwiftUI view, so it lives in its own window (nesting it in our SwiftUI crashes AttributeGraph).
enum SystemClock {
    static let loaded: Bool = dlopen("/System/Library/PrivateFrameworks/LoginUIKit.framework/Versions/A/LoginUIKit", RTLD_NOW) != nil
    /// The user's directory GUID, which LoginUIKit uses to find their clock settings.
    static let guid: String? = {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/dscl")
        p.arguments = [".", "-read", "/Users/\(NSUserName())", "GeneratedUID"]
        let pipe = Pipe()
        p.standardOutput = pipe
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return out.split(separator: " ").last.map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
    }()
    static var isAvailable: Bool {
        loaded && guid != nil && NSClassFromString("LoginUIKit.LUI2GlassTextView") != nil && NSClassFromString("LUIClockSettings") != nil
    }

    /// LoginUIKit's glass text view (what the lock screen draws its clock with). Used directly: its controller
    /// (LUI2BigTimeViewController) aborts inside SwiftUI when hosted in a window.
    static func makeView(frame: NSRect) -> NSView? {
        (NSClassFromString("LoginUIKit.LUI2GlassTextView") as? NSView.Type)?.init(frame: frame)
    }

    /// Must run AFTER the view is in an on-screen window, on a later runloop turn: configuring it earlier trips a
    /// SwiftUI AttributeGraph precondition (verified: same calls survive when made after the window is shown).
    static func configure(_ v: NSView, size: CGFloat) {
        guard let guid,
              let sCls = NSClassFromString("LUIClockSettings") as? NSObject.Type,
              let alloc = sCls.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue(),
              let settings = alloc.perform(NSSelectorFromString("initWithUserGUID:"), with: guid)?.takeUnretainedValue() as? NSObject,
              let fontName = settings.value(forKey: "bigClockFontName") as? String,
              let weight = settings.value(forKey: "bigClockFontWeight") as? Double,
              let m = class_getInstanceMethod(type(of: v), NSSelectorFromString("setDisplayFont:size:weight:"))
        else { return }
        typealias Fn = @convention(c) (AnyObject, Selector, AnyObject?, Double, Double) -> Void
        unsafeBitCast(method_getImplementation(m), to: Fn.self)(v, NSSelectorFromString("setDisplayFont:size:weight:"), fontName as NSString, Double(size), weight)
        v.setValue(NSTextAlignment.center.rawValue, forKey: "alignment")  // defaults to leading, which pushes the clock left
        v.perform(NSSelectorFromString("setDate:"), with: Date())
    }
}

/// The digits as a vector outline, so the system's real Liquid Glass can be applied to the text shape.
struct TextShape: Shape {
    var text: String
    var size: CGFloat
    func path(in rect: CGRect) -> Path {
        let base = NSFont.systemFont(ofSize: size, weight: .bold)
        let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        let glyphPath = CGMutablePath()
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
            let n = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: n), pos = [CGPoint](repeating: .zero, count: n)
            CTRunGetGlyphs(run, CFRangeMake(0, n), &glyphs)
            CTRunGetPositions(run, CFRangeMake(0, n), &pos)
            for i in 0..<n {
                if let g = CTFontCreatePathForGlyph(runFont, glyphs[i], nil) {
                    glyphPath.addPath(g, transform: CGAffineTransform(translationX: pos[i].x, y: pos[i].y))
                }
            }
        }
        let bb = glyphPath.boundingBoxOfPath  // CoreText is y-up: flip, then center in rect
        var t = CGAffineTransform(translationX: -bb.midX, y: -bb.midY)
            .concatenating(CGAffineTransform(scaleX: 1, y: -1))
            .concatenating(CGAffineTransform(translationX: rect.midX, y: rect.midY))
        return Path(glyphPath.copy(using: &t) ?? glyphPath)
    }
}

func clockString(_ d: Date) -> String {
    var h = Calendar.current.component(.hour, from: d)
    let m = Calendar.current.component(.minute, from: d)
    if (DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? "").contains("a") { h = h % 12 == 0 ? 12 : h % 12 }
    return String(format: "%d:%02d", h, m)
}

/// Current synced lyric line, one line at a time with a soft slide/fade between lines.
struct LyricsLineView: View {
    @ObservedObject var player: Player
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { ctx in
            let line = player.currentLyric(ctx.date) ?? ""
            Text(line).id(line)
                .font(.system(size: 21, weight: .semibold, design: .rounded))
                .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.7)
                .foregroundStyle(.white.opacity(0.92))
                .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                .animation(.smooth(duration: 0.35), value: line)
        }
        .clipped()
    }
}

/// Apple Music-style lyrics: the whole song scrolls, the current line is large and bright, the rest dim and softly blurred.
struct LyricsFullView: View {
    @ObservedObject var player: Player
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { ctx in
            let pos = player.livePosition(ctx.date) + Settings.shared.lyricOffset
            let idx = player.lyrics.lastIndex(where: { $0.t <= pos }) ?? 0
            // how far through an instrumental gap we are (drives the 3 intro dots), quantised so rows only redraw in steps
            let dots: Double = {
                guard player.lyrics.indices.contains(idx), player.lyrics[idx].text.isEmpty else { return 0 }
                let end = player.lyrics.indices.contains(idx + 1) ? player.lyrics[idx + 1].t : player.lyrics[idx].t + 6
                return (min(1, max(0, (pos - player.lyrics[idx].t) / max(0.1, end - player.lyrics[idx].t))) * 12).rounded() / 12
            }()
            LyricsList(lines: player.lyrics, current: idx, dotProgress: dots)
        }
    }
}

/// Apple Music's instrumental-gap indicator: three dots that fill in one by one.
struct IntroDots: View {
    var progress: Double
    var body: some View {
        HStack(spacing: 9) {
            ForEach(0..<3, id: \.self) { i in
                Circle().fill(.white.opacity(progress * 3 > Double(i) ? 0.95 : 0.35)).frame(width: 9, height: 9)
            }
        }
        .padding(.vertical, 14)
    }
}

struct LyricsList: View {
    var lines: [LyricLine]
    var current: Int
    var dotProgress: Double
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 26) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
                        let d = abs(i - current)
                        Group {
                            if l.text.isEmpty {
                                IntroDots(progress: d == 0 ? dotProgress : 0).opacity(d == 0 ? 1 : 0.5)
                            } else {
                                Text(l.text)
                                    .font(.system(size: 27, weight: .bold))
                                    .foregroundStyle(.white.opacity([1, 0.55, 0.38, 0.26][min(d, 3)]))  // fades gradually with distance from the current line
                                    .blur(radius: d == 0 ? 0 : min(CGFloat(d) * 0.5, 2))
                            }
                        }
                        .scaleEffect(d == 0 ? 1 : 0.93, anchor: .leading)  // current line grows into place
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // each line reacts a beat after its neighbour, so the change ripples outward like Apple Music
                        .animation(.spring(response: 0.55, dampingFraction: 0.82).delay(Double(min(d, 8)) * 0.03), value: current)
                        .id(i)
                    }
                }
                .padding(.vertical, 300)
            }
            .scrollDisabled(true)
            .onChange(of: current) { _, new in withAnimation(.spring(response: 0.65, dampingFraction: 0.9)) { proxy.scrollTo(new, anchor: UnitPoint(x: 0.5, y: 0.4)) } }
            .onAppear { proxy.scrollTo(current, anchor: UnitPoint(x: 0.5, y: 0.4)) }
        }
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.1), .init(color: .black, location: 0.85), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
    }
}

struct LyricsView: View {
    @ObservedObject var player: Player
    @ObservedObject var settings = Settings.shared
    var body: some View {
        if settings.lyricStyle == .full { LyricsFullView(player: player) } else { LyricsLineView(player: player) }
    }
}

struct AudioOut: Identifiable {
    let id: AudioDeviceID
    let name: String
    let symbol: String
    let isDefault: Bool
}

/// CoreAudio: list output devices and switch the system default output (Music and Spotify follow it).
enum AudioOutputs {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func addr(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func defaultOutput() -> AudioDeviceID {
        var a = addr(kAudioHardwarePropertyDefaultOutputDevice), id = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(system, &a, 0, nil, &size, &id)
        return id
    }

    static func setDefault(_ id: AudioDeviceID) {
        for sel in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultSystemOutputDevice] {
            var a = addr(sel), dev = id
            AudioObjectSetPropertyData(system, &a, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &dev)
        }
    }

    static func hasOutput(_ id: AudioDeviceID) -> Bool {
        var a = addr(kAudioDevicePropertyStreamConfiguration, kAudioDevicePropertyScopeOutput), size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return false }
        let buf = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { buf.deallocate() }
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, buf) == noErr else { return false }
        return UnsafeMutableAudioBufferListPointer(buf.assumingMemoryBound(to: AudioBufferList.self)).contains { $0.mNumberChannels > 0 }
    }

    static func name(_ id: AudioDeviceID) -> String? {
        var a = addr(kAudioObjectPropertyName), cf: Unmanaged<CFString>?, size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &cf) == noErr else { return nil }
        return cf?.takeRetainedValue() as String?
    }

    static func symbol(_ id: AudioDeviceID) -> String {
        var a = addr(kAudioDevicePropertyTransportType), t = UInt32(0), size = UInt32(4)
        AudioObjectGetPropertyData(id, &a, 0, nil, &size, &t)
        switch t {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "headphones"
        case kAudioDeviceTransportTypeBuiltIn: return "laptopcomputer"
        case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "tv"
        case kAudioDeviceTransportTypeUSB: return "hifispeaker"
        default: return "speaker.wave.2"
        }
    }

    static func devices() -> [AudioOut] {
        var a = addr(kAudioHardwarePropertyDevices), size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(system, &a, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &a, 0, nil, &size, &ids) == noErr else { return [] }
        let def = defaultOutput()
        return ids.compactMap { id in
            guard hasOutput(id), let n = name(id) else { return nil }
            return AudioOut(id: id, name: n, symbol: symbol(id), isDefault: id == def)
        }
    }
}

@MainActor final class OutputModel: ObservableObject {
    static let shared = OutputModel()
    @Published var open = false
    @Published var devices: [AudioOut] = []
    var currentSymbol: String { devices.first(where: \.isDefault)?.symbol ?? "headphones" }
    private var logged = false
    func refresh() {
        devices = AudioOutputs.devices()
        if !logged, !devices.isEmpty { logged = true; dlog("outputs: " + devices.map { "\($0.name)[\($0.symbol)\($0.isDefault ? ",default" : "")]" }.joined(separator: " | ")) }
    }
    func toggle() { open.toggle(); if open { refresh() } }
    func select(_ d: AudioOut) { AudioOutputs.setDefault(d.id); refresh(); open = false }
}

/// Inline output picker (a system menu would pop up behind the lock screen).
struct OutputView: View {
    @ObservedObject var model = OutputModel.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(model.devices.prefix(8)) { d in
                Button { model.select(d) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: d.symbol).frame(width: 20)
                        Text(d.name).lineLimit(1)
                        Spacer(minLength: 0)
                        if d.isDefault { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)) }
                    }
                    .font(.system(size: 13, weight: d.isDefault ? .semibold : .regular))
                    .padding(.horizontal, 10).frame(height: 34)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .foregroundStyle(.white)
        .padding(8)
        .background { ZStack { RoundedRectangle(cornerRadius: 18).fill(.black.opacity(0.32)); glassBackground(18) } }
        .environment(\.colorScheme, .dark)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
}

/// Top-left lock screen control: a button that expands into the style options.
struct SettingsView: View {
    @ObservedObject var player: Player
    @ObservedObject var settings = Settings.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { settings.open.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: settings.open ? "xmark" : "slider.horizontal.3").font(.system(size: settings.open ? 14 : 12, weight: .medium)).opacity(settings.open ? 1 : 0.55)
                    if settings.open { Text("Style").font(.system(size: 13, weight: .semibold)) }
                }
            }
            .buttonStyle(.plain)
            if settings.open {
                Toggle("Live lyrics", isOn: $settings.lyrics).toggleStyle(.switch).font(.system(size: 12))
                row("Lyrics timing  \(String(format: "%+.2f", settings.lyricOffset))s") { Slider(value: $settings.lyricOffset, in: -1...3) }
            }
        }
        .foregroundStyle(.white)
        .padding(settings.open ? 14 : 9)
        .frame(width: settings.open ? 270 : nil, alignment: .topLeading)
        .background { ZStack { RoundedRectangle(cornerRadius: 20).fill(.black.opacity(0.28)); glassBackground(20) } }
        .environment(\.colorScheme, .dark)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    func row<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11)).foregroundStyle(.white.opacity(0.65))
            c()
        }
    }
}

/// Soft colour blobs drifting slowly: two copies of the pre-blurred cover at different scales, rotating and sliding on
/// out-of-phase sine waves. Only transforms change per frame, so it stays smooth.
struct LivingBackdrop: View {
    var art: NSImage
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            GeometryReader { g in
                ZStack {
                    layer(g.size, scale: 1.15 + 0.04 * sin(t * 0.13), rot: 4 * sin(t * 0.11), dx: 40 * sin(t * 0.17), dy: 28 * cos(t * 0.13), opacity: 1)
                    layer(g.size, scale: 1.3 + 0.05 * cos(t * 0.10), rot: -5 * cos(t * 0.09), dx: -50 * cos(t * 0.15), dy: 32 * sin(t * 0.12), opacity: 0.35)
                }
            }
            .clipped()
        }
    }
    func layer(_ size: CGSize, scale: Double, rot: Double, dx: Double, dy: Double, opacity: Double) -> some View {
        Image(nsImage: art).resizable().interpolation(.high).scaledToFill()
            .frame(width: size.width, height: size.height)
            .scaleEffect(scale).rotationEffect(.degrees(rot)).offset(x: dx, y: dy).opacity(opacity)
    }
}

/// Album art cut into horizontal strips that slide sideways on moving sine waves (no Metal shader needed).
/// Drawn at quarter resolution and scaled up: it's blurred anyway, and full-res redraws made animations choppy.
struct WavyArt: View {
    var art: NSImage
    var wave: Double = 1
    var body: some View {
        GeometryReader { g in
            TimelineView(.animation(minimumInterval: 1.0 / 24)) { ctx in
                Canvas { gc, size in
                    let t = ctx.date.timeIntervalSinceReferenceDate
                    let img = gc.resolve(Image(nsImage: art))
                    let side = max(size.width, size.height) * 1.1  // overscan so the wave never shows an edge
                    let strips = 60, h = size.height / CGFloat(strips)
                    for i in 0..<strips {
                        let dx = (sin(t * 0.9 + Double(i) * 0.33) * 0.0095 + sin(t * 0.5 + Double(i) * 0.1) * 0.0054) * size.width * wave
                        var c = gc
                        c.clip(to: Path(CGRect(x: 0, y: CGFloat(i) * h, width: size.width, height: h + 1)))
                        c.draw(img, in: CGRect(x: (size.width - side) / 2 + dx, y: (size.height - side) / 2, width: side, height: side))
                    }
                }
                .frame(width: g.size.width / 4, height: g.size.height / 4)
                .scaleEffect(4)
                .frame(width: g.size.width, height: g.size.height)
            }
        }
    }
}

/// Layer-hosting view showing a shared AVPlayer; plays only while `playing`.
struct MotionCover: NSViewRepresentable {
    var player: AVPlayer
    var playing: Bool
    func makeNSView(context: Context) -> NSView {
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspectFill
        let v = NSView()
        v.layer = layer
        v.wantsLayer = true
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {
        if playing { player.play() } else { player.pause() }
    }
}

/// Full-screen layer shown while expanded. We cover the system lock UI, so we draw our own clock, date and hint.
/// The cover morphs out of the card's thumbnail with GPU transforms (scale + offset), driven by `player.revealed`.
struct BackdropView: View {
    @ObservedObject var player: Player
    @ObservedObject var settings = Settings.shared
    var body: some View {
        GeometryReader { g in
            if let art = player.art {
                let side = g.size.height * 0.40, s = 50 / side
                let r = player.revealed
                let full = settings.fullCover && player.motionPlayer != nil  // full-screen animated cover mode
                let sb = !full && player.expanded && player.lyricsOpen && settings.lyrics && settings.lyricStyle == .full && !player.lyrics.isEmpty  // side-by-side
                ZStack {
                    ZStack {
                        Group {
                            if full, let mp = player.motionPlayer {
                                if full {
                                    ZStack {
                                        // blurred copy fills the sides; the sharp square video sits in the middle, fitted to the screen height
                                        // soft fill without a live blur: draw the video tiny, scale it up (cheap on the GPU)
                                        MotionCover(player: mp, playing: r).frame(width: g.size.width / 8, height: g.size.height / 8)
                                            .scaleEffect(8 * 1.3)
                                            .frame(width: g.size.width, height: g.size.height)  // scaleEffect doesn't change layout size: restore full-screen
                                        MotionCover(player: mp, playing: r).frame(width: g.size.height, height: g.size.height)
                                            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.1), .init(color: .black, location: 0.9), .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing))
                                    }
                                    .frame(width: g.size.width, height: g.size.height)
                                }
                            } else {
                            switch settings.back {
                            case .wavy: WavyArt(art: art, wave: settings.wave).blur(radius: settings.blur)
                            case .blur: LivingBackdrop(art: player.softArt ?? art).frame(width: g.size.width, height: g.size.height)
                            case .sharp: Image(nsImage: art).resizable().scaledToFill().frame(width: g.size.width, height: g.size.height)
                            }
                            }
                        }
                        .overlay(Color.black.opacity(full ? 0.12 : 0.28)).clipped()
                        .scaleEffect(r ? 1 : 1.25)  // starts zoomed in and settles as it fades in
                        VStack(spacing: 0) {
                            VStack(spacing: 0) {
                                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                                    Text(dateString(ctx.date)).font(.system(size: 22, weight: .medium))
                                }
                                if SystemClock.isAvailable {
                                    Color.clear.frame(width: 560, height: 190)  // the system clock window (AppDelegate.clockPanel) sits here
                                } else {
                                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                                        let shape = TextShape(text: clockString(ctx.date), size: 150)
                                        // fallback, hand-drawn glass: all vector, no blur
                                        ZStack {
                                            shape.fill(LinearGradient(colors: [.white.opacity(0.36), .white.opacity(0.06), .white.opacity(0.18)], startPoint: .top, endPoint: .bottom))
                                            shape.stroke(.black.opacity(0.2), lineWidth: 3).offset(x: 1.5, y: 1.5).clipShape(shape)
                                            shape.fill(LinearGradient(colors: [.white.opacity(0.4), .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.4)))
                                            shape.stroke(LinearGradient(colors: [.white.opacity(0.95), .white.opacity(0.1), .white.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.6)
                                        }
                                        .frame(width: 560, height: 190)
                                        .shadow(color: .black.opacity(0.22), radius: 2, y: 2)
                                    }
                                }
                            }
                            .foregroundStyle(.white.opacity(0.9))
                            .padding(.top, 92)
                            Spacer()
                            Text("Touch ID or Enter Password").font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.white.opacity(full ? 0 : 0.6)).padding(.bottom, 28)
                        }
                    }
                    .opacity(r ? 1 : 0)  // (no animated full-screen blur: it forced a full-res GPU blur every frame)

                    ZStack {
                        Image(nsImage: art).resizable().interpolation(.high).scaledToFill()
                    }
                        .frame(width: side, height: side)
                        .clipShape(RoundedRectangle(cornerRadius: r ? 12 : 9 / s))
                        .blur(radius: r ? 0 : 8)  // cover starts soft and sharpens as it grows (small area, cheap)
                        .opacity(full ? 0 : 1)
                        .scaleEffect(r ? (sb ? 1.05 : 1) : s)
                        .offset(x: r ? (sb ? -0.25 * g.size.width : 0) : -104,
                                y: r ? 0 : g.size.height * 0.285 - 111)  // else: thumbnail's spot in the collapsed card
                }
                .animation(settings.animation, value: r)
                .animation(settings.animation, value: sb)
                .contentShape(Rectangle())
                .onTapGesture { player.expanded = false }
            }
        }
    }
}

struct StatusRow: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            if let b = battery() {
                Label("\(b.0)%", systemImage: b.1 ? "bolt.fill" : "battery.50percent")
                    .font(.system(size: 18, weight: .medium)).foregroundStyle(.white.opacity(0.8))
            }
        }
    }
    func battery() -> (Int, Bool)? {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        guard let src = (IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]).first,
              let d = IOPSGetPowerSourceDescription(info, src).takeUnretainedValue() as? [String: Any],
              let pct = d[kIOPSCurrentCapacityKey] as? Int else { return nil }
        return (pct, d[kIOPSIsChargingKey] as? Bool ?? false)
    }
}

/// Private SkyLight: a Space at a huge absolute level renders above the lock screen.
/// Debug logging and test hooks are off unless the app is started with LM_DEBUG=1 (log: ~/Library/Logs/LockMusic.log).
let debugOn = ProcessInfo.processInfo.environment["LM_DEBUG"] != nil

func dlog(_ m: String) {
    guard debugOn else { return }
    let line = "\(Date()) \(m)\n"
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/LockMusic.log")
    if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
    else { try? line.write(to: url, atomically: true, encoding: .utf8) }
}

enum SkyLight {
    static let h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    static func sym<T>(_ n: String) -> T? { dlsym(h, n).map { unsafeBitCast($0, to: T.self) } }
    static let conn: (@convention(c) () -> Int32)? = sym("SLSMainConnectionID")
    static let create: (@convention(c) (Int32, Int32, CFDictionary?) -> UInt64)? = sym("SLSSpaceCreate")
    static let level: (@convention(c) (Int32, UInt64, Int32) -> Int32)? = sym("SLSSpaceSetAbsoluteLevel")
    static let show: (@convention(c) (Int32, CFArray) -> Int32)? = sym("SLSShowSpaces")
    static let move: (@convention(c) (Int32, UInt64, CFArray, Int32) -> Void)? = sym("SLSSpaceAddWindowsAndRemoveFromSpaces")

    static let setLevel: (@convention(c) (Int32, UInt32, Int32) -> Int32)? = sym("SLSSetWindowLevel")
    static let spacesForWindows: (@convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?)? = sym("SLSCopySpacesForWindows")
    static let displaySpaces: (@convention(c) (Int32) -> Unmanaged<CFArray>?)? = sym("SLSCopyManagedDisplaySpaces")
    static let copySpaces: (@convention(c) (Int32, Int32) -> Unmanaged<CFArray>?)? = sym("SLSCopySpaces")
    static let spaceType: (@convention(c) (Int32, UInt64) -> Int32)? = sym("SLSSpaceGetType")
    static func newestLockSpace() -> UInt64? { conn.flatMap { systemSpace($0()) } }
    static var space: UInt64 = 0
    static var dumped = false

    /// Newest type-3 Space: created fresh at each lock (id 149, 151, ...), assumed to be the lock screen. Not listed by the managed-display call.
    static func systemSpace(_ cid: Int32) -> UInt64? {
        guard let spaceType, let all = copySpaces?(cid, 0xFFFF)?.takeRetainedValue() as? [NSNumber] else { return nil }
        let typed = all.map { ($0.uint64Value, spaceType(cid, $0.uint64Value)) }
        if !dumped { dumped = true; dlog("all spaces (id,type): \(typed)") }
        return typed.filter { $0.1 == 3 }.map { $0.0 }.max()
    }

    /// Current Space of the main display; while locked this is the lock screen's Space.
    static func displaySpace(_ cid: Int32) -> UInt64? {
        guard let arr = displaySpaces?(cid)?.takeRetainedValue() as? [[String: Any]] else { return nil }
        if !dumped { dumped = true; dlog("displays: \(arr)") }
        return ((arr.first?["Current Space"] as? [String: Any])?["id64"] as? NSNumber)?.uint64Value
    }

    /// The Space that loginwindow's lock-screen windows live in, if any.
    static func lockSpace(_ cid: Int32) -> UInt64? {
        guard let spacesForWindows,
              let all = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else { return nil }
        let lw = all.filter { ($0[kCGWindowOwnerName as String] as? String) == "loginwindow" }
        let ids = lw.compactMap { $0[kCGWindowNumber as String] as? Int }
        dlog("loginwindow windows: " + lw.map { "\($0[kCGWindowNumber as String] ?? "?")@layer\($0[kCGWindowLayer as String] ?? "?")" }.joined(separator: " "))
        for id in ids {
            guard let spaces = spacesForWindows(cid, 7, [id] as CFArray)?.takeRetainedValue() as? [NSNumber],
                  let sp = spaces.first else { continue }
            dlog("loginwindow wid=\(id) space=\(sp)")
            return sp.uint64Value
        }
        return nil
    }

    /// Returns false if the private symbols are missing (macOS changed) - caller falls back to a normal window.
    static func lift(_ window: NSWindow, level lvl: Int32 = Int32(CGShieldingWindowLevel()) + 1) -> Bool {
        guard let conn, let create, let level, let show, let move else { return false }
        let cid = conn()
        var target = systemSpace(cid) ?? displaySpace(cid)
        if target == nil {
            if space == 0 { space = create(cid, 1, nil); _ = level(cid, space, 2_147_483_647) }
            _ = show(cid, [space] as CFArray)
            target = space
        }
        move(cid, target!, [window.windowNumber] as CFArray, 7)
        let r3 = setLevel?(cid, UInt32(window.windowNumber), lvl) ?? -1
        return true
    }
}

final class Panel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func keyDown(with e: NSEvent) { if e.keyCode == 53 { orderOut(nil) } }  // esc
}

var hotKeyAction: (() -> Void)?

/// Carbon global hotkey: works without Accessibility permission. Not delivered while the screen is locked.
func installHotKey(keyCode: Int, modifiers: Int, _ action: @escaping () -> Void) {
    hotKeyAction = action
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
        DispatchQueue.main.async { hotKeyAction?() }
        return noErr
    }, 1, &spec, nil, nil)
    var ref: EventHotKeyRef?
    RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), EventHotKeyID(signature: OSType(0x4c4d5558), id: 1),
                        GetApplicationEventTarget(), 0, &ref)
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let player = Player()
    var item: NSStatusItem!
    var panel: Panel?
    var statusPanel: Panel?
    var backdrop: Panel?
    var clockPanel: Panel?
    var lastClockSecond = 0
    var lastState = ""
    var clockReady = false
    var clockHidden = false
    var lastFit = ""
    var settingsPanel: Panel?
    var lyricsPanel: Panel?
    var outputPanel: Panel?
    var artShown = false
    var toggleItem: NSMenuItem!
    var enabled = UserDefaults.standard.object(forKey: "enabled") as? Bool ?? true
    var laidOutExpanded = false
    var laidOutStyle = Settings.shared.lyricStyle
    var laidOutSide = false
    var cardOrigin = NSPoint.zero
    var cancellables = Set<AnyCancellable>()
    var lyricsShown = false
    var previewing = false
    var lastWant = false
    var notified = false
    var beat = 0
    var baseline: UInt64 = 0
    var lockedSince: Date?

    func applicationDidFinishLaunching(_ n: Notification) {
        // Layout reacts the instant a toggle changes (the SwiftUI cover already does), not on the next 0.15s tick.
        Publishers.Merge3(player.$lyricsOpen.map { _ in () }, player.$expanded.map { _ in () }, player.$lyrics.map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in MainActor.assumeIsolated { self?.tick() } }
            .store(in: &cancellables)
        _ = SystemClock.loaded; _ = SystemClock.guid  // resolve now: waiting on dscl inside a SwiftUI update aborts the app
        player.start()
        dlog("launch")
        ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "lock widget")
        for (name, v) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            DistributedNotificationCenter.default().addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in
                dlog("notification \(name)")
                MainActor.assumeIsolated { self?.notified = v; self?.tick() }
            }
        }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "LockMusic")
        let menu = NSMenu()
        toggleItem = menu.addItem(withTitle: "", action: #selector(toggleEnabled), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(withTitle: "Preview Lock Widget (8s)", action: #selector(preview), keyEquivalent: "l").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        refreshToggle()
        installHotKey(keyCode: kVK_ANSI_L, modifiers: controlKey | optionKey) { [weak self] in
            MainActor.assumeIsolated { self?.toggleEnabled() }
        }
        Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func locked() -> Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    // Failsafe: the panel exists only while locked (or during a timed preview).
    func tick() {
        beat += 1
                if debugOn, FileManager.default.fileExists(atPath: "/tmp/lockmusic-preview") {  // dev hook: touch the file to preview
            try? FileManager.default.removeItem(atPath: "/tmp/lockmusic-preview"); preview()
        }
        if debugOn, FileManager.default.fileExists(atPath: "/tmp/lockmusic-expand") {  // dev hook: touch the file to expand the cover
            try? FileManager.default.removeItem(atPath: "/tmp/lockmusic-expand"); player.expanded.toggle()
        }
        if debugOn, FileManager.default.fileExists(atPath: "/tmp/lockmusic-full") {  // dev hook: touch the file to toggle full-screen cover
            try? FileManager.default.removeItem(atPath: "/tmp/lockmusic-full"); Settings.shared.fullCover.toggle()
        }
        let stateNow = "expanded=\(player.expanded) lyricsOpen=\(player.lyricsOpen) full=\(Settings.shared.fullCover) motion=\(player.motionPlayer != nil) side=\(sideBySide) artShown=\(artShown) revealed=\(player.revealed)"
        if stateNow != lastState { lastState = stateNow; dlog("state: " + stateNow) }
        let isLocked = locked() || notified
        let want = (enabled && isLocked) || previewing
        if want != lastWant { lastWant = want; dlog("want=\(want) locked=\(isLocked)") }
        if !isLocked {
            lockedSince = nil
            baseline = SkyLight.newestLockSpace() ?? baseline
        } else if lockedSince == nil { lockedSince = Date() }
        // Wait for the fresh lock-screen Space (newer than the one seen while unlocked) so we don't beat the lock screen.
        let ready = !isLocked || previewing
            || (SkyLight.newestLockSpace() ?? 0) > baseline
            || Date().timeIntervalSince(lockedSince ?? Date()) > 1.5
        if want && ready && panel?.isVisible != true { show() }
        else if want && ready, let w = panel, let s = statusPanel { layoutSettings(); _ = SkyLight.lift(w); _ = SkyLight.lift(s); if let g = settingsPanel { _ = SkyLight.lift(g) }; if let l = lyricsPanel { _ = SkyLight.lift(l) } }
        if !want && panel?.isVisible == true { hide(); SkyLight.dumped = false }
        if panel != nil, Settings.shared.lyricStyle != laidOutStyle || sideBySide != laidOutSide { applyLayout(animated: true) }
        let showLyrics = Settings.shared.lyrics && !player.lyrics.isEmpty && player.expanded && !player.fullCoverActive && player.lyricsOpen && want && ready
        if showLyrics != lyricsShown {
            lyricsShown = showLyrics
            if showLyrics {
                // wait for the cover to slide left, then fade the lyrics in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self, self.lyricsShown else { return }
                    NSAnimationContext.runAnimationGroup { c in c.duration = 0.45; self.lyricsPanel?.animator().alphaValue = 1 }
                }
            } else {
                // clear out fast, before the cover slides back under them
                NSAnimationContext.runAnimationGroup { c in c.duration = 0.15; lyricsPanel?.animator().alphaValue = 0 }
            }
        }
        updateArt(visible: want && ready)
        if beat % 14 == 0 { OutputModel.shared.refresh() }  // keeps the button icon in step with the current output
        updateOutputPanel(show: OutputModel.shared.open && want && ready)
        // Watchdog: if the animated cover ever stalls or pauses while shown, resume it.
        if player.revealed, let mp = player.motionPlayer, mp.timeControlStatus == .paused { mp.play() }
        if player.fullCoverActive, artShown, beat % 14 == 0, let mp = player.motionPlayer {
            let it = mp.currentItem
            dlog("full-cover video: control=\(mp.timeControlStatus.rawValue) rate=\(mp.rate) item=\(it?.status.rawValue ?? -1) err=\(String(describing: it?.error)) size=\(String(describing: it?.presentationSize)) revealed=\(player.revealed)")
        }
    }

    /// Big album art above the player while `player.expanded`; click it to dismiss.
    func updateArt(visible: Bool) {
        guard let f = NSScreen.main?.frame else { return }
        let want = visible && player.expanded && player.art != nil
        if visible, panel != nil, player.expanded != laidOutExpanded { applyLayout(animated: true) }
        if want {
            if !artShown { artShown = true; presentArt(f) }
            if let b = backdrop { _ = SkyLight.lift(b, level: Int32(CGShieldingWindowLevel())) }
            if let c = clockPanel, c.isVisible {
                _ = SkyLight.lift(c)
                let sec = Int(Date().timeIntervalSince1970)
                if clockReady, sec != lastClockSecond { lastClockSecond = sec; c.contentView?.perform(NSSelectorFromString("setDate:"), with: Date()) }
                if clockReady { recenterClock() }

            }
        } else if artShown {
            artShown = false
            if visible { dismissArt() } else { backdrop?.orderOut(nil); clockPanel?.orderOut(nil); player.revealed = false; player.thumbHidden = false }
        }
        if !visible { player.expanded = false }
    }

    func presentArt(_ f: NSRect) {
        let b = backdrop ?? make(BackdropView(player: player), size: f.size)
        b.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))  // just under the card; covers the system lock UI (layer 2004)
        b.setFrame(f, display: true)
        player.revealed = false
        player.thumbHidden = true
        b.orderFrontRegardless()
        _ = SkyLight.lift(b, level: Int32(CGShieldingWindowLevel()))
        backdrop = b
        presentClock(f)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.player.revealed = true }  // next frame, so SwiftUI animates the change
    }

    /// The user's real lock-screen clock (their font + weight) in its own window above the backdrop.
    func presentClock(_ f: NSRect) {
        guard SystemClock.isAvailable else { return }
        let size = NSSize(width: 640, height: 200)
        var fresh = false
        if clockPanel == nil, let v = SystemClock.makeView(frame: NSRect(origin: .zero, size: size)) {
            let p = Panel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.contentView = v
            p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false; p.ignoresMouseEvents = true
            p.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            clockPanel = p; fresh = true
        }
        guard let p = clockPanel else { return }
        p.setFrameOrigin(NSPoint(x: (f.midX - size.width / 2).rounded(), y: (f.maxY - 98 - size.height).rounded()))
        p.alphaValue = 0
        p.orderFrontRegardless()
        _ = SkyLight.lift(p)
        if fresh, let v = p.contentView {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { SystemClock.configure(v, size: 138); self.clockReady = true; self.recenterClock() }  // 138 ~ the real lock clock (~96pt tall digits)
        }
        NSAnimationContext.runAnimationGroup { c in c.duration = max(0.05, Settings.shared.duration); p.animator().alphaValue = 1 }
    }

    /// The glass clock draws left-aligned inside its view, so size the window to the text and center that on screen.
    func recenterClock() {
        guard let p = clockPanel, let v = p.contentView, let f = NSScreen.main?.frame else { return }
        let inner = v.subviews.first
        var fit = inner?.fittingSize ?? v.fittingSize
        if fit.width < 60, let i = inner { fit = i.intrinsicContentSize }
        if "\(fit)" != lastFit { lastFit = "\(fit)"; dlog("clock sizes: view fitting=\(v.fittingSize) intrinsic=\(v.intrinsicContentSize); inner=\(String(describing: inner.map { type(of: $0) })) fitting=\(String(describing: inner?.fittingSize)) intrinsic=\(String(describing: inner?.intrinsicContentSize)) frame=\(String(describing: inner?.frame))") }
        guard fit.width > 100, fit.width < 1200 else { return }  // ignore the tiny pre-layout reading
        let w = ceil(fit.width), h = max(ceil(fit.height), 160)
        let r = NSRect(x: (f.midX - w / 2).rounded(), y: (f.maxY - 98 - h).rounded(), width: w, height: h)
        if p.frame != r { p.setFrame(r, display: false) }
    }

    func dismissArt() {
        player.revealed = false
        NSAnimationContext.runAnimationGroup { c in c.duration = max(0.05, Settings.shared.duration * 0.6); clockPanel?.animator().alphaValue = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + Settings.shared.settle) { [weak self] in
            if self?.artShown == false { self?.player.thumbHidden = false }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            if self?.artShown == false { self?.backdrop?.orderOut(nil); self?.clockPanel?.orderOut(nil) }
        }
    }

    @objc func toggleEnabled() {
        enabled.toggle()
        UserDefaults.standard.set(enabled, forKey: "enabled")
        refreshToggle()
        NSSound(named: enabled ? "Pop" : "Bottle")?.play()
    }

    func refreshToggle() {
        toggleItem.title = "Lock Widget: \(enabled ? "On" : "Off")   (^⌥L)"
        item.button?.appearsDisabled = !enabled
    }

    @objc func preview() {
        previewing = true
        show()
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { self.previewing = false }
    }

    func make(_ view: some View, size: NSSize) -> Panel {
        let p = Panel(contentRect: NSRect(origin: .zero, size: size),
                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.contentView = NSHostingView(rootView: view)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
        p.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        return p
    }

    func show() {
        guard let f = NSScreen.main?.frame else { return }
        let w = panel ?? make(WidgetView(player: player), size: NSSize(width: 290, height: 150))
        let s = statusPanel ?? make(StatusRow(), size: NSSize(width: 200, height: 30))
        panel = w; statusPanel = s
        let g = settingsPanel ?? make(SettingsView(player: player), size: NSSize(width: 36, height: 36))
        settingsPanel = g
        let l = lyricsPanel ?? make(LyricsView(player: player), size: NSSize(width: 620, height: 400))
        l.ignoresMouseEvents = true
        if lyricsPanel == nil { l.alphaValue = 0 }  // revealed by tick() only while expanded
        lyricsPanel = l
        layoutSettings()
        g.orderFrontRegardless()
        _ = SkyLight.lift(g)
        l.orderFrontRegardless()
        _ = SkyLight.lift(l)
        applyLayout()
        for p in [w, s] {
            p.orderFrontRegardless()
            if !SkyLight.lift(p) { NSLog("LockMusic: SkyLight symbols missing, using normal window level") }
        }
        panel = w; statusPanel = s
    }

    /// Output picker sits just above the player card, right-aligned with it (where the output button is).
    func updateOutputPanel(show: Bool) {
        guard show, let w = panel else { outputPanel?.orderOut(nil); return }
        let m = OutputModel.shared
        let rows = min(m.devices.count, 8)
        guard rows > 0 else { outputPanel?.orderOut(nil); return }
        let p = outputPanel ?? make(OutputView(), size: NSSize(width: 250, height: 100))
        let size = NSSize(width: 250, height: CGFloat(rows) * 36 + 16)
        let top = player.expanded ? cardOrigin.y + 129 : cardOrigin.y + 150          // top edge of the card
        let right = player.expanded ? cardOrigin.x + 145 + 130 : cardOrigin.x + 290  // right edge of the card
        let r = NSRect(x: (right - size.width).rounded(), y: (top + 8).rounded(), width: size.width, height: size.height)
        if p.frame != r { p.setFrame(r, display: true) }
        if !p.isVisible { p.orderFrontRegardless() }
        _ = SkyLight.lift(p)
        outputPanel = p
    }

    func layoutSettings() {
        guard let f = NSScreen.main?.frame, let g = settingsPanel else { return }
        let size = Settings.shared.open ? NSSize(width: 270, height: 170) : NSSize(width: 36, height: 36)
        let r = NSRect(x: f.minX + 28, y: f.maxY - 48 - size.height, width: size.width, height: size.height)
        if g.frame != r { g.setFrame(r, display: true) }
    }

    /// Expanded + Apple Music lyrics: cover and player on the left, lyrics on the right.
    var sideBySide: Bool {
        player.expanded && !player.fullCoverActive && player.lyricsOpen && Settings.shared.lyrics && Settings.shared.lyricStyle == .full && !player.lyrics.isEmpty
    }

    /// Apple-style ease-out (the iOS sheet curve).
    static let curve = CAMediaTimingFunction(controlPoints: 0.32, 0.72, 0, 1)

    /// Collapsed: player under the clock. Expanded: big cover mid-screen, compact player lower (like Canopy).
    func applyLayout(animated: Bool = false) {
        guard let f = NSScreen.main?.frame, let w = panel else { return }
        let e = player.expanded, sb = sideBySide
        // The card's window is one fixed strip covering every card position; the card slides inside it with a SwiftUI offset
        // (animating the window frame itself stuttered).
        let cx = (f.midX - 145).rounded(), lx = (f.minX + f.width * 0.25 - 145).rounded()
        let yLow = (f.minY + f.height * 0.12 - 21).rounded(), yHigh = (f.minY + f.height * 0.215).rounded()
        let x0 = min(cx, lx) - 8, y0 = yLow - 8
        let win = NSRect(x: x0, y: y0, width: max(cx, lx) + 290 + 8 - x0, height: yHigh + 150 + 8 - y0)
        if w.frame != win { w.setFrame(win, display: true) }
        player.cardWindow = win.size
        let origin: NSPoint = sb ? NSPoint(x: lx, y: (f.minY + f.height * 0.13 - 21).rounded())
            : e ? NSPoint(x: cx, y: yLow)
            : NSPoint(x: cx, y: yHigh)
        cardOrigin = origin
        let frame = NSRect(x: origin.x, y: origin.y, width: 290, height: 150)  // where the card sits (used to place the lyrics)
        player.cardOffset = CGSize(width: origin.x - win.minX, height: origin.y - win.minY)
        if animated && Settings.shared.duration > 0 {
            NSAnimationContext.runAnimationGroup { c in
                c.duration = Settings.shared.duration; c.timingFunction = Self.curve
                statusPanel?.animator().alphaValue = e ? 0 : 1
            }
        } else {
            statusPanel?.alphaValue = e ? 0 : 1
        }
        statusPanel?.setFrameOrigin(NSPoint(x: (f.midX - 100).rounded(), y: (f.minY + f.height * 0.72).rounded()))
        if sb {
            // below the clock (ends ~27% from the top), above the bottom edge: lyrics never reach the digits.
            // (Only placed here: moving it while it fades out made the text jump across the cover.)
            lyricsPanel?.setFrame(NSRect(x: (f.minX + f.width * 0.50).rounded(), y: (f.minY + f.height * 0.08).rounded(),
                                         width: (f.width * 0.28).rounded(), height: (f.height * 0.65).rounded()), display: true)
        }
        laidOutStyle = Settings.shared.lyricStyle
        laidOutSide = sb
        laidOutExpanded = e
    }

    func hide() { OutputModel.shared.open = false; outputPanel?.orderOut(nil); lyricsPanel?.orderOut(nil); Settings.shared.open = false; settingsPanel?.orderOut(nil); panel?.orderOut(nil); statusPanel?.orderOut(nil); backdrop?.orderOut(nil); clockPanel?.orderOut(nil); artShown = false; player.revealed = false; player.thumbHidden = false }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
