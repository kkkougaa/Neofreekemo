import SwiftUI

@main
struct LinkOpenerApp: App {
    var body: some Scene {
        WindowGroup {
            GuideView()
        }
    }
}

// The app has nothing to do by itself: it only says how to turn the extension on.
struct GuideView: View {
    var body: some View {
        NavigationView {
            List {
                Section {
                    Text("Safari에서 x.com · twitter.com 링크를 열면 NeoFreeBird 앱으로 바로 넘겨줘요.")
                }
                Section("켜는 방법") {
                    Label("설정 앱 → Safari → 확장 프로그램", systemImage: "1.circle")
                    Label("‘X 링크 열기’를 켜기", systemImage: "2.circle")
                    Label("x.com, twitter.com 접근을 ‘허용’으로", systemImage: "3.circle")
                }
                Section("참고") {
                    Text("링크를 열 때 ‘앱에서 여시겠습니까?’ 확인이 한 번 뜰 수 있어요.")
                    Text("카카오톡 같은 앱 안 브라우저에서는 동작하지 않아요. ‘Safari로 열기’를 한 번 거쳐 주세요.")
                }
            }
            .navigationTitle("X 링크 열기")
        }
        .navigationViewStyle(.stack)
    }
}
