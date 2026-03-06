//
//  HoopReelApp.swift
//  HoopReel
//
//  Created by 陈晓鹏 on 2026/2/20.
//

import SwiftUI

@main
struct HoopReelApp: App {

    @StateObject private var langMgr = LanguageManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(langMgr)
        }
    }
}
