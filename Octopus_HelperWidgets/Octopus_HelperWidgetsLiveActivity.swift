//
//  Octopus_HelperWidgetsLiveActivity.swift
//  Octopus_HelperWidgets
//
//  Created by James To on 31/12/2024.
//

import ActivityKit
import WidgetKit
import SwiftUI

struct Octopus_HelperWidgetsAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        // Dynamic stateful properties about your activity go here!
        var emoji: String
    }

    // Fixed non-changing properties about your activity go here!
    var name: String
}

struct Octopus_HelperWidgetsLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: Octopus_HelperWidgetsAttributes.self) { context in
            // Lock screen/banner UI goes here
            VStack {
                Text("Hello \(context.state.emoji)")
            }
            .activityBackgroundTint(Color.cyan)
            .activitySystemActionForegroundColor(Color.black)

        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded UI goes here.  Compose the expanded UI through
                // various regions, like leading/trailing/center/bottom
                DynamicIslandExpandedRegion(.leading) {
                    Text("Leading")
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("Trailing")
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("Bottom \(context.state.emoji)")
                    // more content
                }
            } compactLeading: {
                Text("L")
            } compactTrailing: {
                Text("T \(context.state.emoji)")
            } minimal: {
                Text(context.state.emoji)
            }
            .widgetURL(URL(string: "http://www.apple.com"))
            .keylineTint(Color.red)
        }
    }
}

extension Octopus_HelperWidgetsAttributes {
    fileprivate static var preview: Octopus_HelperWidgetsAttributes {
        Octopus_HelperWidgetsAttributes(name: "World")
    }
}

extension Octopus_HelperWidgetsAttributes.ContentState {
    fileprivate static var smiley: Octopus_HelperWidgetsAttributes.ContentState {
        Octopus_HelperWidgetsAttributes.ContentState(emoji: "😀")
     }
     
     fileprivate static var starEyes: Octopus_HelperWidgetsAttributes.ContentState {
         Octopus_HelperWidgetsAttributes.ContentState(emoji: "🤩")
     }
}
