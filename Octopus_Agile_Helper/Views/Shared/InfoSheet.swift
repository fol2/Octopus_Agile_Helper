import OctopusHelperShared
import SwiftUI

struct InfoSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @EnvironmentObject var globalSettings: GlobalSettingsManager
    @StateObject var viewModel: InfoSheetViewModel

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(viewModel.title)
                        .font(Theme.mainFont())
                        .foregroundColor(Theme.mainTextColor)
                        .textCase(.none)
                        .padding(.bottom, viewModel.isPremium ? 4 : 8)
                        .padding(.horizontal, 20)

                    if viewModel.isPremium {
                        HStack {
                            Image(systemName: "star.fill")
                                .foregroundColor(.yellow)
                                .font(Theme.subFont())
                            Text(LocalizedStringKey("Premium Feature"))
                                .font(Theme.titleFont())
                                .foregroundColor(Theme.mainTextColor)
                                .textCase(.none)
                        }
                        .padding(.bottom, 8)
                        .padding(.horizontal, 20)
                    }

                    Text(viewModel.message)
                        .font(Theme.secondaryFont())
                        .foregroundColor(Theme.secondaryTextColor)
                        .textCase(.none)
                        .padding(.horizontal, 20)

                    if !viewModel.mediaItems.isEmpty {
                        VStack(alignment: .leading, spacing: 24) {
                            ForEach(viewModel.mediaItems.indices, id: \.self) { index in
                                MediaItemView(item: viewModel.mediaItems[index])
                            }
                        }
                        .padding(.vertical, 8)
                    }

                    if let linkURL = viewModel.linkURL, let linkText = viewModel.linkText {
                        Link(destination: linkURL) {
                            HStack {
                                Text(linkText)
                                    .font(Theme.secondaryFont())
                                    .foregroundColor(Theme.mainColor)
                                    .textCase(.none)
                                Image(systemName: "arrow.up.right")
                                    .font(Theme.subFont())
                                    .foregroundColor(Theme.mainColor)
                            }
                        }
                        .padding(.top, 8)
                        .padding(.horizontal, 20)
                    }
                }
                .padding(.vertical, 16)
            }
            .background(Theme.mainBackground)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Text(LocalizedStringKey("Done"))
                            .font(Theme.secondaryFont())
                            .foregroundColor(Theme.mainColor)
                            .textCase(.none)
                    }
                }
            }
        }
        .environment(\.locale, locale)
    }
}

#Preview {
    InfoSheet(
        viewModel: InfoSheetViewModel(
            title: "Example Title",
            message: "This is an example message that explains something important.",
            mediaItems: [
                MediaItem(
                    localName: "example-image",
                    caption: "Example caption"
                ),
                MediaItem(
                    youtubeID: "dQw4w9WgXcQ",
                    caption: "Example YouTube video"
                ),
            ],
            linkURL: URL(string: "https://example.com"),
            linkText: "Learn more",
            isPremium: true
        )
    )
    .environmentObject(GlobalSettingsManager())
}
