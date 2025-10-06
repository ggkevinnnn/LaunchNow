//
//  SwiftUIView.swift
//  LaunchNow
//
//  Created by gzk on 10/2/25.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import SwiftData

struct WelcomeView: View {
    @ObservedObject var appStore: AppStore

    var body: some View {
        VStack {
            VStack(alignment: .leading) {
                Text(NSLocalizedString("Welcome", comment: "Welcome"))
                    .font(.largeTitle)
                    .padding()
                Text(NSLocalizedString("Scroll", comment: "scroll"))
                Text(NSLocalizedString("Drag", comment: "drag"))
                Text(NSLocalizedString("Hover", comment: "hover"))
                Text(NSLocalizedString("RunOnBackground", comment: "RunOnBackGround"))
                Text(NSLocalizedString("Keyboard", comment: "Keyboard"))
            }
            .padding()
            
            Button {
                appStore.showWelcomeSheet = false
            } label: {
                Text(NSLocalizedString("StartNow", comment: "Start Now"))
                    .font(.title)
            }
            .padding()
        }
        .padding()
    }
}
