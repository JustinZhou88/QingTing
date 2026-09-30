import SwiftUI

@main
struct QingTingPhoneApp: App {
    @StateObject private var audio = PhoneController()

    var body: some Scene {
        WindowGroup {
            PhoneContentView().environmentObject(audio)
                .task { audio.startDemoIfRequested() }
        }
    }
}
