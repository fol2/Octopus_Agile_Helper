import AVKit
import OctopusHelperShared
import SwiftUI
import WebKit

#if os(iOS)
    struct YouTubeWebView: UIViewRepresentable {
        let videoID: String

        func makeUIView(context: Context) -> WKWebView {
            let webView = WKWebView()
            webView.scrollView.isScrollEnabled = false
            webView.backgroundColor = .clear
            webView.isOpaque = false
            return webView
        }

        func updateUIView(_ webView: WKWebView, context: Context) {
            loadYouTubeEmbed(into: webView)
        }
    }
#else
    struct YouTubeWebView: NSViewRepresentable {
        let videoID: String

        func makeNSView(context: Context) -> WKWebView {
            let webView = WKWebView()
            return webView
        }

        func updateNSView(_ webView: WKWebView, context: Context) {
            loadYouTubeEmbed(into: webView)
        }
    }
#endif

extension YouTubeWebView {
    func loadYouTubeEmbed(into webView: WKWebView) {
        let embedHTML = """
            <html>
            <head>
                <meta name="viewport" content="width=device-width, initial-scale=1">
                <style>
                    body { margin: 0; background-color: transparent; }
                    .video-container { position: relative; padding-bottom: 56.25%; height: 0; overflow: hidden; }
                    .video-container iframe { position: absolute; top: 0; left: 0; width: 100%; height: 100%; }
                </style>
            </head>
            <body>
                <div class="video-container">
                    <iframe width="100%" height="100%"
                        src="https://www.youtube.com/embed/\(videoID)"
                        frameborder="0"
                        allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture"
                        allowfullscreen>
                    </iframe>
                </div>
            </body>
            </html>
            """
        webView.loadHTMLString(embedHTML, baseURL: nil)
    }
}

struct MediaItemView: View {
    let item: MediaItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let caption = item.caption {
                Text(caption)
                    .font(Theme.subFont())
                    .foregroundColor(Theme.secondaryTextColor)
                    .textCase(.none)
                    .padding(.horizontal, 20)
            }

            if let youtubeID = item.youtubeID {
                YouTubeWebView(videoID: youtubeID)
                    .frame(maxWidth: .infinity)
                    .frame(height: 200)
                    .padding(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Theme.secondaryColor, lineWidth: 2)
                    )
            } else if let localName = item.localName {
                if item.isVideo {
                    if let videoURL = Bundle.main.url(forResource: localName, withExtension: "mp4")
                    {
                        VideoPlayer(player: AVPlayer(url: videoURL))
                            .frame(maxWidth: .infinity)
                            .frame(height: 200)
                            .padding(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Theme.secondaryColor, lineWidth: 2)
                            )
                    }
                } else {
                    Image(localName)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Theme.secondaryColor, lineWidth: 2)
                        )
                        .frame(maxWidth: .infinity)
                }
            } else if let remoteURL = item.remoteURL {
                if item.isVideo {
                    VideoPlayer(player: AVPlayer(url: remoteURL))
                        .frame(maxWidth: .infinity)
                        .frame(height: 200)
                        .padding(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Theme.secondaryColor, lineWidth: 2)
                        )
                } else {
                    AsyncImage(url: remoteURL) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .padding(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Theme.secondaryColor, lineWidth: 2)
                            )
                    } placeholder: {
                        ProgressView()
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }
}
