//
//  SmartTubecontrollerApp.swift
//  SmartTubecontroller
//
//  Created by Akshay Cm on 11/6/26.
//

import SwiftUI

@main
struct SmartTubecontrollerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        // Set the window's initial and minimum size at the scene level. Applying a
        // min-size .frame directly on a NavigationSplitView fights the column/inspector
        // width constraints and triggers an infinite Auto Layout update loop (crash).
        .platformDefaultSize(width: 1040, height: 660)
        .platformWindowResizability(.contentMinSize)
    }
}
