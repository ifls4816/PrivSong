import SwiftUI

struct MainPageToolbar: ViewModifier {
    let title: String

    func body(content: Content) -> some View {
        content
            .navigationTitle(title)
            .toolbarTitleDisplayMode(.large)
            .background(Color.musicPageBackground)
    }
}

extension View {
    func mainPageToolbar(_ title: String) -> some View {
        modifier(MainPageToolbar(title: title))
    }
}
