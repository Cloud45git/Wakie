//
//  WakieApp.swift
//  Wakie
//
//  Created by Tushar Shaw on 16/11/2026.
//

import SwiftUI

@main
struct WakieApp: App {
    @State private var model = AppModel.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .preferredColorScheme(model.isNight ? .dark : .light)
                .task { model.start() }
        }
    }
}
